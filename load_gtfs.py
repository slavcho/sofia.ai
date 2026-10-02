#!/usr/bin/env python3
"""Load the static GTFS timetable of Sofia's public transport into schema gtfs.

  python3 load_gtfs.py            # the zip mirrored by sync.py (dataset gtfs-static)
  python3 load_gtfs.py --force    # reload even if the zip did not change
  python3 load_gtfs.py --zip x.zip

The feed is kept as published: one table per file (gtfs.stops,
gtfs.stop_times, ...), every column as text, empty values as NULL. Typing
and interpretation (times past 24:00, which stops are served, ...) happen
in db/city/transit.sql, so a change of the feed's columns never breaks the
load. gtfs.feed says which file was loaded, from where and when.

The whole feed loads in one transaction: a half-loaded timetable would be
worse than the previous one.

Connection: --dsn or $DATABASE_URL, else as load_db.py.
"""
import argparse
import csv
import io
import json
import os
import re
import sys
import time
import zipfile
from pathlib import Path

import psycopg
from psycopg import sql

DEFAULT_DSN = "host=127.0.0.1 dbname=urbandata user=urbanuser"
DATASET_DIR = "mobility/gtfs-static"

# Looked up often by the city scripts.
INDEXES = {
    "stop_times": ["trip_id", "stop_id"],
    "trips": ["trip_id", "route_id", "service_id"],
    "shapes": ["shape_id"],
    "calendar_dates": ["date"],
    "stops": ["stop_id"],
    "routes": ["route_id"],
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def table_name(member):
    """stops.txt -> stops; None for what is not a GTFS table."""
    m = re.fullmatch(r"(?:.*/)?([a-z_]+)\.txt", member)
    return m.group(1) if m else None


def read_table(zf, member):
    """(columns, rows) of one file; rows are lists with None for empty values."""
    reader = csv.reader(io.TextIOWrapper(zf.open(member), "utf-8-sig", newline=""))
    columns = [c.strip() for c in next(reader)]
    if len(set(columns)) != len(columns) or not all(re.fullmatch(r"[a-z_]+", c) for c in columns):
        raise ValueError(f"{member}: unexpected header {columns}")

    def rows():
        for row in reader:
            if not any(row):
                continue
            if len(row) != len(columns):
                raise ValueError(f"{member} line {reader.line_num}: {len(row)} values for {len(columns)} columns")
            yield [v if v != "" else None for v in row]
    return columns, rows()


def find_zip(data_dir):
    zips = sorted((data_dir / DATASET_DIR).glob("*.zip"))
    if len(zips) != 1:
        raise SystemExit(f"expected one zip in {data_dir / DATASET_DIR}, found {len(zips)}")
    return zips[0]


def feed_meta(path):
    """The sync.py record of the zip: source URL, sha256, download time."""
    meta_path = path.parent / (path.name.split("__")[0] + ".meta.json")
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    return {"source_url": meta.get("final_url") or meta.get("url"),
            "sha256": meta.get("sha256"), "downloaded_at": meta.get("downloaded_at")}


def load(conn, path, meta):
    with zipfile.ZipFile(path) as zf, conn.transaction():
        conn.execute("CREATE SCHEMA IF NOT EXISTS gtfs")
        conn.execute("""CREATE TABLE IF NOT EXISTS gtfs.feed (
                          file text NOT NULL, source_url text, sha256 text,
                          downloaded_at timestamptz, loaded_at timestamptz NOT NULL DEFAULT now())""")
        conn.execute("DELETE FROM gtfs.feed")
        for member in zf.namelist():
            name = table_name(member)
            if not name or name == "feed":
                continue
            t = time.time()
            columns, rows = read_table(zf, member)
            table = sql.Identifier("gtfs", name)
            conn.execute(sql.SQL("DROP TABLE IF EXISTS {}").format(table))
            conn.execute(sql.SQL("CREATE TABLE {} ({})").format(
                table, sql.SQL(", ").join(sql.SQL("{} text").format(sql.Identifier(c)) for c in columns)))
            n = 0
            with conn.cursor().copy(sql.SQL("COPY {} FROM STDIN").format(table)) as copy:
                for row in rows:
                    copy.write_row(row)
                    n += 1
            for col in INDEXES.get(name, []):
                if col in columns:
                    conn.execute(sql.SQL("CREATE INDEX ON {} ({})").format(table, sql.Identifier(col)))
            conn.execute(sql.SQL("ANALYZE {}").format(table))
            log(f"{n:9} rows {time.time() - t:5.1f}s  gtfs.{name}")
        conn.execute("INSERT INTO gtfs.feed (file, source_url, sha256, downloaded_at) VALUES (%s, %s, %s, %s)",
                     (path.name, meta["source_url"], meta["sha256"], meta["downloaded_at"]))


def is_current(conn, meta):
    if not conn.execute("SELECT to_regclass('gtfs.feed')").fetchone()[0]:
        return False
    row = conn.execute("SELECT sha256 FROM gtfs.feed").fetchone()
    return bool(row and meta["sha256"] and row[0] == meta["sha256"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", type=Path, default=Path(os.environ.get("SOFIA_DATA_DIR", "data")))
    ap.add_argument("--zip", type=Path, help="this file instead of the mirrored one")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL", DEFAULT_DSN))
    ap.add_argument("--force", action="store_true", help="reload even if unchanged")
    args = ap.parse_args()

    path = args.zip or find_zip(args.data_dir)
    meta = feed_meta(path)
    # autocommit: conn.transaction() in load() is then a real transaction
    conn = psycopg.connect(args.dsn, autocommit=True)
    if not args.force and is_current(conn, meta):
        log(f"unchanged: {path.name}")
        return 0
    load(conn, path, meta)
    log(f"loaded {path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
