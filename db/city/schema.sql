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

-- ----------------------------------------------------- public transport
--
-- Stops, lines and how often they run, from the static GTFS timetable of
-- the Center for Urban Mobility (schema gtfs, load_gtfs.py). Filled by
-- transit.sql. The feed has no regular week: every service lists its
-- dates, so one date stands for each kind of day (transit_days).

CREATE TABLE IF NOT EXISTS transit_days (
    day  text PRIMARY KEY CHECK (day IN ('weekday', 'saturday', 'sunday')),
    date date NOT NULL                        -- its timetable stands for the day
);

-- A stop as people see it: one pole or shelter. The feed has one stop per
-- mode (A0328 for buses, TB0328 for trolleybuses) with the same code on
-- the sign, so those are merged by code. A metro station is one stop.
CREATE TABLE IF NOT EXISTS transit_stops (
    id             text PRIMARY KEY,          -- the code on the sign; the stop_id for the metro
    code           text,                      -- stop_code in the feed
    name           text,
    modes          text[] NOT NULL,           -- bus, trolleybus, tram, metro; of the lines calling on a reference day
    gtfs_stop_ids  text[] NOT NULL,
    served         boolean NOT NULL,          -- some trip calls here on a reference day
    metro_station_id integer REFERENCES metro_stations(id) ON DELETE SET NULL,  -- by location, within 300 m
    geom           geometry(Point, 4326) NOT NULL,  -- centre of the merged stops
    data_as_of     date NOT NULL,             -- the day the feed was downloaded
    source_dataset text NOT NULL
);
CREATE INDEX IF NOT EXISTS transit_stops_geom_idx ON transit_stops USING gist (geom);

CREATE TABLE IF NOT EXISTS transit_routes (
    id             text PRIMARY KEY,          -- route_id in the feed
    name           text NOT NULL,             -- as on the vehicle: 94, 5, M2, N1
    long_name      text,                      -- termini
    mode           text NOT NULL CHECK (mode IN ('bus', 'trolleybus', 'tram', 'metro')),
    color          text,                      -- hex, without #
    text_color     text,
    night          boolean NOT NULL,          -- a night line (N1 .. N4)
    trips_weekday  integer NOT NULL,
    trips_saturday integer NOT NULL,
    trips_sunday   integer NOT NULL,
    geom           geometry(MultiLineString, 4326),  -- the shapes its trips run on the reference days
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL
);
CREATE INDEX IF NOT EXISTS transit_routes_geom_idx ON transit_routes USING gist (geom);

-- Every departure on the reference days, by clock time. A trip past
-- midnight counts on the day it runs: 25:10 of Monday's timetable is
-- 01:10 on Tuesday. The last call of a trip is not a departure.
CREATE TABLE IF NOT EXISTS transit_departures (
    day      text NOT NULL REFERENCES transit_days(day),
    stop_id  text NOT NULL REFERENCES transit_stops(id) ON DELETE CASCADE,
    route_id text NOT NULL REFERENCES transit_routes(id) ON DELETE CASCADE,
    trip_id  text NOT NULL,                   -- trip_id in the feed
    headsign text,
    at       timestamp NOT NULL               -- local time
);
CREATE INDEX IF NOT EXISTS transit_departures_stop_idx ON transit_departures (stop_id, day, at);

-- transit_departures by clock hour.
CREATE TABLE IF NOT EXISTS transit_stop_hours (
    stop_id    text NOT NULL REFERENCES transit_stops(id) ON DELETE CASCADE,
    day        text NOT NULL REFERENCES transit_days(day),
    hour       integer NOT NULL CHECK (hour BETWEEN 0 AND 23),
    departures integer NOT NULL,
    route_ids  text[] NOT NULL,
    PRIMARY KEY (stop_id, day, hour)
);

-- Problems of the feed as a whole, worked out by transit.sql (the raw
-- gtfs tables need not exist when this schema is applied).
CREATE TABLE IF NOT EXISTS transit_feed_issues (
    issue  text NOT NULL,
    detail text
);

CREATE OR REPLACE VIEW transit_issues AS
SELECT issue, NULL::text AS stop_id, NULL::text AS route_id, detail FROM transit_feed_issues
UNION ALL
SELECT 'stop never served', s.id, NULL,
       format('%s (%s), no trip on the reference days', coalesce(s.name, '?'), array_to_string(s.gtfs_stop_ids, ', '))
  FROM transit_stops s WHERE NOT s.served
UNION ALL
SELECT 'temporary stop', s.id, NULL, format('%s, %s', s.name, CASE WHEN s.served THEN 'served' ELSE 'not served' END)
  FROM transit_stops s WHERE s.name ~* 'временн'
UNION ALL
SELECT 'Latin letter in a Cyrillic name', s.id, NULL, s.name
  FROM transit_stops s WHERE s.name ~ '[А-Яа-я][A-Za-z]|[A-Za-z][А-Яа-я]'
UNION ALL
SELECT 'metro stop away from any station', s.id, NULL, s.name
  FROM transit_stops s WHERE 'metro' = ANY (s.modes) AND s.metro_station_id IS NULL
UNION ALL
SELECT 'metro name differs', s.id, NULL, format('GTFS %s, Sofiaplan %s', s.name, m.name)
  FROM transit_stops s JOIN metro_stations m ON m.id = s.metro_station_id
 WHERE upper(translate(s.name, 'AEOPCTXaeopctx', 'АЕОРСТХаеорстх')) IS DISTINCT FROM upper(m.name)
UNION ALL
SELECT 'line without trips', NULL, r.id, format('%s %s, %s: no trip on the reference days', r.mode, r.name, r.long_name)
  FROM transit_routes r WHERE r.trips_weekday + r.trips_saturday + r.trips_sunday = 0;

-- --------------------------------------------- public transport access
--
-- For each inhabited building (2019), the stops served within 400 m in a
-- straight line (about 5 minutes' walk, the common planning norm) and
-- how many vehicles leave from them in an hour, by time of day. Filled
-- by transit_access.sql. A trip counts once however many of the nearby
-- stops it calls at; both directions count (the feed has none). Times
-- are clock times on the reference days (transit_days):
--   peak      weekday 07:00-09:00
--   evening   weekday 20:00-23:00
--   saturday  Saturday 10:00-18:00
--   sunday    Sunday 10:00-18:00
--   night     weekday 01:00-04:00, when only night lines run
CREATE TABLE IF NOT EXISTS building_transit_access (
    building_id      integer PRIMARY KEY REFERENCES building_residents(id) ON DELETE CASCADE,
    stop_id          text REFERENCES transit_stops(id) ON DELETE SET NULL,  -- nearest served stop
    distance_m       numeric,
    stops_400        integer NOT NULL,         -- served stops within 400 m
    routes_400       integer NOT NULL,         -- lines leaving them on the weekday
    peak_per_hour    numeric NOT NULL,         -- trips per hour from those stops
    evening_per_hour numeric NOT NULL,
    saturday_per_hour numeric NOT NULL,
    sunday_per_hour  numeric NOT NULL,
    night_per_hour   numeric NOT NULL,
    sofiaplan_400    boolean NOT NULL          -- inside Sofiaplan's 0-400 m access zone (2021)
);

-- Shares of residents (2019). "Frequent" is 12 trips an hour or more
-- within 400 m, both directions together: about one every 10 minutes
-- each way. The same bar for the peak, the evening and the weekend, so
-- they compare; "night" asks for at least one trip an hour.
CREATE OR REPLACE VIEW area_transit_access AS
WITH b AS (
    SELECT r.people, r.district_code, r.neighbourhood_id, r.planning_unit_id, a.*
      FROM building_residents r
      JOIN building_transit_access a ON a.building_id = r.id
), levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM b
    UNION ALL SELECT 'district', b.district_code, b.* FROM b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM b
)
SELECT area_kind, area_id,
       sum(people) AS people,
       round(coalesce(sum(people) FILTER (WHERE stops_400 > 0), 0)::numeric / nullif(sum(people), 0), 3) AS transit_share_400,
       round(coalesce(sum(people) FILTER (WHERE peak_per_hour >= 12), 0)::numeric / nullif(sum(people), 0), 3) AS frequent_share,
       round(coalesce(sum(people) FILTER (WHERE evening_per_hour >= 12), 0)::numeric / nullif(sum(people), 0), 3) AS evening_share,
       round(coalesce(sum(people) FILTER (WHERE saturday_per_hour >= 12), 0)::numeric / nullif(sum(people), 0), 3) AS saturday_share,
       round(coalesce(sum(people) FILTER (WHERE sunday_per_hour >= 12), 0)::numeric / nullif(sum(people), 0), 3) AS sunday_share,
       round(coalesce(sum(people) FILTER (WHERE night_per_hour >= 1), 0)::numeric / nullif(sum(people), 0), 3) AS night_share,
       round(coalesce(sum(people) FILTER (WHERE sofiaplan_400), 0)::numeric / nullif(sum(people), 0), 3) AS sofiaplan_transit_share_400,
       -- Sofiaplan walked 400 m along streets in 2021, we draw a straight
       -- line to today's served stops: "ours only" is expected, "theirs
       -- only" means a stop near them that has no service now.
       round(coalesce(sum(people) FILTER (WHERE stops_400 > 0 AND NOT sofiaplan_400), 0)::numeric / nullif(sum(people), 0), 3) AS transit_ours_only_share,
       round(coalesce(sum(people) FILTER (WHERE stops_400 = 0 AND sofiaplan_400), 0)::numeric / nullif(sum(people), 0), 3) AS transit_theirs_only_share,
       -- of the buildings, not weighted by people
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY peak_per_hour))::numeric, 1) AS median_peak_per_hour
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- ------------------------------------------------------------- buildings
--
-- Every building outline of the archived cadastral plan (GIS Sofia,
-- published 2026-09-08). "Archived": the plan as it stood before the
-- cadastral map came into force, so buildings put up since then are
-- missing; the publisher does not say when that was. Filled by
-- buildings.sql.
CREATE TABLE IF NOT EXISTS buildings (
    id               integer PRIMARY KEY,     -- rn in the source
    function         text,                    -- as in the source, e.g. Сгради многожилищни
    category         text,                    -- our grouping of function, see buildings.sql
    ownership        text,                    -- as in the source; NULL where it is "---"
    municipal        boolean NOT NULL,        -- outline of a municipal building (obst_sobstv_sgradi)
    municipal_part   text,                    -- e.g. "ид. част", when only part of it is
    floors_text      text,                    -- as in the source: "4", "-1", "2/3", "1 1/2"
    floors           integer,                 -- floors_text when a whole number; negative: underground only
    footprint_m2     numeric NOT NULL,
    region_label     text,                    -- district name in the source
    -- From Sofiaplan's buildings (2019) whose centroid lies in this outline
    -- (or within 10 m of it); NULL when there is none.
    buildings_2019   integer NOT NULL DEFAULT 0,
    people_2019      integer,
    households_2019  integer,
    apartments_2019  integer,
    built_year_2019  integer,                 -- the earliest, if several
    floors_2019      integer,                 -- the highest, if several
    geom             geometry(Polygon, 4326) NOT NULL,
    district_code    text REFERENCES districts(code),
    neighbourhood_id integer REFERENCES neighbourhoods(id),
    planning_unit_id integer REFERENCES planning_units(id),
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS buildings_geom_idx ON buildings USING gist (geom);
CREATE INDEX IF NOT EXISTS buildings_district_idx ON buildings (district_code);
CREATE INDEX IF NOT EXISTS buildings_neighbourhood_idx ON buildings (neighbourhood_id);
CREATE INDEX IF NOT EXISTS buildings_planning_unit_idx ON buildings (planning_unit_id);

-- All of Sofiaplan's 2019 building centroids, inhabited or not, and the
-- cadastre outline each falls in. id is the same as building_residents.id
-- for the inhabited ones. match: 'inside' the outline, 'nearest' outline
-- within 10 m (the two drawings are offset by a few metres in places),
-- or 'none'.
CREATE TABLE IF NOT EXISTS buildings_2019 (
    id             integer PRIMARY KEY,       -- id in the source
    building_id    integer REFERENCES buildings(id) ON DELETE SET NULL,
    match          text NOT NULL CHECK (match IN ('inside', 'nearest', 'none')),
    distance_m     numeric,                   -- to the outline, for 'nearest' and 'none'
    cadastre_ref   text,                      -- id_kk, e.g. 68134.707.14.1
    people         integer NOT NULL,
    households     integer,
    apartments     integer,
    floors         integer,
    built_year     integer,
    footprint_m2   numeric,
    geom           geometry(Point, 4326) NOT NULL,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);
CREATE INDEX IF NOT EXISTS buildings_2019_geom_idx ON buildings_2019 USING gist (geom);
CREATE INDEX IF NOT EXISTS buildings_2019_building_idx ON buildings_2019 (building_id);

CREATE OR REPLACE VIEW building_issues AS
SELECT 'inhabited building of 2019 missing from the cadastral plan' AS issue,
       b.id::text AS building_id, NULL::integer AS cadastre_id,
       format('%s people, nearest outline %s m away', b.people, round(b.distance_m)) AS detail,
       b.geom
  FROM buildings_2019 b WHERE b.match = 'none' AND b.people > 0
UNION ALL
SELECT 'building without a function', NULL, c.id,
       format('%s, %s m²', coalesce(c.ownership, 'ownership unknown'), round(c.footprint_m2)),
       ST_PointOnSurface(c.geom)
  FROM buildings c WHERE c.function IS NULL
UNION ALL
SELECT 'floor count is not a number', NULL, c.id,
       format('"%s" (%s)', c.floors_text, c.function),
       ST_PointOnSurface(c.geom)
  FROM buildings c WHERE c.floors IS NULL AND c.floors_text IS NOT NULL
UNION ALL
SELECT 'district label disagrees with its location', NULL, c.id,
       format('labelled "%s", lies in %s', c.region_label, coalesce(d.name, 'no district')),
       ST_PointOnSurface(c.geom)
  FROM buildings c LEFT JOIN districts d ON d.code = c.district_code
 WHERE lower(c.region_label) IS DISTINCT FROM lower(d.name)
UNION ALL
SELECT 'outline smaller than 1 m²', NULL, c.id,
       format('%s m², %s', round(c.footprint_m2, 2), c.function),
       ST_PointOnSurface(c.geom)
  FROM buildings c WHERE c.footprint_m2 < 1;

-- Building stock by area, from the cadastral plan.
CREATE OR REPLACE VIEW area_buildings AS
WITH levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, b.* FROM buildings b
    UNION ALL SELECT 'district', b.district_code, b.* FROM buildings b
    UNION ALL SELECT 'neighbourhood', b.neighbourhood_id::text, b.* FROM buildings b
    UNION ALL SELECT 'planning_unit', b.planning_unit_id::text, b.* FROM buildings b
)
SELECT area_kind, area_id,
       count(*) AS buildings,
       count(*) FILTER (WHERE category = 'residential') AS residential_buildings,
       round(sum(footprint_m2)) AS footprint_m2,
       -- footprint times floors: a rough gross floor area, above ground only
       round(sum(footprint_m2 * floors) FILTER (WHERE floors > 0)) AS floor_area_m2,
       round(avg(floors) FILTER (WHERE floors > 0 AND category = 'residential'), 1) AS residential_mean_floors,
       count(*) FILTER (WHERE municipal) AS municipal_buildings
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;

-- ------------------------------------------------------ census addresses
--
-- NSI's 2011 census, summed by address and geocoded by Sofiaplan
-- (2018-02-27). One row per address point. Filled by census.sql.
-- Counts NSI withheld (-1 in the source, small numbers kept back for
-- privacy) are NULL, so sums of them are lower bounds. The dwelling
-- fields nj12_*, nj16_* and nj17_* are not loaded: nothing says what
-- their codes mean.
CREATE TABLE IF NOT EXISTS census_addresses (
    id               integer PRIMARY KEY,     -- id in the source
    nsi_building_id  text,
    street           text,
    street_code      text,
    number           text,                    -- e.g. 12, 5А
    settlement_code  text,                    -- EKATTE; 68134 is Sofia
    district_label   text,                    -- ecode_rayon in the source
    people           integer,                 -- NULL: no residents given
    dwellings        integer,
    male             integer,
    female           integer,
    age_0_14         integer,
    age_15_24        integer,
    age_25_34        integer,
    age_35_44        integer,
    age_45_54        integer,
    age_55_64        integer,
    age_65_plus      integer,
    -- Education, "from higher down to basic and lower" in the dataset
    -- description: edu_1 higher, edu_2 secondary, the rest lower; the
    -- exact levels are not documented. Only people aged 7 and over.
    edu_1            integer,
    edu_2            integer,
    edu_3            integer,
    edu_4            integer,
    edu_5            integer,
    -- Country of birth (ncob_*): Bulgaria, another EU country, elsewhere.
    born_bg          integer,
    born_eu          integer,
    born_non_eu      integer,
    built_year       integer,
    -- The cadastre outline the point lies in, or the nearest within 20 m.
    building_id      integer REFERENCES buildings(id) ON DELETE SET NULL,
    match            text NOT NULL CHECK (match IN ('inside', 'nearest', 'none')),
    distance_m       numeric,
    geom             geometry(Point, 4326) NOT NULL,
    district_code    text REFERENCES districts(code),
    neighbourhood_id integer REFERENCES neighbourhoods(id),
    planning_unit_id integer REFERENCES planning_units(id),
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS census_addresses_geom_idx ON census_addresses USING gist (geom);
CREATE INDEX IF NOT EXISTS census_addresses_building_idx ON census_addresses (building_id);

CREATE OR REPLACE VIEW census_issues AS
SELECT 'census address outside every district' AS issue, a.id AS address_id,
       format('%s %s, %s people', a.street, a.number, coalesce(a.people::text, 'withheld')) AS detail, a.geom
  FROM census_addresses a WHERE a.district_code IS NULL
UNION ALL
SELECT 'census address in another district than its code', a.id,
       format('%s %s: code %s, lies in %s (%s)', a.street, a.number, a.district_label,
              a.district_code, d.name), a.geom
  FROM census_addresses a JOIN districts d ON d.code = a.district_code
 WHERE a.district_label IS DISTINCT FROM a.district_code
UNION ALL
SELECT 'inhabited census address without a building outline', a.id,
       format('%s %s, %s people, nearest outline %s m away', a.street, a.number,
              a.people, round(a.distance_m)), a.geom
  FROM census_addresses a WHERE a.match = 'none' AND a.people > 0
UNION ALL
SELECT 'NSI building id used by several addresses', a.id,
       format('%s %s, building %s', a.street, a.number, a.nsi_building_id), a.geom
  FROM census_addresses a
 WHERE a.nsi_building_id IN (SELECT nsi_building_id FROM census_addresses
                              GROUP BY nsi_building_id HAVING count(*) > 1);

-- Residents by area, 2011 census, next to Sofiaplan's 2019 count (which
-- the rest of the measures weigh by). Shares of withheld counts are of
-- the addresses where the count is given.
CREATE OR REPLACE VIEW area_census AS
WITH levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, a.* FROM census_addresses a
    UNION ALL SELECT 'district', a.district_code, a.* FROM census_addresses a
    UNION ALL SELECT 'neighbourhood', a.neighbourhood_id::text, a.* FROM census_addresses a
    UNION ALL SELECT 'planning_unit', a.planning_unit_id::text, a.* FROM census_addresses a
), r AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, sum(people) AS people FROM building_residents
    UNION ALL SELECT 'district', district_code, sum(people) FROM building_residents GROUP BY district_code
    UNION ALL SELECT 'neighbourhood', neighbourhood_id::text, sum(people) FROM building_residents GROUP BY neighbourhood_id
    UNION ALL SELECT 'planning_unit', planning_unit_id::text, sum(people) FROM building_residents GROUP BY planning_unit_id
), c AS (
    SELECT area_kind, area_id,
           sum(people) AS census_people,
           sum(dwellings) AS census_dwellings,
           round(sum(people)::numeric / nullif(sum(dwellings) FILTER (WHERE people IS NOT NULL), 0), 2) AS people_per_dwelling,
           round(sum(age_0_14)::numeric / nullif(sum(people), 0), 3) AS census_share_0_14,
           round(sum(age_65_plus)::numeric / nullif(sum(people), 0), 3) AS census_share_65_plus,
           round(sum(edu_1) FILTER (WHERE edu_2 + edu_3 + edu_4 + edu_5 IS NOT NULL)::numeric
                 / nullif(sum(edu_1 + edu_2 + edu_3 + edu_4 + edu_5), 0), 3) AS higher_education_share,
           round(sum(born_eu + born_non_eu) FILTER (WHERE born_bg IS NOT NULL)::numeric
                 / nullif(sum(born_bg + born_eu + born_non_eu), 0), 3) AS born_abroad_share,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY built_year)
                  FILTER (WHERE people > 0))::numeric) AS median_built_year
      FROM levels
     WHERE area_id IS NOT NULL
     GROUP BY area_kind, area_id
)
SELECT c.*, r.people AS residents_2019,
       round(r.people::numeric / nullif(c.census_people, 0), 3) AS residents_2019_vs_census
  FROM c LEFT JOIN r USING (area_kind, area_id);

-- ------------------------------------------------ building attachments
--
-- What other datasets say about single buildings, each linked to a
-- cadastre outline where possible. Filled by building_extras.sql.

-- Large-panel apartment blocks (Sofiaplan, 2019-01-22): the 2019
-- building and the panel system it was built with.
CREATE TABLE IF NOT EXISTS panel_buildings (
    id             integer PRIMARY KEY,       -- id in the source
    sofiaplan_id   integer REFERENCES buildings_2019(id) ON DELETE SET NULL,
    building_id    integer REFERENCES buildings(id) ON DELETE SET NULL,
    panel_system   text,                      -- pan_nomen, e.g. ЕПЖС - БС 69 СФ/УД/
    cadastre_ref   text NOT NULL,             -- built from ekatte, cadregion, cadimmovab, cadbuildin
    people         integer,
    apartments     integer,
    floors         integer,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);

-- The register of buildings in the national energy efficiency
-- programme for multi-family buildings (2020-07-03). It has addresses
-- only; they are found among the census addresses: 'street' by street
-- and number, 'block' by housing estate and block number.
CREATE TABLE IF NOT EXISTS renovations (
    id                integer PRIMARY KEY,    -- id in the source
    status            text,                   -- Одобрено / Отхвърлено
    stage             integer,                -- stage_contract 1-5; not documented
    address           text NOT NULL,
    association       text,                   -- name_ss: the owners' association
    association_reg   text,                   -- reg_nr_ss
    census_address_id integer REFERENCES census_addresses(id) ON DELETE SET NULL,
    building_id       integer REFERENCES buildings(id) ON DELETE SET NULL,
    match             text NOT NULL CHECK (match IN ('street', 'block', 'none')),
    geom              geometry(Point, 4326),  -- the census address point
    district_code     text REFERENCES districts(code),  -- from the address text
    data_as_of        date NOT NULL,
    source_dataset    text NOT NULL,
    source_fid        text NOT NULL
);

-- Buildings certified (or being certified) under BREEAM (2020-10-01).
CREATE TABLE IF NOT EXISTS breeam_buildings (
    id             integer PRIMARY KEY,       -- id in the source
    name           text,                      -- as the project calls itself
    title          text,                      -- ime: the building
    stage          text,                      -- Проект / В строеж / В експлоатация
    details        jsonb NOT NULL,            -- the other, mostly empty, fields as given
    building_id    integer REFERENCES buildings(id) ON DELETE SET NULL,  -- outline within 30 m
    distance_m     numeric,                   -- to that outline, 0 if inside
    geom           geometry(Point, 4326) NOT NULL,
    district_code  text REFERENCES districts(code),
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL,
    source_fid     text NOT NULL
);

-- Shade on the units (apartments, offices) of each building, from
-- Sofiaplan's sunlight model (2020-07-01): one point per unit and
-- floor with "shaded", 0-1 as in the source, which does not say over
-- what period. The model's own building ids do not match ours, so the
-- unit points are taken by the outline they lie in.
CREATE TABLE IF NOT EXISTS building_shading (
    building_id    integer PRIMARY KEY REFERENCES buildings(id) ON DELETE CASCADE,
    units          integer NOT NULL,          -- unit points in the outline
    units_rated    integer NOT NULL,          -- of them with a shaded value
    shaded_mean    numeric,
    shaded_min     numeric,
    shaded_max     numeric,
    data_as_of     date NOT NULL,
    source_dataset text NOT NULL
);

CREATE OR REPLACE VIEW building_extra_issues AS
SELECT 'panel building not among the 2019 buildings' AS issue, p.id::text AS record_id,
       format('cadastre %s, %s', p.cadastre_ref, p.panel_system) AS detail, NULL::geometry AS geom
  FROM panel_buildings p WHERE p.sofiaplan_id IS NULL
UNION ALL
SELECT 'renovated building not found among the census addresses', r.id::text,
       format('%s (%s)', r.address, r.status), NULL
  FROM renovations r WHERE r.match = 'none'
UNION ALL
SELECT 'renovated building address found, but no outline', r.id::text, r.address, r.geom
  FROM renovations r WHERE r.match <> 'none' AND r.building_id IS NULL
UNION ALL
SELECT 'BREEAM building far from any outline', b.id::text,
       format('%s (%s)', b.title, b.stage), b.geom
  FROM breeam_buildings b WHERE b.building_id IS NULL;

-- ------------------------------------------- planning unit indicators

-- Sofiaplan's analyses by planning unit, about twenty datasets with a
-- column layout each. Kept long, one row per unit, indicator and
-- breakdown (a year, a scenario, a function), so that one table and one
-- map code path serve them all. indicators.sql says which column of
-- which dataset each indicator is.
CREATE TABLE IF NOT EXISTS indicators (
    id             text PRIMARY KEY,
    label          text NOT NULL,
    unit           text NOT NULL,             -- '%', 'share', 'count', 'm²', ...
    theme          text NOT NULL,
    description    text,
    data_as_of     date,                      -- what the values describe
    source_dataset text NOT NULL,
    source_units   integer NOT NULL,          -- units in the source file
    unmatched      integer NOT NULL           -- of them not found among ours
);

-- No foreign key to planning_units: areas.sql rebuilds those, and this
-- table is rebuilt after it (tests check that every unit exists).
CREATE TABLE IF NOT EXISTS planning_unit_indicators (
    planning_unit_id integer NOT NULL,
    indicator        text NOT NULL REFERENCES indicators(id) ON DELETE CASCADE,
    breakdown        text NOT NULL DEFAULT '',  -- year, scenario or function
    value            numeric,
    value_text       text,                      -- for categories
    match            text NOT NULL CHECK (match IN ('id', 'name', 'shape')),
    source_fid       text NOT NULL,
    PRIMARY KEY (planning_unit_id, indicator, breakdown)
);
CREATE INDEX IF NOT EXISTS planning_unit_indicators_indicator_idx
    ON planning_unit_indicators (indicator, breakdown);

CREATE OR REPLACE VIEW indicator_issues AS
SELECT 'source units not found among the planning units' AS issue, i.id AS indicator,
       format('%s of %s units of %s', i.unmatched, i.source_units, i.source_dataset) AS detail
  FROM indicators i WHERE i.unmatched > 0
UNION ALL
SELECT 'indicator covers only part of the planning units', i.id,
       format('%s of %s units', count(DISTINCT v.planning_unit_id),
              (SELECT count(*) FROM planning_units))
  FROM indicators i JOIN planning_unit_indicators v ON v.indicator = i.id
 GROUP BY i.id
HAVING count(DISTINCT v.planning_unit_id) < (SELECT count(*) FROM planning_units) * 0.9
UNION ALL
SELECT 'percentage outside 0-100', v.indicator,
       format('%s: %s %%', u.name, round(v.value, 1))
  FROM planning_unit_indicators v
  JOIN indicators i ON i.id = v.indicator AND i.unit = '%'
  LEFT JOIN planning_units u ON u.id = v.planning_unit_id
 WHERE v.value < 0 OR v.value > 100
UNION ALL
-- In the energy scenarios the heat demand is heating plus hot water,
-- except in a few units, nearly all in the optimistic 2050.
SELECT 'heat demand is not heating plus hot water', t.indicator,
       format('%s, %s: %s MWh, but %s + %s', u.name, t.breakdown, round(t.value), round(h.value), round(w.value))
  FROM planning_unit_indicators t
  JOIN planning_unit_indicators h ON h.planning_unit_id = t.planning_unit_id AND h.breakdown = t.breakdown
   AND h.indicator = 'energy_space_heating_mwh'
  JOIN planning_unit_indicators w ON w.planning_unit_id = t.planning_unit_id AND w.breakdown = t.breakdown
   AND w.indicator = 'energy_hot_water_mwh'
  LEFT JOIN planning_units u ON u.id = t.planning_unit_id
 WHERE t.indicator = 'energy_heat_demand_mwh' AND abs(t.value - h.value - w.value) > 1
UNION ALL
-- District heating is one of the sources of the heat demand, yet in some
-- units it supplies more, up to eleven times: probably the district heat
-- includes non-residential buildings while the demand is residential.
SELECT 'district heating supplies more than the heat demand', d.indicator,
       format('%s, %s: %s MWh district heating, %s MWh demand', u.name, d.breakdown, round(d.value), round(t.value))
  FROM planning_unit_indicators d
  JOIN planning_unit_indicators t ON t.planning_unit_id = d.planning_unit_id AND t.breakdown = d.breakdown
   AND t.indicator = 'energy_heat_demand_mwh'
  LEFT JOIN planning_units u ON u.id = d.planning_unit_id
 WHERE d.indicator = 'energy_district_heating_mwh' AND d.value > t.value * 1.01;

-- ------------------------------------------- small statistical areas

-- NSI census tracts (преброителни участъци, 2017), with what the 2011
-- census addresses and the 2019 buildings put inside them. Both are
-- placed by their building outline where they have one: address points
-- lie on the street, which is often the tract boundary.
CREATE TABLE IF NOT EXISTS census_tracts (
    id               text PRIMARY KEY,          -- district-control area-tract, e.g. 20-042-1
    district_code    text NOT NULL,             -- ecode_rayon as given
    ekatte           text NOT NULL,             -- settlement
    control_area     text NOT NULL,             -- kontr_r
    tract            text NOT NULL,             -- pr_u
    geom             geometry(MultiPolygon, 4326) NOT NULL,
    area_km2         numeric NOT NULL,
    census_addresses integer NOT NULL,
    census_people    integer,
    dwellings        integer,
    age_0_14         integer,
    age_65_plus      integer,
    residents_2019   integer,
    data_as_of       date,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS census_tracts_geom_idx ON census_tracts USING gist (geom);

-- NSI's 2011 census on the European 1 km grid, for the Sofia
-- agglomeration; in_sofia marks the cells whose centre is in a district.
CREATE TABLE IF NOT EXISTS population_grid (
    id               text PRIMARY KEY,          -- grd_id, e.g. 1kmN2269E5360
    people           integer NOT NULL,
    male             integer,
    female           integer,
    age_0_14         integer,
    age_15_64        integer,
    age_65_plus      integer,
    method           text,                      -- methd_cl, not documented
    in_sofia         boolean NOT NULL,
    census_address_people integer,              -- the same census by address
    residents_2019   integer,                   -- the 2019 buildings
    geom             geometry(MultiPolygon, 4326) NOT NULL,
    data_as_of       date,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS population_grid_geom_idx ON population_grid USING gist (geom);

-- Polling sections of the April 2026 election: the polling place, and
-- the section's area from the August 2026 electoral division.
CREATE TABLE IF NOT EXISTS polling_sections (
    id               text PRIMARY KEY,          -- section number, e.g. 234602001
    district_code    text NOT NULL,             -- digits 5-6 of the number
    number           integer NOT NULL,          -- within the district
    place            text,                      -- building, from the address
    address          text,
    geom             geometry(Point, 4326) NOT NULL,  -- the polling place
    place_district_code text,                   -- district the place lies in
    area             geometry(MultiPolygon, 4326),    -- NULL: not in the division
    residents_2019   integer,                   -- buildings inside the area
    mean_distance_m  integer,                   -- resident-weighted, straight line
    max_distance_m   integer,                   -- to the farthest inhabited building
    data_as_of       date,
    area_as_of       date,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS polling_sections_geom_idx ON polling_sections USING gist (geom);
CREATE INDEX IF NOT EXISTS polling_sections_area_idx ON polling_sections USING gist (area);

-- Electoral division areas with no polling place in April 2026.
CREATE TABLE IF NOT EXISTS polling_areas_unplaced (
    district_code    text NOT NULL,
    number           integer NOT NULL,
    place            text,
    geom             geometry(MultiPolygon, 4326) NOT NULL,
    PRIMARY KEY (district_code, number)
);

CREATE OR REPLACE VIEW small_area_issues AS
SELECT 'census tract coded for another district' AS issue, 'census_tract' AS kind, t.id,
       format('code %s, lies in %s', t.district_code, d.name) AS detail, ST_PointOnSurface(t.geom) AS geom
  FROM census_tracts t JOIN districts d ON ST_Contains(d.geom, ST_PointOnSurface(t.geom))
 WHERE d.code <> t.district_code
UNION ALL
SELECT 'grid cell: census by address far from the grid', 'grid', g.id,
       format('grid %s people, addresses %s', g.people, coalesce(g.census_address_people, 0)),
       ST_Centroid(g.geom)
  FROM population_grid g
 WHERE g.in_sofia AND greatest(g.people, coalesce(g.census_address_people, 0)) >= 200
   AND abs(g.people - coalesce(g.census_address_people, 0)) > 0.5 * greatest(g.people, coalesce(g.census_address_people, 0))
UNION ALL
SELECT 'polling place in another district than its section', 'polling_section', s.id,
       format('%s, lies in district %s', coalesce(s.place, s.address), s.place_district_code), s.geom
  FROM polling_sections s WHERE s.place_district_code IS DISTINCT FROM s.district_code
UNION ALL
SELECT 'polling section without an area in the division', 'polling_section', s.id,
       concat_ws(', ', s.place, s.address), s.geom
  FROM polling_sections s WHERE s.area IS NULL
UNION ALL
SELECT 'polling place far from its section', 'polling_section', s.id,
       format('%s: %s m from the section area', coalesce(s.place, s.address),
              round(ST_Distance(s.geom::geography, s.area::geography))), s.geom
  FROM polling_sections s
 WHERE s.area IS NOT NULL AND NOT ST_DWithin(s.geom::geography, s.area::geography, 1000)
UNION ALL
SELECT 'section area without a polling place', 'polling_area', u.district_code || '-' || u.number,
       format('section %s in district %s (%s)', u.number, u.district_code, u.place), ST_PointOnSurface(u.geom)
  FROM polling_areas_unplaced u;

-- ------------------------------------------------------- street lighting
--
-- The municipality's survey of the street lighting (DTI, 2017-11-01)
-- and Sofia Electric Transport's rectifier stations. Filled by
-- lighting.sql. Districts and planning units are where the point lies;
-- the survey's own district ("area") is kept to check against it.
CREATE TABLE IF NOT EXISTS street_lights (
    id               integer PRIMARY KEY,       -- id in the source
    pole_id          text,                      -- bankid: the pole it is on
    lamp_type        text,                      -- in English; NULL: not given
    lamp_type_source text,                      -- lighttype as given
    lamps            integer,                   -- numberofli
    condition        text CHECK (condition IN ('excellent', 'very good', 'good', 'poor', 'very poor')),
    working          boolean,                   -- bankwork
    mount            text,                      -- banktype: pole, park pole, facade, tunnel...
    electronic_ballast boolean,                 -- pratype
    voltage          text,
    source_district_code text,                  -- area, translated to a district code
    geom             geometry(Point, 4326) NOT NULL,
    district_code    text,
    neighbourhood_id integer,
    planning_unit_id integer,
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS street_lights_geom_idx ON street_lights USING gist (geom);

CREATE TABLE IF NOT EXISTS light_poles (
    id               integer PRIMARY KEY,       -- id in the source
    pole_id          text,                      -- poleid
    height_m         numeric,                   -- NULL: not given, 0 or above 30 m
    height_source    text,                      -- height as given, in cm
    material         text,                      -- steel tube, reinforced concrete, wood
    owner            text,                      -- poleowner as given
    marked           boolean,
    attached         text,                      -- facility: advertising, GSM, other
    geom             geometry(Point, 4326) NOT NULL,
    district_code    text,
    planning_unit_id integer,
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS light_poles_geom_idx ON light_poles USING gist (geom);

CREATE TABLE IF NOT EXISTS lighting_panels (
    id               integer PRIMARY KEY,       -- id in the source
    box_id           text,
    address          text,
    condition        text CHECK (condition IN ('excellent', 'very good', 'good', 'poor', 'very poor')),
    photocell        boolean,                   -- switched by daylight
    radio_control    boolean,
    clock_control    boolean,                   -- watchcontr
    manual_control   boolean,
    source_district_code text,
    geom             geometry(Point, 4326) NOT NULL,
    district_code    text,
    planning_unit_id integer,
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);
CREATE INDEX IF NOT EXISTS lighting_panels_geom_idx ON lighting_panels USING gist (geom);

-- Traction rectifier stations (ТИС) feeding the trams and trolleybuses.
CREATE TABLE IF NOT EXISTS rectifier_stations (
    id               integer PRIMARY KEY,
    name             text NOT NULL,
    built            text,                      -- godina: a year or a range
    address          text,
    geom             geometry(Point, 4326) NOT NULL,
    district_code    text,
    data_as_of       date NOT NULL,
    source_dataset   text NOT NULL,
    source_fid       text NOT NULL
);

CREATE OR REPLACE VIEW lighting_issues AS
SELECT 'street light outside every district' AS issue, 'street_light' AS kind, s.id::text AS id,
       concat_ws(', ', s.lamp_type_source, s.mount) AS detail, s.geom
  FROM street_lights s WHERE s.district_code IS NULL
UNION ALL
-- Along the boundaries the survey and the district outlines often
-- disagree by a few metres; only lights well inside another district
-- are listed.
SELECT 'street light coded for another district', 'street_light', s.id::text,
       format('coded %s, lies in %s, %s m from it', s.source_district_code, s.district_code,
              round(ST_Distance(s.geom::geography, d.geom::geography))), s.geom
  FROM street_lights s JOIN districts d ON d.code = s.source_district_code
 WHERE s.source_district_code <> s.district_code
   AND NOT ST_DWithin(s.geom::geography, d.geom::geography, 100)
UNION ALL
SELECT 'street light without a district code', 'street_light', s.id::text,
       concat_ws(', ', s.lamp_type_source, s.mount), s.geom
  FROM street_lights s WHERE s.source_district_code IS NULL
UNION ALL
SELECT 'lamp type with extra fields', 'street_light', s.id::text, s.lamp_type_source, s.geom
  FROM street_lights s WHERE s.lamp_type_source LIKE '%|%'
UNION ALL
SELECT 'light pole height out of range', 'light_pole', p.id::text,
       format('%s cm', p.height_source), p.geom
  FROM light_poles p WHERE p.height_source ~ '^\d+$' AND p.height_source::integer > 3000
UNION ALL
SELECT 'lighting panel coded for another district', 'lighting_panel', p.id::text,
       format('%s: area %s, lies in %s', coalesce(p.address, p.box_id), p.source_district_code, p.district_code), p.geom
  FROM lighting_panels p
 WHERE p.source_district_code IS NOT NULL AND p.source_district_code <> p.district_code;

CREATE OR REPLACE VIEW area_lighting AS
WITH levels AS (
    SELECT 'city' AS area_kind, 'all' AS area_id, s.* FROM street_lights s
    UNION ALL SELECT 'district', s.district_code, s.* FROM street_lights s
    UNION ALL SELECT 'neighbourhood', s.neighbourhood_id::text, s.* FROM street_lights s
    UNION ALL SELECT 'planning_unit', s.planning_unit_id::text, s.* FROM street_lights s
)
SELECT area_kind, area_id,
       count(*) AS street_lights,
       sum(lamps) AS lamps,
       round(count(*) FILTER (WHERE lamp_type = 'LED')::numeric
             / nullif(count(lamp_type), 0), 4) AS led_share,
       round(count(*) FILTER (WHERE condition IN ('poor', 'very poor'))::numeric
             / nullif(count(condition), 0), 4) AS poor_share,
       round(count(*) FILTER (WHERE NOT working)::numeric
             / nullif(count(working), 0), 4) AS not_working_share
  FROM levels
 WHERE area_id IS NOT NULL
 GROUP BY area_kind, area_id;
