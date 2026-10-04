#!/usr/bin/env python3
"""Fetch the GTFS-realtime feeds of Sofia's public transport into schema live.

  python3 poll_live.py            # both feeds, once
  python3 poll_live.py --feed vehicle-positions

Meant to run every minute from cron (see README):

  * * * * * cd ~/work/ai.sofia && flock -n /tmp/poll_live.lock python3 poll_live.py >> logs/live.log 2>&1

Every fetch is logged in live.fetches, failed ones too, so that gaps in
the history are known. Each feed is written in its own transaction: a
failure of one does not lose the other.

- vehicle-positions: one row per vehicle report in live.vehicle_positions.
- trip-updates: the predicted time of every trip and stop goes into
  live.stop_arrivals, which keeps the first and the latest prediction
  and the scheduled time from gtfs.stop_times (see db/live/schema.sql).

Needs db/live/schema.sql applied, and the static timetable (load_gtfs.py)
for the scheduled times. Connection: --dsn or $DATABASE_URL.
"""
import argparse
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import psycopg
import requests
from google.transit import gtfs_realtime_pb2 as rt

DEFAULT_DSN = "host=127.0.0.1 dbname=urbandata user=urbanuser"
FEEDS = {
    "vehicle-positions": "https://gtfs.sofiatraffic.bg/api/v1/vehicle-positions",
    "trip-updates": "https://gtfs.sofiatraffic.bg/api/v1/trip-updates",
}
TIMEOUT = 20  # seconds; a run must end well within its minute


def log(msg):
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


def ts(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc) if seconds else None


def enum_name(enum, value):
    """IN_TRANSIT_TO -> 'in transit to'."""
    return enum.Name(value).lower().replace("_", " ")


def parse(body):
    feed = rt.FeedMessage()
    feed.ParseFromString(body)
    return feed


def vehicle_rows(feed):
    """(vehicle_id, recorded_at, trip_id, route_id, stop_id, status, lon, lat,
    speed, occupancy, congestion) for every vehicle with a position."""
    VP = rt.VehiclePosition
    header_time = ts(feed.header.timestamp)
    for e in feed.entity:
        if not e.HasField("vehicle") or not e.vehicle.HasField("position"):
            continue
        v = e.vehicle
        yield (v.vehicle.id or e.id,
               ts(v.timestamp) or header_time,
               v.trip.trip_id or None,
               v.trip.route_id or None,
               v.stop_id or None,
               enum_name(VP.VehicleStopStatus, v.current_status) if v.HasField("current_status") else None,
               v.position.longitude, v.position.latitude,
               v.position.speed if v.position.HasField("speed") else None,
               enum_name(VP.OccupancyStatus, v.occupancy_status) if v.HasField("occupancy_status") else None,
               enum_name(VP.CongestionLevel, v.congestion_level) if v.HasField("congestion_level") else None)


def arrival_rows(feed):
    """(trip_id, route_id, stop_id, predicted) for every stop with a
    predicted time; the arrival time, else the departure time."""
    for e in feed.entity:
        if not e.HasField("trip_update") or e.is_deleted:
            continue
        tu = e.trip_update
        if tu.trip.schedule_relationship == rt.TripDescriptor.CANCELED:
            continue
        for u in tu.stop_time_update:
            t = (u.arrival.time if u.HasField("arrival") and u.arrival.time
                 else u.departure.time if u.HasField("departure") else 0)
            if not t or not u.stop_id or u.schedule_relationship == u.SKIPPED:
                continue
            yield (tu.trip.trip_id, tu.trip.route_id or None, u.stop_id, ts(t))


def ensure_partitions(conn, now):
    # The positions go by UTC day; the arrivals by service day, which is
    # yesterday's for the trips running past midnight.
    for day in {now.date(), (now - timedelta(days=1)).date(), (now + timedelta(days=1)).date()}:
        conn.execute("SELECT live.ensure_partitions(%s)", (day,))


def write_vehicles(conn, feed, fetch_id):
    rows = list(vehicle_rows(feed))
    conn.execute("""CREATE TEMP TABLE IF NOT EXISTS vp_in (
                        vehicle_id text, recorded_at timestamptz, trip_id text, route_id text,
                        stop_id text, status text, lon double precision, lat double precision,
                        speed real, occupancy text, congestion text) ON COMMIT DROP""")
    conn.execute("TRUNCATE vp_in")  # dropped at commit; empty it for a second write in one transaction
    with conn.cursor().copy("""COPY vp_in (vehicle_id, recorded_at, trip_id, route_id, stop_id, status,
                                           lon, lat, speed, occupancy, congestion) FROM STDIN""") as copy:
        for r in rows:
            copy.write_row(r)
    cur = conn.execute("""
        INSERT INTO live.vehicle_positions
        SELECT DISTINCT ON (vehicle_id, recorded_at)
               vehicle_id, recorded_at, %s, trip_id, route_id, stop_id, status,
               lon, lat, speed, occupancy, congestion
          FROM vp_in
         ORDER BY vehicle_id, recorded_at
        ON CONFLICT DO NOTHING""", (fetch_id,))
    return cur.rowcount


def write_arrivals(conn, feed, seen_at):
    rows = list(arrival_rows(feed))
    conn.execute("""CREATE TEMP TABLE IF NOT EXISTS ta_in (
                        trip_id text, route_id text, stop_id text, predicted timestamptz) ON COMMIT DROP""")
    conn.execute("TRUNCATE ta_in")
    with conn.cursor().copy("COPY ta_in FROM STDIN") as copy:
        for r in rows:
            copy.write_row(r)
    # GTFS times count from the service day's midnight and pass 24:00 for
    # trips running past it. The service day is the local date of the
    # prediction less the scheduled time, rounded to the nearest day, so
    # a delay of up to 12 hours either way still finds the right day.
    # Trips not in the timetable get the local date of the prediction,
    # with the day turning at 04:00 as the night service ends.
    cur = conn.execute("""
        WITH x AS (
            SELECT i.trip_id, i.route_id, i.stop_id, i.predicted,
                   s.stop_sequence::integer AS stop_sequence,
                   split_part(coalesce(s.arrival_time, s.departure_time), ':', 1)::integer * 3600
                   + split_part(coalesce(s.arrival_time, s.departure_time), ':', 2)::integer * 60
                   + split_part(coalesce(s.arrival_time, s.departure_time), ':', 3)::integer AS secs
              FROM (SELECT DISTINCT ON (trip_id, stop_id) * FROM ta_in ORDER BY trip_id, stop_id) i
              LEFT JOIN gtfs.stop_times s ON s.trip_id = i.trip_id AND s.stop_id = i.stop_id
        ), d AS (
            SELECT x.*,
                   CASE WHEN secs IS NULL
                        THEN ((predicted AT TIME ZONE 'Europe/Sofia') - interval '4 hours')::date
                        ELSE ((predicted AT TIME ZONE 'Europe/Sofia') - make_interval(secs => secs)
                              + interval '12 hours')::date END AS service_date
              FROM x
        )
        INSERT INTO live.stop_arrivals AS a
               (service_date, trip_id, stop_id, route_id, stop_sequence, scheduled,
                first_predicted, first_seen, last_predicted, last_seen)
        SELECT service_date, trip_id, stop_id, route_id, stop_sequence,
               (service_date + make_interval(secs => secs)) AT TIME ZONE 'Europe/Sofia',
               predicted, %(seen)s, predicted, %(seen)s
          FROM d
        ON CONFLICT (service_date, trip_id, stop_id) DO UPDATE
           SET last_predicted = excluded.last_predicted,
               last_seen = excluded.last_seen,
               updates = a.updates + 1""", {"seen": seen_at})
    return cur.rowcount


WRITERS = {
    "vehicle-positions": lambda conn, feed, fetch_id, fetched_at: write_vehicles(conn, feed, fetch_id),
    "trip-updates": lambda conn, feed, fetch_id, fetched_at: write_arrivals(conn, feed, fetched_at),
}


def poll(conn, name, get=requests.get):
    """Fetch one feed and write it; returns True on success. The fetch is
    logged either way."""
    fetched_at = datetime.now(timezone.utc)
    start = time.monotonic()
    body, feed, rows, error = None, None, None, None
    try:
        resp = get(FEEDS[name], timeout=TIMEOUT)
        resp.raise_for_status()
        body = resp.content
        feed = parse(body)
        with conn.transaction():
            ensure_partitions(conn, fetched_at)
            fetch_id = conn.execute("""INSERT INTO live.fetches (feed, fetched_at) VALUES (%s, %s)
                                       RETURNING id""", (name, fetched_at)).fetchone()[0]
            rows = WRITERS[name](conn, feed, fetch_id, fetched_at)
            conn.execute("""UPDATE live.fetches SET feed_timestamp = %s, duration_ms = %s, bytes = %s,
                                   entities = %s, rows_written = %s WHERE id = %s""",
                         (ts(feed.header.timestamp), int((time.monotonic() - start) * 1000),
                          len(body), len(feed.entity), rows, fetch_id))
    except Exception as e:  # logged and kept; the next minute tries again
        error = f"{type(e).__name__}: {e}"[:1000]
        conn.execute("""INSERT INTO live.fetches (feed, fetched_at, duration_ms, bytes, error)
                        VALUES (%s, %s, %s, %s, %s)""",
                     (name, fetched_at, int((time.monotonic() - start) * 1000),
                      len(body) if body is not None else None, error))
    took = time.monotonic() - start
    if error:
        log(f"{name}: FAILED after {took:.1f}s: {error}")
    else:
        log(f"{name}: {len(feed.entity)} entities, {rows} rows, {took:.1f}s")
    return error is None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL", DEFAULT_DSN))
    ap.add_argument("--feed", choices=FEEDS, action="append", help="only this feed (default: both)")
    args = ap.parse_args()

    # autocommit: conn.transaction() in poll() is then a real transaction
    with psycopg.connect(args.dsn, autocommit=True, connect_timeout=10) as conn:
        ok = [poll(conn, name) for name in args.feed or FEEDS]
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())
