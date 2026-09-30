import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import load_db  # noqa: E402

POINT = {"type": "Point", "coordinates": [23.32, 42.69]}
AREA = {"type": "MultiPolygon", "coordinates": [[[[23.3, 42.6], [23.4, 42.6], [23.4, 42.7], [23.3, 42.6]]]]}


def collection(*features, **extra):
    return dict({"type": "FeatureCollection", "features": list(features)}, **extra)


class FeatureRowsTest(unittest.TestCase):
    def rows(self, doc):
        stats = load_db.LayerStats()
        return list(load_db.feature_rows(doc, stats)), stats

    def test_rows_and_stats(self):
        rows, stats = self.rows(collection(
            {"type": "Feature", "id": 7, "properties": {"name": "a", "n": 1}, "geometry": AREA},
            {"type": "Feature", "properties": {"name": None, "n": 2.5, "ok": True}, "geometry": AREA},
            {"type": "Feature", "properties": {"name": "c"}, "geometry": POINT},
        ))
        self.assertEqual([r[0] for r in rows], ["7", "1", "2"])  # own id, else the position
        self.assertEqual(rows[0][1:], ({"name": "a", "n": 1}, AREA))
        self.assertEqual(stats.count, 3)
        self.assertEqual(stats.geometry_type(), "MultiPolygon")
        self.assertEqual(stats.field_types(), {"name": "null|string", "n": "number", "ok": "boolean"})

    def test_missing_geometry_and_properties(self):
        rows, stats = self.rows(collection({"type": "Feature", "properties": None, "geometry": None}))
        self.assertEqual(rows, [("0", {}, None)])
        self.assertIsNone(stats.geometry_type())

    def test_empty_collection(self):
        rows, stats = self.rows(collection())
        self.assertEqual((rows, stats.count), ([], 0))

    def test_not_a_feature_collection(self):
        # e.g. the forest-areas .json files: a plain list of attribute rows
        with self.assertRaises(ValueError):
            self.rows([{"id": 1}])
        with self.assertRaises(ValueError):
            self.rows(None)  # sync.load_json gives None for unreadable JSON

    def test_crs(self):
        wgs = {"type": "name", "properties": {"name": "urn:ogc:def:crs:OGC:1.3:CRS84"}}
        self.assertEqual(len(self.rows(collection({"geometry": POINT}, crs=wgs))[0]), 1)
        bgs = {"type": "name", "properties": {"name": "urn:ogc:def:crs:EPSG::7801"}}
        with self.assertRaises(ValueError):
            self.rows(collection({"geometry": POINT}, crs=bgs))


class KindTest(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(load_db.kind_of(["a/b.geojson"], "ok"), "vector")
        self.assertEqual(load_db.kind_of(["x.shp", "x.dbf", "x.prj"], "ok"), "vector")
        self.assertEqual(load_db.kind_of(["x.csv"], "ok"), "table")
        self.assertEqual(load_db.kind_of(["x.7z"], "ok"), "archive")
        self.assertEqual(load_db.kind_of(["https://www.sofia.bg/page"], "link"), "link")
        self.assertEqual(load_db.kind_of(["https://gtfs.sofiatraffic.bg/api/v1/alerts"], "ok"), "other")


class CatalogRowsTest(unittest.TestCase):
    pkg = {
        "id": "pkg-1", "name": "bus-lines", "title": "Bus lines",
        "groups": [{"name": "mobility"}, {"name": "buldings"}],
        "organization": {"name": "sofiaplan"},
        "tags": [{"name": "GeoJSON"}, {"name": "CSV"}],
        "extras": [{"key": "Актуален към", "value": "28.08.2026 г."}],
        "license_id": "cc-by",
        "metadata_created": "2026-01-01T00:00:00.5",
        "metadata_modified": "2026-02-01T10:00:00+00:00",
    }

    def test_dataset_row(self):
        row = load_db.dataset_row(self.pkg)
        self.assertEqual(row["section"], "buildings")  # misspelled group slug fixed, as in sync.py
        self.assertEqual(row["groups"], ["buildings", "mobility"])
        self.assertEqual(row["tags"], ["CSV", "GeoJSON"])
        self.assertEqual(row["organization"], "sofiaplan")
        self.assertEqual(row["license"], "cc-by")
        self.assertEqual(row["extras"], {"Актуален към": "28.08.2026 г."})
        self.assertEqual(row["metadata_created"], "2026-01-01T00:00:00.5+00:00")
        self.assertEqual(row["metadata_modified"], "2026-02-01T10:00:00+00:00")
        self.assertIs(row["raw"], self.pkg)

    def test_resource_row_multi_part(self):
        meta = {"status": "ok", "size": 3, "parts": [{"file": "r__a.geojson", "sha256": "aa"},
                                                     {"file": "r__b.geojson", "sha256": "bb"}]}
        res = {"id": "r", "url": "https://a/1, https://a/2", "format": "GeoJSON"}
        row = load_db.resource_row(self.pkg, res, meta)
        self.assertEqual(row["file_path"], "buildings/bus-lines/r__a.geojson;buildings/bus-lines/r__b.geojson")
        self.assertEqual(row["kind"], "vector")
        self.assertEqual(load_db.resource_layers(meta, "buildings/bus-lines"),
                         [("buildings/bus-lines/r__a.geojson", "aa"), ("buildings/bus-lines/r__b.geojson", "bb")])

    def test_resource_row_not_downloaded(self):
        res = {"id": "r", "url": "https://api.sofiaplan.bg/datasets/1", "format": "GeoJSON"}
        row = load_db.resource_row(self.pkg, res, {"status": "error", "file": "stale.geojson"})
        self.assertEqual((row["file_path"], row["kind"], row["status"]), (None, "vector", "error"))
        self.assertEqual(load_db.resource_layers({"status": "error"}, "x"), [])
        self.assertEqual(load_db.resource_row(self.pkg, res, {})["status"], "not-fetched")

    def test_only_geojson_files_become_layers(self):
        meta = {"status": "ok", "file": "r__x.zip", "sha256": "cc"}
        self.assertEqual(load_db.resource_layers(meta, "d"), [])


if __name__ == "__main__":
    unittest.main()
