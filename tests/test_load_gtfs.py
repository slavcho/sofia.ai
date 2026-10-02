import io
import sys
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import load_gtfs  # noqa: E402


def feed(**files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, text in files.items():
            zf.writestr(name, text)
    buf.seek(0)
    return zipfile.ZipFile(buf)


class ReadTableTest(unittest.TestCase):
    def test_empty_values_are_null_and_bom_is_dropped(self):
        zf = feed(**{"stops.txt": "﻿stop_id,stop_code,parent_station\r\nA1,0001,\r\n\r\nM1,,OMSt\r\n"})
        columns, rows = load_gtfs.read_table(zf, "stops.txt")
        self.assertEqual(columns, ["stop_id", "stop_code", "parent_station"])
        self.assertEqual(list(rows), [["A1", "0001", None], ["M1", None, "OMSt"]])

    def test_quoted_commas_stay_in_the_value(self):
        zf = feed(**{"stops.txt": 'stop_id,stop_name\nA1,"УЛ. X, БЛ. 5"\n'})
        self.assertEqual(list(load_gtfs.read_table(zf, "stops.txt")[1]), [["A1", "УЛ. X, БЛ. 5"]])

    def test_a_short_row_is_an_error(self):
        zf = feed(**{"stops.txt": "stop_id,stop_name\nA1\n"})
        with self.assertRaises(ValueError):
            list(load_gtfs.read_table(zf, "stops.txt")[1])

    def test_table_names(self):
        self.assertEqual(load_gtfs.table_name("stop_times.txt"), "stop_times")
        self.assertEqual(load_gtfs.table_name("gtfs/stops.txt"), "stops")
        self.assertIsNone(load_gtfs.table_name("README.md"))


if __name__ == "__main__":
    unittest.main()
