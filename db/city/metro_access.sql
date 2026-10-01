-- Rebuild city.building_metro_access: for every inhabited building, the
-- nearest metro station now and with the planned stations.
-- Needs metro.sql and areas.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/metro_access.sql
--
-- Distances are straight lines to the station outline, not walking
-- routes; see the note on building_metro_access in schema.sql.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM building_metro_access;

-- Nearest by distance in metres. Not by <->: that is nearest in degrees,
-- and a degree of longitude is only 0.73 of a degree of latitude here,
-- which picked the wrong station for one building in six. With under a
-- hundred stations measuring them all is cheap enough.
INSERT INTO building_metro_access (building_id, station_id, distance_m,
                                   planned_station_id, planned_distance_m)
SELECT b.id, e.id, round(e.d::numeric), p.id, round(p.d::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (
       SELECT s.id, ST_Distance(s.outline::geography, b.geom::geography) AS d
         FROM metro_stations s
        WHERE s.status = 'existing'
        ORDER BY d LIMIT 1) e
  CROSS JOIN LATERAL (
       SELECT s.id, ST_Distance(s.outline::geography, b.geom::geography) AS d
         FROM metro_stations s
        ORDER BY d LIMIT 1) p;

COMMIT;

SELECT * FROM area_metro_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.people, a.share_500, a.share_1000, a.planned_share_500, a.planned_share_1000
  FROM area_metro_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.share_1000 DESC;
