#!/usr/bin/env python3
"""Mirror the Sofia open data portal (https://urbandata.sofia.bg, CKAN 2.11).

Layout under DATA_DIR (default ./data, override with SOFIA_DATA_DIR or --data-dir):

    _catalog/<timestamp>/{packages,organizations,groups}.json   raw API snapshots
    _catalog/latest/...                                          copy of the newest snapshot
    _index.csv                                                   one row per resource
    <section>/<dataset-name>/dataset.json                        full CKAN metadata
    <section>/<dataset-name>/<resource-id>__<filename>           the downloaded file
    <section>/<dataset-name>/<resource-id>.meta.json             how/when it was fetched

A resource is re-downloaded only when its CKAN metadata changed, the previous
attempt failed, or --force is given. api.sofiaplan.bg (most of the files) sends
no ETag/Last-Modified and no Range support, so CKAN metadata + sha256 are the
only change signals we have.
"""
import argparse
import concurrent.futures as cf
import csv
import datetime as dt
import hashlib
import json
import os
import re
import sys
import threading
import time
from email.message import Message
from pathlib import Path
from urllib.parse import unquote, urlparse

import requests

API = "https://urbandata.sofia.bg/api/3/action"
# www.sofia.bg answers 403 to non-browser user agents.
USER_AGENT = "Mozilla/5.0 (compatible; ai.sofia-mirror/0.1)"
CHUNK = 1 << 20
RETRIES = 3
# Files above this are fetched in a second pass, after everything else. Sofiaplan
# gives no size in the catalog, and its 20-60 GB archives would otherwise block
# the workers for hours before the small GeoJSONs arrive.
DEFER_SIZE = 1024 ** 3

# Some group slugs on the portal are misspelled; use readable folder names.
SECTION_FIX = {"bnopa3hoo6pa3ne": "biodiversity", "buldings": "buildings"}
NO_SECTION = "_no-section"
LINK_FORMATS = {"WEB"}
KEPT_HEADERS = ("Content-Type", "Content-Length", "Last-Modified", "ETag", "Content-Disposition")

_print_lock = threading.Lock()


def log(*a):
    with _print_lock:
        print(*a, flush=True)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def make_session():
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    return s


def save_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


# ---------------------------------------------------------------- catalog

def api_call(s, action, **params):
    r = s.get(f"{API}/{action}", params=params, timeout=60)
    r.raise_for_status()
    body = r.json()
    if not body.get("success"):
        raise RuntimeError(f"{action} failed: {body.get('error')}")
    return body["result"]


def fetch_catalog(s):
    packages, start, rows = [], 0, 500
    while True:
        res = api_call(s, "package_search", rows=rows, start=start, include_private="false")
        packages += res["results"]
        start += rows
        if start >= res["count"]:
            break
    orgs = api_call(s, "organization_list", all_fields="true")
    groups = api_call(s, "group_list", all_fields="true")
    return packages, orgs, groups


def snapshot_catalog(data_dir, packages, orgs, groups):
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    latest = data_dir / "_catalog" / "latest"
    previous = load_json(latest / "packages.json") or []
    for d in (data_dir / "_catalog" / stamp, latest):
        save_json(d / "packages.json", packages)
        save_json(d / "organizations.json", orgs)
        save_json(d / "groups.json", groups)
    return previous


def report_catalog_diff(previous, packages):
    if not previous:
        return
    old = {p["id"]: p for p in previous}
    new = {p["id"]: p for p in packages}
    added = [new[i]["name"] for i in new.keys() - old.keys()]
    removed = [old[i]["name"] for i in old.keys() - new.keys()]
    changed = [new[i]["name"] for i in new.keys() & old.keys()
               if new[i]["metadata_modified"] != old[i]["metadata_modified"]]
    log(f"catalog diff vs previous run: +{len(added)} added, -{len(removed)} removed, "
        f"~{len(changed)} modified")
    for name in removed:
        log(f"  removed from portal (local copy kept): {name}")


# ---------------------------------------------------------------- files

def section_of(pkg):
    groups = sorted(g["name"] for g in pkg.get("groups") or [])
    if not groups:
        return NO_SECTION
    return SECTION_FIX.get(groups[0], groups[0])


def safe_name(name, limit=150):
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name).strip(" .")
    return name[:limit] or "file"


def filename_from(resp):
    cd = resp.headers.get("Content-Disposition")
    if cd:
        m = Message()
        m["content-disposition"] = cd
        fn = m.get_filename()
        if fn:
            # requests decodes headers as latin-1, servers here send raw UTF-8.
            try:
                fn = fn.encode("latin-1").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
            return safe_name(fn)
    base = unquote(os.path.basename(urlparse(resp.url).path))
    return safe_name(base) if base else "file"


def needs_download(res, pkg_dir, meta, force):
    # "skipped-too-large" is retried every run: the size limit may be different now.
    if force or not meta or meta.get("status") not in ("ok", "link"):
        return True
    if meta["status"] == "ok" and not (pkg_dir / meta["file"]).exists():
        return True
    ck = meta.get("ckan", {})
    return any(ck.get(k) != res.get(k) for k in ("url", "metadata_modified", "last_modified"))


class Skip(Exception):
    """The URL answered, but it is not a file we want to store."""

    def __init__(self, status, **extra):
        self.status, self.extra = status, extra


def fetch_to_part(s, url, pkg_dir, res_id, max_size, meta):
    """Stream one URL into <pkg_dir>/<res_id>__<name>.part. Returns (fname, size, sha256)."""
    with s.get(url, stream=True, timeout=(30, 300), allow_redirects=True) as r:
        meta["final_url"] = r.url
        meta["http_status"] = r.status_code
        meta["headers"] = {k: r.headers[k] for k in KEPT_HEADERS if k in r.headers}
        r.raise_for_status()
        if r.headers.get("Content-Type", "").startswith("text/html"):
            raise Skip("link")  # a web page / app, not a data file
        length = int(r.headers.get("Content-Length") or 0)
        if max_size and length > max_size:
            raise Skip("skipped-too-large", size=length)

        fname = f"{res_id}__{filename_from(r)}"
        part = pkg_dir / (fname + ".part")
        h, size = hashlib.sha256(), 0
        with open(part, "wb") as f:
            for chunk in r.iter_content(CHUNK):
                f.write(chunk)
                h.update(chunk)
                size += len(chunk)
    if length and size != length:
        raise IOError(f"truncated: got {size} of {length} bytes")
    return fname, size, h.hexdigest()


def fetch_with_retries(s, res, pkg_dir, max_size, meta):
    for attempt in range(RETRIES):
        try:
            return fetch_to_part(s, res["url"], pkg_dir, res["id"], max_size, meta)
        except (requests.RequestException, IOError) as e:
            code = getattr(getattr(e, "response", None), "status_code", None)
            if attempt == RETRIES - 1 or (code and 400 <= code < 500):
                raise  # out of retries, or a client error that retrying will not fix
            log(f"  retry {attempt + 1} {res['url']}: {e}")
            time.sleep(10 * (attempt + 1))


def sync_resource(s, res, pkg_dir, max_size):
    meta_path = pkg_dir / f"{res['id']}.meta.json"
    old = load_json(meta_path) or {}
    meta = {
        "resource_id": res["id"],
        "dataset_id": res["package_id"],
        "url": res["url"],
        "ckan": {k: res.get(k) for k in ("url", "format", "name", "mimetype", "size", "hash",
                                         "metadata_modified", "last_modified")},
        "attempted_at": now_iso(),
        "history": old.get("history", []),
    }
    if (res.get("format") or "").strip().upper() in LINK_FORMATS:
        meta["status"] = "link"
        save_json(meta_path, meta)
        return meta

    try:
        fname, size, sha = fetch_with_retries(s, res, pkg_dir, max_size, meta)
    except Skip as sk:
        meta.update(status=sk.status, **sk.extra)
        save_json(meta_path, meta)
        return meta
    except (requests.RequestException, IOError) as e:
        meta["status"] = "error"
        meta["error"] = f"{type(e).__name__}: {e}"[:500]
        save_json(meta_path, meta)
        return meta

    # Replace the previous file (its name may have changed upstream).
    if old.get("file") and old["file"] != fname:
        (pkg_dir / old["file"]).unlink(missing_ok=True)
    os.replace(pkg_dir / (fname + ".part"), pkg_dir / fname)
    changed = old.get("sha256") not in (None, sha)
    if changed:
        meta["history"].append({k: old.get(k) for k in ("sha256", "size", "downloaded_at")})
    meta.update(status="ok", file=fname, size=size, sha256=sha, downloaded_at=now_iso(),
                content_changed=changed if old.get("sha256") else None)
    save_json(meta_path, meta)
    return meta


# ---------------------------------------------------------------- main

INDEX_COLS = ["section", "dataset", "dataset_title", "organization", "groups", "resource_id",
              "resource_name", "format", "status", "size", "sha256", "file", "url",
              "downloaded_at", "error"]


def write_index(data_dir, rows):
    path = data_dir / "_index.csv"
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, INDEX_COLS)
        w.writeheader()
        w.writerows(sorted(rows, key=lambda r: (r["section"], r["dataset"], r["resource_id"])))
    os.replace(tmp, path)


def parse_size(text):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([KMGT]?)B?", text.strip().upper())
    if not m:
        raise argparse.ArgumentTypeError(f"bad size: {text}")
    return int(float(m[1]) * 1024 ** " KMGT".index(m[2] or " "))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", type=Path, default=Path(os.environ.get("SOFIA_DATA_DIR", "data")))
    ap.add_argument("--only-meta", action="store_true", help="save catalog + dataset.json, skip files")
    ap.add_argument("--dataset", action="append", help="only these dataset names (repeatable)")
    ap.add_argument("--max-size", type=parse_size, help="skip files bigger than this, e.g. 2G")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--force", action="store_true", help="re-download even if unchanged")
    args = ap.parse_args()

    data_dir = args.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    s = make_session()

    log("fetching catalog ...")
    packages, orgs, groups = fetch_catalog(s)
    previous = snapshot_catalog(data_dir, packages, orgs, groups)
    log(f"{len(packages)} datasets, {sum(len(p['resources']) for p in packages)} resources, "
        f"{len(orgs)} organizations, {len(groups)} groups")
    report_catalog_diff(previous, packages)

    jobs, rows = [], {}
    for pkg in packages:
        section = section_of(pkg)
        pkg_dir = data_dir / section / pkg["name"]
        save_json(pkg_dir / "dataset.json", pkg)
        for res in pkg["resources"]:
            meta = load_json(pkg_dir / f"{res['id']}.meta.json")
            rows[res["id"]] = (pkg, section, res, meta or {})
            if args.dataset and pkg["name"] not in args.dataset:
                continue
            if not args.only_meta and needs_download(res, pkg_dir, meta, args.force):
                jobs.append((pkg_dir, res))

    # Small/known-size files first so useful data lands early; unknown sizes are
    # mostly GeoJSON from api.sofiaplan.bg and go in the middle.
    jobs.sort(key=lambda j: j[1].get("size") or 10 * 1024 ** 2)
    log(f"{len(jobs)} resources to fetch, {len(rows) - len(jobs)} up to date or filtered")

    def work(job, max_size):
        pkg_dir, res = job
        t = time.time()
        meta = sync_resource(s, res, pkg_dir, max_size)
        mb = (meta.get("size") or 0) / 1024 ** 2
        log(f"[{meta['status']:>17}] {mb:9.1f} MB {time.time() - t:6.0f}s  "
            f"{pkg_dir.parent.name}/{pkg_dir.name}  {meta.get('error', '')}")
        return res["id"], meta

    def run_pass(jobs, max_size):
        done = 0
        with cf.ThreadPoolExecutor(args.workers) as ex:
            for fut in cf.as_completed([ex.submit(work, j, max_size) for j in jobs]):
                rid, meta = fut.result()
                pkg, section, res, _ = rows[rid]
                rows[rid] = (pkg, section, res, meta)
                done += 1
                if done % 20 == 0:  # keep the index usable while a long run is going
                    write_index(data_dir, [index_row(*v) for v in rows.values()])

    first_limit = min(args.max_size or DEFER_SIZE, DEFER_SIZE)
    run_pass(jobs, first_limit)
    if args.max_size is None or args.max_size > first_limit:
        big = [j for j in jobs if rows[j[1]["id"]][3].get("status") == "skipped-too-large"
               and (args.max_size is None or rows[j[1]["id"]][3]["size"] <= args.max_size)]
        big.sort(key=lambda j: rows[j[1]["id"]][3]["size"])
        if big:
            gb = sum(rows[j[1]["id"]][3]["size"] for j in big) / 1024 ** 3
            log(f"second pass: {len(big)} large files, {gb:.1f} GB")
            run_pass(big, args.max_size)

    write_index(data_dir, [index_row(*v) for v in rows.values()])
    stats = {}
    for _, _, _, meta in rows.values():
        stats[meta.get("status", "not-fetched")] = stats.get(meta.get("status", "not-fetched"), 0) + 1
    log("summary:", ", ".join(f"{k}={v}" for k, v in sorted(stats.items())))
    return 0 if not stats.get("error") else 1


def index_row(pkg, section, res, meta):
    return {
        "section": section,
        "dataset": pkg["name"],
        "dataset_title": pkg.get("title"),
        "organization": (pkg.get("organization") or {}).get("name"),
        "groups": ";".join(g["name"] for g in pkg.get("groups") or []),
        "resource_id": res["id"],
        "resource_name": res.get("name"),
        "format": res.get("format"),
        "status": meta.get("status", "not-fetched"),
        "size": meta.get("size"),
        "sha256": meta.get("sha256"),
        "file": f"{section}/{pkg['name']}/{meta['file']}" if meta.get("file") else "",
        "url": res["url"],
        "downloaded_at": meta.get("downloaded_at"),
        "error": meta.get("error"),
    }


if __name__ == "__main__":
    sys.exit(main())
