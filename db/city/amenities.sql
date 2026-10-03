-- Rebuild city.playgrounds, city.markets and city.building_amenity_access
-- from the raw portal data. Needs areas.sql and the building residents.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/amenities.sql
-- One transaction: either everything is rebuilt, or nothing changes.
--
-- Neither file is dated; both were published on 2026-03-09. The
-- playgrounds come from the programme for their repair, which marks new
-- ones from 2018.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, f.source_fid, f.properties AS p, ST_GeometryN(f.geom, 1) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('playgrounds', 'markets');

CREATE TEMP TABLE place ON COMMIT DROP AS
SELECT s.dataset, s.source_fid,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, s.geom) LIMIT 1) AS district_code,
       (SELECT n.id FROM neighbourhoods n WHERE ST_Intersects(n.geom, s.geom) LIMIT 1) AS neighbourhood_id,
       (SELECT u.id FROM planning_units u WHERE ST_Intersects(u.geom, s.geom) LIMIT 1) AS planning_unit_id
  FROM src s;

-- "―", "—" and "---" stand for nothing given.
CREATE FUNCTION pg_temp.given(v text) RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE WHEN btrim(v) IN ('', '―', '—', '-', '---') THEN NULL ELSE btrim(v) END $$;
CREATE FUNCTION pg_temp.num(v text) RETURNS integer IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE WHEN btrim(v) ~ '^\d+$' THEN btrim(v)::integer END $$;

DELETE FROM building_amenity_access;
DELETE FROM playgrounds;
DELETE FROM markets;

-- ---------------------------------------------------------- playgrounds

-- Left out: the 12 under repair measures that the register itself says
-- not to show, as technical errors, duplicates, a private plot, or one
-- replaced by three others. The 56 planned ones are kept as planned.
INSERT INTO playgrounds (id, number, location, status, measure, managed_by, ownership, age_groups,
                         area_m2, area_source, meets_regulation, shade, built, equipment, note,
                         source_district, geom, district_code, neighbourhood_id, planning_unit_id,
                         data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, pg_temp.given(s.p->>'nobekt_new'), pg_temp.given(s.p->>'new_mestopolozh'),
       CASE WHEN s.p->>'new_meropr' ~ '^новопредвид' THEN 'planned' ELSE 'existing' END,
       CASE WHEN s.p->>'new_meropr' ~ '^основен ремонт' THEN 'major repair'
            WHEN s.p->>'new_meropr' ~ '^частичен ремонт' THEN 'partial repair'
            WHEN s.p->>'new_meropr' ~ '^новоизградени' THEN 'new'
            WHEN s.p->>'new_meropr' ~ '^новопредвид' THEN 'planned' END,
       CASE s.p->>'stopanin' WHEN 'РА' THEN 'district' WHEN 'ДЗС' THEN 'green system directorate' END,
       pg_temp.given(s.p->>'new_sobstvenos'), pg_temp.given(s.p->>'new_vazrgrupi'),
       CASE WHEN btrim(s.p->>'new_plost') ~ '^\d+(\.\d+)?$' THEN btrim(s.p->>'new_plost')::numeric END,
       pg_temp.given(s.p->>'new_plost'),
       CASE WHEN lower(pg_temp.given(s.p->>'new_naredba1')) ~ '^да' THEN true
            WHEN lower(pg_temp.given(s.p->>'new_naredba1')) ~ '^не' THEN false END,
       CASE s.p->>'shadows' WHEN '1' THEN true WHEN '0' THEN false END,
       pg_temp.given(s.p->>'new_izgrazhdane'),
       nullif(jsonb_strip_nulls(jsonb_build_object(
           'swings', pg_temp.num(s.p->>'new_lulki'),
           'rockers', nullif(coalesce(pg_temp.num(s.p->>'new_klatush_0_3'), 0)
                             + coalesce(pg_temp.num(s.p->>'new_klatushka_3_12'), 0), 0),
           'climbing frames', pg_temp.num(s.p->>'new_katerushka'),
           'combined', nullif(coalesce(pg_temp.num(s.p->>'new_kombsaor_0_3'), 0)
                              + coalesce(pg_temp.num(s.p->>'new_kombsaor_3_12'), 0), 0),
           'sandpits', pg_temp.num(s.p->>'new_pyasachnik'),
           'play panels', pg_temp.num(s.p->>'new_igrovipanel'),
           'benches', pg_temp.num(s.p->>'new_parkmebel'),
           'fence', pg_temp.num(s.p->>'new_ograda'),
           'sign', pg_temp.num(s.p->>'new_inftabela'))), '{}'::jsonb),
       pg_temp.given(s.p->>'new_zabelezhka'), btrim(s.p->>'raion'), s.geom,
       x.district_code, x.neighbourhood_id, x.planning_unit_id,
       '2026-03-09', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'playgrounds'
   AND NOT (s.p->>'new_label' = 'не се показват на картата' AND s.p->>'new_meropr' ~ 'ремонт');

-- ---------------------------------------------------------- markets

-- The e-mail and phone fields are left out on purpose: they name people.
INSERT INTO markets (id, name, operator, address, website, note, source_district, geom,
                     district_code, neighbourhood_id, planning_unit_id,
                     data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, btrim(s.p->>'obekt_ime'), pg_temp.given(s.p->>'pazari'),
       pg_temp.given(s.p->>'obekt_adres'), pg_temp.given(s.p->>'website'),
       pg_temp.given(s.p->>'zabelzhka'), btrim(s.p->>'rayon'), s.geom,
       x.district_code, x.neighbourhood_id, x.planning_unit_id,
       '2026-03-09', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'markets';

-- ---------------------------------------------------------- distances

-- As in park_access.sql: the 5 nearest by index on a copy stretched so
-- that a degree of longitude is as long as one of latitude, then the
-- nearest of them in metres.
CREATE TEMP TABLE pg ON COMMIT DROP AS
SELECT id, geom, ST_Scale(geom, cos(radians(42.7)), 1) AS flat FROM playgrounds WHERE status = 'existing';
CREATE INDEX ON pg USING gist (flat);
CREATE TEMP TABLE mk ON COMMIT DROP AS
SELECT id, geom, ST_Scale(geom, cos(radians(42.7)), 1) AS flat FROM markets;
CREATE INDEX ON mk USING gist (flat);
ANALYZE pg;
ANALYZE mk;

INSERT INTO building_amenity_access (building_id, playground_id, playground_m, market_id, market_m)
SELECT b.id, p.id, round(p.d::numeric), m.id, round(m.d::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (SELECT ST_Scale(b.geom, cos(radians(42.7)), 1) AS flat) f
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM pg ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) p
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM mk ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) m;

COMMIT;

SELECT status, measure, count(*), count(district_code) AS in_city FROM playgrounds GROUP BY 1, 2 ORDER BY 1, 2;
SELECT count(*) AS markets, count(district_code) AS in_city FROM markets;
SELECT area_id, people, playgrounds, markets, playground_share_300, children_playground_share_300,
       market_share_1000, children_per_playground
  FROM area_amenity_access WHERE area_kind IN ('city', 'district') ORDER BY area_kind, area_id;
