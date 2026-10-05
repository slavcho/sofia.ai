-- What the people using the site add to it, kept apart from city.*, which
-- the db/city scripts rebuild from the sources.
--
-- Apply with:  psql -v ON_ERROR_STOP=1 -d urbandata -f db/app/schema.sql
-- Safe to re-run: every object is created only if it is missing.

CREATE SCHEMA IF NOT EXISTS app;
SET search_path = app, public;

-- Focuses besides the built-in ones in web/focuses.json, served with them
-- by GET /api/focuses. definition is a focus as in that file, without its
-- id; the page checks its layers, metrics and lists before showing it.
-- An id taken by a built-in focus is left out. The id goes into the URL
-- (?focus=<id>), so it is unique across all owners.
CREATE TABLE IF NOT EXISTS focuses (
    id         text PRIMARY KEY CHECK (id ~ '^[a-z0-9-]{1,64}$'),
    owner      text,                          -- NULL: shown to everyone; later, the user's own
    definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
    -- clock_timestamp(), so that focuses added in one transaction keep their order
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS focuses_owner_idx ON focuses (owner);
