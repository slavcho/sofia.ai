# sofia.ai

## Mission

Help the community and the municipality of Sofia by making the city's open
data (https://urbandata.sofia.bg/) understandable and actionable.

## Primary directives

1. **Understand in detail.** It must be possible to see what is happening
   anywhere in the city at whatever level of detail a question needs: from
   city-wide trends down to a single street, building or parcel.
2. **Visualize.** Everything we know should be showable on a map or in a
   chart, so people can see it and not only read about it.
3. **Run agents over the data** with tasks such as:
   1. Find discrepancies between different areas.
   2. Show the biggest problems in my neighbourhood.
   3. Find areas for improvement.
   4. Find patterns that are not obvious.

   ...and many more.

Every new feature should serve at least one of these directives.

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
- **Not in the database yet:** rasters (elevation, slope, orthophotos, drone
  surveys), GTFS timetables and the live feeds (parking, vehicle positions).

## Querying

- Coordinates are longitude, latitude: `ST_MakePoint(23.358, 42.663)`.
- Use `::geography` for metres, but pre-filter with the index first
  (`geom && ST_Expand(pt, 0.002)` or `ORDER BY geom <-> pt`), otherwise
  every one of the ~8 M rows is scanned.
- Filter by dataset through `features → layers → resources → datasets`.
