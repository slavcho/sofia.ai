-- Rebuild city.building_education_access: for every inhabited building,
-- the nearest open kindergarten and school. Needs education.sql and
-- areas.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/education_access.sql
--
-- As in park_access.sql, the 5 nearest are found by index on a copy
-- stretched so that a degree of longitude is as long as one of latitude
-- (cos 42.7° = 0.735), and the nearest in metres is picked among them.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM building_education_access;

-- Closed and doubtful kindergartens and the "other" places do not count.
CREATE TEMP TABLE kg ON COMMIT DROP AS
SELECT k.id, k.funding, k.geom, ST_Scale(k.geom, cos(radians(42.7)), 1) AS flat
  FROM kindergartens k WHERE k.kind = 'kindergarten' AND k.status = 'open';
CREATE INDEX ON kg USING gist (flat);

CREATE TEMP TABLE sch ON COMMIT DROP AS
SELECT s.id, s.funding, s.geom, ST_Scale(s.geom, cos(radians(42.7)), 1) AS flat
  FROM schools s WHERE s.kind IN ('primary', 'basic', 'secondary');
CREATE INDEX ON sch USING gist (flat);
ANALYZE kg;
ANALYZE sch;

INSERT INTO building_education_access (building_id, kindergarten_id, kindergarten_distance_m,
                                       municipal_kindergarten_id, municipal_kindergarten_distance_m,
                                       school_id, school_distance_m,
                                       municipal_school_id, municipal_school_distance_m)
SELECT b.id, k.id, round(k.d::numeric), mk.id, round(mk.d::numeric),
       s.id, round(s.d::numeric), ms.id, round(ms.d::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (SELECT ST_Scale(b.geom, cos(radians(42.7)), 1) AS flat) f
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM kg ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) k
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM kg WHERE funding = 'municipal' ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) mk
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM sch ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) s
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM sch WHERE funding = 'municipal' ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) ms;

-- --------------------------------------------- Sofiaplan's own result

DELETE FROM school_access_sofiaplan;
DELETE FROM education_unserved_sofiaplan;

CREATE TEMP TABLE every_sch ON COMMIT DROP AS
SELECT s.id, s.geom, ST_Scale(s.geom, cos(radians(42.7)), 1) AS flat FROM schools s;
CREATE INDEX ON every_sch USING gist (flat);

-- The three reach polygons are huge; cut into pieces they can be indexed.
CREATE TEMP TABLE reach ON COMMIT DROP AS
SELECT (f.properties->>'tobreak')::numeric::integer AS within_m, f.source_fid, d.name AS dataset,
       ST_Subdivide(f.geom, 128) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name = 'school-accessibility-400-800-1200-2000-m'
   AND l.source_path LIKE '%uchilishta_merged_400_800_1200m_25_sofpr_20190000.geojson';
CREATE INDEX ON reach USING gist (geom);
ANALYZE every_sch;
ANALYZE reach;

INSERT INTO school_access_sofiaplan (building_id, sofiaplan_within_m, any_school_id, any_school_distance_m,
                                     data_as_of, source_dataset, source_fid)
SELECT b.id, z.within_m, s.id, round(s.d::numeric),
       DATE '2019-01-01', 'school-accessibility-400-800-1200-2000-m', z.source_fid
  FROM building_residents b
  LEFT JOIN LATERAL (
       SELECT within_m, source_fid FROM reach
        WHERE ST_Intersects(reach.geom, b.geom)
        ORDER BY within_m LIMIT 1) z ON true
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM every_sch ORDER BY flat <-> ST_Scale(b.geom, cos(radians(42.7)), 1) LIMIT 5) x
        ORDER BY d LIMIT 1) s;

INSERT INTO education_unserved_sofiaplan (id, name, district_name, people,
                                          kindergarten_unserved, kindergarten_unserved_pct,
                                          school_unserved, school_unserved_pct, geom,
                                          data_as_of, source_dataset, source_fid)
SELECT (f.properties->>'id')::uuid,
       f.properties->>'regname', f.properties->>'rajon',
       (f.properties->>'ppl_all')::numeric,
       (f.properties->>'dg_bez_dos')::numeric, (f.properties->>'dg_perc')::numeric,
       (f.properties->>'uch_bez_do')::numeric, (f.properties->>'uch_perc')::numeric,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(f.geom), 3)),
       DATE '2021-01-01', d.name, f.source_fid
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name = 'pedestrian-access-to-schools-and-municipal-kindergartens-share-of-unserved-population';

UPDATE education_unserved_sofiaplan u
   SET our_people = o.people,
       our_kindergarten_unserved_400 = o.kg_400, our_kindergarten_unserved_500 = o.kg_500,
       our_school_unserved_400 = o.sch_400, our_school_unserved_500 = o.sch_500
  FROM (SELECT u.id,
               sum(r.people) AS people,
               coalesce(sum(r.people) FILTER (WHERE a.municipal_kindergarten_distance_m > 400), 0) AS kg_400,
               coalesce(sum(r.people) FILTER (WHERE a.municipal_kindergarten_distance_m > 500), 0) AS kg_500,
               coalesce(sum(r.people) FILTER (WHERE a.school_distance_m > 400), 0) AS sch_400,
               coalesce(sum(r.people) FILTER (WHERE a.school_distance_m > 500), 0) AS sch_500
          FROM education_unserved_sofiaplan u
          JOIN building_residents r ON ST_Intersects(u.geom, r.geom)
          JOIN building_education_access a ON a.building_id = r.id
         GROUP BY u.id) o
 WHERE o.id = u.id;

COMMIT;

SELECT * FROM area_education_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.children, a.kindergarten_share_500, a.municipal_kindergarten_share_500,
       a.school_share_800, a.municipal_school_share_800, a.registered_per_child
  FROM area_education_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.kindergarten_share_500;
SELECT * FROM school_access_agreement WHERE area_kind = 'city';
SELECT round(100 * sum(kindergarten_unserved) / sum(people), 1) AS sofiaplan_kg_pct,
       round(100.0 * sum(our_kindergarten_unserved_400) / sum(our_people), 1) AS our_kg_400_pct,
       round(100.0 * sum(our_kindergarten_unserved_500) / sum(our_people), 1) AS our_kg_500_pct,
       round(100 * sum(school_unserved) / sum(people), 1) AS sofiaplan_school_pct,
       round(100.0 * sum(our_school_unserved_400) / sum(our_people), 1) AS our_school_400_pct,
       round(100.0 * sum(our_school_unserved_500) / sum(our_people), 1) AS our_school_500_pct,
       round(corr(kindergarten_unserved_pct, 100.0 * our_kindergarten_unserved_500 / our_people)::numeric, 3) AS kg_corr_500,
       round(corr(school_unserved_pct, 100.0 * our_school_unserved_500 / our_people)::numeric, 3) AS school_corr_500
  FROM education_unserved_sofiaplan WHERE our_people > 0;
