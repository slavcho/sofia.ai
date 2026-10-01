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

COMMIT;

SELECT * FROM area_education_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.children, a.kindergarten_share_500, a.municipal_kindergarten_share_500,
       a.school_share_800, a.municipal_school_share_800, a.registered_per_child
  FROM area_education_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.kindergarten_share_500;
