"""Checks on what the LLM may run and read (web/llm_tools.py). Those that
need the database are skipped without it; the ones on the read-only
login also without that role (db/app/llm_role.sql)."""

import datetime
import decimal
import json
import os
import unittest

import psycopg

from web.llm_tools import (LLM_DSN, MAX_CELL, MAX_FEATURES, MAX_ROWS, data_issue_index,
                           describe_table, parse_comments, plain, query_geojson, read_data_issues,
                           run_sql, schema_summary, wrap_query)

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")


def connect(dsn=DSN):
    try:
        return psycopg.connect(dsn, connect_timeout=3)
    except psycopg.OperationalError as e:
        raise unittest.SkipTest(f"no database: {e}")


class WrapQueryTest(unittest.TestCase):
    def test_a_trailing_semicolon_and_comment_are_harmless(self):
        sql = wrap_query("SELECT 1 -- one;\n;  ", 10)
        self.assertTrue(sql.startswith("SELECT * FROM (\nSELECT 1 -- one;\n) AS q"))
        self.assertTrue(sql.endswith("LIMIT 10"))


class PlainTest(unittest.TestCase):
    def test_values(self):
        self.assertEqual(plain(decimal.Decimal("3")), 3)
        self.assertEqual(plain(decimal.Decimal("0.25")), 0.25)
        self.assertEqual(plain(datetime.date(2026, 10, 6)), "2026-10-06")
        self.assertEqual(plain({"a": "б"}), '{"a": "б"}')
        self.assertEqual(plain(b"abc"), "<3 bytes>")

    def test_long_text_is_cut(self):
        text = plain("x" * 1000)
        self.assertTrue(text.startswith("x" * MAX_CELL))
        self.assertIn("(1000 characters)", text)


class ParseCommentsTest(unittest.TestCase):
    SQL = """\
CREATE SCHEMA IF NOT EXISTS city;
SET search_path = city, public;

-- ---------------------------------------------------------------- metro

-- The lines as operated. Not in the portal
-- data.
CREATE TABLE IF NOT EXISTS metro_lines (
    code   text PRIMARY KEY,                  -- M1 .. M4
    name   text NOT NULL,                     -- termini,
                                              -- as signed
    color  text NOT NULL
);

-- Unrelated note.

CREATE OR REPLACE VIEW metro_issues AS
SELECT 1;
-- Known gaps.
CREATE TABLE IF NOT EXISTS live.fetches (
    id bigint                                 -- the fetch
);
"""

    def test_tables_and_columns(self):
        tables = parse_comments(self.SQL)
        self.assertEqual(tables["city.metro_lines"], {
            "comment": "The lines as operated. Not in the portal data.",
            "columns": {"code": "M1 .. M4", "name": "termini, as signed"}})

    def test_a_comment_separated_by_a_blank_line_is_not_the_tables(self):
        self.assertEqual(parse_comments(self.SQL)["city.metro_issues"]["comment"], "")

    def test_a_qualified_name_keeps_its_schema(self):
        tables = parse_comments(self.SQL)
        self.assertEqual(tables["live.fetches"], {"comment": "Known gaps.", "columns": {"id": "the fetch"}})


class DataIssuesTest(unittest.TestCase):
    TEXT = """\
# Data issues

## Summary

| # | Issue |
|---|-------|
| 1 | One |

## Metro

### 1. One

- **Status:** open.

### 2. Two

Body two.

## Areas

### 10. Ten

Body ten.
"""

    def test_the_index_is_the_summary_table(self):
        self.assertEqual(data_issue_index(self.TEXT), "| # | Issue |\n|---|-------|\n| 1 | One |")

    def test_an_issue_ends_at_the_next_issue_or_section(self):
        self.assertEqual(read_data_issues([2, 10], self.TEXT),
                         {"issues": ["### 2. Two\n\nBody two.", "### 10. Ten\n\nBody ten."]})

    def test_unknown_numbers_are_named(self):
        self.assertEqual(read_data_issues([1, 99], self.TEXT),
                         {"issues": ["### 1. One\n\n- **Status:** open."], "unknown": [99]})

    def test_the_real_file_has_an_index(self):
        self.assertIn("| 1 ", data_issue_index())


class RunSqlTest(unittest.TestCase):
    """As the owner of the data: the transaction alone must keep it safe."""

    @classmethod
    def setUpClass(cls):
        connect().close()

    def test_rows_and_columns(self):
        r = run_sql("SELECT 1 AS a, 'x' AS b UNION ALL SELECT 2, 'y' ORDER BY a;", DSN)
        self.assertEqual(r, {"columns": ["a", "b"], "rows": [[1, "x"], [2, "y"]],
                             "row_count": 2, "truncated": False})

    def test_geometries_are_summarised(self):
        r = run_sql("SELECT ST_SetSRID(ST_MakePoint(23.32, 42.69), 4326) AS g, NULL::geometry AS n", DSN)
        self.assertEqual(r["rows"], [["Point, 1 points, at POINT(23.32 42.69)", None]])

    def test_rows_are_capped(self):
        r = run_sql("SELECT generate_series(1, 1000) AS n", DSN)
        self.assertEqual(r["row_count"], MAX_ROWS)
        self.assertTrue(r["truncated"])
        self.assertIn("note", r)

    def test_a_big_result_is_cut_to_fit(self):
        r = run_sql("SELECT repeat('x', 290) AS t FROM generate_series(1, 150)", DSN)
        self.assertLess(r["row_count"], 150)
        self.assertTrue(r["truncated"])

    def test_writes_are_refused(self):
        for sql in ("CREATE TABLE app.llm_test (a int)",
                    "SELECT 1; CREATE TABLE app.llm_test (a int)",
                    "WITH d AS (DELETE FROM app.focuses RETURNING *) SELECT * FROM d",
                    "SELECT 1) AS q; SET statement_timeout = 0; SELECT (1"):
            self.assertIn("error", run_sql(sql, DSN), sql)

    def test_an_error_is_returned_for_the_model(self):
        r = run_sql("SELECT * FROM city.no_such_table", DSN)
        self.assertEqual(r, {"error": '42P01 relation "city.no_such_table" does not exist'})

    def test_an_empty_query(self):
        self.assertEqual(run_sql("  ", DSN), {"error": "the query is empty"})


class QueryGeojsonTest(unittest.TestCase):
    POINT = "ST_SetSRID(ST_MakePoint(23.32, 42.69), 4326)"

    @classmethod
    def setUpClass(cls):
        connect().close()

    def test_features_with_their_columns(self):
        result, geojson = query_geojson(f"SELECT 'Сердика' AS name, 3 AS n, {self.POINT} AS geom;", DSN)
        self.assertEqual(result, {"shown": 1, "geometry_types": ["POINT"], "columns": ["n", "name"],
                                  "extent": [23.32, 42.69, 23.32, 42.69], "truncated": False})
        doc = json.loads(geojson)
        self.assertEqual(doc["features"], [{"type": "Feature", "properties": {"name": "Сердика", "n": 3},
                                            "geometry": {"type": "Point", "coordinates": [23.32, 42.69]}}])

    def test_geography_and_other_srids_come_out_in_degrees(self):
        _, geojson = query_geojson(f"SELECT ST_Transform({self.POINT}, 3857)::geometry AS geom", DSN)
        x, y = json.loads(geojson)["features"][0]["geometry"]["coordinates"]
        self.assertAlmostEqual(x, 23.32, 5)
        _, geojson = query_geojson(f"SELECT {self.POINT}::geography AS geom", DSN)
        self.assertEqual(json.loads(geojson)["features"][0]["geometry"]["coordinates"], [23.32, 42.69])

    def test_features_are_capped(self):
        result, geojson = query_geojson(f"SELECT i, {self.POINT} AS geom FROM generate_series(1, {MAX_FEATURES + 10}) i", DSN)
        self.assertEqual(result["shown"], MAX_FEATURES)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(json.loads(geojson)["features"]), MAX_FEATURES)

    def test_rows_without_a_geometry_are_counted(self):
        result, _ = query_geojson(f"SELECT {self.POINT} AS geom UNION ALL SELECT NULL", DSN)
        self.assertEqual(result["without_geometry"], 1)

    def test_errors(self):
        for sql, error in [("SELECT 1 AS x", "named geom"),
                           ("SELECT ST_MakePoint(1, 2) AS geom", "no SRID"),
                           (f"SELECT {self.POINT} AS geom WHERE false", "no rows"),
                           ("SELECT NULL::geometry AS geom", "no row has a geometry"),
                           (f"SELECT 1; SELECT {self.POINT} AS geom", "syntax error"),
                           ("DELETE FROM app.focuses RETURNING id, NULL::geometry AS geom", "syntax error")]:
            result, geojson = query_geojson(sql, DSN)
            self.assertIn(error, result.get("error", ""), sql)
            self.assertIsNone(geojson)


class SchemaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = connect()

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def test_the_summary_names_tables_with_their_documentation(self):
        summary = schema_summary(self.conn)
        self.assertIn("city.metro_lines: code text, name text", summary)
        self.assertIn("-- The lines as operated.", summary)

    def test_the_summary_leaves_out_partitions(self):
        partitions = [n for (n,) in self.conn.execute(
            "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE nspname = 'live' AND relispartition")]
        summary = schema_summary(self.conn)
        for p in partitions:
            self.assertNotIn(f"live.{p}:", summary)

    def test_describe_a_table(self):
        d = describe_table("city.metro_lines", DSN)
        self.assertEqual(d["columns"][0], {"name": "code", "type": "text", "not_null": True,
                                           "comment": "M1 .. M4"})
        self.assertTrue(d["about"].startswith("The lines as operated."))
        self.assertEqual(d["sample"]["columns"][0], "code")

    def test_describe_refuses_other_names(self):
        self.assertIn("error", describe_table("metro_lines", DSN))
        self.assertIn("error", describe_table("pg_catalog.pg_authid", DSN))
        self.assertIn("error", describe_table("city.no_such_table", DSN))


class ReadOnlyLoginTest(unittest.TestCase):
    """The urban_llm login itself may not write, even outside our
    transaction settings."""

    @classmethod
    def setUpClass(cls):
        try:
            cls.conn = psycopg.connect(LLM_DSN, connect_timeout=3, autocommit=True)
        except psycopg.OperationalError as e:
            raise unittest.SkipTest(f"no read-only login: {e}")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def test_can_read(self):
        (n,) = self.conn.execute("SELECT count(*) FROM city.metro_lines").fetchone()
        self.assertGreater(n, 0)

    def test_cannot_write_even_in_a_read_write_transaction(self):
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with self.conn.transaction():
                self.conn.execute("SET TRANSACTION READ WRITE")
                self.conn.execute("DELETE FROM app.focuses")

    def test_run_sql_uses_it(self):
        self.assertEqual(run_sql("SELECT current_user AS u")["rows"], [["urban_llm"]])


if __name__ == "__main__":
    unittest.main()
