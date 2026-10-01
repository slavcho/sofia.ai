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


class ParksTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.parks").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.parks is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_entrance_is_on_its_park(self):
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.park_entrances e JOIN city.parks p ON p.id = e.park_id
             WHERE e.distance_m > 30
                OR abs(e.distance_m - ST_Distance(p.outline::geography, e.geom::geography)) > 0.1"""), 0)

    def test_entrance_prefers_an_existing_park(self):
        # Where an existing and a planned park meet, the entrance is the
        # existing park's.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.park_entrances e JOIN city.parks p ON p.id = e.park_id
             WHERE p.status = 'planned'
               AND EXISTS (SELECT 1 FROM city.parks q
                            WHERE q.status = 'existing'
                              AND ST_DWithin(q.outline::geography, e.geom::geography, 30))"""), 0)

    def test_unlinked_entrance_has_no_park_within_30_m(self):
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.park_entrances e
             WHERE e.park_id IS NULL
               AND EXISTS (SELECT 1 FROM city.parks p
                            WHERE ST_DWithin(p.outline::geography, e.geom::geography, 30))"""), 0)

    def test_parks_from_2019_are_not_in_2020(self):
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.parks o
             WHERE o.data_as_of < DATE '2020-01-01'
               AND (SELECT coalesce(sum(ST_Area(ST_Intersection(k.outline, o.outline))), 0)
                      FROM city.parks k
                     WHERE k.data_as_of >= DATE '2020-01-01' AND k.outline && o.outline)
                   >= 0.1 * ST_Area(o.outline)"""), 0)

    def test_status_follows_realization(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.parks
             WHERE realization IS NOT NULL
               AND status <> CASE WHEN realization > 0 THEN 'existing' ELSE 'planned' END"""), 0)

    def test_entrance_kind_follows_size(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.park_entrances
             WHERE kind IS DISTINCT FROM CASE size_code WHEN 1 THEN 'main' WHEN 2 THEN 'secondary'
                                                        WHEN 3 THEN 'unofficial' END"""), 0)


class ParkAccessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.building_park_access").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.building_park_access is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_building_is_measured(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_residents r
             WHERE NOT EXISTS (SELECT 1 FROM city.building_park_access a
                                WHERE a.building_id = r.id AND a.distance_m IS NOT NULL)"""), 0)

    def test_distance_is_to_the_nearest_entrance_in_metres(self):
        # park_access.sql only measures the 5 nearest on a stretched copy;
        # check against every entrance for one building in 20.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.building_park_access a
              JOIN city.building_residents r ON r.id = a.building_id
             CROSS JOIN LATERAL (
                   SELECT min(ST_Distance(e.geom::geography, r.geom::geography)) AS d
                     FROM city.park_entrances e JOIN city.parks p ON p.id = e.park_id
                    WHERE p.status = 'existing') m
             WHERE r.id % 20 = 0 AND abs(a.distance_m - m.d) > 1"""), 0)

    def test_edge_is_never_much_farther_than_an_entrance(self):
        # An entrance may lie up to 30 m off its park's edge (parks.sql).
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_park_access
             WHERE outline_distance_m > distance_m + 31"""), 0)

    def test_wider_choices_never_make_it_farther(self):
        # Planned parks add entrances; city parks are a subset.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_park_access
             WHERE planned_distance_m > distance_m OR city_park_distance_m < distance_m"""), 0)


if __name__ == "__main__":
    unittest.main()
