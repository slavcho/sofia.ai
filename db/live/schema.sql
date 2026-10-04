-- The live feeds of Sofia's public transport, kept as history.
--
-- live.*   is filled every minute by poll_live.py from the GTFS-realtime
--          feeds of the Center for Urban Mobility (gtfs.sofiatraffic.bg).
--          Nothing is ever updated after its day has passed, so the
--          history can be read like any other dataset.
--
-- Apply with:  psql -v ON_ERROR_STOP=1 -d urbandata -f db/live/schema.sql
-- Safe to re-run: every object is created only if it is missing.
--
-- The big tables are partitioned by day (positions) or by month
-- (arrivals); live.ensure_partitions(day) makes the partitions for a day
-- and is called by poll_live.py on every run. Dropping an old partition
-- is the way to free space, should that ever be needed.

CREATE SCHEMA IF NOT EXISTS live;
SET search_path = live, public;

-- One row per fetch of a feed, failed or not. Punctuality must leave out
-- the minutes nothing was fetched, and this says which minutes those are.
CREATE TABLE IF NOT EXISTS fetches (
    id             bigserial PRIMARY KEY,
    feed           text NOT NULL CHECK (feed IN ('vehicle-positions', 'trip-updates')),
    fetched_at     timestamptz NOT NULL,      -- when the request was sent
    feed_timestamp timestamptz,               -- header.timestamp of the feed
    duration_ms    integer,                   -- request and write together
    bytes          integer,
    entities       integer,                   -- entities in the feed
    rows_written   integer,                   -- rows inserted or updated
    error          text                       -- NULL when the fetch succeeded
);
CREATE INDEX IF NOT EXISTS fetches_feed_time_idx ON fetches (feed, fetched_at);

-- Where every vehicle was. A vehicle that has not reported since the
-- previous fetch gives the same (vehicle_id, recorded_at) and is not
-- stored twice.
CREATE TABLE IF NOT EXISTS vehicle_positions (
    vehicle_id  text NOT NULL,                -- vehicle.vehicle.id, e.g. A3112
    recorded_at timestamptz NOT NULL,         -- vehicle.timestamp: when the vehicle reported
    fetch_id    bigint NOT NULL,              -- live.fetches(id); no FK on a partitioned table's hot path
    trip_id     text,                         -- as in gtfs.trips
    route_id    text,                         -- as in gtfs.routes
    stop_id     text,                         -- the stop it is at or heading to
    status      text,                         -- incoming / stopped / in transit
    lon         double precision NOT NULL,
    lat         double precision NOT NULL,
    speed       real,                         -- as given; km/h by the look of it
    occupancy   text,                         -- e.g. many seats available
    congestion  text,                         -- e.g. running smoothly
    PRIMARY KEY (vehicle_id, recorded_at)
) PARTITION BY RANGE (recorded_at);
-- Each partition gets these through the parent.
CREATE INDEX IF NOT EXISTS vehicle_positions_time_idx ON vehicle_positions (recorded_at);
CREATE INDEX IF NOT EXISTS vehicle_positions_trip_idx ON vehicle_positions (trip_id);

-- One row per trip, stop and service day. The trip updates only predict
-- times, so every fetch overwrites last_predicted; once the vehicle has
-- passed the stop it drops out of the feed, and the last prediction is
-- as close to the real arrival as the feed gets.
--
-- The scheduled time is copied in from gtfs.stop_times when the row is
-- made, so the history keeps its meaning after a new timetable is loaded
-- with other trip ids. It is NULL for trips not in the loaded timetable.
CREATE TABLE IF NOT EXISTS stop_arrivals (
    service_date    date NOT NULL,            -- the timetable day the trip belongs to
    trip_id         text NOT NULL,
    stop_id         text NOT NULL,            -- a stop occurs once per trip in this feed
    route_id        text,
    stop_sequence   integer,                  -- from gtfs.stop_times
    scheduled       timestamptz,              -- from gtfs.stop_times; NULL if the trip is unknown
    first_predicted timestamptz NOT NULL,     -- the first prediction seen
    first_seen      timestamptz NOT NULL,     -- when it was seen
    last_predicted  timestamptz NOT NULL,     -- the latest prediction seen
    last_seen       timestamptz NOT NULL,     -- when it was seen
    updates         integer NOT NULL DEFAULT 1, -- fetches that included this stop
    PRIMARY KEY (service_date, trip_id, stop_id)
) PARTITION BY RANGE (service_date);
CREATE INDEX IF NOT EXISTS stop_arrivals_stop_idx ON stop_arrivals (stop_id, service_date);
CREATE INDEX IF NOT EXISTS stop_arrivals_route_idx ON stop_arrivals (route_id, service_date);

-- Delay in seconds: positive is late. Only for stops already passed
-- (not seen in the latest trip-updates fetch), where last_predicted
-- stands for the arrival.
CREATE OR REPLACE VIEW passed_arrivals AS
SELECT a.*, extract(epoch FROM a.last_predicted - a.scheduled)::integer AS delay_s
  FROM stop_arrivals a
 WHERE a.scheduled IS NOT NULL
   AND a.last_seen < (SELECT max(fetched_at) FROM fetches
                       WHERE feed = 'trip-updates' AND error IS NULL);

-- Makes the partitions that hold `day`: that day's for the positions
-- (UTC days, as the timestamps are stored) and that month's for the
-- arrivals. Returns how many it created.
CREATE OR REPLACE FUNCTION ensure_partitions(day date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    month   date := date_trunc('month', day)::date;
    created integer := 0;
    name    text;
BEGIN
    name := 'vehicle_positions_' || to_char(day, 'YYYYMMDD');
    IF to_regclass('live.' || name) IS NULL THEN
        EXECUTE format('CREATE TABLE live.%I PARTITION OF live.vehicle_positions
                        FOR VALUES FROM (%L) TO (%L)',
                       name, day::text || ' 00:00:00+00', (day + 1)::text || ' 00:00:00+00');
        created := created + 1;
    END IF;
    name := 'stop_arrivals_' || to_char(month, 'YYYYMM');
    IF to_regclass('live.' || name) IS NULL THEN
        EXECUTE format('CREATE TABLE live.%I PARTITION OF live.stop_arrivals
                        FOR VALUES FROM (%L) TO (%L)',
                       name, month, (month + interval '1 month')::date);
        created := created + 1;
    END IF;
    RETURN created;
END $$;
