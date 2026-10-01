"""Checks on the built city.* tables. They need the database, loaded and
rebuilt with the db/city scripts; without it they are skipped."""

import os
import unittest

import psycopg

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")


def connect():
    try:
        return psycopg.connect(DSN, connect_timeout=3)
    except psycopg.OperationalError as e:
        raise unittest.SkipTest(f"no database: {e}")


class MetroAccessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.building_metro_access").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.building_metro_access is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_planned_stations_never_make_it_farther(self):
        # The planned set includes the existing stations.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_metro_access
             WHERE planned_distance_m > distance_m"""), 0)

    def test_distance_is_to_the_nearest_station_in_metres(self):
        # Nearest in degrees is not nearest in metres: a degree of longitude
        # is only 0.73 of a degree of latitude in Sofia.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.building_metro_access a
              JOIN city.building_residents r ON r.id = a.building_id
             CROSS JOIN LATERAL (
                   SELECT min(ST_Distance(s.outline::geography, r.geom::geography)) AS d
                     FROM city.metro_stations s WHERE s.status = 'existing') m
             WHERE abs(a.distance_m - m.d) > 1"""), 0)

    def test_area_shares_with_planned_are_not_lower(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.area_metro_access
             WHERE planned_share_500 < share_500 OR planned_share_1000 < share_1000"""), 0)


if __name__ == "__main__":
    unittest.main()
