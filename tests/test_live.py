"""Checks on the live.* schema (db/live/schema.sql). They need the database
with the schema applied; without it they are skipped. Every test runs in a
transaction that is rolled back, so nothing stays behind."""

import os
import unittest

import psycopg

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


if __name__ == "__main__":
    unittest.main()
