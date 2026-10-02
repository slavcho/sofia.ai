-- Rebuild the city.transit_* tables from the GTFS timetable (schema gtfs,
-- load with load_gtfs.py). Needs metro.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/transit.sql
--
-- The reference days are a Tuesday, Saturday and Sunday of an ordinary
-- week in October 2026, inside the feed's validity (2026-09-28 ..
-- 2027-09-28) and away from holidays.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM transit_departures;
DELETE FROM transit_stop_hours;
DELETE FROM transit_stops;
DELETE FROM transit_routes;
DELETE FROM transit_days;
DELETE FROM transit_feed_issues;

INSERT INTO transit_days VALUES ('weekday', '2026-10-06'), ('saturday', '2026-10-10'), ('sunday', '2026-10-11');

CREATE TEMP TABLE feed ON COMMIT DROP AS
SELECT f.downloaded_at::date AS data_as_of, 'gtfs-static'::text AS source_dataset FROM gtfs.feed f;

CREATE TEMP TABLE route_modes ON COMMIT DROP AS
SELECT route_id,
       CASE route_type WHEN '3' THEN 'bus' WHEN '11' THEN 'trolleybus' WHEN '0' THEN 'tram' WHEN '1' THEN 'metro' END AS mode
  FROM gtfs.routes;

-- Feed stop -> the stop people see. Surface stops of different modes
-- share the code on the sign; metro stations have codes of their own
-- that could clash with them, so they keep their stop_id.
CREATE TEMP TABLE stop_key ON COMMIT DROP AS
SELECT stop_id, CASE WHEN stop_id ~ '^M\d' OR stop_code IS NULL THEN stop_id ELSE stop_code END AS key,
       stop_code, stop_name,
       ST_SetSRID(ST_MakePoint(stop_lon::float8, stop_lat::float8), 4326) AS geom
  FROM gtfs.stops
 WHERE coalesce(location_type, '0') = '0';

-- Every call of every trip that falls on a reference day, by clock time.
-- The previous day's timetable is included for its trips past midnight.
CREATE TEMP TABLE calls ON COMMIT DROP AS
WITH dates AS (
    SELECT day, date, date AS service_date FROM transit_days
    UNION ALL SELECT day, date, date - 1 FROM transit_days
), last AS (
    SELECT trip_id, max(stop_sequence::integer) AS seq FROM gtfs.stop_times GROUP BY trip_id
)
SELECT d.day, t.trip_id, t.route_id, t.trip_headsign AS headsign, k.key AS stop_id,
       d.service_date + make_interval(secs => split_part(st.departure_time, ':', 1)::integer * 3600
                                            + split_part(st.departure_time, ':', 2)::integer * 60
                                            + split_part(st.departure_time, ':', 3)::integer) AS at,
       st.stop_sequence::integer = l.seq AS is_last
  FROM dates d
  JOIN gtfs.calendar_dates c ON c.date = to_char(d.service_date, 'YYYYMMDD') AND c.exception_type = '1'
  JOIN gtfs.trips t ON t.service_id = c.service_id
  JOIN gtfs.stop_times st ON st.trip_id = t.trip_id
  JOIN last l ON l.trip_id = t.trip_id
  JOIN stop_key k ON k.stop_id = st.stop_id;
DELETE FROM calls c USING transit_days d WHERE d.day = c.day AND c.at::date <> d.date;
CREATE INDEX ON calls (stop_id);
ANALYZE calls;

INSERT INTO transit_stops (id, code, name, modes, gtfs_stop_ids, served, geom, data_as_of, source_dataset)
SELECT k.key, min(k.stop_code),
       mode() WITHIN GROUP (ORDER BY k.stop_name),
       coalesce((SELECT array_agg(DISTINCT m.mode ORDER BY m.mode)
                   FROM calls c JOIN route_modes m USING (route_id) WHERE c.stop_id = k.key), '{}'),
       array_agg(k.stop_id ORDER BY k.stop_id),
       EXISTS (SELECT 1 FROM calls c WHERE c.stop_id = k.key),
       ST_Centroid(ST_Collect(k.geom)),
       (SELECT data_as_of FROM feed), (SELECT source_dataset FROM feed)
  FROM stop_key k
 GROUP BY k.key;

-- Metro stops to our station outlines by location: the names differ
-- (see transit_issues).
UPDATE transit_stops s
   SET metro_station_id = (SELECT m.id FROM metro_stations m
                            WHERE m.status = 'existing'
                              AND ST_DWithin(m.outline::geography, s.geom::geography, 300)
                            ORDER BY ST_Distance(m.outline::geography, s.geom::geography) LIMIT 1)
 WHERE s.id ~ '^M\d';

-- A route's line is the shapes its trips run on the reference days.
CREATE TEMP TABLE shape_lines ON COMMIT DROP AS
SELECT shape_id, ST_MakeLine(ST_SetSRID(ST_MakePoint(shape_pt_lon::float8, shape_pt_lat::float8), 4326)
                             ORDER BY shape_pt_sequence::integer) AS geom
  FROM gtfs.shapes
 WHERE shape_id IN (SELECT DISTINCT t.shape_id FROM gtfs.trips t JOIN calls c USING (trip_id))
 GROUP BY shape_id;

INSERT INTO transit_routes (id, name, long_name, mode, color, text_color, night,
                            trips_weekday, trips_saturday, trips_sunday, geom, data_as_of, source_dataset)
SELECT r.route_id, r.route_short_name, r.route_long_name, m.mode, r.route_color, r.route_text_color,
       r.route_short_name ~ '^N\d',
       (SELECT count(DISTINCT trip_id) FROM calls c WHERE c.route_id = r.route_id AND c.day = 'weekday'),
       (SELECT count(DISTINCT trip_id) FROM calls c WHERE c.route_id = r.route_id AND c.day = 'saturday'),
       (SELECT count(DISTINCT trip_id) FROM calls c WHERE c.route_id = r.route_id AND c.day = 'sunday'),
       (SELECT ST_Multi(ST_Collect(l.geom)) FROM shape_lines l
         WHERE l.shape_id IN (SELECT t.shape_id FROM gtfs.trips t WHERE t.route_id = r.route_id)),
       (SELECT data_as_of FROM feed), (SELECT source_dataset FROM feed)
  FROM gtfs.routes r JOIN route_modes m USING (route_id);

INSERT INTO transit_departures (day, stop_id, route_id, trip_id, headsign, at)
SELECT day, stop_id, route_id, trip_id, headsign, at FROM calls WHERE NOT is_last;
ANALYZE transit_departures;

INSERT INTO transit_stop_hours (stop_id, day, hour, departures, route_ids)
SELECT stop_id, day, extract(hour FROM at)::integer, count(*), array_agg(DISTINCT route_id ORDER BY route_id)
  FROM transit_departures
 GROUP BY 1, 2, 3;

-- What the feed as a whole lacks (see DATA_ISSUES.md).
INSERT INTO transit_feed_issues (issue, detail)
SELECT 'no accessibility data',
       format('%s of %s trips have wheelchair_accessible 0 (unknown); stops.txt has no wheelchair_boarding',
              count(*) FILTER (WHERE coalesce(wheelchair_accessible, '0') = '0'), count(*))
  FROM gtfs.trips
UNION ALL
SELECT 'no trip direction',
       format('%s of %s trips have no direction_id', count(*) FILTER (WHERE direction_id IS NULL), count(*))
  FROM gtfs.trips
UNION ALL
SELECT 'calendar from before the feed',
       format('the calendar starts on %s, the feed on %s: %s dates of %s services are past',
              min(c.date), i.start, count(*) FILTER (WHERE c.date < i.start),
              count(DISTINCT c.service_id) FILTER (WHERE c.date < i.start))
  FROM gtfs.calendar_dates c
 CROSS JOIN (SELECT feed_start_date AS start FROM gtfs.feed_info) i
 GROUP BY i.start
UNION ALL
SELECT 'all times are estimates',
       format('%s of %s stop times have timepoint 0 (approximate)',
              count(*) FILTER (WHERE timepoint = '0'), count(*))
  FROM gtfs.stop_times
UNION ALL
SELECT 'one stop under several ids',
       format('%s stop codes are used by several stop ids (one per mode), merged into one stop',
              count(*) FILTER (WHERE cardinality(gtfs_stop_ids) > 1))
  FROM transit_stops;

COMMIT;

SELECT * FROM transit_days;
SELECT count(*) AS stops, count(*) FILTER (WHERE served) AS served,
       count(*) FILTER (WHERE cardinality(gtfs_stop_ids) > 1) AS merged,
       count(*) FILTER (WHERE metro_station_id IS NOT NULL) AS metro_matched
  FROM transit_stops;
-- How far apart the merged stops are: one pole should be a few metres.
SELECT s.id, s.name, s.gtfs_stop_ids,
       round(max(ST_Distance(ST_MakePoint(g.stop_lon::float8, g.stop_lat::float8)::geography,
                             s.geom::geography))::numeric) AS spread_m
  FROM transit_stops s CROSS JOIN unnest(s.gtfs_stop_ids) u(stop_id) JOIN gtfs.stops g USING (stop_id)
 WHERE cardinality(s.gtfs_stop_ids) > 1
 GROUP BY 1, 2, 3 ORDER BY spread_m DESC LIMIT 5;
SELECT mode, count(*) AS routes, sum(trips_weekday) AS weekday, sum(trips_saturday) AS saturday,
       sum(trips_sunday) AS sunday, count(*) FILTER (WHERE geom IS NULL) AS no_shape
  FROM transit_routes GROUP BY mode ORDER BY mode;
SELECT issue, count(*), min(detail) FROM transit_issues GROUP BY issue ORDER BY issue;
