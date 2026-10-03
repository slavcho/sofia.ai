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

    def test_school_number_agrees_with_its_name(self):
        # object_nom is 7 for "78 СОУ" and 120 for "129 ОУ"; the name has it right.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.schools
             WHERE name ~ '^\d+ ' AND number IS DISTINCT FROM substring(name FROM '^(\d+) ')::integer"""), 0)


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


class SchoolCatchmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.catchment_addresses").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.catchment_addresses is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_list_row_is_loaded(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.catchment_addresses"), 106629)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.catchment_schools"), 159)

    def test_most_addresses_are_placed(self):
        # 92.9% when written; a drop means a key stopped matching.
        self.assertGreater(self.scalar("""
            SELECT avg((geom IS NOT NULL)::int) FROM city.catchment_addresses"""), 0.9)

    def test_a_point_is_not_both_a_street_and_an_area(self):
        # Ж.К.ГОЦЕ ДЕЛЧЕВ 113 is a block of the estate, not бул. Гоце
        # Делчев 113. (One street under two names in the list is the
        # list's own repeat: DATA_ISSUES.)
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM (
                SELECT address_fid FROM city.catchment_addresses
                 WHERE address_fid IS NOT NULL
                 GROUP BY address_fid
                HAVING count(DISTINCT street ~ '^(УЛ|БУЛ|ПЛ)\\.') > 1) q"""), 0)

    def test_estates_are_placed_by_block(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.catchment_addresses
             WHERE street ~ '^Ж\\.К\\.' AND match = 'street'"""), 0)

    def test_school_matches_its_number(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.catchment_schools c JOIN city.schools s ON s.id = c.school_id
             WHERE substring(s.name from '^(\\d+)') <> substring(c.name from '^(\\d+)')"""), 0)


class BuildingCatchmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.building_school_catchment").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.building_school_catchment is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        with self.conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchone()[0]

    def test_buildings_take_only_a_near_address(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_school_catchment WHERE address_distance_m > 30"""), 0)

    def test_assigned_school_is_never_nearer_than_the_nearest(self):
        # The nearest is among basic and secondary schools, so this holds
        # for an assigned school of those kinds.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_school_catchment b JOIN city.schools s ON s.id = b.school_id
             WHERE s.kind IN ('basic', 'secondary') AND b.school_distance_m < b.nearest_school_distance_m"""), 0)

    def test_city_counts_every_child(self):
        self.assertEqual(
            self.scalar("""SELECT children FROM city.area_school_catchment WHERE area_kind = 'city'"""),
            self.scalar("SELECT sum(age_0_14) FROM city.building_residents"))

    def test_most_children_have_a_catchment(self):
        # 93.6% when written.
        self.assertGreater(self.scalar("""
            SELECT known_share FROM city.area_school_catchment WHERE area_kind = 'city'"""), 0.9)


class TransitTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.transit_stops").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.transit_stops is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_feed_stop_is_in_one_stop(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM gtfs.stops g
             WHERE coalesce(g.location_type, '0') = '0'
               AND (SELECT count(*) FROM city.transit_stops s WHERE g.stop_id = ANY (s.gtfs_stop_ids)) <> 1"""), 0)

    def test_merged_stops_are_one_place(self):
        # Merged by the code on the sign; the farthest pair when written
        # was 82 m apart (a metro station's stops on both sides).
        self.assertLess(self.scalar("""
            SELECT max(ST_Distance(ST_MakePoint(g.stop_lon::float8, g.stop_lat::float8)::geography, s.geom::geography))
              FROM city.transit_stops s
             CROSS JOIN unnest(s.gtfs_stop_ids) u(stop_id) JOIN gtfs.stops g USING (stop_id)"""), 150)

    def test_served_means_departures(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.transit_stops s
             WHERE s.served <> (cardinality(s.modes) > 0)"""), 0)
        # A stop served only as some trips' last call has no departures,
        # so the other way round need not hold; but most have.
        self.assertGreater(self.scalar("""
            SELECT count(DISTINCT stop_id)::float / (SELECT count(*) FROM city.transit_stops WHERE served)
              FROM city.transit_stop_hours"""), 0.95)

    def test_trips_past_midnight_count_on_the_next_day(self):
        # Night lines run at 25:00-28:59 of the previous day's timetable.
        self.assertGreater(self.scalar("""
            SELECT sum(h.departures) FROM city.transit_stop_hours h
             WHERE h.day = 'weekday' AND h.hour BETWEEN 1 AND 3
               AND EXISTS (SELECT 1 FROM city.transit_routes r WHERE r.night AND r.id = ANY (h.route_ids))"""), 0)

    def test_departures_match_the_timetable(self):
        # Weekday departures from the feed directly, without the clock
        # shift: Tuesday's own trips before midnight.
        own = self.scalar("""
            SELECT count(*) FROM gtfs.stop_times st
              JOIN gtfs.trips t USING (trip_id)
              JOIN gtfs.calendar_dates c ON c.service_id = t.service_id AND c.date = '20261006'
             WHERE st.departure_time < '24'
               AND st.stop_sequence::integer < (SELECT max(x.stop_sequence::integer) FROM gtfs.stop_times x
                                                 WHERE x.trip_id = st.trip_id)""")
        early = self.scalar("""
            SELECT count(*) FROM gtfs.stop_times st
              JOIN gtfs.trips t USING (trip_id)
              JOIN gtfs.calendar_dates c ON c.service_id = t.service_id AND c.date = '20261005'
             WHERE st.departure_time >= '24'
               AND st.stop_sequence::integer < (SELECT max(x.stop_sequence::integer) FROM gtfs.stop_times x
                                                 WHERE x.trip_id = st.trip_id)""")
        self.assertEqual(self.scalar("SELECT sum(departures) FROM city.transit_stop_hours WHERE day = 'weekday'"),
                         own + early)

    def test_every_metro_station_is_matched(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.metro_stations m
             WHERE m.status = 'existing'
               AND NOT EXISTS (SELECT 1 FROM city.transit_stops s WHERE s.metro_station_id = m.id)"""), 0)

    def test_every_running_line_has_a_shape(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.transit_routes
             WHERE trips_weekday + trips_saturday + trips_sunday > 0 AND geom IS NULL"""), 0)


class TransitAccessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.building_transit_access").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.building_transit_access is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_building_is_measured(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.building_transit_access"),
                         self.scalar("SELECT count(*) FROM city.building_residents"))

    def test_nearest_stop_is_nearest_in_metres(self):
        # Every 50th building against all served stops.
        self.assertEqual(self.scalar("""
            SELECT count(*)
              FROM city.building_transit_access a
              JOIN city.building_residents r ON r.id = a.building_id
             CROSS JOIN LATERAL (
                   SELECT min(ST_Distance(s.geom::geography, r.geom::geography)) AS d
                     FROM city.transit_stops s WHERE s.served) m
             WHERE r.id % 50 = 0 AND abs(a.distance_m - m.d) > 1"""), 0)

    def test_stops_within_400_m_agree_with_the_nearest(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_transit_access
             WHERE (stops_400 > 0) <> (distance_m <= 400)"""), 0)

    def test_a_trip_counts_once_but_every_trip_counts(self):
        # At least the trips of the nearest stop, at most the departures of
        # all stops within 400 m (a trip calling at two of them is one).
        rows = self.conn.execute("""
            WITH w AS (SELECT date + time '07:00' AS f, date + time '09:00' AS t
                         FROM city.transit_days WHERE day = 'weekday'),
            near AS (
                SELECT a.building_id, a.peak_per_hour, s.id AS stop_id, s.id = a.stop_id AS nearest
                  FROM city.building_transit_access a
                  JOIN city.building_residents r ON r.id = a.building_id
                  -- within 400 m to the metre, as transit_access.sql counts
                  JOIN city.transit_stops s ON s.served AND ST_DWithin(s.geom::geography, r.geom::geography, 401)
                   AND round(ST_Distance(s.geom::geography, r.geom::geography)::numeric) <= 400
                 WHERE r.id % 25 = 0)
            SELECT n.building_id, min(n.peak_per_hour) * 2 AS counted,
                   count(DISTINCT d.trip_id) FILTER (WHERE n.nearest) AS nearest_trips,
                   count(d.trip_id) AS all_departures
              FROM near n CROSS JOIN w
              LEFT JOIN city.transit_departures d
                     ON d.stop_id = n.stop_id AND d.day = 'weekday' AND d.at >= w.f AND d.at < w.t
             GROUP BY n.building_id""").fetchall()
        self.assertTrue(rows)
        for building, counted, nearest, departures in rows:
            self.assertGreaterEqual(counted, nearest, building)
            self.assertLessEqual(counted, departures, building)

    def test_city_shares(self):
        # 97.8 % within 400 m of a served stop and Sofiaplan's 90.9 % when
        # written: their walk along streets is longer than our straight line.
        row = self.conn.execute("""
            SELECT transit_share_400, sofiaplan_transit_share_400, transit_theirs_only_share
              FROM city.area_transit_access WHERE area_kind = 'city'""").fetchone()
        self.assertGreater(row[0], row[1])
        self.assertLess(row[2], 0.01)


class BuildingsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.buildings").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.buildings is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_2019_building_is_kept(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.buildings_2019"),
                         self.scalar("""
            SELECT count(*) FROM urban.features f
              JOIN urban.layers l ON l.id = f.layer_id
              JOIN urban.resources r ON r.id = l.resource_id
              JOIN urban.datasets d ON d.id = r.dataset_id
             WHERE d.name = 'building-centroids-resident-count-800-m'"""))

    def test_inhabited_2019_buildings_are_the_residents(self):
        # Same ids and people as building_residents, so the access tables
        # (keyed on it) can be joined to the outlines.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_residents r
              FULL JOIN (SELECT * FROM city.buildings_2019 WHERE people > 0) b ON b.id = r.id
             WHERE r.id IS NULL OR b.id IS NULL OR r.people <> b.people"""), 0)

    def test_match_agrees_with_the_link(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.buildings_2019
             WHERE (match = 'none') <> (building_id IS NULL)
                OR (match = 'nearest' AND NOT distance_m <= 10)
                OR (match = 'none' AND NOT distance_m >= 10)  -- rounded to 0.1 m"""), 0)

    def test_inside_match_really_is_inside(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.buildings_2019 b
              JOIN city.buildings c ON c.id = b.building_id
             WHERE b.match = 'inside' AND NOT ST_Intersects(c.geom, b.geom)"""), 0)

    def test_people_add_up(self):
        # Every resident of 2019 is either in an outline or in an issue.
        self.assertEqual(self.scalar("""
            SELECT (SELECT sum(people) FROM city.building_residents)
                 - (SELECT sum(people_2019) FROM city.buildings)
                 - (SELECT coalesce(sum(people), 0) FROM city.buildings_2019 WHERE match = 'none')"""), 0)

    def test_2019_aggregates_match_the_link(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.buildings c
             WHERE c.buildings_2019 <> (SELECT count(*) FROM city.buildings_2019 b
                                         WHERE b.building_id = c.id)"""), 0)

    def test_floors_only_when_a_whole_number(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.buildings
             WHERE floors IS NOT NULL AND floors_text::text !~ '^-?[0-9]+$'
                OR floors = 0"""), 0)

    def test_every_function_has_a_category(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.buildings
             WHERE (function IS NULL) <> (category IS NULL)"""), 0)

    def test_buildings_lie_in_a_district(self):
        # The outlines cover the municipality only; a few may sit on the
        # boundary, but not many.
        self.assertLess(self.scalar(
            "SELECT count(*) FROM city.buildings WHERE district_code IS NULL"), 100)

    def test_area_totals_add_up(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.area_buildings a
             WHERE a.area_kind = 'city'
               AND a.buildings <> (SELECT count(*) FROM city.buildings)"""), 0)


class CensusTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.census_addresses").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.census_addresses is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_withheld_counts_are_null_not_negative(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.census_addresses
             WHERE least(people, dwellings, male, female, age_0_14, age_65_plus,
                         edu_1, edu_2, edu_3, edu_4, edu_5, born_bg, born_eu, born_non_eu) < 0"""), 0)

    def test_sexes_and_ages_add_up_to_the_people(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.census_addresses
             WHERE people <> male + female
                OR people <> age_0_14 + age_15_24 + age_25_34 + age_35_44
                             + age_45_54 + age_55_64 + age_65_plus"""), 0)

    def test_people_total_as_in_the_source(self):
        self.assertEqual(self.scalar("SELECT sum(people) FROM city.census_addresses"), 1177165)

    def test_issue_details_have_no_gaps_for_withheld_counts(self):
        # A withheld (NULL) count left "9,  people" in the detail.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.census_issues WHERE detail LIKE '%,  %'"""), 0)

    def test_match_agrees_with_the_link(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.census_addresses
             WHERE (match = 'none') <> (building_id IS NULL)
                OR (match = 'nearest' AND NOT distance_m <= 20)
                OR (match = 'none' AND NOT distance_m >= 20)  -- rounded to 0.1 m
                OR (match = 'inside') <> (distance_m IS NULL)"""), 0)

    def test_shares_are_shares(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.area_census
             WHERE NOT (census_share_0_14 BETWEEN 0 AND 1) OR NOT (census_share_65_plus BETWEEN 0 AND 1)
                OR NOT (higher_education_share BETWEEN 0 AND 1) OR NOT (born_abroad_share BETWEEN 0 AND 1)"""), 0)

    def test_district_totals_add_up_to_the_city(self):
        self.assertEqual(self.scalar("""
            SELECT (SELECT census_people FROM city.area_census WHERE area_kind = 'city')
                 - (SELECT sum(census_people) FROM city.area_census WHERE area_kind = 'district')
                 - (SELECT coalesce(sum(people), 0) FROM city.census_addresses WHERE district_code IS NULL)"""), 0)


class BuildingExtrasTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.panel_buildings").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.panel_buildings is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_panel_buildings_match_their_2019_building(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.panel_buildings p
              JOIN city.buildings_2019 b ON b.id = p.sofiaplan_id
             WHERE b.cadastre_ref <> p.cadastre_ref
                OR p.building_id IS DISTINCT FROM b.building_id"""), 0)

    def test_every_register_entry_is_kept(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.renovations"), 288)

    def test_renovation_match_has_a_point_in_its_district(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.renovations r
              JOIN city.census_addresses a ON a.id = r.census_address_id
             WHERE (r.match = 'none') <> (r.census_address_id IS NULL)
                OR a.district_label <> r.district_code
                OR NOT ST_Equals(a.geom, r.geom)"""), 0)

    def test_renovation_district_read_from_every_address(self):
        self.assertEqual(self.scalar(
            "SELECT count(*) FROM city.renovations WHERE district_code IS NULL"), 0)

    def test_breeam_outline_is_near(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.breeam_buildings b
              JOIN city.buildings c ON c.id = b.building_id
             WHERE ST_Distance(c.geom::geography, b.geom::geography) > 30"""), 0)

    def test_shading_is_a_share(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_shading
             WHERE NOT (shaded_min BETWEEN 0 AND 1 AND shaded_max BETWEEN 0 AND 1)
                OR NOT (shaded_mean BETWEEN shaded_min AND shaded_max)
                OR units_rated > units"""), 0)


class IndicatorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.planning_unit_indicators").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.planning_unit_indicators is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_every_unit_is_a_planning_unit(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators v
             WHERE NOT EXISTS (SELECT 1 FROM city.planning_units u WHERE u.id = v.planning_unit_id)"""), 0)

    def test_every_indicator_has_values(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.indicators i
             WHERE NOT EXISTS (SELECT 1 FROM city.planning_unit_indicators v WHERE v.indicator = i.id)"""), 0)

    def test_every_row_has_a_value(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators
             WHERE value IS NULL AND value_text IS NULL"""), 0)

    def test_percentages_out_of_range_are_reported(self):
        out = self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators v
              JOIN city.indicators i ON i.id = v.indicator AND i.unit = '%'
             WHERE v.value < 0 OR v.value > 100""")
        self.assertEqual(out, self.scalar("""
            SELECT count(*) FROM city.indicator_issues WHERE issue = 'percentage outside 0-100'"""))
        self.assertLess(out, 10)

    def test_shares_within_0_and_1(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators v
              JOIN city.indicators i ON i.id = v.indicator AND i.unit = 'share'
             WHERE v.value < 0 OR v.value > 1"""), 0)

    def test_current_division_matches_every_unit(self):
        # Only the files on an older division may lose units: the 2019
        # functions file and the DKC access (297 units).
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.indicators
             WHERE unmatched > 0
               AND id NOT IN ('function_kinds', 'poi_density', 'dkc_unserved_pct')
               AND theme <> 'Energy'"""), 0)

    def test_totals_as_in_the_source(self):
        self.assertEqual(self.scalar("""
            SELECT sum(value) FROM city.planning_unit_indicators
             WHERE indicator = 'solid_fuel_households'"""), 51809)
        self.assertEqual(self.scalar("""
            SELECT sum(value) FROM city.planning_unit_indicators
             WHERE indicator = 'residential_permits_since_2010'"""), 3575)

    def test_forecast_scenarios_are_ordered(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM (
                SELECT breakdown,
                       sum(value) FILTER (WHERE indicator = 'population_forecast_low') lo,
                       sum(value) FILTER (WHERE indicator = 'population_forecast') mid,
                       sum(value) FILTER (WHERE indicator = 'population_forecast_high') hi
                  FROM city.planning_unit_indicators GROUP BY breakdown) t
             WHERE NOT (lo <= mid AND mid <= hi)"""), 0)

    def test_energy_heat_demand_mismatches_are_reported(self):
        # The source's own mistakes, few, and each in the issues.
        n = self.scalar("""
            SELECT count(*) FROM city.indicator_issues
             WHERE issue = 'heat demand is not heating plus hot water'""")
        self.assertLess(n, 20)
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators t
              JOIN city.planning_unit_indicators h
                ON h.planning_unit_id = t.planning_unit_id AND h.breakdown = t.breakdown
               AND h.indicator = 'energy_space_heating_mwh'
              JOIN city.planning_unit_indicators w
                ON w.planning_unit_id = t.planning_unit_id AND w.breakdown = t.breakdown
               AND w.indicator = 'energy_hot_water_mwh'
             WHERE t.indicator = 'energy_heat_demand_mwh'
               AND abs(t.value - h.value - w.value) > 1"""), n)

    def test_energy_district_heating_above_demand_is_reported(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.indicator_issues
             WHERE issue = 'district heating supplies more than the heat demand'"""),
            self.scalar("""
            SELECT count(*) FROM city.planning_unit_indicators d
              JOIN city.planning_unit_indicators t
                ON t.planning_unit_id = d.planning_unit_id AND t.breakdown = d.breakdown
               AND t.indicator = 'energy_heat_demand_mwh'
             WHERE d.indicator = 'energy_district_heating_mwh' AND d.value > t.value * 1.01"""))
        self.assertGreater(self.scalar("""
            SELECT count(*) FROM city.indicator_issues
             WHERE issue = 'district heating supplies more than the heat demand'"""), 0)

    def test_energy_scenarios_by_decade(self):
        # 2017, the realistic scenario by decade under the bare year, and
        # the optimistic and pessimistic ones for the fields that have them.
        self.assertEqual(self.scalar("""
            SELECT string_agg(DISTINCT breakdown, ',' ORDER BY breakdown)
              FROM city.planning_unit_indicators WHERE indicator = 'energy_heat_demand_mwh'"""),
            '2017,2030,2030 optimistic,2030 pessimistic,2040,2040 optimistic,2040 pessimistic,'
            '2050,2050 optimistic,2050 pessimistic')
        self.assertEqual(self.scalar("""
            SELECT string_agg(DISTINCT breakdown, ',' ORDER BY breakdown)
              FROM city.planning_unit_indicators WHERE indicator = 'energy_district_heating_mwh'"""),
            '2017,2030,2040,2050')

    def test_energy_matches_most_units(self):
        # The file is on the 2019 division (574 units); most still match.
        self.assertGreater(self.scalar("""
            SELECT count(DISTINCT planning_unit_id) FROM city.planning_unit_indicators
             WHERE indicator = 'energy_heat_demand_mwh'"""), 450)


class SmallAreasTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.polling_sections").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.polling_sections is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_all_tracts_and_sections_loaded(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.census_tracts"), 6103)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.polling_sections"), 1598)

    def test_tracts_hold_nearly_all_census_people(self):
        # Points just outside every tract go to the nearest within 50 m.
        self.assertGreater(self.scalar("""
            SELECT sum(t.census_people)::float / (SELECT sum(people) FROM city.census_addresses)
              FROM city.census_tracts t"""), 0.97)

    def test_grid_in_sofia_matches_the_census_total(self):
        # NSI's 2011 count for Sofia (capital) municipality: 1,291,591.
        self.assertAlmostEqual(self.scalar("""
            SELECT sum(people) FROM city.population_grid WHERE in_sofia"""), 1291591, delta=15000)

    def test_polling_places_are_in_sofia(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.polling_sections WHERE place_district_code IS NULL"""), 0)

    def test_section_number_district_is_a_district(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.polling_sections s
             WHERE NOT EXISTS (SELECT 1 FROM city.districts d WHERE d.code = s.district_code)"""), 0)

    def test_most_sections_have_an_area(self):
        self.assertLess(self.scalar("SELECT count(*) FROM city.polling_sections WHERE area IS NULL"), 20)

    def test_place_split_from_address(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.polling_sections
             WHERE place = '' OR place ~ '^(гр|с)\\.' OR address LIKE '%' || chr(13) || '%'"""), 0)


class LightingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.street_lights").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.street_lights is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_everything_loaded(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.street_lights"), 98225)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.light_poles"), 86286)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.lighting_panels"), 1043)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.rectifier_stations"), 24)

    def test_survey_district_numbering_is_translated(self):
        # Numbered alphabetically in the survey; translated, nearly all
        # lights lie in the district they are coded for.
        self.assertGreater(self.scalar("""
            SELECT count(*) FILTER (WHERE source_district_code = district_code)::float
                   / count(source_district_code) FROM city.street_lights"""), 0.98)

    def test_lamp_types_known(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.street_lights
             WHERE lamp_type IS NULL AND split_part(lamp_type_source, '|', 1)
                   NOT IN ('Неопределен', 'Няма данни')"""), 0)

    def test_led_lights(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.street_lights WHERE lamp_type = 'LED'"), 4703)

    def test_pole_heights_plausible(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.light_poles WHERE height_m <= 0 OR height_m > 30"""), 0)

    def test_area_lighting_adds_up(self):
        self.assertEqual(self.scalar("""
            SELECT sum(street_lights) FROM city.area_lighting WHERE area_kind = 'district'"""),
            self.scalar("SELECT count(*) FROM city.street_lights WHERE district_code IS NOT NULL"))
        self.assertGreater(self.scalar("""
            SELECT sum(street_lights) FROM city.area_lighting WHERE area_kind = 'planning_unit'"""), 95000)


class MasterPlanTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.master_plan_zones").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.master_plan_zones is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_all_zones_loaded(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.master_plan_zones WHERE plan = '2009'"), 12306)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.master_plan_zones WHERE plan = 'long-term'"), 413)

    def test_only_special_terrains_left_ungrouped(self):
        self.assertEqual(self.scalar("""
            SELECT string_agg(DISTINCT rtrim(code, '*'), ',' ORDER BY rtrim(code, '*'))
              FROM city.master_plan_zones WHERE zone_group = 'special'"""), 'Топ,Тсп')

    def test_long_term_names_without_prefix(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.master_plan_zones WHERE name ~ '^\\d' OR name = ''"""), 0)

    def test_zones_cover_each_district(self):
        # The streets are left out of the zones: they take 10-16 % of the
        # central districts and 1-3 % of the outer ones. Zones do not overlap.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.districts d
              JOIN (SELECT area_id, sum(area_ha) AS ha FROM city.area_master_plan
                     WHERE area_kind = 'district' GROUP BY 1) m ON m.area_id = d.code
             WHERE m.ha * 1e4 NOT BETWEEN 0.8 * ST_Area(d.geom::geography) AND 1.005 * ST_Area(d.geom::geography)"""), 0)


class AmenitiesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.playgrounds").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.playgrounds is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_everything_loaded(self):
        # 1839 in the register, less the 12 it says not to show.
        self.assertEqual(self.scalar("SELECT count(*) FROM city.playgrounds"), 1827)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.playgrounds WHERE status = 'planned'"), 56)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.markets"), 33)

    def test_hidden_playgrounds_left_out(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.playgrounds p
              JOIN urban.features f ON f.source_fid = p.source_fid
              JOIN urban.layers l ON l.id = f.layer_id
              JOIN urban.resources r ON r.id = l.resource_id
              JOIN urban.datasets d ON d.id = r.dataset_id AND d.name = p.source_dataset
             WHERE f.properties->>'chek' ~ 'да не се показва'"""), 0)

    def test_source_district_agrees_with_location(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.playgrounds p JOIN city.districts d ON d.code = p.district_code
             WHERE lower(replace(p.source_district, 'Бнакя', 'Банкя')) <> lower(d.name)"""), 0)
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.markets m JOIN city.districts d ON d.code = m.district_code
             WHERE lower(m.source_district) <> lower(d.name)"""), 0)

    def test_every_inhabited_building_measured(self):
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.building_residents b
              LEFT JOIN city.building_amenity_access a ON a.building_id = b.id
             WHERE a.playground_m IS NULL OR a.market_m IS NULL"""), 0)

    def test_nearest_is_really_nearest(self):
        # The index search looks at 5 candidates only; check it against
        # every playground and market for a sample of buildings.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM (
                SELECT a.playground_m, a.market_m,
                       (SELECT min(ST_Distance(p.geom::geography, b.geom::geography))
                          FROM city.playgrounds p WHERE p.status = 'existing') AS pd,
                       (SELECT min(ST_Distance(m.geom::geography, b.geom::geography))
                          FROM city.markets m) AS md
                  FROM city.building_residents b
                  JOIN city.building_amenity_access a ON a.building_id = b.id
                 WHERE b.id % 100 = 0) s
             WHERE abs(playground_m - pd) > 1 OR abs(market_m - md) > 1"""), 0)

    def test_area_counts_add_up(self):
        self.assertEqual(self.scalar("""
            SELECT sum(playgrounds) FROM city.area_amenity_access WHERE area_kind = 'district'"""),
            self.scalar("""SELECT count(*) FROM city.playgrounds
                            WHERE status = 'existing' AND district_code IN
                                  (SELECT area_id FROM city.area_amenity_access WHERE area_kind = 'district')"""))
        self.assertEqual(self.scalar("""
            SELECT people FROM city.area_amenity_access WHERE area_kind = 'city'"""),
            self.scalar("SELECT sum(people) FROM city.building_residents"))


class SitesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()
        (n,) = cls.conn.execute("SELECT count(*) FROM city.tent_camp_sites").fetchone()
        if not n:
            cls.conn.close()
            raise unittest.SkipTest("city.tent_camp_sites is empty")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def scalar(self, sql):
        return self.conn.execute(sql).fetchone()[0]

    def test_everything_loaded(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.tent_camp_sites"), 113)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.concessions WHERE status = 'granted'"), 16)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.concessions WHERE status = 'terminated'"), 9)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.metro_project_areas"), 15)
        # 70 settlements, one of them with no geometry, and Sofia city.
        self.assertEqual(self.scalar("SELECT count(*) FROM city.settlement_boundaries"), 70)

    def test_every_school_property_record_found_its_school(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.school_property"), 11)
        # A numbered name must land on a school with that number.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.school_property p JOIN city.schools s ON s.id = p.school_id
             WHERE p.description ~ '^\\d+ '
               AND s.number IS DISTINCT FROM substring(p.description FROM '^(\\d+) ')::integer"""), 0)
        self.assertEqual(self.scalar("SELECT count(*) FROM city.school_property WHERE category IS NULL"), 0)

    def test_tent_camps_are_placed(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM city.tent_camp_sites WHERE district_code IS NULL"), 0)
        self.assertEqual(self.scalar("""
            SELECT sites FROM city.area_tent_camps WHERE area_kind = 'city'"""), 113)

    def test_metro_project_areas_lie_along_the_metro(self):
        # Both projects extend existing lines, so every area lies
        # within 300 m of the planned or existing tracks.
        self.assertEqual(self.scalar("""
            SELECT count(*) FROM city.metro_project_areas m
             WHERE NOT EXISTS (SELECT 1 FROM city.metro_tracks t
                                WHERE ST_DWithin(t.geom::geography, m.geom::geography, 300))"""), 0)
