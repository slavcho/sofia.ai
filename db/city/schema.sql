-- The curated model of the city, built on top of the raw portal mirror.
--
-- urban.*  is a faithful copy of the portal (load_db.py), one generic
--          features table for everything.
-- city.*   is what the city is made of: explicit tables per domain, with
--          real columns, stable ids, and the source and date of every row.
--
-- Apply with:  psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/schema.sql
-- Fill with:   psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/metro.sql
-- Safe to re-run: every object is created only if it is missing.

CREATE SCHEMA IF NOT EXISTS city;
SET search_path = city, public;

-- ---------------------------------------------------------------- metro

-- The lines as operated. Not in the portal data (the track layers do not
-- say which line a segment belongs to), so they are seeded by metro.sql.
CREATE TABLE IF NOT EXISTS metro_lines (
    code   text PRIMARY KEY,                  -- M1 .. M4
    name   text NOT NULL,                     -- termini, as signed
    color  text NOT NULL,                     -- hex, as on the network map
    opened date NOT NULL,                     -- first section opened to passengers
    source text NOT NULL
);

CREATE TABLE IF NOT EXISTS metro_stations (
    id             integer PRIMARY KEY,       -- "id" of the outline in the source
    code           text UNIQUE,               -- МС11; NULL for Line 3 and planned
    name           text,                      -- NULL when no source names it
    name_source    text,                      -- where the name came from
    status         text NOT NULL CHECK (status IN ('existing', 'planned')),
    outline        geometry(MultiPolygon, 4326) NOT NULL,
    point          geometry(Point, 4326) NOT NULL,  -- inside the outline; labels, distances
    area_m2        numeric,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS metro_stations_outline_idx ON metro_stations USING gist (outline);
CREATE INDEX IF NOT EXISTS metro_stations_point_idx ON metro_stations USING gist (point);

-- A station can be served by more than one line (e.g. M1 and M4).
CREATE TABLE IF NOT EXISTS metro_station_lines (
    station_id integer NOT NULL REFERENCES metro_stations(id) ON DELETE CASCADE,
    line_code  text NOT NULL REFERENCES metro_lines(code),
    source     text NOT NULL,
    PRIMARY KEY (station_id, line_code)
);

CREATE TABLE IF NOT EXISTS metro_entrances (
    id             integer PRIMARY KEY,       -- "id" in the source
    station_id     integer REFERENCES metro_stations(id) ON DELETE SET NULL,
    station_name   text,                      -- the station as named in the source (metro_st)
    distance_m     numeric,                   -- from the entrance to the station outline
    name           text,                      -- usually the street or place it opens to
    wheelchair     text CHECK (wheelchair IN ('yes', 'limited', 'no')),  -- NULL: not tagged
    access_note    text,                      -- e.g. "Има асансьор"
    bicycle        text,
    geom           geometry(Point, 4326) NOT NULL,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS metro_entrances_station_idx ON metro_entrances (station_id);
CREATE INDEX IF NOT EXISTS metro_entrances_geom_idx ON metro_entrances USING gist (geom);

-- Track segments; the source does not say which line they belong to.
CREATE TABLE IF NOT EXISTS metro_tracks (
    id             integer PRIMARY KEY,       -- "id" in the source
    status         text NOT NULL CHECK (status IN ('existing', 'planned')),
    geom           geometry(MultiLineString, 4326) NOT NULL,
    length_m       numeric,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS metro_tracks_geom_idx ON metro_tracks USING gist (geom);

-- Known gaps and doubts in the metro data, for people and agents to see.
CREATE OR REPLACE VIEW metro_issues AS
SELECT 'station without a name' AS issue, s.id AS station_id, NULL::integer AS entrance_id,
       s.status AS detail
  FROM metro_stations s WHERE s.name IS NULL
UNION ALL
SELECT 'existing station without a line', s.id, NULL, s.name
  FROM metro_stations s
 WHERE s.status = 'existing'
   AND NOT EXISTS (SELECT 1 FROM metro_station_lines l WHERE l.station_id = s.id)
UNION ALL
SELECT 'existing station without entrances', s.id, NULL, s.name
  FROM metro_stations s
 WHERE s.status = 'existing'
   AND NOT EXISTS (SELECT 1 FROM metro_entrances e WHERE e.station_id = s.id)
UNION ALL
SELECT 'entrance without a station', NULL, e.id, e.station_name
  FROM metro_entrances e WHERE e.station_id IS NULL;
