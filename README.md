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
    psql -v ON_ERROR_STOP=1 -d urbandata -f db/live/schema.sql

The live transit feeds are fetched every minute by cron (`crontab -e`):

    * * * * * cd ~/work/ai.sofia && flock -n /tmp/poll_live.lock python3 poll_live.py >> logs/live.log 2>&1

The chat (POST /api/chat, web/llm.py) queries the database as
`urban_llm`, a login that can only read, and asks OpenAI's Responses API:

    sudo -u postgres psql -v ON_ERROR_STOP=1 -d urbandata -f db/app/llm_role.sql
    sudo -u postgres psql -d urbandata -c '\password urban_llm'
    echo '127.0.0.1:5432:urbandata:urban_llm:<password>' >> ~/.pgpass && chmod 600 ~/.pgpass
    export OPENAI_API_KEY=...     # in the web server's environment

`OPENAI_MODEL` (default gpt-6.1-sol), `OPENAI_REASONING_EFFORT` (medium)
and `LLM_DATABASE_URL` change the model and the login.

## Deployment

https://sofia.novellabs.ai runs on a Mac mini (M4) at home: nginx in
front, uvicorn and the live poller under launchd (`deploy/`), PostgreSQL
and the NAS on the same machine and network. To update it:

    deploy/update.sh

Setting it up from scratch, in the repository's directory:

1. Packages, and keep the machine awake and coming back after a power
   cut. The services are LaunchAgents, so they start at login: turn on
   automatic login (System Settings → Users & Groups).

       brew install postgis python@3.12     # brings its postgresql@NN
       brew services start postgresql@NN    # the one `brew info postgis` names
       sudo pmset -a sleep 0 disksleep 0 autorestart 1
       python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
       mkdir -p logs

2. The NAS, mounted on demand by autofs so that it is there for the
   jobs with nobody logged in to Finder. Add `/-  auto_smb  -nosuid` to
   `/etc/auto_master`, then (URL-encode special characters in the
   password):

       echo '/System/Volumes/Data/mnt/urbandata -fstype=smbfs ://<user>:<password>@slavi-nas.local/urbandata' | sudo tee /etc/auto_smb
       sudo chmod 600 /etc/auto_smb && sudo automount -cv
       ln -s /System/Volumes/Data/mnt/urbandata data

   macOS updates may reset `/etc/auto_master`; check it after one.

3. The database, copied from the old machine. Brew's superuser is your
   own account, not postgres. The roles first, so that the dump's owners
   and grants apply:

       createuser urbanuser -P && createuser urban_llm -P
       createdb -O urbanuser urbandata

   Then stop the old machine's poller (its crontab line), dump there
   and restore here; the live data has a gap for as long as this takes.

       sudo -u postgres pg_dump -Fc urbandata > data/urbandata.dump       # old machine
       pg_restore -j 8 -d urbandata data/urbandata.dump                   # Mac mini
       psql -v ON_ERROR_STOP=1 -d urbandata -f db/app/llm_role.sql        # role settings are not in the dump

   Both passwords go into `~/.pgpass` (see above) and the OpenAI key
   into `.env` (`export OPENAI_API_KEY=...`).

4. The services, with this directory's path filled in (launchd does
   not expand `~`). Logs go to `logs/web.log` and `logs/live.log`.

       for f in deploy/com.sofia.*.plist; do
           sed "s|__REPO__|$PWD|g" $f > ~/Library/LaunchAgents/${f##*/}
           launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/${f##*/}
       done

5. nginx (already serving the other sites, with the shared certificate):

       ln -s $PWD/deploy/nginx-sofia.conf /opt/homebrew/etc/nginx/servers/sofia.conf
       sudo nginx -t && sudo nginx -s reload

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
- **Live transit:** schema `live` (created by `db/live/schema.sql`), filled
  every minute by `poll_live.py` from the GTFS-realtime feeds, kept as
  history since 2026-10-04.
  - `vehicle_positions`: every vehicle report (daily partitions).
  - `stop_arrivals`: per trip, stop and service day the scheduled time and
    the first and latest prediction (monthly partitions);
    `passed_arrivals` adds the delay for the stops already passed.
  - `fetches`: every fetch, failed ones too; use it to leave out gaps.
- **Not in the database yet:** rasters (elevation, slope, orthophotos, drone
  surveys), the transit alerts and the park-and-ride occupancy.

## Querying

- Coordinates are longitude, latitude: `ST_MakePoint(23.358, 42.663)`.
- Use `::geography` for metres, but pre-filter with the index first
  (`geom && ST_Expand(pt, 0.002)` or `ORDER BY geom <-> pt`), otherwise
  every one of the ~8 M rows is scanned.
- Filter by dataset through `features → layers → resources → datasets`.
