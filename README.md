# sofia.ai

A mirror of Sofia's open data portal (https://urbandata.sofia.bg/) with a
PostGIS index over it. The mission and directives are in
[AGENTS.md](AGENTS.md).

## Setup

    pip install -r requirements.txt
    psql -v ON_ERROR_STOP=1 -d urbandata -f db/schema.sql
    python3 sync.py        # download the portal into data/
    python3 load_db.py     # load data/ into the database
    python3 load_gtfs.py   # the public transport timetable into schema gtfs

## Principles for agents

- **Cite the source.** Every finding names the datasets (and layers) it is
  based on, so a person can check it.
- **Know the date of the data.** Many datasets are snapshots from different
  years (see `extras` → "Актуален към" in `urban.datasets`, and the dates in
  file names). Say how old the data behind a claim is; do not compare
  2011 census figures with 2026 data as if they were the same moment.
- **Separate facts from inferences.** "There are no drinking fountains within
  500 m" is a fact from the data; "this area is underserved" is an inference.
  Mark which is which.
- **Missing data is not absence.** A dataset may simply not cover an area.
  Check a layer's extent before concluding that something does not exist.
- **Analysis zones are not objects.** Many Sofiaplan layers are study results
  (accessibility zones, grids, planning units) that cover the whole city.
  They describe an area; they are not things located at a point.

## The data

- **Files:** `data/<section>/<dataset>/` (a symlink to the NAS), filled by
  `sync.py`. Each dataset has `dataset.json` (portal metadata) and one
  `<resource-id>.meta.json` per file (source URL, sha256, download status).
  `data/_index.csv` lists every resource.
- **Database:** PostGIS, schema `urban` (created by `db/schema.sql`), filled
  by `load_db.py`.
  - `datasets`, `resources`, `sections`, `organizations`: the catalog.
  - `layers`: one per loaded file (or sheet, or zip member).
  - `features`: every object and table row: `properties` (jsonb, the
    original attributes) and `geom` (EPSG:4326, NULL for plain tables).
- **Timetable:** schema `gtfs`, filled by `load_gtfs.py`: the static GTFS
  feed of the Center for Urban Mobility, one text table per file as
  published (`gtfs.stops`, `gtfs.stop_times`, ...). `gtfs.feed` names the
  file, its source and when it was downloaded. Interpreted in
  `db/city/transit.sql`.
- **Not in the database yet:** rasters (elevation, slope, orthophotos, drone
  surveys) and the live feeds (parking, vehicle positions, trip updates).

## Querying

- Coordinates are longitude, latitude: `ST_MakePoint(23.358, 42.663)`.
- Use `::geography` for metres, but pre-filter with the index first
  (`geom && ST_Expand(pt, 0.002)` or `ORDER BY geom <-> pt`), otherwise
  every one of the ~8 M rows is scanned.
- Filter by dataset through `features → layers → resources → datasets`.
