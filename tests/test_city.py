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

    def test_both_sofiaplan_files_are_compared(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FILTER (WHERE sofiaplan_access)::text || '/' || count(*)
              FROM city.park_access_sofiaplan"""), "38031/132070")

    def test_sofiaplan_access_has_an_entrance_within_400_m(self):
        # Walking is never shorter than a straight line, so where Sofiaplan
        # finds access within 300 m there must be an entrance close by; the
        # extra 100 m is for measuring from the outline, not the centre.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.park_access_sofiaplan
             WHERE sofiaplan_access AND any_distance_m > 400"""), 0)

    def test_agreement_share_is_zero_not_null_without_access(self):
        # Дружба 2: no Sofiaplan building with access, and none of ours.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.park_access_agreement
             WHERE (sofiaplan_share IS NULL OR our_share_300 IS NULL)
               AND buildings > 0"""), 0)


class EducationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.kindergartens").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.kindergartens is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_point_is_loaded(self):
        self.assertEqual(self.scalar("""
            SELECT (SELECT count(*) FROM city.kindergartens) || '/' || (SELECT count(*) FROM city.schools)"""),
            "397/275")

    def test_every_registration_is_on_its_kindergarten(self):
        # Matched by number, which is wrong for some sites; the name has it right.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM urban.features f
              JOIN urban.layers l ON l.id = f.layer_id
              LEFT JOIN city.kindergartens k ON k.registration_id = (f.properties->>'id')::integer
             WHERE l.source_path LIKE '%dg_reg_karti_26_sofpr_20180808.geojson'
               AND (k.id IS NULL OR k.is_branch
                    OR k.name !~ ('№ ?' || (f.properties->>'nomer') || '([^0-9]|$)'))"""), 0)

    def test_a_registration_is_used_once(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) - count(DISTINCT registration_id) FROM city.kindergartens
             WHERE registration_id IS NOT NULL"""), 0)

    def test_nursery_children_are_part_of_all_children(self):
        # ДГ №197 has a registration but no groups: unknown, not zero.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.kindergartens
             WHERE nursery_children > children
                OR (children IS NULL) <> (nursery_children IS NULL)"""), 0)

    def test_branch_by_name_is_a_branch(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.kindergartens WHERE name ~* 'филиал' AND NOT is_branch"""), 0)

    def test_every_school_has_a_kind(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.schools WHERE kind IS NULL"), 0)


class EducationAccessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.building_education_access").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.building_education_access is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_building_is_measured(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_residents r
             WHERE NOT EXISTS (SELECT 1 FROM city.building_education_access a
                                WHERE a.building_id = r.id AND a.kindergarten_distance_m IS NOT NULL
                                  AND a.school_distance_m IS NOT NULL)"""), 0)

    def test_distance_is_to_the_nearest_in_metres(self):
        # education_access.sql only measures the 5 nearest on a stretched
        # copy; check against all of them for one building in 20.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.building_education_access a
              JOIN city.building_residents r ON r.id = a.building_id
             CROSS JOIN LATERAL (
                   SELECT min(ST_Distance(k.geom::geography, r.geom::geography)) AS d
                     FROM city.kindergartens k WHERE k.kind = 'kindergarten' AND k.status = 'open') k
             CROSS JOIN LATERAL (
                   SELECT min(ST_Distance(s.geom::geography, r.geom::geography)) AS d
                     FROM city.schools s WHERE s.kind IN ('primary', 'basic', 'secondary')) s
             WHERE r.id % 20 = 0
               AND (abs(a.kindergarten_distance_m - k.d) > 1 OR abs(a.school_distance_m - s.d) > 1)"""), 0)

    def test_municipal_is_never_nearer_than_any(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_education_access
             WHERE municipal_kindergarten_distance_m < kindergarten_distance_m
                OR municipal_school_distance_m < school_distance_m"""), 0)

    def test_city_counts_every_child_and_place(self):
        self.assertEqual(self.scalar("""
            SELECT a.children = (SELECT sum(age_0_14) FROM city.building_residents)
               AND a.registered_children = (SELECT sum(children) FROM city.kindergartens)
              FROM city.area_education_access a WHERE a.area_kind = 'city'"""), True)

    def test_both_sofiaplan_sources_are_compared(self):
        self.assertEqual(self.scalar("""
            SELECT (SELECT count(*) FROM city.school_access_sofiaplan) || '/'
                || (SELECT count(*) FROM city.building_residents) || ' '
                || (SELECT count(*) FROM city.education_unserved_sofiaplan)"""), "34619/34619 228")

    def test_our_unserved_fits_the_residents(self):
        # Farther thresholds leave fewer unserved, never more than live there.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.education_unserved_sofiaplan
             WHERE our_kindergarten_unserved_500 > our_kindergarten_unserved_400
                OR our_school_unserved_500 > our_school_unserved_400
                OR our_kindergarten_unserved_400 > our_people
                OR our_school_unserved_400 > our_people"""), 0)

    def test_any_school_is_never_farther_than_a_lower_grade_school(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.school_access_sofiaplan s
              JOIN city.building_education_access a USING (building_id)
             WHERE s.any_school_distance_m > a.school_distance_m"""), 0)


if __name__ == "__main__":
    unittest.main()
