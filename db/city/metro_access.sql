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

-- The <-> ordering uses the spatial index to find the nearest outline
-- in degrees; the distance is then measured in metres.
INSERT INTO building_metro_access (building_id, station_id, distance_m,
                                   planned_station_id, planned_distance_m)
SELECT b.id,
       e.id, round(ST_Distance(e.outline::geography, b.geom::geography)::numeric),
       p.id, round(ST_Distance(p.outline::geography, b.geom::geography)::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (
       SELECT s.id, s.outline FROM metro_stations s
        WHERE s.status = 'existing'
        ORDER BY s.outline <-> b.geom LIMIT 1) e
  CROSS JOIN LATERAL (
       SELECT s.id, s.outline FROM metro_stations s
        ORDER BY s.outline <-> b.geom LIMIT 1) p;

COMMIT;

SELECT * FROM area_metro_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.people, a.share_500, a.share_1000, a.planned_share_500, a.planned_share_1000
  FROM area_metro_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.share_1000 DESC;
