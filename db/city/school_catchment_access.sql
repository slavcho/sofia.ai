-- Rebuild city.building_school_catchment: each inhabited building in
-- the catchment of the nearest placed list address. Needs
-- school_catchments.sql and education.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/school_catchment_access.sql
--
-- The building points (2019) and the address points (2026) are both near
-- the building, 5 m apart at the median. Beyond 30 m the nearest address
-- is as likely a neighbour's across a catchment border, so such a
-- building is left out (6% of children).
-- Nearest addresses and schools are found as in park_access.sql, on a
-- copy stretched so that a degree of longitude is as long as one of
-- latitude, and the nearest in metres picked among the 5 closest.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM building_school_catchment;

CREATE TEMP TABLE addr ON COMMIT DROP AS
SELECT a.id, a.list_school_id, c.school_id, a.geom, ST_Scale(a.geom, cos(radians(42.7)), 1) AS flat
  FROM catchment_addresses a JOIN catchment_schools c ON c.list_id = a.list_school_id
 WHERE a.geom IS NOT NULL;
CREATE INDEX ON addr USING gist (flat);

-- The assigned schools are all СУ or ОУ: compare with the nearest of those.
CREATE TEMP TABLE sch ON COMMIT DROP AS
SELECT s.id, s.geom, ST_Scale(s.geom, cos(radians(42.7)), 1) AS flat
  FROM schools s WHERE s.kind IN ('basic', 'secondary');
CREATE INDEX ON sch USING gist (flat);
ANALYZE addr;
ANALYZE sch;

INSERT INTO building_school_catchment (building_id, address_id, address_distance_m, list_school_id,
                                       school_id, school_distance_m,
                                       nearest_school_id, nearest_school_distance_m)
SELECT b.id, a.id, round(a.d::numeric), a.list_school_id,
       a.school_id, round(ST_Distance(s.geom::geography, b.geom::geography)::numeric),
       n.id, round(n.d::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (SELECT ST_Scale(b.geom, cos(radians(42.7)), 1) AS flat) f
  CROSS JOIN LATERAL (
       SELECT x.id, x.list_school_id, x.school_id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM addr ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d, x.id LIMIT 1) a
  LEFT JOIN schools s ON s.id = a.school_id
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM sch ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) n
 WHERE a.d <= 30;

COMMIT;

SELECT * FROM area_school_catchment WHERE area_kind = 'city';
SELECT area_id, (SELECT name FROM districts WHERE code = area_id), children, known_share, assigned_share_800,
       assigned_nearest_share, assigned_farther_share, median_assigned_m
  FROM area_school_catchment WHERE area_kind = 'district' ORDER BY area_id;
