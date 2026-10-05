"""Checks on the web API. Those that need the database, with the app
schema applied (db/app/schema.sql), are skipped without it."""

import json
import os
import unittest

import psycopg
from fastapi.testclient import TestClient

from web.app import BUILTIN_FOCUSES, app, focus_problems, merge_focuses, stored_focuses

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")


class BuiltinFocusesTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads(BUILTIN_FOCUSES.read_text())

    def test_every_focus_has_the_right_shape(self):
        for f in self.doc["focuses"]:
            self.assertEqual(focus_problems(f), [], f.get("id"))

    def test_ids_are_unique(self):
        ids = [f["id"] for f in self.doc["focuses"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_categories_are_known(self):
        for f in self.doc["focuses"]:
            self.assertIn(f["category"], [None, *self.doc["categories"]], f["id"])

    def test_the_first_is_the_overview(self):
        # The page falls back to the first focus for an unknown id.
        self.assertEqual(self.doc["focuses"][0]["id"], "overview")


class FocusProblemsTest(unittest.TestCase):
    def test_a_minimal_focus_is_fine(self):
        self.assertEqual(focus_problems({"id": "x", "title": "X", "layers": []}), [])

    def test_bad_shapes(self):
        self.assertTrue(focus_problems([]))
        self.assertTrue(focus_problems({"title": "X", "layers": []}))
        self.assertTrue(focus_problems({"id": "x", "title": "", "layers": []}))
        self.assertTrue(focus_problems({"id": "x", "title": "X"}))
        self.assertTrue(focus_problems({"id": "x", "title": "X", "layers": "schools"}))
        self.assertTrue(focus_problems({"id": "x", "title": "X", "layers": [], "areas": "district"}))
        self.assertTrue(focus_problems({"id": "x", "title": "X", "layers": [], "minZoom": "12"}))
        self.assertTrue(focus_problems({"id": "x y", "title": "X", "layers": []}))


class FocusesEndpointTest(unittest.TestCase):
    def test_returns_the_builtin_focuses(self):
        r = TestClient(app).get("/api/focuses")
        self.assertEqual(r.status_code, 200)
        doc = r.json()
        self.assertIn("Education", doc["categories"])
        ids = [f["id"] for f in doc["focuses"]]
        self.assertEqual(ids[0], "overview")
        self.assertIn("school-catchments", ids)


class MergeFocusesTest(unittest.TestCase):
    BUILTIN = [{"id": "overview", "title": "Overview", "layers": []}]

    def test_stored_ones_come_after_the_builtin_ones(self):
        merged = merge_focuses(self.BUILTIN, [("mine", {"title": "Mine", "layers": ["schools"]})])
        self.assertEqual([f["id"] for f in merged], ["overview", "mine"])
        self.assertEqual(merged[1], {"id": "mine", "title": "Mine", "layers": ["schools"]})

    def test_the_column_id_wins_over_one_in_the_definition(self):
        merged = merge_focuses([], [("mine", {"id": "other", "title": "Mine", "layers": []})])
        self.assertEqual(merged[0]["id"], "mine")

    def test_a_stored_one_cannot_replace_a_builtin_one(self):
        merged = merge_focuses(self.BUILTIN, [("overview", {"title": "Mine", "layers": []})])
        self.assertEqual(merged, self.BUILTIN)

    def test_a_badly_shaped_one_is_left_out(self):
        merged = merge_focuses(self.BUILTIN, [("bad", {"title": "Bad"}),
                                              ("good", {"title": "Good", "layers": []})])
        self.assertEqual([f["id"] for f in merged], ["overview", "good"])


class StoredFocusesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.conn = psycopg.connect(DSN, connect_timeout=3)
        except psycopg.OperationalError as e:
            raise unittest.SkipTest(f"no database: {e}")
        if cls.conn.execute("SELECT to_regclass('app.focuses')").fetchone()[0] is None:
            cls.conn.close()
            raise unittest.SkipTest("app schema not applied")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def tearDown(self):
        self.conn.rollback()

    def insert(self, id, definition, owner=None):
        self.conn.execute("INSERT INTO app.focuses (id, owner, definition) VALUES (%s, %s, %s)",
                          (id, owner, psycopg.types.json.Jsonb(definition)))

    def test_only_the_shared_ones_in_the_order_added(self):
        self.insert("test-b", {"title": "B", "layers": []})
        self.insert("test-a", {"title": "A", "layers": []})
        self.insert("test-private", {"title": "P", "layers": []}, owner="someone")
        rows = [r for r in stored_focuses(self.conn) if r[0].startswith("test-")]
        self.assertEqual(rows, [("test-b", {"title": "B", "layers": []}),
                                ("test-a", {"title": "A", "layers": []})])

    def test_the_id_must_fit_a_url(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            self.insert("Test A", {"title": "A", "layers": []})

    def test_the_definition_must_be_an_object(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            self.insert("test-a", ["A"])


if __name__ == "__main__":
    unittest.main()
