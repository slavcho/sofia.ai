-- Rebuild city.building_transit_access: for every inhabited building,
-- the served stops within 400 m and how often something leaves them.
-- Needs transit.sql and areas.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/transit_access.sql
--
-- Straight lines, not walking routes: an upper bound on reach, as for
-- the metro and the parks. The time windows are in schema.sql.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM building_transit_access;

CREATE TEMP TABLE windows (name text, day text, from_at timestamp, to_at timestamp, hours numeric) ON COMMIT DROP;
INSERT INTO windows
SELECT 'peak', day, date + time '07:00', date + time '09:00', 2 FROM transit_days WHERE day = 'weekday'
UNION ALL SELECT 'evening', day, date + time '20:00', date + time '23:00', 3 FROM transit_days WHERE day = 'weekday'
UNION ALL SELECT 'saturday', day, date + time '10:00', date + time '18:00', 8 FROM transit_days WHERE day = 'saturday'
UNION ALL SELECT 'sunday', day, date + time '10:00', date + time '18:00', 8 FROM transit_days WHERE day = 'sunday'
UNION ALL SELECT 'night', day, date + time '01:00', date + time '04:00', 3 FROM transit_days WHERE day = 'weekday';

-- Served stops within 400 m of each building. The box first (400 m is
-- 0.0036 degrees of latitude and 0.0049 of longitude here), then metres,
-- rounded as distance_m is so that the two agree.
CREATE TEMP TABLE near ON COMMIT DROP AS
SELECT b.id AS building_id, s.id AS stop_id
  FROM building_residents b
  JOIN transit_stops s ON s.served AND s.geom && ST_Expand(b.geom, 0.005)
 WHERE ST_DWithin(s.geom::geography, b.geom::geography, 401)
   AND round(ST_Distance(s.geom::geography, b.geom::geography)::numeric) <= 400;

-- Many buildings share the same stops; count trips once per set of stops.
CREATE TEMP TABLE sets ON COMMIT DROP AS
SELECT building_id, array_agg(stop_id ORDER BY stop_id) AS stops FROM near GROUP BY building_id;
CREATE TEMP TABLE set_ids ON COMMIT DROP AS
SELECT row_number() OVER () AS set_id, stops FROM (SELECT DISTINCT stops FROM sets) u;
CREATE TEMP TABLE set_stops ON COMMIT DROP AS
SELECT set_id, unnest(stops) AS stop_id FROM set_ids;
-- Only the departures in a window matter (and the weekday's, for lines).
CREATE TEMP TABLE window_trips ON COMMIT DROP AS
SELECT w.name, w.hours, d.stop_id, d.trip_id
  FROM windows w
  JOIN transit_departures d ON d.day = w.day AND d.at >= w.from_at AND d.at < w.to_at;
CREATE TEMP TABLE set_counts ON COMMIT DROP AS
SELECT i.stops, c.name, c.per_hour
  FROM set_ids i
  JOIN (SELECT s.set_id, t.name, round(count(DISTINCT t.trip_id) / min(t.hours), 1) AS per_hour
          FROM set_stops s JOIN window_trips t USING (stop_id)
         GROUP BY s.set_id, t.name
        UNION ALL
        SELECT s.set_id, 'routes', count(DISTINCT h.route_id)
          FROM set_stops s
          JOIN (SELECT DISTINCT stop_id, route_id FROM transit_departures WHERE day = 'weekday') h USING (stop_id)
         GROUP BY s.set_id) c USING (set_id);
CREATE INDEX ON set_counts (stops, name);

-- Sofiaplan's 0-400 m zone of 2021, cut into small pieces so a point
-- test does not walk the whole city-wide polygon.
CREATE TEMP TABLE sofiaplan ON COMMIT DROP AS
SELECT ST_Subdivide(f.geom, 64) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
 WHERE l.source_path LIKE 'mobility/accessibility-to-public-transport/%merged%'
   AND (f.properties->>'frombreak')::numeric = 0 AND (f.properties->>'tobreak')::numeric = 400;
CREATE INDEX ON sofiaplan USING gist (geom);

-- Served stops with a geometry where a degree is as long east-west as
-- north-south, so that <-> orders them by distance (see park_access.sql).
CREATE TEMP TABLE served ON COMMIT DROP AS
SELECT id, geom, ST_Scale(geom, cos(radians(42.7)), 1) AS flat FROM transit_stops WHERE served;
CREATE INDEX ON served USING gist (flat);
ANALYZE served;

INSERT INTO building_transit_access (building_id, stop_id, distance_m, stops_400, routes_400,
                                     peak_per_hour, evening_per_hour, saturday_per_hour,
                                     sunday_per_hour, night_per_hour, sofiaplan_400)
SELECT b.id, n.id, round(n.d::numeric),
       coalesce(cardinality(s.stops), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'routes'), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'peak'), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'evening'), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'saturday'), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'sunday'), 0),
       coalesce((SELECT c.per_hour FROM set_counts c WHERE c.stops = s.stops AND c.name = 'night'), 0),
       EXISTS (SELECT 1 FROM sofiaplan z WHERE ST_Intersects(z.geom, b.geom))
  FROM building_residents b
  LEFT JOIN sets s ON s.building_id = b.id
  -- Nearest in metres among the nearest few on the flattened map.
 CROSS JOIN LATERAL (
       SELECT k.id, ST_Distance(k.geom::geography, b.geom::geography) AS d
         FROM (SELECT t.id, t.geom FROM served t
                ORDER BY t.flat <-> ST_Scale(b.geom, cos(radians(42.7)), 1) LIMIT 5) k
        ORDER BY d LIMIT 1) n;

COMMIT;

SELECT * FROM area_transit_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.people, a.transit_share_400, a.frequent_share, a.evening_share,
       a.saturday_share, a.night_share, a.sofiaplan_transit_share_400, a.median_peak_per_hour
  FROM area_transit_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.frequent_share DESC;
