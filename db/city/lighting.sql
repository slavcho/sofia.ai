-- Rebuild city.street_lights, city.light_poles, city.lighting_panels and
-- city.rectifier_stations from the raw portal data.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/lighting.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql first.
--
-- Not loaded: the street lighting cables (140 overhead, 44 underground)
-- and manholes (55) cover a few streets only, and the field survey for
-- the Simeonovo-Krastova analysis is 553 points with one code (2OST1).

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, f.source_fid, f.properties AS p, ST_GeometryN(f.geom, 1) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('street-lighting-luminaire', 'street-lighting-light-pole',
                  'street-lighting-control-panel', 'power-rectifier-stations');
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

-- Where each point lies.
CREATE TEMP TABLE place ON COMMIT DROP AS
SELECT s.dataset, s.source_fid,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, s.geom) LIMIT 1) AS district_code,
       (SELECT n.id FROM neighbourhoods n WHERE ST_Intersects(n.geom, s.geom) LIMIT 1) AS neighbourhood_id,
       (SELECT u.id FROM planning_units u WHERE ST_Intersects(u.geom, s.geom) LIMIT 1) AS planning_unit_id
  FROM src s;
CREATE INDEX ON place (dataset, source_fid);

-- "Неопределен" (undetermined) and "Няма данни" (no data) are both
-- taken as not given.
CREATE FUNCTION pg_temp.given(v text) RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE WHEN lower(btrim(v)) IN ('', 'неопределен', 'неопределена', 'няма данни') THEN NULL
                ELSE btrim(v) END $$;
CREATE FUNCTION pg_temp.yes(v text) RETURNS boolean IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE pg_temp.given(v) WHEN 'Да' THEN true WHEN 'Не' THEN false END $$;
CREATE FUNCTION pg_temp.condition(v text) RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE pg_temp.given(v) WHEN 'отлично' THEN 'excellent' WHEN 'много добро' THEN 'very good'
                WHEN 'добро' THEN 'good' WHEN 'лошо' THEN 'poor' WHEN 'много лошо' THEN 'very poor' END $$;

-- The survey numbers the districts alphabetically, 01 Банкя to 24
-- Триадица, not by their codes.
CREATE TEMP TABLE survey_district ON COMMIT DROP AS
SELECT * FROM (VALUES ('01', '24'), ('02', '17'), ('03', '20'), ('04', '03'), ('05', '08'), ('06', '12'),
                      ('07', '14'), ('08', '11'), ('09', '02'), ('10', '22'), ('11', '09'), ('12', '19'),
                      ('13', '15'), ('14', '13'), ('15', '21'), ('16', '04'), ('17', '18'), ('18', '23'),
                      ('19', '06'), ('20', '05'), ('21', '07'), ('22', '01'), ('23', '16'), ('24', '10'))
              AS t (area, code);

DELETE FROM street_lights;
DELETE FROM light_poles;
DELETE FROM lighting_panels;
DELETE FROM rectifier_stations;

-- ---------------------------------------------------------- luminaires

-- 29 lamp types read like "НЛВН|12|84": the type with two more fields
-- run into it. The type before the bar is used.
INSERT INTO street_lights (id, pole_id, lamp_type, lamp_type_source, lamps, condition, working, mount,
                           electronic_ballast, voltage, source_district_code, geom,
                           district_code, neighbourhood_id, planning_unit_id,
                           data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, pg_temp.given(s.p->>'bankid'),
       CASE split_part(pg_temp.given(s.p->>'lighttype'), '|', 1)
            WHEN 'НЛВН' THEN 'high-pressure sodium' WHEN 'НЛНН' THEN 'low-pressure sodium'
            WHEN 'LED' THEN 'LED' WHEN 'ЖЛВН' THEN 'mercury vapour'
            WHEN 'КЛЛ' THEN 'compact fluorescent' WHEN 'ЛЛК' THEN 'fluorescent'
            WHEN 'МХЛ' THEN 'metal halide' WHEN 'ЛНЖ' THEN 'incandescent' END,
       s.p->>'lighttype',
       CASE WHEN s.p->>'numberofli' ~ '^\d+$' THEN (s.p->>'numberofli')::integer END,
       pg_temp.condition(s.p->>'condition'), pg_temp.yes(s.p->>'bankwork'),
       pg_temp.given(s.p->>'banktype'),
       CASE pg_temp.given(s.p->>'pratype') WHEN 'електронна' THEN true END,
       pg_temp.given(s.p->>'voltage'), (SELECT a.code FROM survey_district a WHERE a.area = s.p->>'area'), s.geom,
       x.district_code, x.neighbourhood_id, x.planning_unit_id,
       '2017-11-01', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'street-lighting-luminaire';

-- ---------------------------------------------------------- poles

-- Heights are in cm. 0 and above 30 m are taken as not given.
INSERT INTO light_poles (id, pole_id, height_m, height_source, material, owner, marked, attached, geom,
                         district_code, planning_unit_id, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, pg_temp.given(s.p->>'poleid'),
       CASE WHEN s.p->>'height' ~ '^\d+$' AND (s.p->>'height')::integer BETWEEN 1 AND 3000
            THEN (s.p->>'height')::numeric / 100 END,
       s.p->>'height',
       CASE pg_temp.given(s.p->>'material') WHEN 'Стоманотръбен' THEN 'steel tube'
            WHEN 'Железобетонен' THEN 'reinforced concrete' WHEN 'Дървен' THEN 'wood' END,
       pg_temp.given(s.p->>'poleowner'), pg_temp.yes(s.p->>'marked'),
       CASE pg_temp.given(s.p->>'facility') WHEN 'Реклама' THEN 'advertising' WHEN 'GSM' THEN 'GSM'
            WHEN 'Друг' THEN 'other' END,
       s.geom, x.district_code, x.planning_unit_id, '2017-11-01', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'street-lighting-light-pole';

-- ---------------------------------------------------------- control panels

INSERT INTO lighting_panels (id, box_id, address, condition, photocell, radio_control, clock_control,
                             manual_control, source_district_code, geom, district_code, planning_unit_id,
                             data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, pg_temp.given(s.p->>'boxid'), pg_temp.given(s.p->>'address'),
       pg_temp.condition(s.p->>'condition'), pg_temp.yes(s.p->>'photocellc'),
       pg_temp.yes(s.p->>'radiocontr'), pg_temp.yes(s.p->>'watchcontr'), pg_temp.yes(s.p->>'manualcont'),
       (SELECT a.code FROM survey_district a WHERE a.area = s.p->>'area'), s.geom, x.district_code, x.planning_unit_id,
       '2017-11-01', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'street-lighting-control-panel';

-- ---------------------------------------------------------- rectifier stations

INSERT INTO rectifier_stations (id, name, built, address, geom, district_code,
                                data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, btrim(s.p->>'name'), pg_temp.given(s.p->>'godina'),
       pg_temp.given(s.p->>'address'), s.geom, x.district_code, '2021-07-05', s.dataset, s.source_fid
  FROM src s JOIN place x USING (dataset, source_fid)
 WHERE s.dataset = 'power-rectifier-stations';

ANALYZE street_lights;
ANALYZE light_poles;
ANALYZE lighting_panels;

COMMIT;

SELECT count(*) AS lights, sum(lamps) AS lamps, count(*) FILTER (WHERE lamp_type = 'LED') AS led,
       count(*) FILTER (WHERE condition IN ('poor', 'very poor')) AS poor,
       count(*) FILTER (WHERE NOT working) AS not_working, count(*) FILTER (WHERE district_code IS NULL) AS outside
  FROM street_lights;
SELECT count(*) AS poles, count(height_m) AS with_height, round(avg(height_m), 1) AS mean_height_m
  FROM light_poles;
SELECT count(*) AS panels, count(*) FILTER (WHERE photocell) AS photocell FROM lighting_panels;
SELECT count(*) AS rectifier_stations FROM rectifier_stations;
SELECT issue, count(*) FROM lighting_issues GROUP BY issue ORDER BY issue;
