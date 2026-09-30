-- Initial schema for the urbandata.sofia.bg mirror.
--
-- Apply with:  psql -v ON_ERROR_STOP=1 -d urbandata -f db/schema.sql
-- Safe to re-run: every object is created only if it is missing.
--
-- The extensions need a superuser once per database; after that the
-- IF NOT EXISTS makes those lines a no-op for the owner.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS urban;
SET search_path = urban, public;

CREATE TABLE IF NOT EXISTS schema_version (
    version    integer PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

-- Portal groups; the first group of a dataset is its section (see sync.section_of).
CREATE TABLE IF NOT EXISTS sections (
    slug        text PRIMARY KEY,
    ckan_id     uuid UNIQUE,
    title       text,
    description text,
    raw         jsonb
);

CREATE TABLE IF NOT EXISTS organizations (
    slug        text PRIMARY KEY,
    ckan_id     uuid UNIQUE,
    title       text,
    description text,
    raw         jsonb
);

CREATE TABLE IF NOT EXISTS datasets (
    id                uuid PRIMARY KEY,           -- CKAN package id
    name              text NOT NULL UNIQUE,       -- CKAN slug, also the folder name
    title             text,
    notes             text,
    section           text REFERENCES sections(slug),
    organization      text REFERENCES organizations(slug),
    groups            text[] NOT NULL DEFAULT '{}',
    tags              text[] NOT NULL DEFAULT '{}',
    license           text,
    metadata_created  timestamptz,
    metadata_modified timestamptz,
    extras            jsonb NOT NULL DEFAULT '{}',  -- CKAN extras as key -> value
    raw               jsonb NOT NULL,               -- the full dataset.json
    loaded_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS datasets_section_idx ON datasets (section);
CREATE INDEX IF NOT EXISTS datasets_tags_idx ON datasets USING gin (tags);
CREATE INDEX IF NOT EXISTS datasets_title_trgm_idx ON datasets USING gin (title gin_trgm_ops);

CREATE TABLE IF NOT EXISTS resources (
    id            uuid PRIMARY KEY,               -- CKAN resource id
    dataset_id    uuid NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,
    name          text,
    format        text,                           -- as declared on the portal
    url           text,
    kind          text CHECK (kind IN ('vector', 'table', 'raster', 'archive',
                                       'document', 'link', 'live', 'other')),
    status        text,                           -- ok / link / error / skipped-too-large
    file_path     text,                           -- relative to the data dir; ';' for multi-part
    size          bigint,
    sha256        text,
    downloaded_at timestamptz,
    meta          jsonb NOT NULL DEFAULT '{}',    -- the .meta.json written by sync.py
    loaded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS resources_dataset_idx ON resources (dataset_id);
CREATE INDEX IF NOT EXISTS resources_kind_idx ON resources (kind);

-- One loadable file of a resource. A resource can have several: a zip with
-- a few GeoJSON files inside, or a multi-URL resource like bus-lines.
CREATE TABLE IF NOT EXISTS layers (
    id            serial PRIMARY KEY,
    resource_id   uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
    source_path   text NOT NULL,                  -- file, or 'archive.zip!/inner/path.geojson'
    sha256        text,                           -- of the source file; unchanged -> skip reload
    geometry_type text,                           -- dominant type, NULL for plain tables
    srid          integer,
    feature_count integer,
    extent        geometry(Geometry, 4326),
    fields        jsonb NOT NULL DEFAULT '{}',    -- property name -> observed type
    loaded_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (resource_id, source_path)
);
CREATE INDEX IF NOT EXISTS layers_extent_idx ON layers USING gist (extent);

-- Every feature of every layer, and every row of plain tables (geom NULL).
CREATE TABLE IF NOT EXISTS features (
    id            bigserial PRIMARY KEY,
    layer_id      integer NOT NULL REFERENCES layers(id) ON DELETE CASCADE,
    source_fid    text,                           -- feature id / row number in the source
    properties    jsonb NOT NULL DEFAULT '{}',
    geom          geometry(Geometry, 4326),
    geom_repaired boolean NOT NULL DEFAULT false  -- true when ST_MakeValid changed it
);
CREATE INDEX IF NOT EXISTS features_layer_idx ON features (layer_id);
CREATE INDEX IF NOT EXISTS features_geom_idx ON features USING gist (geom);
CREATE INDEX IF NOT EXISTS features_properties_idx ON features USING gin (properties jsonb_path_ops);

INSERT INTO schema_version (version) VALUES (1) ON CONFLICT DO NOTHING;
