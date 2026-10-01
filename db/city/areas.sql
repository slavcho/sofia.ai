-- Rebuild the city area tables (districts, neighbourhoods, planning units)
-- and the inhabited buildings from the raw portal data in urban.*.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/areas.sql
-- One transaction: either everything is rebuilt, or nothing changes.
--
-- Sources:
--   regions_sofia-zip                        regions_sofia.geojson  districts (GIS Sofia, 2026)
--   districts-of-sofia-municipality          districts_26_nag_20170101  the 2017 boundaries, for comparison
--   districts                                kvartali_26_sofpr_20190101  neighbourhoods (the slug is misleading)
--   urban-planning-units                     ge_26_sofpr_20200616   planning units
--   building-centroids-resident-count-800-m  residents per building, 2019
--   nsi-control-areas                        NSI population by control area, 2017

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset,
       regexp_replace(l.source_path, '^.*__', '') AS file,
       f.source_fid, f.properties AS p, ST_MakeValid(f.geom) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('regions_sofia-zip', 'districts-of-sofia-municipality', 'districts',
                  'urban-planning-units', 'nsi-control-areas')
    OR (d.name = 'building-centroids-resident-count-800-m'
        AND (f.properties->>'nn_people_')::numeric > 0);
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

DELETE FROM neighbourhood_districts;
DELETE FROM planning_unit_districts;
DELETE FROM building_residents;
DELETE FROM neighbourhoods;
DELETE FROM planning_units;
DELETE FROM districts;

-- --------------------------------------------------------- districts

-- Official names and transliteration, by district number. The sources
-- have them in capitals and with an ad-hoc Latin spelling.
INSERT INTO districts (code, name, name_latin, geom, area_km2, population_nsi,
                       boundary_diff_km2, data_as_of, source_dataset, source_fid)
SELECT n.code, n.name, n.latin,
       ST_Multi(ST_CollectionExtract(s.geom, 3)),
       round((ST_Area(s.geom::geography) / 1e6)::numeric, 2),
       (SELECT sum((c.p->>'nas_all')::numeric)::integer
          FROM src c WHERE c.dataset = 'nsi-control-areas' AND c.p->>'ecode_rayon' = n.code),
       (SELECT round((ST_Area(ST_SymDifference(s.geom, o.geom)::geography) / 1e6)::numeric, 2)
          FROM src o WHERE o.dataset = 'districts-of-sofia-municipality' AND o.p->>'obns_num' = n.code),
       DATE '2026-08-28', s.dataset, s.source_fid
  FROM src s
  JOIN (VALUES
        ('01', 'Средец', 'Sredets'),         ('02', 'Красно село', 'Krasno selo'),
        ('03', 'Възраждане', 'Vazrazhdane'), ('04', 'Оборище', 'Oborishte'),
        ('05', 'Сердика', 'Serdika'),        ('06', 'Подуяне', 'Poduyane'),
        ('07', 'Слатина', 'Slatina'),        ('08', 'Изгрев', 'Izgrev'),
        ('09', 'Лозенец', 'Lozenets'),       ('10', 'Триадица', 'Triaditsa'),
        ('11', 'Красна поляна', 'Krasna polyana'), ('12', 'Илинден', 'Ilinden'),
        ('13', 'Надежда', 'Nadezhda'),       ('14', 'Искър', 'Iskar'),
        ('15', 'Младост', 'Mladost'),        ('16', 'Студентски', 'Studentski'),
        ('17', 'Витоша', 'Vitosha'),         ('18', 'Овча купел', 'Ovcha kupel'),
        ('19', 'Люлин', 'Lyulin'),           ('20', 'Връбница', 'Vrabnitsa'),
        ('21', 'Нови Искър', 'Novi Iskar'),  ('22', 'Кремиковци', 'Kremikovtsi'),
        ('23', 'Панчарево', 'Pancharevo'),   ('24', 'Банкя', 'Bankya')
       ) AS n(code, name, latin)
    ON lpad(s.p->>'rn', 2, '0') = n.code
 WHERE s.dataset = 'regions_sofia-zip';

-- ---------------------------------------------------- neighbourhoods

-- type_kv as used in the source; the kinds are read from the names and
-- prefixes that occur with each code (ЖК./КВ., В.З., С., М. ...).
INSERT INTO neighbourhoods (id, name, prefix, kind, type_code, geom, area_km2,
                            data_as_of, source_dataset, source_fid)
SELECT (s.p->>'object_id')::integer,
       nullif(btrim(s.p->>'kvname'), '---'),
       nullif(nullif(btrim(s.p->>'prefname'), '---'), ''),
       CASE s.p->>'type_kv'
            WHEN '1' THEN 'residential'
            WHEN '2' THEN 'industrial'
            WHEN '3' THEN 'park'
            WHEN '4' THEN 'villa_zone'
            WHEN '5.1' THEN 'hamlet'
            WHEN '5.2' THEN 'locality'
            WHEN '6' THEN 'settlement'
            ELSE 'other' END,
       s.p->>'type_kv',
       ST_Multi(ST_CollectionExtract(s.geom, 3)),
       round((ST_Area(s.geom::geography) / 1e6)::numeric, 3),
       DATE '2019-01-01', s.dataset, s.source_fid
  FROM src s
 WHERE s.dataset = 'districts';

-- ---------------------------------------------------- planning units

INSERT INTO planning_units (id, name, district_label, geom, area_km2,
                            data_as_of, source_dataset, source_fid)
SELECT (s.p->>'object_id')::integer,
       btrim(s.p->>'regname'),
       nullif(btrim(s.p->>'rajon'), ''),
       ST_Multi(ST_CollectionExtract(s.geom, 3)),
       round((ST_Area(s.geom::geography) / 1e6)::numeric, 3),
       DATE '2020-06-16', s.dataset, s.source_fid
  FROM src s
 WHERE s.dataset = 'urban-planning-units';

-- ---------------------------------------------------------- residents

-- A point on a shared border is given to one area only (the first found).
INSERT INTO building_residents (id, people, households, age_0_14, age_65_plus,
                                floors, built_year, function, geom,
                                district_code, neighbourhood_id, planning_unit_id,
                                data_as_of, source_dataset, source_fid)
SELECT (b.p->>'id')::integer,
       (b.p->>'nn_people_')::numeric::integer,
       (b.p->>'nn_househ_')::numeric::integer,
       (b.p->>'nage_0_14')::numeric::integer,
       (b.p->>'nage_65_')::numeric::integer,
       nullif((b.p->>'floorcount')::numeric, 0)::integer,
       nullif((b.p->>'nbuild_y_')::numeric, 0)::integer,
       b.p->>'Функц',
       ST_GeometryN(b.geom, 1),
       (SELECT d.code FROM districts d
         WHERE ST_Intersects(d.geom, b.geom) ORDER BY d.code LIMIT 1),
       (SELECT n.id FROM neighbourhoods n
         WHERE ST_Intersects(n.geom, b.geom) ORDER BY n.id LIMIT 1),
       (SELECT u.id FROM planning_units u
         WHERE ST_Intersects(u.geom, b.geom) ORDER BY u.id LIMIT 1),
       DATE '2019-01-01', b.dataset, b.source_fid
  FROM src b
 WHERE b.dataset = 'building-centroids-resident-count-800-m';

UPDATE districts d
   SET population = (SELECT coalesce(sum(b.people), 0) FROM building_residents b
                      WHERE b.district_code = d.code);

-- ------------------------------------------------ area <-> districts

-- Parts under 1 % of an area are border slivers between the layers and
-- are left out, unless people live in them: then they are kept, so the
-- link tables add up to the full population.

INSERT INTO neighbourhood_districts (neighbourhood_id, district_code, share, population)
SELECT x.id, x.code, x.share,
       (SELECT coalesce(sum(b.people), 0) FROM building_residents b
         WHERE b.neighbourhood_id = x.id AND b.district_code = x.code)
  FROM (SELECT n.id, d.code,
               round((ST_Area(ST_Intersection(n.geom, d.geom)::geography)
                      / ST_Area(n.geom::geography))::numeric, 3) AS share
          FROM neighbourhoods n
          JOIN districts d ON ST_Intersects(n.geom, d.geom)) x
 WHERE x.share >= 0.01
    OR EXISTS (SELECT 1 FROM building_residents b
                WHERE b.neighbourhood_id = x.id AND b.district_code = x.code);

INSERT INTO planning_unit_districts (planning_unit_id, district_code, share, population)
SELECT x.id, x.code, x.share,
       (SELECT coalesce(sum(b.people), 0) FROM building_residents b
         WHERE b.planning_unit_id = x.id AND b.district_code = x.code)
  FROM (SELECT u.id, d.code,
               round((ST_Area(ST_Intersection(u.geom, d.geom)::geography)
                      / ST_Area(u.geom::geography))::numeric, 3) AS share
          FROM planning_units u
          JOIN districts d ON ST_Intersects(u.geom, d.geom)) x
 WHERE x.share >= 0.01
    OR EXISTS (SELECT 1 FROM building_residents b
                WHERE b.planning_unit_id = x.id AND b.district_code = x.code);

UPDATE neighbourhoods n
   SET (district_code, district_share) =
       (SELECT x.district_code, x.share FROM neighbourhood_districts x
         WHERE x.neighbourhood_id = n.id ORDER BY x.share DESC LIMIT 1),
       population = (SELECT coalesce(sum(b.people), 0) FROM building_residents b
                      WHERE b.neighbourhood_id = n.id);

UPDATE planning_units u
   SET (district_code, district_share) =
       (SELECT x.district_code, x.share FROM planning_unit_districts x
         WHERE x.planning_unit_id = u.id ORDER BY x.share DESC LIMIT 1),
       population = (SELECT coalesce(sum(b.people), 0) FROM building_residents b
                      WHERE b.planning_unit_id = u.id);

COMMIT;

SELECT 'districts' AS "table", count(*), sum(population) AS people FROM districts
UNION ALL SELECT 'neighbourhoods', count(*), sum(population) FROM neighbourhoods
UNION ALL SELECT 'planning units', count(*), sum(population) FROM planning_units
UNION ALL SELECT 'buildings', count(*), sum(people) FROM building_residents
UNION ALL SELECT 'neighbourhood districts', count(*), sum(population) FROM neighbourhood_districts
UNION ALL SELECT 'planning unit districts', count(*), sum(population) FROM planning_unit_districts;
SELECT issue, count(*) FROM area_issues GROUP BY 1 ORDER BY 1;
