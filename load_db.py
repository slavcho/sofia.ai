#!/usr/bin/env python3
"""Load the mirrored urbandata.sofia.bg files into PostGIS (see db/schema.sql).

  python3 load_db.py                      # catalog + every GeoJSON/CSV/Excel/JSON layer, also inside zips
  python3 load_db.py --dataset bus-lines  # only these datasets (repeatable)
  python3 load_db.py --only-catalog       # datasets/resources tables only
  python3 load_db.py --force              # reload layers even if unchanged

Connection: --dsn or $DATABASE_URL, else host 127.0.0.1, database urbandata,
user urbanuser; the password comes from ~/.pgpass. (127.0.0.1, not localhost:
.pgpass matches the host name literally.)

A layer is reloaded only when the sha256 of its source file changed. Every
layer loads in its own transaction, so one broken file does not stop the run.
"""
import argparse
import csv
import datetime as dt
import io
import json
import os
import re
import sys
import time
import zipfile
from collections import Counter
from pathlib import Path

import openpyxl
import psycopg
import xlrd
from psycopg.types.json import Jsonb

import sync

DEFAULT_DSN = "host=127.0.0.1 dbname=urbandata user=urbanuser"

# Shapefile side files (.dbf, .shx, ...) carry no kind of their own.
KIND_BY_EXT = {
    ".geojson": "vector", ".shp": "vector",
    ".json": "table", ".csv": "table", ".xlsx": "table", ".xls": "table",
    ".tif": "raster", ".tiff": "raster",
    ".zip": "archive", ".7z": "archive", ".rar": "archive",
    ".pdf": "document", ".doc": "document", ".docx": "document",
}
KIND_ORDER = ["vector", "table", "raster", "archive", "document"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def utc(ts):
    """CKAN timestamps are UTC without an offset; Postgres would read them as local time."""
    if not ts or "+" in ts[10:] or ts.endswith("Z"):
        return ts
    return ts + "+00:00"


def kind_of(files, status):
    if status == "link":
        return "link"
    kinds = {KIND_BY_EXT.get(os.path.splitext(f)[1].lower()) for f in files} - {None}
    for k in KIND_ORDER:
        if k in kinds:
            return k
    return "other"


# ---- catalog rows ---------------------------------------------------------

def section_row(group):
    return {
        "slug": sync.SECTION_FIX.get(group["name"], group["name"]),
        "ckan_id": group.get("id"),
        "title": group.get("title") or group.get("display_name"),
        "description": group.get("description"),
        "raw": group,
    }


def organization_row(org):
    return {
        "slug": org["name"],
        "ckan_id": org.get("id"),
        "title": org.get("title"),
        "description": org.get("description"),
        "raw": org,
    }


def dataset_row(pkg):
    return {
        "id": pkg["id"],
        "name": pkg["name"],
        "title": pkg.get("title"),
        "notes": pkg.get("notes"),
        "section": sync.section_of(pkg),
        "organization": (pkg.get("organization") or {}).get("name"),
        "groups": sorted(sync.SECTION_FIX.get(g["name"], g["name"]) for g in pkg.get("groups") or []),
        "tags": sorted(t["name"] for t in pkg.get("tags") or []),
        "license": pkg.get("license_title") or pkg.get("license_id"),
        "metadata_created": utc(pkg.get("metadata_created")),
        "metadata_modified": utc(pkg.get("metadata_modified")),
        "extras": {e["key"]: e["value"] for e in pkg.get("extras") or []},
        "raw": pkg,
    }


def resource_row(pkg, res, meta):
    rel_dir = f"{sync.section_of(pkg)}/{pkg['name']}"
    files = [f"{rel_dir}/{f}" for f in sync.meta_files(meta)] if meta.get("status") == "ok" else []
    return {
        "id": res["id"],
        "dataset_id": pkg["id"],
        "name": res.get("name"),
        "format": res.get("format"),
        "url": res.get("url"),
        # Not downloaded: guess from the URL, then from the declared format.
        "kind": kind_of(files or [res.get("url") or "", "format." + (res.get("format") or "").lower()],
                        meta.get("status")),
        "status": meta.get("status", "not-fetched"),
        "file_path": ";".join(files) or None,
        "size": meta.get("size"),
        "sha256": meta.get("sha256"),
        "downloaded_at": meta.get("downloaded_at"),
        "meta": meta,
    }


def resource_layers(meta, rel_dir):
    """(path relative to the data dir, sha256) of every loadable file of a resource."""
    if meta.get("status") != "ok":
        return []
    parts = meta.get("parts") or [meta]
    return [(f"{rel_dir}/{p['file']}", p.get("sha256")) for p in parts
            if os.path.splitext(p.get("file", ""))[1].lower() in LOADABLE]


# ---- parsing --------------------------------------------------------------
#
# Every reader turns a file into [(source_path suffix, rows, srid)], one entry per
# layer (a workbook has one per sheet), rows being (source_fid, properties, geometry).

JSON_TYPES = [(bool, "boolean"), ((int, float), "number"), (str, "string"),
              (dict, "object"), (list, "array"), (type(None), "null")]


def json_type(v):
    for t, name in JSON_TYPES:  # bool first: it is a subclass of int
        if isinstance(v, t):
            return name
    return type(v).__name__


class LayerStats:
    def __init__(self):
        self.count = 0
        self.geometry = Counter()
        self.fields = {}

    def add(self, props, geom):
        self.count += 1
        self.geometry[(geom or {}).get("type")] += 1
        for k, v in props.items():
            self.fields.setdefault(k, set()).add(json_type(v))

    def geometry_type(self):
        types = [t for t, _ in self.geometry.most_common() if t]
        return types[0] if types else None

    def field_types(self):
        return {k: "|".join(sorted(v)) for k, v in self.fields.items()}


def crs_srid(doc):
    """SRID of a GeoJSON "crs" member; none means WGS 84 (RFC 7946).

    Most files are WGS 84, but e.g. building-solar-irradiance is in EPSG:7801
    (BGS2005 / CCS2005); PostGIS converts those while loading.
    """
    name = ((doc.get("crs") or {}).get("properties") or {}).get("name", "")
    if not name or name.endswith("CRS84"):
        return 4326
    m = re.search(r"EPSG:+(\d+)$", name)
    if not m:
        raise ValueError(f"unsupported CRS {name}")
    return int(m.group(1))


def feature_rows(doc):
    """Yield (source_fid, properties, geometry) for each feature of a FeatureCollection."""
    if not isinstance(doc, dict) or doc.get("type") != "FeatureCollection":
        raise ValueError(f"not a GeoJSON FeatureCollection: {type(doc).__name__}")
    for i, ft in enumerate(doc.get("features") or []):
        fid = ft.get("id")
        yield (str(fid) if fid is not None else str(i)), ft.get("properties") or {}, ft.get("geometry") or None


# Column names seen on the portal: lat, latitude, "Latitude (географска ширина)",
# long, longitude and the misspelled "Longtitude (географска дължина)".
LAT_RE = re.compile(r"^lat(itude)?\b|ширина", re.I)
LON_RE = re.compile(r"^(lon|lng|long|longitude|longtitude)\b|дължина", re.I)


def coord_columns(names):
    lat = next((n for n in names if LAT_RE.search(n.strip())), None)
    lon = next((n for n in names if LON_RE.search(n.strip())), None)
    return lat, lon


def to_float(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).strip().replace(",", "."))
    except ValueError:
        return None


def point(lat, lon):
    if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat, lon) == (0, 0):
        return None
    return {"type": "Point", "coordinates": [lon, lat]}


def cell(v):
    if isinstance(v, (dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer():
        return int(v)  # Excel stores every number as a float: 133950.0 -> 133950
    if v == "":
        return None
    return v


def dict_rows(records):
    """Rows of a table given as dicts; a point geometry when there are lat/long columns."""
    lat, lon = coord_columns(list(records[0])) if records and isinstance(records[0], dict) else (None, None)
    for i, rec in enumerate(records, 1):
        props = rec if isinstance(rec, dict) else {"value": rec}
        geom = point(to_float(props.get(lat)), to_float(props.get(lon))) if lat and lon else None
        yield str(i), props, geom


def clean_header(header):
    names, seen = [], Counter()
    for j, h in enumerate(header, 1):
        name = str(h).strip() if h is not None else ""
        name = name or f"col_{j}"
        seen[name] += 1
        names.append(name if seen[name] == 1 else f"{name}_{seen[name]}")
    return names


def table_rows(rows):
    """Rows of a sheet or CSV: the first row with 2+ values is the header, empty rows are dropped."""
    rows = iter(rows)
    for header in rows:
        if sum(v not in (None, "") for v in header) >= 2:
            break
    else:
        return []
    names = clean_header(header)
    records = []
    for r in rows:
        values = [cell(v) for v in r]
        if all(v is None for v in values):
            continue
        values += [None] * (len(names) - len(values))
        names += [f"col_{j}" for j in range(len(names) + 1, len(values) + 1)]
        # Unnamed columns are mostly padding: keep them only where they hold a value.
        records.append({n: v for n, v in zip(names, values) if v is not None or not n.startswith("col_")})
    return records


def read_json(data):
    doc = json.loads(data)
    if isinstance(doc, list):  # attribute tables exported without their geometry
        return [("", dict_rows(doc), 4326)]
    rows = feature_rows(doc)
    return [("", rows, crs_srid(doc))]


def read_csv(data):
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1251")
    try:
        dialect = csv.Sniffer().sniff(text[:20000], delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    return [("", dict_rows(table_rows(csv.reader(io.StringIO(text), dialect))), 4326)]


def sheets(named_rows):
    """One layer per non-empty sheet; the sheet name goes in the path only if there are several."""
    tables = [(name, table_rows(rows)) for name, rows in named_rows]
    tables = [(name, t) for name, t in tables if t]
    return [(f"!/{name}" if len(tables) > 1 else "", dict_rows(t), 4326) for name, t in tables]


def read_xlsx(data):
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    return sheets((ws.title, ws.iter_rows(values_only=True)) for ws in wb.worksheets)


def read_xls(data):
    wb = xlrd.open_workbook(file_contents=data)
    return sheets((sh.name, (sh.row_values(i) for i in range(sh.nrows))) for sh in wb.sheets())


READERS = {".geojson": read_json, ".json": read_json, ".csv": read_csv,
           ".xlsx": read_xlsx, ".xls": read_xls}


def parse_file(name, data):
    return READERS[os.path.splitext(name)[1].lower()](data)


def zip_layers(file):
    """Layers of every readable member of a zip; members not in READERS (.gpkg, .tif, ...) are skipped.

    Members are read one at a time: some archives are several GB of rasters.
    """
    with zipfile.ZipFile(file) as zf:
        for info in zf.infolist():
            if info.is_dir() or os.path.splitext(info.filename)[1].lower() not in READERS:
                continue
            for suffix, rows, srid in parse_file(info.filename, zf.read(info)):
                yield f"!/{info.filename}{suffix}", rows, srid


LOADABLE = set(READERS) | {".zip"}


# ---- database -------------------------------------------------------------

def upsert(cur, table, key, rows, touch=False):
    if not rows:
        return
    cols = list(rows[0])
    sets = [f"{c} = EXCLUDED.{c}" for c in cols if c != key] + (["loaded_at = now()"] if touch else [])
    sql = (f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))}) "
           f"ON CONFLICT ({key}) DO UPDATE SET {', '.join(sets)}")
    cur.executemany(sql, [[Jsonb(r[c]) if isinstance(r[c], dict) else r[c] for c in cols] for r in rows])


def load_catalog(conn, data_dir):
    cat = data_dir / "_catalog" / "latest"
    packages = sync.load_json(cat / "packages.json")
    groups = sync.load_json(cat / "groups.json") or []
    orgs = {o["name"]: o for o in sync.load_json(cat / "organizations.json") or []}
    for pkg in packages:  # a dataset's organization may be missing from organization_list
        if pkg.get("organization"):
            orgs.setdefault(pkg["organization"]["name"], pkg["organization"])

    sections = {r["slug"]: r for r in map(section_row, groups)}
    for pkg in packages:  # same for groups: e.g. "finance" is not in group_list
        for g in pkg.get("groups") or []:
            row = section_row(g)
            sections.setdefault(row["slug"], row)
    sections.setdefault(sync.NO_SECTION, {"slug": sync.NO_SECTION, "ckan_id": None,
                                          "title": "No section", "description": None, "raw": {}})
    resources, metas = [], {}
    for pkg in packages:
        pkg_dir = data_dir / sync.section_of(pkg) / pkg["name"]
        for res in pkg["resources"]:
            meta = sync.load_json(pkg_dir / f"{res['id']}.meta.json") or {}
            metas[res["id"]] = (pkg, meta)
            resources.append(resource_row(pkg, res, meta))

    with conn.transaction(), conn.cursor() as cur:
        upsert(cur, "sections", "slug", list(sections.values()))
        upsert(cur, "organizations", "slug", [organization_row(o) for o in orgs.values()])
        upsert(cur, "datasets", "id", [dataset_row(p) for p in packages], touch=True)
        upsert(cur, "resources", "id", resources, touch=True)
    log(f"catalog: {len(sections)} sections, {len(orgs)} organizations, "
        f"{len(packages)} datasets, {len(resources)} resources")
    return metas


def layer_is_current(conn, resource_id, path, sha):
    """True when every layer loaded from this file (one per sheet, or per zip member) has this sha256."""
    n, same = conn.execute(
        "SELECT count(*), bool_and(sha256 = %s AND feature_count IS NOT NULL) FROM layers "
        "WHERE resource_id = %s AND (source_path = %s OR left(source_path, length(%s) + 2) = %s || '!/')",
        (sha, resource_id, path, path, path)).fetchone()
    return bool(sha and n and same)


def load_layer(conn, resource_id, source_path, sha, rows, srid=4326):
    """Replace one layer's features. `rows` is consumed inside the transaction."""
    stats = LayerStats()
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("INSERT INTO layers (resource_id, source_path) VALUES (%s, %s) "
                    "ON CONFLICT (resource_id, source_path) DO UPDATE SET loaded_at = now() RETURNING id",
                    (resource_id, source_path))
        layer_id = cur.fetchone()[0]
        cur.execute("DELETE FROM features WHERE layer_id = %s", (layer_id,))
        cur.execute("CREATE TEMP TABLE stage (source_fid text, properties jsonb, geom_json text) ON COMMIT DROP")
        with cur.copy("COPY stage FROM STDIN") as copy:
            for fid, props, geom in rows:
                stats.add(props, geom)
                copy.write_row((fid, Jsonb(props), None if geom is None else Jsonb(geom)))
        # All the source data is 2D; Force2D only protects the 2D column from a stray Z.
        # ST_Transform is a no-op for data that is already in 4326.
        cur.execute("""
            INSERT INTO features (layer_id, source_fid, properties, geom, geom_repaired)
            SELECT %s, source_fid, properties,
                   CASE WHEN ST_IsValid(g) THEN g ELSE ST_MakeValid(g) END,
                   coalesce(NOT ST_IsValid(g), false)
            FROM (SELECT source_fid, properties,
                         ST_Transform(ST_Force2D(ST_SetSRID(ST_GeomFromGeoJSON(geom_json), %s)), 4326) AS g
                  FROM stage) s""", (layer_id, srid))
        cur.execute("""
            UPDATE layers SET sha256 = %s, geometry_type = %s, srid = %s, feature_count = %s,
                   fields = %s, loaded_at = now(),
                   extent = (SELECT ST_SetSRID(ST_Extent(geom)::geometry, 4326)
                             FROM features WHERE layer_id = %s)
            WHERE id = %s""",
                    (sha, stats.geometry_type(), srid, stats.count, Jsonb(stats.field_types()), layer_id, layer_id))
        repaired = cur.execute("SELECT count(*) FROM features WHERE layer_id = %s AND geom_repaired",
                               (layer_id,)).fetchone()[0]
    return stats, repaired


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", type=Path, default=Path(os.environ.get("SOFIA_DATA_DIR", "data")))
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL", DEFAULT_DSN))
    ap.add_argument("--dataset", action="append", help="only these dataset names (repeatable)")
    ap.add_argument("--only-catalog", action="store_true")
    ap.add_argument("--force", action="store_true", help="reload layers even if unchanged")
    args = ap.parse_args()

    # autocommit: each conn.transaction() below is then a real transaction, not a savepoint
    conn = psycopg.connect(args.dsn, autocommit=True, options="-c search_path=urban,public")
    metas = load_catalog(conn, args.data_dir)
    if args.only_catalog:
        return 0

    jobs = []
    for rid, (pkg, meta) in metas.items():
        if args.dataset and pkg["name"] not in args.dataset:
            continue
        rel_dir = f"{sync.section_of(pkg)}/{pkg['name']}"
        jobs += [(rid, path, sha) for path, sha in resource_layers(meta, rel_dir)]

    loaded = skipped = features = 0
    errors = []
    for n, (rid, path, sha) in enumerate(jobs, 1):
        if not args.force and layer_is_current(conn, rid, path, sha):
            skipped += 1
            continue
        t = time.time()
        try:
            full = args.data_dir / path
            layers = zip_layers(full) if path.lower().endswith(".zip") else parse_file(path, full.read_bytes())
            for suffix, rows, srid in layers:
                stats, repaired = load_layer(conn, rid, path + suffix, sha, rows, srid)
                loaded += 1
                features += stats.count
                log(f"[{n}/{len(jobs)}] {stats.count:8} {stats.geometry_type() or '-':16} "
                    f"repaired={repaired:<5} {time.time() - t:5.0f}s  {path + suffix}")
                t = time.time()
        except Exception as e:  # one bad file must not stop a run over hundreds
            errors.append((path, f"{type(e).__name__}: {str(e).splitlines()[0] if str(e) else ''}"))
            log(f"[{n}/{len(jobs)}] ERROR {path}: {errors[-1][1]}")

    log(f"layers: {loaded} loaded ({features} features), {skipped} unchanged, {len(errors)} errors")
    for path, err in errors:
        log(f"  {path}: {err}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
