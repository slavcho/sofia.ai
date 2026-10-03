-- Rebuild city.census_addresses: NSI's 2011 census by address, geocoded
-- by Sofiaplan, linked to the cadastre outlines and the areas.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/census.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql and buildings.sql first.
--
-- Sources:
--   population-data   adresi_26_nsi_sofpr_20180227   NSI census 2011, geocoded 2018-02-27
--
-- data_as_of is the census reference day, 2011-02-01: the counts are
-- of then, only the geocoding is of 2018.
--
-- The address points sit at the street front, often outside the outline:
-- the nearest outline within 20 m is taken as the building (10 m for the
-- 2019 centroids in buildings.sql, which are inside their buildings),
-- a residential one if there is any. distance_m stays the distance to
-- the nearest outline of any kind.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, f.source_fid, f.properties AS p,
       ST_GeometryN(f.geom, 1) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name = 'population-data';
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

-- A count: NULL when missing or withheld (-1).
CREATE FUNCTION pg_temp.n(v text) RETURNS integer LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN v::numeric >= 0 THEN v::numeric::integer END $$;

DELETE FROM census_addresses;

CREATE TEMP TABLE area_parts ON COMMIT DROP AS
SELECT 'district' AS kind, code AS id, ST_Subdivide(geom, 64) AS geom FROM districts
UNION ALL SELECT 'neighbourhood', id::text, ST_Subdivide(geom, 64) FROM neighbourhoods
UNION ALL SELECT 'planning_unit', id::text, ST_Subdivide(geom, 64) FROM planning_units;
CREATE INDEX ON area_parts USING gist (geom);
ANALYZE area_parts;

INSERT INTO census_addresses (id, nsi_building_id, street, street_code, number, settlement_code,
                              district_label, people, dwellings, male, female,
                              age_0_14, age_15_24, age_25_34, age_35_44, age_45_54, age_55_64,
                              age_65_plus, edu_1, edu_2, edu_3, edu_4, edu_5,
                              born_bg, born_eu, born_non_eu, built_year,
                              building_id, match, distance_m, geom,
                              district_code, neighbourhood_id, planning_unit_id,
                              data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       nullif(s.p->>'buildingid', ''),
       nullif(btrim(s.p->>'nstreetnam'), ''),
       nullif(s.p->>'nstreetcod', ''),
       nullif(btrim(s.p->>'nnumber'), ''),
       nullif(s.p->>'ecode_settlem', ''),
       nullif(s.p->>'ecode_rayon', ''),
       pg_temp.n(s.p->>'nbroi_lica'), pg_temp.n(s.p->>'nn_jilisht'),
       pg_temp.n(s.p->>'nmale_sum'), pg_temp.n(s.p->>'nfemale_su'),
       pg_temp.n(s.p->>'nage0_14'), pg_temp.n(s.p->>'nage15_24'), pg_temp.n(s.p->>'nage25_34'),
       pg_temp.n(s.p->>'nage35_44'), pg_temp.n(s.p->>'nage45_54'), pg_temp.n(s.p->>'nage55_64'),
       pg_temp.n(s.p->>'nage65_'),
       pg_temp.n(s.p->>'nedu1_sum'), pg_temp.n(s.p->>'nedu2_sum'), pg_temp.n(s.p->>'nedu3_sum'),
       pg_temp.n(s.p->>'nedu4_sum'), pg_temp.n(s.p->>'nedu5_sum'),
       pg_temp.n(s.p->>'ncob_bg'), pg_temp.n(s.p->>'ncob_eu'), pg_temp.n(s.p->>'ncob_noneu'),
       nullif(pg_temp.n(s.p->>'nbuildingy'), 0),
       CASE WHEN i.id IS NOT NULL THEN i.id WHEN n.d <= 20 THEN coalesce(h.id, n.id) END,
       CASE WHEN i.id IS NOT NULL THEN 'inside' WHEN n.d <= 20 THEN 'nearest' ELSE 'none' END,
       CASE WHEN i.id IS NULL THEN round(n.d::numeric, 1) END,
       s.geom,
       (SELECT min(a.id) FROM area_parts a
         WHERE a.kind = 'district' AND ST_Intersects(a.geom, s.geom)),
       (SELECT min(a.id::integer) FROM area_parts a
         WHERE a.kind = 'neighbourhood' AND ST_Intersects(a.geom, s.geom)),
       (SELECT min(a.id::integer) FROM area_parts a
         WHERE a.kind = 'planning_unit' AND ST_Intersects(a.geom, s.geom)),
       DATE '2011-02-01', s.dataset, s.source_fid
  FROM src s
  LEFT JOIN LATERAL (SELECT c.id FROM buildings c
                      WHERE ST_Intersects(c.geom, s.geom) ORDER BY c.id LIMIT 1) i ON true
  LEFT JOIN LATERAL (SELECT c.id, ST_Distance(c.geom::geography, s.geom::geography) AS d
                       FROM buildings c
                      WHERE i.id IS NULL
                      ORDER BY c.geom <-> s.geom LIMIT 1) n ON true
  -- A garage or shed is often nearer the street than the house: prefer
  -- the nearest residential outline within 20 m.
  LEFT JOIN LATERAL (SELECT c.id FROM buildings c
                      WHERE i.id IS NULL AND c.category = 'residential'
                        AND c.geom && ST_Expand(s.geom, 0.0003)
                        AND ST_DWithin(c.geom::geography, s.geom::geography, 20)
                      ORDER BY ST_Distance(c.geom::geography, s.geom::geography) LIMIT 1) h ON true;
ANALYZE census_addresses;

COMMIT;

SELECT match, count(*), count(*) FILTER (WHERE people > 0) AS inhabited, sum(people) AS people
  FROM census_addresses GROUP BY match ORDER BY match;
SELECT census_people, residents_2019, residents_2019_vs_census, people_per_dwelling,
       census_share_0_14, census_share_65_plus, higher_education_share, born_abroad_share
  FROM area_census WHERE area_kind = 'city';
SELECT issue, count(*) FROM census_issues GROUP BY issue ORDER BY issue;
