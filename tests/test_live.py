"""Checks on the live.* schema (db/live/schema.sql). They need the database
with the schema applied; without it they are skipped. Every test runs in a
transaction that is rolled back, so nothing stays behind."""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
try:
    import poll_live
    from google.transit import gtfs_realtime_pb2 as rt
except ImportError as e:  # gtfs-realtime-bindings not installed
    poll_live = rt = None
    MISSING = str(e)

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")


def connect():
    try:
        return psycopg.connect(DSN, connect_timeout=3)
    except psycopg.OperationalError as e:
        raise unittest.SkipTest(f"no database: {e}")


class LiveSchemaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        if cls.conn.execute("SELECT to_regclass('live.stop_arrivals')").fetchone()[0] is None:
            cls.conn.close()
            raise unittest.SkipTest("live schema not applied")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def tearDown(self):
        self.conn.rollback()

    def scalar(self, sql, params=None):
        return self.conn.execute(sql, params).fetchone()[0]

    def test_partitions_are_made_once(self):
        # A day far ahead, so no real partition is touched.
        self.assertEqual(self.scalar("SELECT live.ensure_partitions('2099-03-15')"), 2)
        self.assertEqual(self.scalar("SELECT live.ensure_partitions('2099-03-16')"), 1)
        self.assertEqual(self.scalar("SELECT live.ensure_partitions('2099-03-16')"), 0)
        self.assertIsNotNone(self.scalar("SELECT to_regclass('live.vehicle_positions_20990315')"))
        self.assertIsNotNone(self.scalar("SELECT to_regclass('live.stop_arrivals_209903')"))

    def test_positions_go_to_their_utc_day(self):
        self.scalar("SELECT live.ensure_partitions('2099-03-15')")
        self.scalar("SELECT live.ensure_partitions('2099-03-16')")
        # 01:30 in Sofia is still the 15th in UTC.
        self.conn.execute("""
            INSERT INTO live.vehicle_positions (vehicle_id, recorded_at, fetch_id, lon, lat)
            VALUES ('T1', '2099-03-16 01:30+02', 1, 23.3, 42.7)""")
        self.assertEqual(self.scalar("SELECT count(*) FROM live.vehicle_positions_20990315"), 1)

    def test_a_vehicle_report_is_stored_once(self):
        self.scalar("SELECT live.ensure_partitions('2099-03-15')")
        insert = """INSERT INTO live.vehicle_positions (vehicle_id, recorded_at, fetch_id, lon, lat)
                    VALUES ('T1', '2099-03-15 12:00+00', %s, 23.3, 42.7)
                    ON CONFLICT DO NOTHING"""
        self.conn.execute(insert, (1,))
        self.conn.execute(insert, (2,))
        self.assertEqual(self.scalar("""SELECT count(*) FROM live.vehicle_positions
                                         WHERE vehicle_id = 'T1'"""), 1)

    def test_only_passed_stops_have_a_delay(self):
        self.scalar("SELECT live.ensure_partitions('2099-03-15')")
        self.conn.execute("""
            INSERT INTO live.fetches (feed, fetched_at) VALUES ('trip-updates', '2099-03-15 12:10+00');
            INSERT INTO live.stop_arrivals (service_date, trip_id, stop_id, scheduled,
                                            first_predicted, first_seen, last_predicted, last_seen)
            VALUES ('2099-03-15', 'X', 'passed', '2099-03-15 12:00+00',
                    '2099-03-15 12:00+00', '2099-03-15 11:50+00', '2099-03-15 12:02+00', '2099-03-15 12:01+00'),
                   ('2099-03-15', 'X', 'ahead', '2099-03-15 12:20+00',
                    '2099-03-15 12:20+00', '2099-03-15 11:50+00', '2099-03-15 12:21+00', '2099-03-15 12:10+00')""")
        rows = self.conn.execute("""SELECT stop_id, delay_s FROM live.passed_arrivals
                                     WHERE trip_id = 'X'""").fetchall()
        self.assertEqual(rows, [('passed', 120)])


SOFIA = ZoneInfo("Europe/Sofia")


def local(text):
    return datetime.fromisoformat(text).replace(tzinfo=SOFIA)


def epoch(dt):
    return int(dt.timestamp())


def vehicle_feed(*vehicles, at=local("2099-03-15 12:00")):
    feed = rt.FeedMessage()
    feed.header.gtfs_realtime_version = "2.0"
    feed.header.timestamp = epoch(at)
    for vid, when, trip in vehicles:
        e = feed.entity.add(id=vid)
        e.vehicle.vehicle.id = vid
        e.vehicle.trip.trip_id = trip
        e.vehicle.trip.route_id = trip.split("-")[0]
        e.vehicle.position.latitude, e.vehicle.position.longitude = 42.7, 23.3
        e.vehicle.position.speed = 34
        if when:
            e.vehicle.timestamp = epoch(when)
        e.vehicle.current_status = rt.VehiclePosition.IN_TRANSIT_TO
        e.vehicle.occupancy_status = rt.VehiclePosition.MANY_SEATS_AVAILABLE
    return feed


def trip_feed(trips, at=local("2099-03-15 12:00")):
    """trips: {trip_id: [(stop_id, predicted local datetime), ...]}"""
    feed = rt.FeedMessage()
    feed.header.gtfs_realtime_version = "2.0"
    feed.header.timestamp = epoch(at)
    for trip, stops in trips.items():
        e = feed.entity.add(id=trip)
        e.trip_update.trip.trip_id = trip
        e.trip_update.trip.route_id = trip.split("-")[0]
        for stop, when in stops:
            u = e.trip_update.stop_time_update.add(stop_id=stop)
            u.arrival.time = epoch(when)
    return feed


class ParseTest(unittest.TestCase):
    def setUp(self):
        if poll_live is None:
            self.skipTest(MISSING)

    def test_vehicle_rows(self):
        rows = list(poll_live.vehicle_rows(vehicle_feed(("A1", local("2099-03-15 11:59:30"), "A81-x"))))
        self.assertEqual(len(rows), 1)
        vid, when, trip, route, stop, status, lon, lat, speed, occ, cong = rows[0]
        self.assertEqual((vid, trip, route, status, occ, cong),
                         ("A1", "A81-x", "A81", "in transit to", "many seats available", None))
        self.assertEqual(when, local("2099-03-15 11:59:30"))
        self.assertAlmostEqual(lon, 23.3, places=5)

    def test_a_vehicle_without_its_own_time_takes_the_feed_time(self):
        rows = list(poll_live.vehicle_rows(vehicle_feed(("A1", None, "A81-x"))))
        self.assertEqual(rows[0][1], local("2099-03-15 12:00"))

    def test_arrival_rows_skip_cancelled_trips(self):
        feed = trip_feed({"A1-x": [("S1", local("2099-03-15 12:05"))],
                          "A1-y": [("S1", local("2099-03-15 12:06"))]})
        feed.entity[1].trip_update.trip.schedule_relationship = rt.TripDescriptor.CANCELED
        self.assertEqual(list(poll_live.arrival_rows(feed)),
                         [("A1-x", "A1", "S1", local("2099-03-15 12:05"))])


class PollTest(unittest.TestCase):
    """Writes into the live tables, rolled back after every test."""

    @classmethod
    def setUpClass(cls):
        if poll_live is None:
            raise unittest.SkipTest(MISSING)
        cls.conn = connect()
        if cls.conn.execute("SELECT to_regclass('live.stop_arrivals')").fetchone()[0] is None:
            cls.conn.close()
            raise unittest.SkipTest("live schema not applied")
        # A trip that runs past midnight: its last stops are after 24:00.
        row = cls.conn.execute("""
            SELECT trip_id, stop_id, arrival_time FROM gtfs.stop_times
             WHERE arrival_time >= '24:' ORDER BY trip_id, stop_sequence::integer LIMIT 1""").fetchone()
        if row is None:
            cls.conn.close()
            raise unittest.SkipTest("no timetable loaded")
        cls.night_trip, cls.night_stop, cls.night_time = row
        cls.day_stop, cls.day_time = cls.conn.execute("""
            SELECT stop_id, arrival_time FROM gtfs.stop_times
             WHERE trip_id = %s AND arrival_time < '24:' ORDER BY stop_sequence::integer DESC LIMIT 1""",
            (cls.night_trip,)).fetchone()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def setUp(self):
        for day in ("2099-03-15", "2099-03-16"):
            self.conn.execute("SELECT live.ensure_partitions(%s)", (day,))

    def tearDown(self):
        self.conn.rollback()

    def at(self, gtfs_time, day="2099-03-15", late_s=0):
        h, m, s = map(int, gtfs_time.split(":"))
        return local(day + " 00:00") + timedelta(hours=h, minutes=m, seconds=s + late_s)

    def arrivals(self):
        return self.conn.execute("""
            SELECT stop_id, service_date::text, scheduled, first_predicted, last_predicted, updates
              FROM live.stop_arrivals WHERE trip_id = %s ORDER BY stop_id""",
            (self.night_trip,)).fetchall()

    def test_a_trip_past_midnight_stays_on_its_service_day(self):
        night = self.at(self.night_time, late_s=90)   # e.g. 24:00 + 90 s is 00:01:30 on the 16th
        poll_live.write_arrivals(self.conn, trip_feed({self.night_trip: [(self.night_stop, night)]}),
                                 datetime.now(timezone.utc))
        ((stop, service_date, scheduled, first, last, n),) = self.arrivals()
        self.assertEqual(service_date, "2099-03-15")
        self.assertEqual(scheduled, self.at(self.night_time))
        self.assertEqual((last - scheduled).total_seconds(), 90)

    def test_later_fetches_keep_the_first_and_update_the_last_prediction(self):
        t1 = self.at(self.day_time, late_s=60)
        t2 = self.at(self.day_time, late_s=180)
        for predicted, seen in ((t1, "2099-03-15 10:00+00"), (t2, "2099-03-15 10:01+00")):
            poll_live.write_arrivals(self.conn, trip_feed({self.night_trip: [(self.day_stop, predicted)]}),
                                     datetime.fromisoformat(seen))
        ((stop, service_date, scheduled, first, last, n),) = self.arrivals()
        self.assertEqual((first, last, n), (t1, t2, 2))

    def test_a_trip_not_in_the_timetable_is_kept_without_schedule(self):
        poll_live.write_arrivals(self.conn, trip_feed({"NOPE-1": [("S1", local("2099-03-16 02:00"))]}),
                                 datetime.now(timezone.utc))
        row = self.conn.execute("""SELECT service_date::text, scheduled FROM live.stop_arrivals
                                    WHERE trip_id = 'NOPE-1'""").fetchone()
        self.assertEqual(row, ("2099-03-15", None))   # before 04:00: still the previous day

    def test_vehicles_are_written_once_per_report(self):
        feed = vehicle_feed(("T1", local("2099-03-15 11:59"), self.night_trip),
                            ("T2", local("2099-03-15 11:58"), self.night_trip))
        self.assertEqual(poll_live.write_vehicles(self.conn, feed, 1), 2)
        self.assertEqual(poll_live.write_vehicles(self.conn, feed, 2), 0)

    def test_a_failed_fetch_is_logged(self):
        def broken(url, timeout):
            raise OSError("connection refused")
        self.assertFalse(poll_live.poll(self.conn, "trip-updates", get=broken))
        error = self.conn.execute("""SELECT error FROM live.fetches
                                      ORDER BY id DESC LIMIT 1""").fetchone()[0]
        self.assertIn("connection refused", error)

    def test_a_good_fetch_is_logged_with_its_counts(self):
        body = vehicle_feed(("T1", local("2099-03-15 11:59"), self.night_trip)).SerializeToString()

        class Resp:
            content = body
            def raise_for_status(self):
                pass
        self.assertTrue(poll_live.poll(self.conn, "vehicle-positions", get=lambda url, timeout: Resp()))
        row = self.conn.execute("""SELECT entities, rows_written, bytes, error FROM live.fetches
                                    ORDER BY id DESC LIMIT 1""").fetchone()
        self.assertEqual(row, (1, 1, len(body), None))


if __name__ == "__main__":
    unittest.main()
