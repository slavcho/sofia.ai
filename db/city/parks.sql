-- Rebuild city.parks and city.park_entrances from the raw portal data.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/parks.sql
-- One transaction: either everything is rebuilt, or nothing changes.
--
-- Sources (all Sofiaplan, section green-system):
--   public-parks-and-gardens   parkove_gradini_26_sofpr_20200914       outlines, zone, realization
--   public-parks-and-gardens   parkove_gradini_26_sofpr_20191001       names; parks missing in 2020
--   park-and-garden-entrances  parkove_gradini_vhod_26_sofpr_20200914  entrances
--   park-and-garden-entrances  parkove_gradini_vhod_26_sofpr_20191001  only to decode "size"
--
-- The 2020 entrances do not say what size 1/2/3 means. Matched to the
-- 2019 entrances within 5 m, 410 of 413 size 1 are "главен", 491 of 494
-- size 2 "второстепенен" and the size 3 ones "нерегламентиран".

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset,
       regexp_replace(l.source_path, '^.*__', '') AS file,
       f.source_fid, f.properties AS p,
       ST_CollectionExtract(ST_MakeValid(f.geom), CASE WHEN d.name = 'public-parks-and-gardens'
                                                       THEN 3 ELSE 1 END) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('public-parks-and-gardens', 'park-and-garden-entrances');
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

DELETE FROM park_entrances;
DELETE FROM parks;

-- ------------------------------------------------------------- parks

-- realiz 0 parks have no entrances (entr is NULL for all of them and 1
-- for all others), so they are taken as planned. Some of them exist on
-- the ground as unkept land, e.g. the western part of Западен парк.
INSERT INTO parks (id, name, name_source, kind, zone_code, status, realization,
                   outline, area_m2, tree_cover_pct, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::uuid,
       n.name,
       CASE WHEN n.name IS NOT NULL THEN 'public-parks-and-gardens, 2019 outline covering most of it' END,
       CASE substring(s.p->>'new_end' FROM '^[^*]+')
            WHEN 'Зп' THEN 'city_park' WHEN 'Тго' THEN 'local_garden' WHEN 'Тзсп' THEN 'special_green' END,
       s.p->>'new_end',
       CASE WHEN (s.p->>'realiz')::integer > 0 THEN 'existing' ELSE 'planned' END,
       (s.p->>'realiz')::integer,
       ST_Multi(s.geom),
       round(ST_Area(s.geom::geography)::numeric),
       (s.p->>'perc_tree_massifs')::numeric,
       DATE '2020-09-14', s.dataset, s.source_fid
  FROM src s
  -- The 2019 park that covers the largest part of this one, if over half.
  LEFT JOIN LATERAL (
       SELECT nullif(btrim(o.p->>'name_'), '') AS name
         FROM src o
        WHERE o.file = 'parkove_gradini_26_sofpr_20191001.geojson'
          AND o.geom && s.geom
          AND ST_Area(ST_Intersection(o.geom, s.geom)) > 0.5 * ST_Area(s.geom)
        ORDER BY ST_Area(ST_Intersection(o.geom, s.geom)) DESC
        LIMIT 1) n ON true
 WHERE s.file = 'parkove_gradini_26_sofpr_20200914.geojson';

-- 2019 parks the 2020 layer dropped (under 10 % covered by it) but whose
-- 2020 entrances are still there: Врана, most of Гео Милев, Негован, ...
INSERT INTO parks (id, name, name_source, kind, zone_code, status, realization,
                   outline, area_m2, tree_cover_pct, data_as_of, source_dataset, source_fid)
SELECT (o.p->>'id')::uuid,
       nullif(btrim(o.p->>'name_'), ''),
       CASE WHEN nullif(btrim(o.p->>'name_'), '') IS NOT NULL THEN 'public-parks-and-gardens, 2019' END,
       CASE o.p->>'function_'
            WHEN 'Градски паркове' THEN 'city_park'
            WHEN 'Градски градини' THEN 'local_garden'
            WHEN 'Квартални градини/ паркове' THEN 'local_garden' END,
       NULL, 'existing', NULL,
       ST_Multi(o.geom),
       round(ST_Area(o.geom::geography)::numeric),
       NULL,
       DATE '2019-10-01', o.dataset, o.source_fid
  FROM src o
 WHERE o.file = 'parkove_gradini_26_sofpr_20191001.geojson'
   AND coalesce((SELECT sum(ST_Area(ST_Intersection(k.geom, o.geom)))
                   FROM src k
                  WHERE k.file = 'parkove_gradini_26_sofpr_20200914.geojson'
                    AND k.geom && o.geom), 0) < 0.1 * ST_Area(o.geom)
   AND EXISTS (SELECT 1 FROM src e
                WHERE e.file = 'parkove_gradini_vhod_26_sofpr_20200914.geojson'
                  AND e.geom && ST_Expand(o.geom, 0.001)
                  AND ST_DWithin(e.geom::geography, o.geom::geography, 30));

-- --------------------------------------------------------- entrances

-- Each entrance goes to the nearest park within 30 m, an existing one
-- before a planned one (entrances sit on the edge, where parks meet).
INSERT INTO park_entrances (id, park_id, distance_m, kind, size_code, reglament, note,
                            geom, data_as_of, source_dataset, source_fid)
SELECT (e.p->>'id')::integer,
       k.id, round(k.d::numeric, 1),
       CASE (e.p->>'size')::integer WHEN 1 THEN 'main' WHEN 2 THEN 'secondary' WHEN 3 THEN 'unofficial' END,
       (e.p->>'size')::integer,
       (e.p->>'reglament')::integer,
       nullif(btrim(e.p->>'note'), ''),
       ST_GeometryN(e.geom, 1),
       DATE '2020-09-14', e.dataset, e.source_fid
  FROM src e
  LEFT JOIN LATERAL (
       SELECT k.id, ST_Distance(k.outline::geography, e.geom::geography) AS d
         FROM parks k
        WHERE k.outline && ST_Expand(e.geom, 0.001)
          AND ST_DWithin(k.outline::geography, e.geom::geography, 30)
        ORDER BY k.status = 'existing' DESC, d
        LIMIT 1) k ON true
 WHERE e.file = 'parkove_gradini_vhod_26_sofpr_20200914.geojson';

COMMIT;

SELECT status, kind, count(*), round(sum(area_m2) / 1e6, 2) AS km2,
       count(*) FILTER (WHERE data_as_of < DATE '2020-01-01') AS from_2019
  FROM parks GROUP BY 1, 2 ORDER BY 1, 2;
SELECT kind, count(*), count(park_id) AS with_park FROM park_entrances GROUP BY 1 ORDER BY 1;
SELECT issue, count(*) FROM park_issues GROUP BY 1 ORDER BY 1;
