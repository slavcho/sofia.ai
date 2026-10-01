-- Rebuild the city.metro_* tables from the raw portal data in urban.*.
--
-- Run from the repository root (for the \copy of metro_fixes.csv):
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/metro.sql
-- Everything happens in one transaction: either the whole metro is
-- rebuilt, or nothing changes.
--
-- Sources (all Sofiaplan, section mobility):
--   subway-stations           mgt_metro_spirki_26_sofpr_20210308  outlines, codes, status
--   subway-stations           mgt_metro_spirki_25_sofpr_20190000  points with names
--   metro-stations-entrances  mgt_metro_spirki_vhodove_25_osm_20200402  entrances (OSM)
--   subway-lines              mgt_metro_26_sofpr_20210308         track segments
-- Lines and which stations they serve are not in the portal data; they
-- are seeded below from the operator's published network.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

-- The raw features we need, with the file name (without the resource id)
-- so a reload of the same file keeps matching.
CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset,
       regexp_replace(l.source_path, '^.*__', '') AS file,
       f.source_fid, f.properties AS p, f.geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('subway-stations', 'metro-stations-entrances', 'subway-lines');

DELETE FROM metro_entrances;
DELETE FROM metro_station_lines;
DELETE FROM metro_stations;
DELETE FROM metro_tracks;

-- ------------------------------------------------------------- lines

-- M4 runs on M1 track plus the airport branch; its date is the branch's.
INSERT INTO metro_lines (code, name, color, opened, source) VALUES
    ('M1', 'Сливница – Бизнес Парк София', '#E3242B', '1998-01-28', 'Metropoliten EAD network map'),
    ('M2', 'Обеля – Витоша',               '#1E6FB8', '2012-08-31', 'Metropoliten EAD network map'),
    ('M3', 'Хаджи Димитър – Горна баня',   '#2BA84A', '2020-08-26', 'Metropoliten EAD network map'),
    ('M4', 'Обеля – Летище София',         '#F5B800', '2015-04-02', 'Metropoliten EAD network map')
ON CONFLICT (code) DO UPDATE
   SET name = excluded.name, color = excluded.color, opened = excluded.opened,
       source = excluded.source;

-- ---------------------------------------------------------- stations

-- The 2021 outlines carry codes and status but no names; the names are
-- taken from the 2019 points that lie within 50 m.
INSERT INTO metro_stations (id, code, name, name_source, status, outline, point,
                            area_m2, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       -- The source has lost the Cyrillic prefix: "??11" is МС11.
       'МС' || substring(s.p->>'stancia' FROM '\d+$'),
       n.name,
       CASE WHEN n.name IS NOT NULL
            THEN 'subway-stations, 2019 point within 50 m' END,
       s.p->>'layer',
       ST_Multi(s.geom),
       ST_PointOnSurface(s.geom),
       round(ST_Area(s.geom::geography)::numeric),
       DATE '2021-03-08', s.dataset, s.source_fid
  FROM src s
  LEFT JOIN LATERAL (
       SELECT nullif(q.p->>'name', '') AS name
         FROM src q
        WHERE q.file = 'mgt_metro_spirki_25_sofpr_20190000.geojson'
          AND ST_DWithin(q.geom::geography, s.geom::geography, 50)
        ORDER BY q.geom <-> s.geom
        LIMIT 1) n ON true
 WHERE s.file = 'mgt_metro_spirki_26_sofpr_20210308.geojson';

-- Manual corrections, each with its reason.
CREATE TEMP TABLE fixes (station_id integer, field text, value text, source text)
    ON COMMIT DROP;
\copy fixes FROM 'db/city/metro_fixes.csv' WITH (FORMAT csv, HEADER)

DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(format('%s/%s', f.station_id, f.field), ', ') INTO bad
      FROM fixes f
     WHERE f.field NOT IN ('name', 'status')
        OR (f.field = 'status' AND f.value NOT IN ('existing', 'planned'))
        OR NOT EXISTS (SELECT 1 FROM metro_stations s WHERE s.id = f.station_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'metro_fixes.csv: unknown station, field or status: %', bad;
    END IF;
END $$;

UPDATE metro_stations s
   SET name = f.value, name_source = 'metro_fixes.csv: ' || f.source
  FROM fixes f
 WHERE f.station_id = s.id AND f.field = 'name';

-- Before the lines are assigned: a station that is not built yet is on no line.
UPDATE metro_stations s
   SET status = f.value
  FROM fixes f
 WHERE f.station_id = s.id AND f.field = 'status';

-- Which lines serve which station, by code (Line 1 is МС1–МС23, Line 2
-- МС200–МС212). Line 3 stations have no code in the source.
INSERT INTO metro_station_lines (station_id, line_code, source)
SELECT s.id, l.line_code, l.source
  FROM metro_stations s
  CROSS JOIN LATERAL (SELECT substring(s.code FROM '\d+')::integer AS n) c
  JOIN (VALUES
        ('M1', 'Сливница – Младост 1 and the Бизнес Парк branch (МС1–МС16, МС18)'),
        ('M2', 'Обеля – Витоша (МС200–МС212)'),
        ('M3', 'existing station without a code: the only line built after the codes'),
        ('M4', 'Обеля, Сливница – Младост 1 and the airport branch (МС1–МС13, МС19–МС23)')
       ) AS l(line_code, source)
    ON s.status = 'existing'
   AND CASE l.line_code
         WHEN 'M1' THEN c.n BETWEEN 1 AND 16 OR c.n = 18
         WHEN 'M2' THEN c.n BETWEEN 200 AND 212
         WHEN 'M3' THEN s.code IS NULL
         WHEN 'M4' THEN c.n BETWEEN 1 AND 13 OR c.n BETWEEN 19 AND 23 OR c.n = 200
       END;

-- --------------------------------------------------------- entrances

-- Each entrance goes to the nearest existing station within 500 m,
-- preferring one whose name resembles the station named in the source.
-- Only stations on a line already open at the entrances' date qualify:
-- the 2020 snapshot has "НДК" entrances next to the later Line 3 НДК.
INSERT INTO metro_entrances (id, station_id, station_name, distance_m, name,
                             wheelchair, access_note, bicycle, geom,
                             data_as_of, source_dataset, source_fid)
SELECT (e.p->>'id')::integer,
       m.id, e.p->>'metro_st', round(m.d::numeric, 1),
       e.p->>'name', e.p->>'wheelchair', e.p->>'wheelcha_1', e.p->>'bicycle',
       ST_GeometryN(e.geom, 1),
       DATE '2020-04-02', e.dataset, e.source_fid
  FROM src e
  LEFT JOIN LATERAL (
       SELECT s.id, ST_Distance(s.outline::geography, e.geom::geography) AS d
         FROM metro_stations s
        WHERE s.status = 'existing'
          AND ST_DWithin(s.outline::geography, e.geom::geography, 500)
          AND EXISTS (SELECT 1
                        FROM metro_station_lines sl
                        JOIN metro_lines ml ON ml.code = sl.line_code
                       WHERE sl.station_id = s.id AND ml.opened <= DATE '2020-04-02')
        ORDER BY similarity(lower(s.name), lower(e.p->>'metro_st')) > 0.3 DESC NULLS LAST, d
        LIMIT 1) m ON true
 WHERE e.dataset = 'metro-stations-entrances';

-- ------------------------------------------------------------ tracks

INSERT INTO metro_tracks (id, status, geom, length_m, data_as_of, source_dataset, source_fid)
SELECT (t.p->>'id')::integer, t.p->>'sastoyanie', ST_Multi(t.geom),
       round(ST_Length(t.geom::geography)::numeric),
       DATE '2021-03-08', t.dataset, t.source_fid
  FROM src t
 WHERE t.file = 'mgt_metro_26_sofpr_20210308.geojson';

COMMIT;

SELECT 'stations' AS "table", count(*) FROM metro_stations
UNION ALL SELECT 'station lines', count(*) FROM metro_station_lines
UNION ALL SELECT 'entrances', count(*) FROM metro_entrances
UNION ALL SELECT 'tracks', count(*) FROM metro_tracks;
SELECT issue, count(*) FROM metro_issues GROUP BY 1 ORDER BY 1;
