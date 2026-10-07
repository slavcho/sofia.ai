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

-- The questions asked in the chat (POST /api/chat), one row per turn, to
-- see what people want to know and where the answers fail. The page keeps
-- the conversation and sends all of it every time; only its last message,
-- the new question, is kept here.
CREATE TABLE IF NOT EXISTS questions (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    chat_id  uuid,                                -- the page's conversation; NULL from a page that sends none
    turn     integer NOT NULL CHECK (turn >= 1),  -- 1 for the first question of a chat
    question text NOT NULL,
    asked_at timestamptz NOT NULL DEFAULT now(),
    -- NULL while the turn runs, or if the server stopped before it ended
    outcome  text CHECK (outcome IN ('answered', 'failed', 'stopped')),
    error    text                                 -- why it failed
);
CREATE INDEX IF NOT EXISTS questions_asked_at_idx ON questions (asked_at);
CREATE INDEX IF NOT EXISTS questions_chat_id_idx ON questions (chat_id, turn);

-- What other people asked is not for the model (urban_llm, see
-- llm_role.sql) to read and repeat; its default privileges gave it this
-- table when it was created.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'urban_llm') THEN
        REVOKE ALL ON questions FROM urban_llm;
    END IF;
END $$;
