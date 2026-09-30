#!/usr/bin/env python3
"""Load the mirrored urbandata.sofia.bg files into PostGIS (see db/schema.sql).

  python3 load_db.py                      # catalog + every GeoJSON layer
  python3 load_db.py --dataset bus-lines  # only these datasets (repeatable)
  python3 load_db.py --only-catalog       # datasets/resources tables only
  python3 load_db.py --force              # reload layers even if unchanged

Connection: --dsn or $DATABASE_URL, else host 127.0.0.1, database urbandata,
user urbanuser; PG* environment variables override those, and the password
comes from ~/.pgpass.

A layer is reloaded only when the sha256 of its source file changed. Every
layer loads in its own transaction, so one broken file does not stop the run.
"""
import argparse
import os
import sys
import time
from collections import Counter
from pathlib import Path

import psycopg
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
    """(path relative to the data dir, sha256) of every GeoJSON file of a resource."""
    if meta.get("status") != "ok":
        return []
    parts = meta.get("parts") or [meta]
    return [(f"{rel_dir}/{p['file']}", p.get("sha256")) for p in parts
            if p.get("file", "").lower().endswith(".geojson")]


# ---- GeoJSON parsing ------------------------------------------------------

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


def feature_rows(doc, stats):
    """Yield (source_fid, properties, geometry) for each feature of a FeatureCollection."""
    if not isinstance(doc, dict) or doc.get("type") != "FeatureCollection":
        raise ValueError(f"not a GeoJSON FeatureCollection: {type(doc).__name__}")
    crs = ((doc.get("crs") or {}).get("properties") or {}).get("name", "")
    if crs and not crs.endswith(("CRS84", "4326")):
        raise ValueError(f"unsupported CRS {crs}")
    for i, ft in enumerate(doc.get("features") or []):
        props = ft.get("properties") or {}
        geom = ft.get("geometry") or None
        stats.add(props, geom)
        fid = ft.get("id")
        yield (str(fid) if fid is not None else str(i)), props, geom


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


def layer_is_current(conn, resource_id, source_path, sha):
    row = conn.execute("SELECT sha256, feature_count FROM layers WHERE resource_id = %s AND source_path = %s",
                       (resource_id, source_path)).fetchone()
    return bool(row and sha and row[0] == sha and row[1] is not None)


def load_layer(conn, resource_id, source_path, sha, rows, stats):
    """Replace one layer's features. `rows` is consumed inside the transaction."""
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("INSERT INTO layers (resource_id, source_path) VALUES (%s, %s) "
                    "ON CONFLICT (resource_id, source_path) DO UPDATE SET loaded_at = now() RETURNING id",
                    (resource_id, source_path))
        layer_id = cur.fetchone()[0]
        cur.execute("DELETE FROM features WHERE layer_id = %s", (layer_id,))
        cur.execute("CREATE TEMP TABLE stage (source_fid text, properties jsonb, geom_json text) ON COMMIT DROP")
        with cur.copy("COPY stage FROM STDIN") as copy:
            for fid, props, geom in rows:
                copy.write_row((fid, Jsonb(props), None if geom is None else Jsonb(geom)))
        # All the source data is 2D; Force2D only protects the 2D column from a stray Z.
        cur.execute("""
            INSERT INTO features (layer_id, source_fid, properties, geom, geom_repaired)
            SELECT %s, source_fid, properties,
                   CASE WHEN ST_IsValid(g) THEN g ELSE ST_MakeValid(g) END,
                   coalesce(NOT ST_IsValid(g), false)
            FROM (SELECT source_fid, properties,
                         ST_Force2D(ST_SetSRID(ST_GeomFromGeoJSON(geom_json), 4326)) AS g
                  FROM stage) s""", (layer_id,))
        cur.execute("""
            UPDATE layers SET sha256 = %s, geometry_type = %s, srid = 4326, feature_count = %s,
                   fields = %s, loaded_at = now(),
                   extent = (SELECT ST_SetSRID(ST_Extent(geom)::geometry, 4326)
                             FROM features WHERE layer_id = %s)
            WHERE id = %s""",
                    (sha, stats.geometry_type(), stats.count, Jsonb(stats.field_types()), layer_id, layer_id))
        repaired = cur.execute("SELECT count(*) FROM features WHERE layer_id = %s AND geom_repaired",
                               (layer_id,)).fetchone()[0]
    return repaired


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
        stats = LayerStats()
        try:
            doc = sync.load_json(args.data_dir / path)
            repaired = load_layer(conn, rid, path, sha, feature_rows(doc, stats), stats)
        except (ValueError, psycopg.Error) as e:
            errors.append((path, str(e).splitlines()[0]))
            log(f"[{n}/{len(jobs)}] ERROR {path}: {errors[-1][1]}")
            continue
        finally:
            doc = None  # the biggest files are several GB once parsed
        loaded += 1
        features += stats.count
        log(f"[{n}/{len(jobs)}] {stats.count:8} {stats.geometry_type() or '-':16} "
            f"repaired={repaired:<5} {time.time() - t:5.0f}s  {path}")

    log(f"layers: {loaded} loaded ({features} features), {skipped} unchanged, {len(errors)} errors")
    for path, err in errors:
        log(f"  {path}: {err}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
