-- Rebuild city.building_park_access: for every inhabited building, the
-- nearest park entrance, park edge and city park entrance; and
-- city.park_access_sofiaplan, the same measured for Sofiaplan's buildings.
-- Needs parks.sql and areas.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/park_access.sql
--
-- Distances are straight lines, not walking routes; see the note on
-- building_park_access in schema.sql.

\set ON_ERROR_STOP on
SET search_path = city, public;
BEGIN;

DELETE FROM building_park_access;

-- There are too many entrances to measure every one from every building,
-- as metro_access.sql does. Instead the 5 nearest are found by index on
-- a copy stretched so that a degree of longitude is as long as one of
-- latitude (cos 42.7° = 0.735), and the nearest in metres is picked
-- among them. Unstretched, <-> would favour north-south neighbours.
CREATE TEMP TABLE ent ON COMMIT DROP AS
SELECT e.id, e.park_id, p.status, p.kind, e.geom,
       ST_Scale(e.geom, cos(radians(42.7)), 1) AS flat
  FROM park_entrances e JOIN parks p ON p.id = e.park_id;
CREATE INDEX ON ent USING gist (flat);

CREATE TEMP TABLE edge ON COMMIT DROP AS
SELECT p.id, p.outline, ST_Scale(p.outline, cos(radians(42.7)), 1) AS flat
  FROM parks p WHERE p.status = 'existing';
CREATE INDEX ON edge USING gist (flat);
ANALYZE ent;
ANALYZE edge;

INSERT INTO building_park_access (building_id, entrance_id, park_id, distance_m, outline_distance_m,
                                  planned_entrance_id, planned_distance_m,
                                  city_park_entrance_id, city_park_distance_m)
SELECT b.id, e.id, e.park_id, round(e.d::numeric), round(o.d::numeric),
       p.id, round(p.d::numeric), c.id, round(c.d::numeric)
  FROM building_residents b
  CROSS JOIN LATERAL (SELECT ST_Scale(b.geom, cos(radians(42.7)), 1) AS flat) f
  CROSS JOIN LATERAL (
       SELECT x.id, x.park_id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM ent WHERE status = 'existing' ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) e
  CROSS JOIN LATERAL (
       SELECT ST_Distance(x.outline::geography, b.geom::geography) AS d
         FROM (SELECT * FROM edge ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) o
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM ent ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) p
  CROSS JOIN LATERAL (
       SELECT x.id, ST_Distance(x.geom::geography, b.geom::geography) AS d
         FROM (SELECT * FROM ent WHERE status = 'existing' AND kind = 'city_park'
                ORDER BY flat <-> f.flat LIMIT 5) x
        ORDER BY d LIMIT 1) c;

-- --------------------------------------------- Sofiaplan's own result

DELETE FROM park_access_sofiaplan;

CREATE TEMP TABLE every_ent ON COMMIT DROP AS
SELECT e.id, e.geom, ST_Scale(e.geom, cos(radians(42.7)), 1) AS flat FROM park_entrances e;
CREATE INDEX ON every_ent USING gist (flat);
ANALYZE every_ent;

INSERT INTO park_access_sofiaplan (sofiaplan_access, source_id, people, floor_area_m2, geom,
                                   district_code, neighbourhood_id, distance_m, any_distance_m,
                                   data_as_of, source_dataset, source_fid)
SELECT d.name = 'housing-units-with-walking-access-to-parks-and-gardens',
       (f.properties->>'id')::integer,
       (f.properties->>'ppl_sgr_30')::numeric,
       (f.properties->>'rzp')::numeric,
       g.geom,
       (SELECT x.code FROM districts x WHERE ST_Intersects(x.geom, g.geom) LIMIT 1),
       (SELECT x.id FROM neighbourhoods x WHERE ST_Intersects(x.geom, g.geom) LIMIT 1),
       round(e.d::numeric), round(a.d::numeric),
       DATE '2021-01-01', d.name, f.source_fid
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
  CROSS JOIN LATERAL (SELECT ST_GeometryN(f.geom, 1) AS geom) g
  CROSS JOIN LATERAL (SELECT ST_Scale(g.geom, cos(radians(42.7)), 1) AS flat) s
  CROSS JOIN LATERAL (
       SELECT min(ST_Distance(x.geom::geography, g.geom::geography)) AS d
         FROM (SELECT * FROM ent WHERE status = 'existing' ORDER BY flat <-> s.flat LIMIT 5) x) e
  CROSS JOIN LATERAL (
       SELECT min(ST_Distance(x.geom::geography, g.geom::geography)) AS d
         FROM (SELECT * FROM every_ent ORDER BY flat <-> s.flat LIMIT 5) x) a
 WHERE d.name IN ('housing-units-with-walking-access-to-parks-and-gardens',
                  'housing-units-without-walking-access-to-parks-and-gardens');

COMMIT;

SELECT * FROM area_park_access WHERE area_kind = 'city';
SELECT d.code, d.name, a.people, a.share_300, a.share_400, a.share_800,
       a.planned_share_300, a.city_park_share_800
  FROM area_park_access a JOIN districts d ON d.code = a.area_id
 WHERE a.area_kind = 'district'
 ORDER BY a.share_300 DESC;
SELECT * FROM park_access_agreement WHERE area_kind = 'city';
