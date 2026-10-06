"""What the LLM may look at: read-only SQL over the data, the tables and
their documentation, and the known data issues.

Every function returns plain JSON-able values; the chat loop (web/llm.py)
hands them to the model as tool output. Errors the model can act on (a
bad query, an unknown table) are returned, not raised, so it can retry.

The SQL runs as the read-only login urban_llm (db/app/llm_role.sql):
$LLM_DATABASE_URL, or the local default with the password from ~/.pgpass.
"""

import datetime
import decimal
import json
import os
import re
from pathlib import Path

import psycopg

LLM_DSN = os.environ.get("LLM_DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urban_llm")
ROOT = Path(__file__).resolve().parent.parent
SCHEMAS = ["city", "urban", "gtfs", "live", "app"]
# The files that document the tables, by the schema they create.
SCHEMA_FILES = [ROOT / "db/schema.sql", ROOT / "db/city/schema.sql",
                ROOT / "db/live/schema.sql", ROOT / "db/app/schema.sql"]
DATA_ISSUES = ROOT / "DATA_ISSUES.md"

TIMEOUT = "15s"
MAX_ROWS = 200        # rows given to the model; the query may match more
MAX_CELL = 300        # characters of one value
MAX_CHARS = 20_000    # of the whole result, so one query cannot fill the context


def connect(dsn: str = LLM_DSN):
    return psycopg.connect(dsn, connect_timeout=5)


def wrap_query(sql: str, limit: int) -> str:
    """The query as a subquery, so that it can only be a SELECT (or WITH ...
    SELECT), not a SET or a data-modifying WITH. The newline keeps a
    trailing -- comment from swallowing the parenthesis."""
    body = sql.strip().rstrip(";").strip()
    return f"SELECT * FROM (\n{body}\n) AS q LIMIT {int(limit)}"


def plain(value):
    """A value as the model should see it: short, and valid JSON."""
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, decimal.Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, (datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        return str(value)
    if isinstance(value, (bytes, memoryview)):
        return f"<{len(value)} bytes>"
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    return text if len(text) <= MAX_CELL else text[:MAX_CELL] + f"… ({len(text)} characters)"


def geometry_oids(conn) -> set[int]:
    return {oid for (oid,) in conn.execute(
        "SELECT oid FROM pg_type WHERE typname IN ('geometry', 'geography')")}


def summarise_geometries(conn, values: list) -> list:
    """Each geometry as its type, size and a point inside it, instead of
    kilobytes of coordinates the model cannot use. The values are the hex
    EWKB that psycopg returns for geometry and geography."""
    rows = conn.execute("""
        SELECT CASE WHEN g IS NULL THEN NULL
                    ELSE format('%%s, %%s points, at %%s', replace(ST_GeometryType(g), 'ST_', ''), ST_NPoints(g),
                                ST_AsText(ST_Centroid(g), 5)) END
          FROM (SELECT ST_GeomFromEWKB(decode(h, 'hex')) AS g, i
                  FROM unnest(%s::text[]) WITH ORDINALITY AS t(h, i)) t
         ORDER BY i
    """, (values,)).fetchall()
    return [r[0] for r in rows]


def read_only(conn):
    """Start the transaction every query of the model runs in."""
    conn.execute("SET TRANSACTION READ ONLY")
    conn.execute(f"SET LOCAL statement_timeout = '{TIMEOUT}'")


def query_error(e: psycopg.Error) -> dict:
    """A failed query as an error the model can act on."""
    if isinstance(e, psycopg.errors.QueryCanceled):
        return {"error": f"the query ran longer than {TIMEOUT} and was stopped. Filter with the "
                         "spatial indexes (geom && ST_Expand(...), ORDER BY geom <-> point) or "
                         "aggregate before joining."}
    if isinstance(e, psycopg.OperationalError):
        return {"error": f"cannot reach the database: {e}"}
    diag = e.diag
    message = diag.message_primary or str(e)
    for extra in (diag.message_detail, diag.message_hint):
        if extra:
            message += f" ({extra})"
    return {"error": f"{diag.sqlstate or ''} {message}".strip()}


def run_sql(sql: str, dsn: str = LLM_DSN) -> dict:
    """Run one read-only query; at most MAX_ROWS rows come back.

    {"columns": [...], "rows": [[...]], "row_count": n, "truncated": bool}
    or {"error": "..."}.
    """
    if not sql or not sql.strip():
        return {"error": "the query is empty"}
    try:
        with connect(dsn) as conn:
            read_only(conn)
            # Prepared, so that the server refuses more than one statement:
            # the subquery alone can be closed early by the text itself.
            cur = conn.execute(wrap_query(sql, MAX_ROWS + 1), prepare=True)
            columns = [d.name for d in cur.description]
            rows = cur.fetchall()
            more = len(rows) > MAX_ROWS
            rows = [list(r) for r in rows[:MAX_ROWS]]
            geo = geometry_oids(conn)
            for i, d in enumerate(cur.description):
                if d.type_code in geo and rows:
                    for r, s in zip(rows, summarise_geometries(conn, [r[i] for r in rows])):
                        r[i] = s
            conn.rollback()
    except psycopg.Error as e:
        return query_error(e)

    result = {"columns": columns, "rows": [[plain(v) for v in r] for r in rows],
              "row_count": len(rows), "truncated": more}
    # Drop rows from the end until the result fits.
    while len(json.dumps(result, ensure_ascii=False)) > MAX_CHARS and result["rows"]:
        result["rows"] = result["rows"][:len(result["rows"]) * 3 // 4]
        result["row_count"] = len(result["rows"])
        result["truncated"] = True
    if result["truncated"]:
        result["note"] = (f"only the first {result['row_count']} rows are shown; "
                          "aggregate, or add a LIMIT and ORDER BY, to see what matters")
    return result


# ------------------------------------------------------------- the map

MAX_FEATURES = 5000          # drawn on the map from one query
MAX_GEOJSON = 8_000_000      # bytes sent to the page


def query_geojson(sql: str, dsn: str = LLM_DSN) -> tuple[dict, str | None]:
    """Run one read-only query with a geom column for the map.

    Returns what the model is told (how many features, of which types,
    where, with which columns; or {"error": ...}) and the FeatureCollection
    for the page, with every other column as a property. The model never
    gets the coordinates: it already knows the query.
    """
    if not sql or not sql.strip():
        return {"error": "the query is empty"}, None
    # The row number marks the one row past the cap, which only says
    # that there were more.
    body = sql.strip().rstrip(";").strip()
    query = f"""
        SELECT json_build_object('type', 'FeatureCollection', 'features', coalesce(json_agg(
                   json_build_object('type', 'Feature',
                                     'geometry', ST_AsGeoJSON(ST_Transform(t.geom::geometry, 4326), 6)::json,
                                     'properties', to_jsonb(t) - 'geom' - 'llm_n'))
                   FILTER (WHERE t.llm_n <= {MAX_FEATURES}), '[]'))::text,
               count(*) FILTER (WHERE t.llm_n <= {MAX_FEATURES}),
               count(*) > {MAX_FEATURES},
               count(*) FILTER (WHERE t.geom IS NULL),
               array_agg(DISTINCT GeometryType(t.geom::geometry)) FILTER (WHERE t.geom IS NOT NULL),
               ST_Extent(ST_Transform(t.geom::geometry, 4326)),
               (SELECT array_agg(key) FROM jsonb_object_keys((array_agg(to_jsonb(t) - 'geom' - 'llm_n'))[1]) key)
          FROM (SELECT q.*, row_number() OVER () AS llm_n FROM (
{body}
) AS q LIMIT {MAX_FEATURES + 1}) AS t
    """
    try:
        with connect(dsn) as conn:
            read_only(conn)
            row = conn.execute(query, prepare=True).fetchone()
            conn.rollback()
    except psycopg.Error as e:
        message = e.diag.message_primary or ""
        if isinstance(e, psycopg.errors.UndefinedColumn) and re.search(r"\bt\.geom\b", message):
            return {"error": "the query must return the geometry as a column named geom "
                             "(e.g. SELECT name, point AS geom FROM ...)"}, None
        if "unknown (0) SRID" in message:
            return {"error": "the geometry has no SRID; give it one with ST_SetSRID(geom, 4326)"}, None
        return query_error(e), None
    geojson, shown, more, without, types, extent, columns = row
    if not shown:
        return {"error": "the query returned no rows, so nothing was drawn"}, None
    if without == shown:
        return {"error": "no row has a geometry in geom, so nothing was drawn"}, None
    if len(geojson) > MAX_GEOJSON:
        return {"error": f"the result is {len(geojson) // 1_000_000} MB, too big for the map "
                         "(the limit is 8 MB): simplify the shapes with ST_Simplify(geom, 0.0001), "
                         "or show fewer rows"}, None
    # BOX(minx miny,maxx maxy) as [west, south, east, north].
    extent = [round(float(v), 5) for v in re.findall(r"-?[\d.]+(?:e-?\d+)?", extent)]
    result = {"shown": shown, "geometry_types": types, "columns": columns or [],
              "extent": extent, "truncated": more}
    if without:
        result["without_geometry"] = without
    if more:
        result["note"] = f"only the first {MAX_FEATURES} rows are drawn"
    return result, geojson


# ------------------------------------------------------------- the schema

CREATE = re.compile(r"^CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?(?:TABLE|VIEW)\s+"
                    r"(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)", re.I)
COLUMN = re.compile(r"^\s+(\w+)\s+[^-]*?--\s?(.*)$")
SEARCH_PATH = re.compile(r"^SET\s+search_path\s*=\s*(\w+)", re.I)


def parse_comments(text: str, schema: str = "public") -> dict[str, dict]:
    """The comments in a schema file: for each "schema.table", the block
    right above its CREATE and the comment at the end of each column line.

    {"city.metro_lines": {"comment": "...", "columns": {"code": "M1 .. M4"}}}
    """
    tables, block, current, last_column = {}, [], None, None
    for line in text.splitlines():
        if m := SEARCH_PATH.match(line):
            schema = m.group(1)
        if current:
            if line.startswith(")"):
                current = None
            elif line.strip().startswith("--") and last_column:
                # A comment continued on the next line.
                current["columns"][last_column] += " " + line.strip()[2:].strip()
            elif m := COLUMN.match(line):
                last_column = m.group(1)
                current["columns"][last_column] = m.group(2).strip()
            continue
        if m := CREATE.match(line):
            name = m.group(1) if "." in m.group(1) else f"{schema}.{m.group(1)}"
            entry = {"comment": " ".join(block), "columns": {}}
            tables[name] = entry
            current, last_column = (entry if line.rstrip().endswith("(") else None), None
            block = []
        elif line.startswith("--") and not line.startswith("-- ---"):
            block.append(line[2:].strip())
        else:
            block = []
    for entry in tables.values():
        entry["comment"] = re.sub(r"\s+", " ", entry["comment"]).strip()
    return tables


def documented_tables() -> dict[str, dict]:
    tables = {}
    for path in SCHEMA_FILES:
        if path.exists():
            tables.update(parse_comments(path.read_text()))
    return tables


def first_sentence(text: str) -> str:
    m = re.match(r"(.+?[.;])(\s|$)", text)
    return (m.group(1) if m else text)[:200]


# The prompt carries every column, so the long type names are shortened.
SHORT_TYPES = [("timestamp with time zone", "timestamptz"), ("timestamp without time zone", "timestamp"),
               ("double precision", "float8"), ("character varying", "varchar")]


def schema_summary(conn) -> str:
    """Every table and view with its columns, one line each, and the first
    sentence of its documentation; partitions are left out."""
    docs = documented_tables()
    rows = conn.execute("""
        SELECT n.nspname || '.' || c.relname AS name,
               CASE c.relkind WHEN 'v' THEN ' (view)' WHEN 'm' THEN ' (materialized view)' ELSE '' END,
               string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
         WHERE n.nspname = ANY(%s) AND c.relkind IN ('r', 'v', 'm', 'p', 'f') AND NOT c.relispartition
         GROUP BY n.nspname, c.relname, c.relkind
         ORDER BY array_position(%s, n.nspname::text), name
    """, (SCHEMAS, SCHEMAS)).fetchall()
    lines = []
    for name, kind, columns in rows:
        for long, short in SHORT_TYPES:
            columns = columns.replace(long, short)
        about = first_sentence(docs.get(name, {}).get("comment", ""))
        lines.append(f"{name}{kind}: {columns}" + (f"\n    -- {about}" if about else ""))
    return "\n".join(lines)


def describe_table(name: str, dsn: str = LLM_DSN) -> dict:
    """A table's columns with their types and comments, its documentation,
    its size and three sample rows."""
    if not re.fullmatch(r"[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*", name or ""):
        return {"error": "give the table as schema.table, e.g. city.schools"}
    schema, table = name.split(".")
    if schema not in SCHEMAS:
        return {"error": f"unknown schema {schema}; the data is in {', '.join(SCHEMAS)}"}
    try:
        with connect(dsn) as conn:
            columns = conn.execute("""
                SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
                  FROM pg_attribute a
                 WHERE a.attrelid = to_regclass(%s) AND a.attnum > 0 AND NOT a.attisdropped
                 ORDER BY a.attnum
            """, (name,)).fetchall()
            if not columns:
                return {"error": f"there is no table {name}"}
            (estimate,) = conn.execute(
                "SELECT reltuples::bigint FROM pg_class WHERE oid = to_regclass(%s)", (name,)).fetchone()
    except psycopg.OperationalError as e:
        return {"error": f"cannot reach the database: {e}"}
    doc = documented_tables().get(name, {"comment": "", "columns": {}})
    sample = run_sql(f"SELECT * FROM {schema}.{table} LIMIT 3", dsn)
    return {
        "table": name,
        "about": doc["comment"] or None,
        # -1 for a table never analysed (and for views).
        "rows_estimate": estimate if estimate >= 0 else None,
        "columns": [{"name": n, "type": t, **({"not_null": True} if nn else {}),
                     **({"comment": doc["columns"][n]} if doc["columns"].get(n) else {})}
                    for n, t, nn in columns],
        "sample": sample,
    }


# ------------------------------------------------------- the data issues

ISSUE = re.compile(r"^### (\d+)\. (.*)$", re.M)


def data_issue_index(text: str | None = None) -> str:
    """The summary table of DATA_ISSUES.md: number, title, area, status."""
    text = DATA_ISSUES.read_text() if text is None else text
    m = re.search(r"^## Summary\n(.*?)(?=^## )", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def read_data_issues(numbers: list[int], text: str | None = None) -> dict:
    """The full entries of DATA_ISSUES.md with these numbers."""
    text = DATA_ISSUES.read_text() if text is None else text
    starts = list(ISSUE.finditer(text))
    found = {}
    for i, m in enumerate(starts):
        if int(m.group(1)) in numbers:
            end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
            # An issue ends where the next one, or the next section, begins.
            section = re.search(r"^## ", text[m.end():end], re.M)
            body = text[m.start():(m.end() + section.start()) if section else end]
            found[int(m.group(1))] = body.strip()
    missing = [n for n in numbers if n not in found]
    return {"issues": [found[n] for n in numbers if n in found],
            **({"unknown": missing} if missing else {})}
