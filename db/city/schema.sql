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

-- ---------------------------------------------------------------- parks
--
-- Public parks and gardens with their entrances (Sofiaplan). Filled by
-- parks.sql. The base is the 2020 layer, which follows the 2009 master
-- plan zones; parks it dropped but the 2019 layer and the 2020 entrances
-- still have are added from 2019 (data_as_of says which).

CREATE TABLE IF NOT EXISTS parks (
    id             uuid PRIMARY KEY,          -- "id" in the source
    name           text,                      -- NULL when no source names it
    name_source    text,
    kind           text CHECK (kind IN ('city_park', 'local_garden', 'special_green')),  -- NULL: not classified
    zone_code      text,                      -- master plan zone: Зп, Зп*, Тго, Тзсп
    status         text NOT NULL CHECK (status IN ('existing', 'planned')),
    realization    integer,                   -- realiz in the source: 0 none, 1 partly, 2 fully built
    outline        geometry(MultiPolygon, 4326) NOT NULL,
    area_m2        numeric NOT NULL,
    tree_cover_pct numeric,                   -- share covered by tree massifs (2020 only)
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS parks_outline_idx ON parks USING gist (outline);

CREATE TABLE IF NOT EXISTS park_entrances (
    id             integer PRIMARY KEY,       -- "id" in the source
    park_id        uuid REFERENCES parks(id) ON DELETE SET NULL,  -- nearest park within 30 m
    distance_m     numeric,                   -- from the entrance to that park's outline
    kind           text CHECK (kind IN ('main', 'secondary', 'unofficial')),  -- size 1, 2, 3
    size_code      integer,                   -- size in the source
    reglament      integer,                   -- reglament in the source; meaning unknown
    note           text,                      -- how it is reached: светофар, подлез, спирка ...
    geom           geometry(Point, 4326) NOT NULL,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS park_entrances_park_idx ON park_entrances (park_id);
CREATE INDEX IF NOT EXISTS park_entrances_geom_idx ON park_entrances USING gist (geom);

CREATE OR REPLACE VIEW park_issues AS
SELECT 'existing park without entrances' AS issue, p.id AS park_id, NULL::integer AS entrance_id,
       format('%s, %s m²', coalesce(p.name, p.zone_code), p.area_m2) AS detail
  FROM parks p
 WHERE p.status = 'existing'
   AND NOT EXISTS (SELECT 1 FROM park_entrances e WHERE e.park_id = p.id)
UNION ALL
SELECT 'planned park with entrances', p.id, NULL,
       format('%s, %s m², %s entrances', coalesce(p.name, p.zone_code), p.area_m2,
              (SELECT count(*) FROM park_entrances e WHERE e.park_id = p.id))
  FROM parks p
 WHERE p.status = 'planned'
   AND EXISTS (SELECT 1 FROM park_entrances e WHERE e.park_id = p.id)
UNION ALL
SELECT 'city park without a name', p.id, NULL, format('%s m²', p.area_m2)
  FROM parks p WHERE p.kind = 'city_park' AND p.status = 'existing' AND p.name IS NULL
UNION ALL
SELECT 'entrance without a park', NULL, e.id, coalesce(e.kind, '') || coalesce(', ' || e.note, '')
  FROM park_entrances e WHERE e.park_id IS NULL;

-- ----------------------------------------------------------- park access
--
-- Straight-line distance from each inhabited building to the nearest
-- park entrance, as for the metro an upper bound on reach. Only
-- entrances linked to a park count (see park_issues for the others).

CREATE TABLE IF NOT EXISTS building_park_access (
    building_id          integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    entrance_id          integer REFERENCES park_entrances(id) ON DELETE SET NULL,  -- nearest of an existing park
    park_id              uuid REFERENCES parks(id) ON DELETE SET NULL,              -- its park
    distance_m           numeric,
    outline_distance_m   numeric,     -- to the nearest existing park's edge, 0 inside; ignores gates
    planned_entrance_id  integer REFERENCES park_entrances(id) ON DELETE SET NULL,  -- planned parks included
    planned_distance_m   numeric,
    city_park_entrance_id integer REFERENCES park_entrances(id) ON DELETE SET NULL, -- nearest of an existing city park (Зп)
    city_park_distance_m numeric
);

-- Residents within 300 m (Sofiaplan's threshold), 400 m and 800 m of a
-- park entrance, for every district, neighbourhood, planning unit and the city.
CREATE OR REPLACE VIEW area_park_access AS
WITH b AS (
    SELECT r.people, r.district_code, r.neighbourhood_id, r.planning_unit_id,
           a.distance_m, a.planned_distance_m, a.city_park_distance_m
      FROM building_residents r
      JOIN building_park_access a ON a.building_id = r.id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM b
)
SELECT area_kind, area_id,
       sum(people) AS people,
       coalesce(sum(people) FILTER (WHERE distance_m <= 300), 0) AS within_300,
       coalesce(sum(people) FILTER (WHERE distance_m <= 400), 0) AS within_400,
       coalesce(sum(people) FILTER (WHERE distance_m <= 800), 0) AS within_800,
       coalesce(sum(people) FILTER (WHERE planned_distance_m <= 300), 0) AS planned_within_300,
       coalesce(sum(people) FILTER (WHERE city_park_distance_m <= 800), 0) AS city_park_within_800,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 300), 0)::numeric / nullif(sum(people), 0), 3) AS share_300,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 400), 0)::numeric / nullif(sum(people), 0), 3) AS share_400,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 800), 0)::numeric / nullif(sum(people), 0), 3) AS share_800,
       round(coalesce(sum(people) FILTER (WHERE planned_distance_m <= 300), 0)::numeric / nullif(sum(people), 0), 3) AS planned_share_300,
       round(coalesce(sum(people) FILTER (WHERE city_park_distance_m <= 800), 0)::numeric / nullif(sum(people), 0), 3) AS city_park_share_800
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- Sofiaplan's own answer to the same question (2021): every building
-- marked with or without walking access to a park, compared with our
-- straight-line distances from the same points. Filled by park_access.sql.
CREATE TABLE IF NOT EXISTS park_access_sofiaplan (
    sofiaplan_access boolean NOT NULL,        -- which of the two files it is in
    source_id      integer NOT NULL,          -- "id" in that file
    people         numeric,                   -- ppl_sgr_30; the "30" is not explained
    floor_area_m2  numeric,                   -- rzp (gross floor area)
    geom           geometry(Point, 4326) NOT NULL,
    district_code  text REFERENCES districts(code),
    neighbourhood_id integer REFERENCES neighbourhoods(id),
    distance_m     numeric,                   -- nearest entrance we count (existing park)
    any_distance_m numeric,                   -- nearest of all entrances, park or not
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL,
    PRIMARY KEY (sofiaplan_access, source_id)
);
CREATE INDEX IF NOT EXISTS park_access_sofiaplan_geom_idx ON park_access_sofiaplan USING gist (geom);

-- How the two answers agree, by area. Sofiaplan most likely measured
-- 300 m along footpaths from the building outline, we measure straight
-- lines from its centre point, so:
--   ours_only        expected: the walk is longer than the straight line
--   excluded_entrance Sofiaplan counted an entrance we do not (no park, or a planned park)
--   beyond_300       a building's centre is a little farther than its outline
--   beyond_400       a real contradiction: no entrance at all within 400 m
CREATE OR REPLACE VIEW park_access_agreement AS
WITH c AS (
    SELECT s.*,
           CASE WHEN s.sofiaplan_access AND s.distance_m <= 300 THEN 'both'
                WHEN NOT s.sofiaplan_access AND s.distance_m > 300 THEN 'neither'
                WHEN NOT s.sofiaplan_access THEN 'ours_only'
                WHEN s.any_distance_m <= 300 THEN 'excluded_entrance'
                WHEN s.any_distance_m <= 400 THEN 'beyond_300'
                ELSE 'beyond_400' END AS agreement
      FROM park_access_sofiaplan s
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, c.* FROM c
    UNION ALL SELECT 'district', c.district_code, c.* FROM c
    UNION ALL SELECT 'neighbourhood', c.neighbourhood_id::text, c.* FROM c
)
SELECT area_kind, area_id,
       count(*) AS buildings,
       count(*) FILTER (WHERE agreement = 'both') AS both,
       count(*) FILTER (WHERE agreement = 'neither') AS neither,
       count(*) FILTER (WHERE agreement = 'ours_only') AS ours_only,
       count(*) FILTER (WHERE agreement = 'excluded_entrance') AS excluded_entrance,
       count(*) FILTER (WHERE agreement = 'beyond_300') AS beyond_300,
       count(*) FILTER (WHERE agreement = 'beyond_400') AS beyond_400,
       round(coalesce(sum(people) FILTER (WHERE sofiaplan_access), 0) / nullif(sum(people), 0), 3) AS sofiaplan_share,
       round(coalesce(sum(people) FILTER (WHERE distance_m <= 300), 0) / nullif(sum(people), 0), 3) AS our_share_300
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- ------------------------------------------- kindergartens and schools
--
-- Kindergartens, nurseries and schools as points (Sofiaplan, 2018-08-08).
-- Filled by education.sql. A point is a site, not an institution: one
-- kindergarten can have several buildings and branches, each a row.

CREATE TABLE IF NOT EXISTS kindergartens (
    id             integer PRIMARY KEY,       -- "id" in the source
    name           text NOT NULL,             -- object_nam
    number         integer,                   -- object_nom, the municipal number
    kind           text NOT NULL CHECK (kind IN ('kindergarten', 'nursery', 'other')),  -- from the name
    type_code      text,                      -- type in the source; contradicts its own code list
    funding        text CHECK (funding IN ('state', 'municipal', 'private')),  -- NULL: unknown code
    funding_code   text,                      -- finansiran in the source
    is_branch      boolean NOT NULL,          -- "филиал" in the name, or osn_fil 2
    status         text NOT NULL CHECK (status IN ('open', 'closed', 'doubtful')),  -- doubtful: the source doubts it
    note           text,                      -- zabelezhka
    address        text,
    district_code  text REFERENCES districts(code),  -- kod_rayon, as the source says
    details_url    text,
    registration_id integer,                  -- dg_reg_karti id; municipal main sites only
    groups         integer,                   -- registered groups (2018)
    children       integer,                   -- registered children, all groups
    nursery_children integer,                 -- of them in nursery groups (under 3)
    geom           geometry(Point, 4326) NOT NULL,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS kindergartens_geom_idx ON kindergartens USING gist (geom);

CREATE TABLE IF NOT EXISTS schools (
    id             integer PRIMARY KEY,       -- "id" in the source
    name           text NOT NULL,
    number         integer,                   -- object_nom
    admin_code     integer,                   -- kodadmin, the ministry's code; NULL for 0
    kind           text CHECK (kind IN ('primary', 'basic', 'secondary', 'profiled', 'vocational', 'special')),
                                              -- type 1-6: НУ, ОУ, СОУ, профилирана, професионална, специална
    funding        text CHECK (funding IN ('state', 'municipal', 'private')),
    funding_code   text,
    class_count    integer,                   -- br_paralel, as given; 0 often means not filled in
    note           text,
    address        text,
    district_code  text REFERENCES districts(code),
    details_url    text,
    geom           geometry(Point, 4326) NOT NULL,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS schools_geom_idx ON schools USING gist (geom);

CREATE OR REPLACE VIEW education_issues AS
SELECT 'kindergarten closed or doubtful' AS issue, k.id AS kindergarten_id, NULL::integer AS school_id,
       format('%s: %s', k.name, coalesce(k.note, k.status)) AS detail
  FROM kindergartens k WHERE k.status <> 'open'
UNION ALL
SELECT 'unknown funding code', k.id, NULL, format('%s: finansiran %s', k.name, k.funding_code)
  FROM kindergartens k WHERE k.funding IS NULL
UNION ALL
SELECT 'unknown funding code', NULL, s.id, format('%s: finansiran %s', s.name, coalesce(s.funding_code, 'missing'))
  FROM schools s WHERE s.funding IS NULL
UNION ALL
-- Nurseries are not in the registration maps, so only kindergartens.
SELECT 'municipal kindergarten without a registration map', k.id, NULL, k.name
  FROM kindergartens k
 WHERE k.funding = 'municipal' AND k.kind = 'kindergarten' AND NOT k.is_branch AND k.status = 'open'
   AND k.registration_id IS NULL
UNION ALL
SELECT 'registration without groups', k.id, NULL, format('%s: registration %s', k.name, k.registration_id)
  FROM kindergartens k WHERE k.registration_id IS NOT NULL AND k.children IS NULL
UNION ALL
SELECT 'number contradicts the name', k.id, NULL, format('%s: number %s', k.name, k.number)
  FROM kindergartens k
 WHERE k.name ~ '№ ?[0-9]' AND k.number IS DISTINCT FROM substring(k.name FROM '№ ?([0-9]+)')::integer
UNION ALL
SELECT 'private by name, not by funding', k.id, NULL, format('%s: %s', k.name, k.funding)
  FROM kindergartens k WHERE k.name ~ '^"?Ч' AND k.funding IS DISTINCT FROM 'private'
UNION ALL
SELECT 'private by name, not by funding', NULL, s.id, format('%s: %s', s.name, s.funding)
  FROM schools s WHERE s.name ~* '^"?Ч|частн' AND s.funding IS DISTINCT FROM 'private'
UNION ALL
SELECT 'school without an admin code', NULL, s.id, s.name
  FROM schools s WHERE s.admin_code IS NULL
UNION ALL
SELECT 'admin code shared by schools', NULL, s.id, format('%s: %s', s.admin_code, s.name)
  FROM schools s
 WHERE (SELECT count(*) FROM schools o WHERE o.admin_code = s.admin_code) > 1
UNION ALL
SELECT 'school with no classes', NULL, s.id, s.name
  FROM schools s WHERE s.class_count = 0
UNION ALL
SELECT 'outside its district', k.id, NULL, format('%s: says %s', k.name, k.district_code)
  FROM kindergartens k
 WHERE NOT EXISTS (SELECT 1 FROM districts d WHERE d.code = k.district_code AND ST_Intersects(d.geom, k.geom))
UNION ALL
SELECT 'outside its district', NULL, s.id, format('%s: says %s', s.name, s.district_code)
  FROM schools s
 WHERE NOT EXISTS (SELECT 1 FROM districts d WHERE d.code = s.district_code AND ST_Intersects(d.geom, s.geom));

-- ------------------------------------------------------ education access
--
-- Straight-line distance from each inhabited building to the nearest
-- open kindergarten and school, an upper bound on reach as for the
-- metro and the parks. Filled by education_access.sql. "School" means
-- one with the lower grades (НУ, ОУ, СОУ); profiled and vocational
-- schools start at grade 8, special schools serve the whole city.

CREATE TABLE IF NOT EXISTS building_education_access (
    building_id          integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    kindergarten_id      integer REFERENCES kindergartens(id) ON DELETE SET NULL,  -- any funding, branches too
    kindergarten_distance_m numeric,
    municipal_kindergarten_id integer REFERENCES kindergartens(id) ON DELETE SET NULL,
    municipal_kindergarten_distance_m numeric,
    school_id            integer REFERENCES schools(id) ON DELETE SET NULL,
    school_distance_m    numeric,
    municipal_school_id  integer REFERENCES schools(id) ON DELETE SET NULL,
    municipal_school_distance_m numeric
);

-- Children aged 0-14 (and all residents) within reach, for every
-- district, neighbourhood, planning unit and the city. The building
-- data has no finer ages, so 0-14 stands for both kindergarten (3-6)
-- and school age. registered_children is the 2018 registration of the
-- municipal kindergartens inside the area, a rough sign of how many
-- places there are for its children; places outside the area count
-- where they are, not where their children live.
CREATE OR REPLACE VIEW area_education_access AS
WITH b AS (
    SELECT r.people, r.age_0_14 AS children, r.district_code, r.neighbourhood_id, r.planning_unit_id,
           a.kindergarten_distance_m AS kg, a.municipal_kindergarten_distance_m AS mkg,
           a.school_distance_m AS sch, a.municipal_school_distance_m AS msch
      FROM building_residents r
      JOIN building_education_access a ON a.building_id = r.id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM b
), k AS (
    SELECT k.children, d.code AS district_code, n.id AS neighbourhood_id, u.id AS planning_unit_id
      FROM kindergartens k
      LEFT JOIN districts d ON ST_Intersects(d.geom, k.geom)
      LEFT JOIN neighbourhoods n ON ST_Intersects(n.geom, k.geom)
      LEFT JOIN planning_units u ON ST_Intersects(u.geom, k.geom)
     WHERE k.registration_id IS NOT NULL
), places AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, sum(children) AS registered_children FROM k
    UNION ALL SELECT 'district', district_code, sum(children) FROM k GROUP BY 2
    UNION ALL SELECT 'neighbourhood', neighbourhood_id::text, sum(children) FROM k GROUP BY 2
    UNION ALL SELECT 'planning_unit', planning_unit_id::text, sum(children) FROM k GROUP BY 2
), s AS (
    SELECT area_kind, area_id,
           sum(people) AS people,
           sum(children) AS children,
           coalesce(sum(children) FILTER (WHERE kg <= 300), 0) AS kindergarten_within_300,
           coalesce(sum(children) FILTER (WHERE kg <= 500), 0) AS kindergarten_within_500,
           coalesce(sum(children) FILTER (WHERE mkg <= 500), 0) AS municipal_kindergarten_within_500,
           coalesce(sum(children) FILTER (WHERE sch <= 400), 0) AS school_within_400,
           coalesce(sum(children) FILTER (WHERE sch <= 800), 0) AS school_within_800,
           coalesce(sum(children) FILTER (WHERE msch <= 800), 0) AS municipal_school_within_800,
           coalesce(sum(people) FILTER (WHERE kg <= 500), 0) AS people_kindergarten_within_500,
           coalesce(sum(people) FILTER (WHERE sch <= 800), 0) AS people_school_within_800
      FROM levels
     WHERE area_id IS NOT NULL
     GROUP BY area_kind, area_id
)
SELECT s.*,
       round(kindergarten_within_300::numeric / nullif(children, 0), 3) AS kindergarten_share_300,
       round(kindergarten_within_500::numeric / nullif(children, 0), 3) AS kindergarten_share_500,
       round(municipal_kindergarten_within_500::numeric / nullif(children, 0), 3) AS municipal_kindergarten_share_500,
       round(school_within_400::numeric / nullif(children, 0), 3) AS school_share_400,
       round(school_within_800::numeric / nullif(children, 0), 3) AS school_share_800,
       round(municipal_school_within_800::numeric / nullif(children, 0), 3) AS municipal_school_share_800,
       coalesce(p.registered_children, 0) AS registered_children,
       round(coalesce(p.registered_children, 0)::numeric / nullif(children, 0), 3) AS registered_per_child
  FROM s LEFT JOIN places p USING (area_kind, area_id);

-- Sofiaplan's own answers about schools and kindergartens, compared
-- with ours. Filled by education_access.sql.
--
-- 2019: the area within 400, 800 and 1200 m on foot of any school (all
-- 242 they used, of every kind). Each building gets the smallest that
-- holds it, next to our straight line to any of our 275 schools. Walking
-- is never shorter, so a building they put within 400 m should be
-- within 400 m of us too, unless the schools differ.
CREATE TABLE IF NOT EXISTS school_access_sofiaplan (
    building_id    integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    sofiaplan_within_m integer CHECK (sofiaplan_within_m IN (400, 800, 1200)),  -- NULL: beyond 1200 m
    any_school_id  integer REFERENCES schools(id) ON DELETE SET NULL,  -- nearest school of any kind
    any_school_distance_m numeric,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text                       -- the polygon it is in; NULL when in none
);

CREATE OR REPLACE VIEW school_access_agreement AS
WITH b AS (
    SELECT r.age_0_14 AS children, r.district_code, r.neighbourhood_id,
           s.sofiaplan_within_m AS t, s.any_school_distance_m AS d
      FROM school_access_sofiaplan s JOIN building_residents r ON r.id = s.building_id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
)
SELECT area_kind, area_id,
       count(*) AS buildings,
       sum(children) AS children,
       round(coalesce(sum(children) FILTER (WHERE t <= 400), 0)::numeric / nullif(sum(children), 0), 3) AS sofiaplan_share_400,
       round(coalesce(sum(children) FILTER (WHERE d <= 400), 0)::numeric / nullif(sum(children), 0), 3) AS our_share_400,
       round(coalesce(sum(children) FILTER (WHERE t <= 800), 0)::numeric / nullif(sum(children), 0), 3) AS sofiaplan_share_800,
       round(coalesce(sum(children) FILTER (WHERE d <= 800), 0)::numeric / nullif(sum(children), 0), 3) AS our_share_800,
       count(*) FILTER (WHERE t <= 400 AND d > 400) AS sofiaplan_only_400,  -- should not happen
       count(*) FILTER (WHERE t <= 800 AND d > 800) AS sofiaplan_only_800
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- 2021: residents without walking access to a school or a municipal
-- kindergarten, per Sofiaplan area. The distance they used is not
-- given. Ours is counted at 400 and 500 m straight; with walking
-- longer than a straight line, 400 m straight is roughly 500 m on foot.
-- Their residents (ppl_all) are a later and larger count than the 2019
-- building data, so compare shares, not people.
CREATE TABLE IF NOT EXISTS education_unserved_sofiaplan (
    id             uuid PRIMARY KEY,          -- "id" in the source
    name           text,                      -- regname
    district_name  text,                      -- rajon
    people         numeric,                   -- ppl_all
    kindergarten_unserved numeric,            -- dg_bez_dos
    kindergarten_unserved_pct numeric,        -- dg_perc
    school_unserved numeric,                  -- uch_bez_do
    school_unserved_pct numeric,              -- uch_perc
    geom           geometry(MultiPolygon, 4326) NOT NULL,
    our_people     integer,                   -- residents of the 2019 buildings inside
    our_kindergarten_unserved_400 integer,    -- of them over 400 m from a municipal kindergarten
    our_kindergarten_unserved_500 integer,
    our_school_unserved_400 integer,          -- over 400 m from a school with the lower grades
    our_school_unserved_500 integer,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS education_unserved_sofiaplan_geom_idx ON education_unserved_sofiaplan USING gist (geom);

-- Assigned schools (прилежащи училища): the city's list of the addresses
-- each school (СУ or ОУ) takes first, as of 2026-06-30. It names the
-- address as street and number (or estate and block) with no
-- coordinates; school_catchments.sql finds each one among the official
-- address points (address_sofia). The schools are matched to our 2018
-- points, so a school opened since then has no school_id.
CREATE TABLE IF NOT EXISTS catchment_schools (
    list_id        integer PRIMARY KEY,       -- "ИД на прилежащо училище"
    name           text NOT NULL,             -- "Прилежащо училище"
    school_id      integer REFERENCES schools(id) ON DELETE SET NULL,
    match          text CHECK (match IN ('number_and_type', 'number')),  -- NULL: not found
    addresses      integer NOT NULL,          -- rows in the list
    located        integer NOT NULL,          -- of them found among the address points
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL
);

CREATE TABLE IF NOT EXISTS catchment_addresses (
    id             integer PRIMARY KEY,       -- OBJECTID
    list_school_id integer NOT NULL REFERENCES catchment_schools(list_id),
    border_list_ids integer[] NOT NULL DEFAULT '{}',  -- "ИД на гранични прилежащи училища"
    district_code  text REFERENCES districts(code),
    town           text NOT NULL,             -- as given, e.g. ГР.СОФИЯ,КВ.ДРАГАЛЕВЦИ
    street         text,                      -- street, estate (Ж.К.) or quarter (КВ.)
    number         text,                      -- house number, or block for an estate
    entrance       text,
    match          text CHECK (match IN ('street', 'block', 'alternative_name')),  -- NULL: not found
    address_fid    text,                      -- the address_sofia point
    geom           geometry(Point, 4326),
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS catchment_addresses_geom_idx ON catchment_addresses USING gist (geom);
CREATE INDEX IF NOT EXISTS catchment_addresses_school_idx ON catchment_addresses (list_school_id);

CREATE OR REPLACE VIEW catchment_issues AS
SELECT 'list school not in the 2018 schools' AS issue, c.list_id, NULL::text AS district_code,
       NULL::text AS street, c.name || ' (' || c.addresses || ' addresses)' AS detail
  FROM catchment_schools c WHERE c.school_id IS NULL
UNION ALL
SELECT 'list school matched by number only', c.list_id, NULL, NULL,
       c.name || ' → ' || s.name
  FROM catchment_schools c JOIN schools s ON s.id = c.school_id WHERE c.match = 'number'
UNION ALL
-- One row per street, not per address: most misses are whole streets.
SELECT 'address not among the address points', NULL, a.district_code, a.street,
       a.town || ', ' || a.street || ': ' || count(*) || ' addresses'
  FROM catchment_addresses a WHERE a.match IS NULL
 GROUP BY a.district_code, a.town, a.street
UNION ALL
-- Mostly villages with no school of their own (Долни Богров, Желява):
-- a fact about the list, worth seeing, not necessarily an error.
SELECT 'addresses over 5 km from their school', a.list_school_id, a.district_code, NULL,
       a.town || ' → ' || s.name || ': ' || count(*) || ' addresses, about '
         || round(avg(ST_Distance(a.geom::geography, s.geom::geography))::numeric / 1000, 1) || ' km'
  FROM catchment_addresses a
  JOIN catchment_schools c ON c.list_id = a.list_school_id
  JOIN schools s ON s.id = c.school_id
 WHERE ST_Distance(a.geom::geography, s.geom::geography) > 5000
 GROUP BY a.list_school_id, a.district_code, a.town, s.name;

-- Each inhabited building (2019) in the catchment of the nearest placed
-- list address within 30 m (median 5 m): the school it is assigned to,
-- against the nearest school that teaches grades 1-7 (basic or
-- secondary). A building with no placed address that near has no row
-- here: its catchment is unknown, not missing.
CREATE TABLE IF NOT EXISTS building_school_catchment (
    building_id    integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    address_id     integer NOT NULL REFERENCES catchment_addresses(id) ON DELETE CASCADE,
    address_distance_m numeric NOT NULL,
    list_school_id integer NOT NULL REFERENCES catchment_schools(list_id),
    school_id      integer REFERENCES schools(id) ON DELETE SET NULL,  -- NULL: not in the 2018 schools
    school_distance_m numeric,                -- straight line to the assigned school
    nearest_school_id integer REFERENCES schools(id) ON DELETE SET NULL,
    nearest_school_distance_m numeric
);
CREATE INDEX IF NOT EXISTS building_school_catchment_school_idx ON building_school_catchment (list_school_id);

-- Shares are of children aged 0-14 in buildings whose catchment is known.
CREATE OR REPLACE VIEW area_school_catchment AS
WITH b AS (
    SELECT r.age_0_14 AS children, r.district_code, r.neighbourhood_id, r.planning_unit_id,
           c.building_id IS NOT NULL AS known, c.school_distance_m AS d,
           c.school_id = c.nearest_school_id AS is_nearest,
           c.school_distance_m - c.nearest_school_distance_m AS extra_m
      FROM building_residents r LEFT JOIN building_school_catchment c ON c.building_id = r.id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM b
)
SELECT area_kind, area_id,
       sum(children) AS children,
       coalesce(sum(children) FILTER (WHERE known), 0) AS children_known,
       round(coalesce(sum(children) FILTER (WHERE known), 0)::numeric / nullif(sum(children), 0), 3) AS known_share,
       round(coalesce(sum(children) FILTER (WHERE d <= 800), 0)::numeric
             / nullif(sum(children) FILTER (WHERE d IS NOT NULL), 0), 3) AS assigned_share_800,
       round(coalesce(sum(children) FILTER (WHERE is_nearest), 0)::numeric
             / nullif(sum(children) FILTER (WHERE d IS NOT NULL), 0), 3) AS assigned_nearest_share,
       -- assigned to a school at least 400 m farther than the nearest
       round(coalesce(sum(children) FILTER (WHERE extra_m >= 400), 0)::numeric
             / nullif(sum(children) FILTER (WHERE d IS NOT NULL), 0), 3) AS assigned_farther_share,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d))::numeric) AS median_assigned_m
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- Per list school: the buildings and children in its catchment.
CREATE OR REPLACE VIEW catchment_school_children AS
SELECT c.list_id, c.school_id, count(b.building_id) AS buildings,
       coalesce(sum(r.age_0_14), 0) AS children,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY b.school_distance_m))::numeric) AS median_distance_m,
       count(b.building_id) FILTER (WHERE b.school_id = b.nearest_school_id) AS buildings_nearest
  FROM catchment_schools c
  LEFT JOIN building_school_catchment b ON b.list_school_id = c.list_id
  LEFT JOIN building_residents r ON r.id = b.building_id
 GROUP BY c.list_id, c.school_id;
