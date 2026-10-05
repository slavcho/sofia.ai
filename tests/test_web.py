"""Checks on the web API that need no database."""

import json
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from web.app import BUILTIN_FOCUSES, app, focus_problems

ROOT = Path(__file__).resolve().parent.parent


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


if __name__ == "__main__":
    unittest.main()
