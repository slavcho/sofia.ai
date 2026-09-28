import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sync  # noqa: E402


class FakeResponse:
    def __init__(self, url, body, filename):
        self.url = url
        self.status_code = 200
        self.body = body
        self.headers = {
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
            "Content-Disposition": f'attachment; filename="{filename}"',
        }

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    def iter_content(self, chunk):
        yield self.body


class FakeSession:
    """Serves fixed bodies; any URL not in `files` is a server error, like api.sofiaplan.bg."""

    def __init__(self, files):
        self.files = files
        self.requested = []

    def get(self, url, **kw):
        self.requested.append(url)
        if url not in self.files:
            raise sync.requests.HTTPError(f"500 Server Error for url: {url}")
        body, filename = self.files[url]
        return FakeResponse(url, body, filename)


def resource(url):
    return {"id": "res-1", "package_id": "pkg-1", "url": url, "format": "GeoJSON",
            "metadata_modified": "2026-01-01T00:00:00", "last_modified": None}


class SplitUrlsTest(unittest.TestCase):
    def test_single_url_unchanged(self):
        self.assertEqual(sync.split_urls("https://a/1"), ["https://a/1"])

    def test_comma_separated(self):
        self.assertEqual(sync.split_urls("https://a/1, https://a/2"), ["https://a/1", "https://a/2"])

    def test_comma_inside_non_url_is_left_alone(self):
        self.assertEqual(sync.split_urls("https://a/?q=1,2"), ["https://a/?q=1,2"])


class MultiUrlResourceTest(unittest.TestCase):
    # bus-lines on the portal: 'https://api.sofiaplan.bg/datasets/268, https://api.sofiaplan.bg/datasets/333'
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.files = {
            "https://api.sofiaplan.bg/datasets/268": (b'{"a": 1}', "lines_a.geojson"),
            "https://api.sofiaplan.bg/datasets/333": (b'{"b": 2}', "lines_b.geojson"),
        }
        self.orig_retries = sync.RETRIES
        sync.RETRIES = 1

    def tearDown(self):
        sync.RETRIES = self.orig_retries
        self.tmp.cleanup()

    def test_downloads_every_part(self):
        s = FakeSession(self.files)
        res = resource(", ".join(self.files))
        meta = sync.sync_resource(s, res, self.dir, None)

        self.assertEqual(meta["status"], "ok", meta.get("error"))
        self.assertEqual(s.requested, list(self.files))
        self.assertEqual([p["url"] for p in meta["parts"]], list(self.files))
        for part, (body, filename) in zip(meta["parts"], self.files.values()):
            self.assertEqual(part["file"], f"res-1__{filename}")
            self.assertEqual((self.dir / part["file"]).read_bytes(), body)
            self.assertEqual(part["sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(meta["size"], sum(len(b) for b, _ in self.files.values()))
        self.assertFalse(sync.needs_download(res, self.dir, meta, force=False))

    def test_one_failed_part_fails_the_resource(self):
        s = FakeSession(dict(list(self.files.items())[:1]))
        meta = sync.sync_resource(s, resource(", ".join(self.files)), self.dir, None)
        self.assertEqual(meta["status"], "error")

    def test_single_url_meta_is_unchanged(self):
        url, (body, filename) = next(iter(self.files.items()))
        meta = sync.sync_resource(FakeSession(self.files), resource(url), self.dir, None)
        self.assertEqual(meta["status"], "ok")
        self.assertEqual(meta["file"], f"res-1__{filename}")
        self.assertNotIn("parts", meta)


class DatasetJsonTest(unittest.TestCase):
    # Rewriting all 344 dataset.json files on every run is slow over the NAS mount.
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.pkg = {"id": "pkg-1", "name": "bus-lines", "metadata_modified": "2026-01-01T00:00:00"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_written_when_missing(self):
        self.assertTrue(sync.write_dataset_json(self.pkg, self.dir, {"pkg-1": dict(self.pkg)}))
        self.assertEqual(sync.load_json(self.dir / "dataset.json"), self.pkg)

    def test_skipped_when_unchanged(self):
        sync.save_json(self.dir / "dataset.json", self.pkg)
        self.assertFalse(sync.write_dataset_json(self.pkg, self.dir, {"pkg-1": dict(self.pkg)}))

    def test_written_when_modified(self):
        sync.save_json(self.dir / "dataset.json", self.pkg)
        newer = dict(self.pkg, metadata_modified="2026-02-01T00:00:00")
        self.assertTrue(sync.write_dataset_json(newer, self.dir, {"pkg-1": self.pkg}))
        self.assertEqual(sync.load_json(self.dir / "dataset.json"), newer)

    def test_written_when_new_on_portal(self):
        sync.save_json(self.dir / "dataset.json", {"stale": True})
        self.assertTrue(sync.write_dataset_json(self.pkg, self.dir, {}))
        self.assertEqual(sync.load_json(self.dir / "dataset.json"), self.pkg)


if __name__ == "__main__":
    unittest.main()
