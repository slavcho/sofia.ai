-- The login the LLM's SQL runs as (web/llm_tools.py): it may read the
-- data and nothing else, so no query it writes can change or drop a row,
-- whatever the query looks like.
--
-- Creating a role needs a superuser, so apply as postgres:
--     sudo -u postgres psql -v ON_ERROR_STOP=1 -d urbandata -f db/app/llm_role.sql
-- then give it a password and put that in ~/.pgpass:
--     sudo -u postgres psql -c "\password urban_llm"
--     127.0.0.1:5432:urbandata:urban_llm:<password>
-- Safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'urban_llm') THEN
        CREATE ROLE urban_llm LOGIN;
    END IF;
END $$;

-- Defaults for every session, a second line of defence behind the
-- grants; the app also sets them for each query.
ALTER ROLE urban_llm SET default_transaction_read_only = on;
ALTER ROLE urban_llm SET statement_timeout = '15s';
ALTER ROLE urban_llm SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE urban_llm SET temp_file_limit = '1GB';
ALTER ROLE urban_llm CONNECTION LIMIT 10;

GRANT CONNECT ON DATABASE urbandata TO urban_llm;

-- Every schema with data; public for PostGIS.
GRANT USAGE ON SCHEMA public, urban, city, gtfs, live, app TO urban_llm;
GRANT SELECT ON ALL TABLES IN SCHEMA public, urban, city, gtfs, live, app TO urban_llm;

-- The db/city scripts and load_gtfs.py drop and recreate tables, and
-- poll_live.py adds a partition every day; the new ones must be readable
-- too.
ALTER DEFAULT PRIVILEGES FOR ROLE urbanuser IN SCHEMA public, urban, city, gtfs, live, app
    GRANT SELECT ON TABLES TO urban_llm;
