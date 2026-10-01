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

-- ---------------------------------------------------------------- areas
--
-- Three ways the municipality is divided, each covering all of it.
-- They do not nest: a neighbourhood or planning unit can straddle
-- district borders, so each keeps a main district (largest share of its
-- area) and every district it touches in a link table.

CREATE TABLE IF NOT EXISTS districts (
    code           text PRIMARY KEY,          -- 01 .. 24, the official district number
    name           text NOT NULL,             -- official name, e.g. Красно село
    name_latin     text NOT NULL,             -- official transliteration
    geom           geometry(MultiPolygon, 4326) NOT NULL,
    area_km2       numeric NOT NULL,
    population     integer,                   -- residents of the buildings inside (2019)
    population_nsi integer,                   -- NSI control areas with this district code
    boundary_diff_km2 numeric,                -- symmetric difference to the 2017 NAG boundary
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS districts_geom_idx ON districts USING gist (geom);

CREATE TABLE IF NOT EXISTS neighbourhoods (
    id             integer PRIMARY KEY,       -- object_id in the source
    name           text,                      -- as in the source, NULL where it is "---"
    prefix         text,                      -- ЖК., КВ., В.З., С., М. ...
    kind           text NOT NULL,             -- residential, industrial, park, villa_zone, ...
    type_code      text,                      -- type_kv in the source
    district_code  text REFERENCES districts(code),  -- main district
    district_share numeric,                   -- share of the area in the main district
    geom           geometry(MultiPolygon, 4326) NOT NULL,
    area_km2       numeric NOT NULL,
    population     integer,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS neighbourhoods_geom_idx ON neighbourhoods USING gist (geom);

-- Sofiaplan's analysis unit (градоустройствена единица, УПЕ); most of its
-- indicators are published per planning unit.
CREATE TABLE IF NOT EXISTS planning_units (
    id             integer PRIMARY KEY,       -- object_id in the source
    name           text NOT NULL,             -- regname
    district_label text,                      -- rajon as in the source, e.g. "Средец / Оборище"
    district_code  text REFERENCES districts(code),  -- main district
    district_share numeric,
    geom           geometry(MultiPolygon, 4326) NOT NULL,
    area_km2       numeric NOT NULL,
    population     integer,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS planning_units_geom_idx ON planning_units USING gist (geom);

-- Every district an area touches (slivers under 1 % of the area are left
-- out unless people live in them).
CREATE TABLE IF NOT EXISTS neighbourhood_districts (
    neighbourhood_id integer NOT NULL REFERENCES neighbourhoods(id) ON DELETE CASCADE,
    district_code    text NOT NULL REFERENCES districts(code),
    share            numeric NOT NULL,        -- of the neighbourhood's area
    population       integer,                 -- its residents in this district
    PRIMARY KEY (neighbourhood_id, district_code)
);

CREATE TABLE IF NOT EXISTS planning_unit_districts (
    planning_unit_id integer NOT NULL REFERENCES planning_units(id) ON DELETE CASCADE,
    district_code    text NOT NULL REFERENCES districts(code),
    share            numeric NOT NULL,
    population       integer,
    PRIMARY KEY (planning_unit_id, district_code)
);

-- Inhabited buildings with their residents; the base for any
-- population-weighted measure (e.g. how many people live near a station).
CREATE TABLE IF NOT EXISTS building_residents (
    id             integer PRIMARY KEY,       -- id in the source
    people         integer NOT NULL,
    households     integer,
    age_0_14       integer,
    age_65_plus    integer,
    floors         integer,
    built_year     integer,
    function       text,                      -- e.g. Жилищна сграда - многофамилна
    geom           geometry(Point, 4326) NOT NULL,
    district_code  text REFERENCES districts(code),
    neighbourhood_id integer REFERENCES neighbourhoods(id),
    planning_unit_id integer REFERENCES planning_units(id),
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS building_residents_geom_idx ON building_residents USING gist (geom);
CREATE INDEX IF NOT EXISTS building_residents_district_idx ON building_residents (district_code);
CREATE INDEX IF NOT EXISTS building_residents_neighbourhood_idx ON building_residents (neighbourhood_id);
CREATE INDEX IF NOT EXISTS building_residents_planning_unit_idx ON building_residents (planning_unit_id);

-- Discrepancies between and within the area sources. Worth keeping:
-- they are often findings in themselves.
CREATE OR REPLACE VIEW area_issues AS
SELECT 'district boundary changed since 2017' AS issue, 'district' AS area_kind,
       d.code AS area_id, d.name,
       format('%s km² differ from the 2017 NAG boundary', d.boundary_diff_km2) AS detail
  FROM districts d WHERE d.boundary_diff_km2 >= 0.01
UNION ALL
SELECT 'population differs from NSI', 'district', d.code, d.name,
       format('buildings 2019: %s, NSI control areas: %s (%s%%)', d.population, d.population_nsi,
              round(100.0 * (d.population - d.population_nsi) / nullif(d.population_nsi, 0)))
  FROM districts d
 WHERE abs(d.population - coalesce(d.population_nsi, 0)) > 0.1 * greatest(d.population_nsi, 1)
UNION ALL
SELECT 'neighbourhood without a name', 'neighbourhood', n.id::text, NULL,
       format('%s, %s km²', n.kind, n.area_km2)
  FROM neighbourhoods n WHERE n.name IS NULL
UNION ALL
SELECT 'neighbourhood in several districts', 'neighbourhood', n.id::text, n.name,
       (SELECT string_agg(format('%s %s%%', d.name, round(100 * x.share)), ', ' ORDER BY x.share DESC)
          FROM neighbourhood_districts x JOIN districts d ON d.code = x.district_code
         WHERE x.neighbourhood_id = n.id)
  FROM neighbourhoods n WHERE n.district_share < 0.9
UNION ALL
SELECT 'planning unit in several districts', 'planning_unit', p.id::text, p.name,
       (SELECT string_agg(format('%s %s%%', d.name, round(100 * x.share)), ', ' ORDER BY x.share DESC)
          FROM planning_unit_districts x JOIN districts d ON d.code = x.district_code
         WHERE x.planning_unit_id = p.id)
  FROM planning_units p WHERE p.district_share < 0.9
UNION ALL
-- The source labels each unit with its district(s); compare that with the
-- districts it actually lies in (ignoring parts under 5 %).
SELECT 'planning unit label disagrees with its location', 'planning_unit', p.id::text, p.name,
       format('labelled "%s", lies in %s', p.district_label,
              (SELECT string_agg(format('%s %s%%', d.name, round(100 * x.share)), ', ' ORDER BY x.share DESC)
                 FROM planning_unit_districts x JOIN districts d ON d.code = x.district_code
                WHERE x.planning_unit_id = p.id AND x.share >= 0.05))
  FROM planning_units p
 WHERE p.district_label IS NULL
    OR (SELECT array_agg(DISTINCT lower(d.name) ORDER BY lower(d.name))
          FROM planning_unit_districts x JOIN districts d ON d.code = x.district_code
         WHERE x.planning_unit_id = p.id AND x.share >= 0.05)
       IS DISTINCT FROM
       (SELECT array_agg(DISTINCT CASE lower(btrim(part))
                                      WHEN 'подуене' THEN 'подуяне'
                                      WHEN 'студентска' THEN 'студентски'
                                      ELSE regexp_replace(lower(btrim(part)), '\s+', ' ', 'g') END
                         ORDER BY CASE lower(btrim(part))
                                      WHEN 'подуене' THEN 'подуяне'
                                      WHEN 'студентска' THEN 'студентски'
                                      ELSE regexp_replace(lower(btrim(part)), '\s+', ' ', 'g') END)
          FROM unnest(string_to_array(p.district_label, '/')) AS part)
UNION ALL
SELECT 'inhabited building outside every district', 'building', b.id::text, NULL,
       format('%s people', b.people)
  FROM building_residents b WHERE b.district_code IS NULL;

-- ---------------------------------------------------------- metro access
--
-- Straight-line distance from each inhabited building to the nearest
-- station outline. Real walking distance is longer (typically 20-40 %),
-- so these numbers are an upper bound on how many people are within reach.

CREATE TABLE IF NOT EXISTS building_metro_access (
    building_id         integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    station_id          integer REFERENCES metro_stations(id) ON DELETE SET NULL,  -- nearest existing
    distance_m          numeric,
    planned_station_id  integer REFERENCES metro_stations(id) ON DELETE SET NULL,  -- nearest, planned included
    planned_distance_m  numeric
);

-- Residents within 500 m and 1 km of a station, now and with the planned
-- stations, for every district, neighbourhood, planning unit and the city.
CREATE OR REPLACE VIEW area_metro_access AS
WITH b AS (
    SELECT r.people, r.district_code, r.neighbourhood_id, r.planning_unit_id,
           a.distance_m, a.planned_distance_m
      FROM building_residents r
      JOIN building_metro_access a ON a.building_id = r.id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM b
)
SELECT area_kind, area_id,
       sum(people) AS people,
       coalesce(sum(people) FILTER (WHERE distance_m <= 500), 0) AS within_500,
       coalesce(sum(people) FILTER (WHERE distance_m <= 1000), 0) AS within_1000,
       coalesce(sum(people) FILTER (WHERE planned_distance_m <= 500), 0) AS planned_within_500,
       coalesce(sum(people) FILTER (WHERE planned_distance_m <= 1000), 0) AS planned_within_1000,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 500), 0)::numeric / nullif(sum(people), 0), 3) AS share_500,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 1000), 0)::numeric / nullif(sum(people), 0), 3) AS share_1000,
       round(coalesce(sum(people) FILTER (WHERE planned_distance_m <= 500), 0)::numeric / nullif(sum(people), 0), 3) AS planned_share_500,
       round(coalesce(sum(people) FILTER (WHERE planned_distance_m <= 1000), 0)::numeric / nullif(sum(people), 0), 3) AS planned_share_1000
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- Residents around each station. Catchments overlap, so these do not add
-- up to the city total; "nearest" counts each building once.
CREATE OR REPLACE VIEW station_catchment AS
SELECT s.id AS station_id,
       (SELECT coalesce(sum(r.people), 0) FROM building_residents r
         WHERE r.geom && ST_Expand(s.outline, 0.01)
           AND ST_DWithin(r.geom::geography, s.outline::geography, 500)) AS within_500,
       (SELECT coalesce(sum(r.people), 0) FROM building_residents r
         WHERE r.geom && ST_Expand(s.outline, 0.02)
           AND ST_DWithin(r.geom::geography, s.outline::geography, 1000)) AS within_1000,
       (SELECT coalesce(sum(r.people), 0) FROM building_residents r
          JOIN building_metro_access a ON a.building_id = r.id
         WHERE a.station_id = s.id OR (s.status = 'planned' AND a.planned_station_id = s.id)) AS nearest_for
  FROM metro_stations s;
