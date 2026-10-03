-- Rebuild city.buildings (the cadastral plan's outlines) and
-- city.buildings_2019 (Sofiaplan's 2019 building centroids, linked to
-- those outlines) from the raw portal data.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/buildings.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs the areas (areas.sql) first.
--
-- Sources:
--   cad_plan_sgr-zip                         cad_plan_sgr.geojson        outlines (GIS Sofia, 2026-09-08)
--   obst_sobstv_sgradi-zip                   obst_sobstv_sgradi.geojson  municipal buildings (GIS Sofia, 2026-09-08)
--   building-centroids-resident-count-800-m  sgradi_centroids_800m_broy_jiteli  Sofiaplan, 2019
--
-- The three share no identifier: rn is a running number in each file,
-- and Sofiaplan's id_kk (cadastral number) is not in the outlines. So
-- they are joined by location. The outlines do not overlap, so a
-- centroid lies in at most one.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset,
       f.source_fid, f.properties AS p,
       CASE WHEN d.name = 'building-centroids-resident-count-800-m'
            THEN ST_GeometryN(f.geom, 1) ELSE f.geom END AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('cad_plan_sgr-zip', 'obst_sobstv_sgradi-zip',
                  'building-centroids-resident-count-800-m');
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

DELETE FROM buildings_2019;
DELETE FROM buildings;

-- --------------------------------------------------------- buildings

INSERT INTO buildings (id, function, category, ownership, municipal, floors_text, floors,
                       footprint_m2, region_label, geom, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'rn')::integer,
       f.function,
       -- Our grouping of the 218 functions; the source mixes an old
       -- classification in capitals with a newer, finer one. Order matters:
       -- "Клозети, обществени" is ancillary, not public.
       CASE
         WHEN f.function IS NULL THEN NULL
         WHEN f.l ~ 'обслужващи и спомагателни|бараки|гараж|клозет|портиерни|павилион|постройка'
           THEN 'ancillary'
         WHEN f.l ~ 'къщи|жилищ|обитаване|вили|общежити|жилищен блок'
           THEN 'residential'
         WHEN f.l ~ 'училищ|детски|детск|ясли|вуз|техникуми'
           THEN 'education'
         WHEN f.l ~ 'болници|поликлиники|диспансери|здравн|аптеки|санатори|бърза помощ|социални грижи|лечебни'
           THEN 'health'
         WHEN f.l ~ 'трансформатор|подстанции|^тец|^вец|^павец|топлоснабд|газоснабд|водоснабд|електропроизв|пречистване на води|помпени|компресорни|парокотелни|пара$|телефонни|ретранслатор|радиостанции|телевизионни|комуникацион|съобщени|телеграфо'
           THEN 'utility'
         WHEN f.l ~ 'селскостоп|краварници|овчарници|оранжерии|парници|гъбарници|птицевъд|животновъд|растениевъд|конюшни|зайчарници|пилчарници|силажни|осеменителни|семехранилище|плодохранилище'
           THEN 'agriculture'
         WHEN f.l ~ 'транспорт|гар|метростанции|аерогари|чакални|депа|хангари'
           THEN 'transport'
         WHEN f.l ~ 'промишлен|склад|производств|производ\.|печатници|полиграф|издателства|хранилище|ремонт|автосервиз|бензиностанции|бутилки|винарски|кожообработ|стъкларска|текстилна|шивашка|трикотажна|обувна'
           THEN 'industry'
         WHEN f.l ~ 'търговия|магазини|ресторант|хотели|мотели|закусвални|сладкарници|столови|хранене|банки|битови|бани|перални|книжарници|комплекси|почивни|хижи'
           THEN 'commercial'
         WHEN f.l ~ 'административ|обществен|държавн|правосъди|църкви|манастири|храм|ритуални|музеи|театри|кина|галерии|библиотеки|читалища|клубове|спорт|посолства|научн|институти|лаборатории|култур|съвети|комитети|организации|младежки|особено|специално'
           THEN 'public'
         ELSE 'other'
       END,
       nullif(nullif(btrim(s.p->>'ownership'), '---'), ''),
       false,
       nullif(btrim(s.p->>'numer_of_floors'), ''),
       CASE WHEN btrim(s.p->>'numer_of_floors') ~ '^-?[0-9]+$'
            THEN nullif(btrim(s.p->>'numer_of_floors')::integer, 0) END,
       round(ST_Area(s.geom::geography)::numeric, 1),
       nullif(btrim(s.p->>'region'), ''),
       s.geom, DATE '2026-09-08', s.dataset, s.source_fid
  FROM src s
 CROSS JOIN LATERAL (SELECT nullif(nullif(btrim(s.p->>'functional_type'), '---'), '') AS function) f0
 CROSS JOIN LATERAL (SELECT f0.function, lower(f0.function) AS l) f
 WHERE s.dataset = 'cad_plan_sgr-zip';

-- Areas by a point inside the outline. Districts subdivided first: a
-- point-in-polygon test against a whole district is slow 265,000 times.
CREATE TEMP TABLE area_parts ON COMMIT DROP AS
SELECT 'district' AS kind, code AS id, ST_Subdivide(geom, 64) AS geom FROM districts
UNION ALL SELECT 'neighbourhood', id::text, ST_Subdivide(geom, 64) FROM neighbourhoods
UNION ALL SELECT 'planning_unit', id::text, ST_Subdivide(geom, 64) FROM planning_units;
CREATE INDEX ON area_parts USING gist (geom);
ANALYZE area_parts;
ANALYZE buildings;

UPDATE buildings b
   SET district_code = x.district_code,
       neighbourhood_id = x.neighbourhood_id,
       planning_unit_id = x.planning_unit_id
  FROM (SELECT c.id,
               min(a.id) FILTER (WHERE a.kind = 'district') AS district_code,
               min(a.id::integer) FILTER (WHERE a.kind = 'neighbourhood') AS neighbourhood_id,
               min(a.id::integer) FILTER (WHERE a.kind = 'planning_unit') AS planning_unit_id
          FROM buildings c
          JOIN area_parts a ON ST_Intersects(a.geom, ST_PointOnSurface(c.geom))
         GROUP BY c.id) x
 WHERE x.id = b.id;

-- Municipal buildings: drawn separately from the same plan, but not
-- identically (none of the outlines is equal), so matched by a point
-- inside each. An empty municipal_ownership is taken as the whole
-- building.
UPDATE buildings b
   SET municipal = true,
       municipal_part = m.part
  FROM (SELECT c.id,
               nullif(string_agg(DISTINCT nullif(btrim(o.p->>'municipal_ownership'), ''), '; '), '') AS part
          FROM src o
          JOIN buildings c ON ST_Intersects(c.geom, ST_PointOnSurface(o.geom))
         WHERE o.dataset = 'obst_sobstv_sgradi-zip'
         GROUP BY c.id) m
 WHERE m.id = b.id;
ANALYZE buildings;

-- ---------------------------------------------------- buildings_2019

INSERT INTO buildings_2019 (id, building_id, match, distance_m, cadastre_ref, people,
                            households, apartments, floors, built_year, footprint_m2, geom,
                            data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       CASE WHEN i.id IS NOT NULL THEN i.id WHEN n.d <= 10 THEN n.id END,
       CASE WHEN i.id IS NOT NULL THEN 'inside' WHEN n.d <= 10 THEN 'nearest' ELSE 'none' END,
       CASE WHEN i.id IS NULL THEN round(n.d::numeric, 1) END,
       nullif(s.p->>'id_kk', ''),
       coalesce((s.p->>'nn_people_')::numeric, 0)::integer,
       nullif((s.p->>'nn_househ_')::numeric, 0)::integer,
       nullif((s.p->>'appcount')::numeric, 0)::integer,
       nullif((s.p->>'floorcount')::numeric, 0)::integer,
       nullif((s.p->>'nbuild_y_')::numeric, 0)::integer,
       round((s.p->>'area')::numeric, 1),
       s.geom, DATE '2019-01-01', s.dataset, s.source_fid
  FROM src s
  LEFT JOIN LATERAL (SELECT c.id FROM buildings c
                      WHERE ST_Intersects(c.geom, s.geom) ORDER BY c.id LIMIT 1) i ON true
  LEFT JOIN LATERAL (SELECT c.id, ST_Distance(c.geom::geography, s.geom::geography) AS d
                       FROM buildings c
                      WHERE i.id IS NULL
                      ORDER BY c.geom <-> s.geom LIMIT 1) n ON true
 WHERE s.dataset = 'building-centroids-resident-count-800-m';

UPDATE buildings b
   SET buildings_2019 = x.n,
       people_2019 = x.people,
       households_2019 = x.households,
       apartments_2019 = x.apartments,
       built_year_2019 = x.built_year,
       floors_2019 = x.floors
  FROM (SELECT building_id, count(*) AS n, sum(people) AS people, sum(households) AS households,
               sum(apartments) AS apartments, min(built_year) AS built_year, max(floors) AS floors
          FROM buildings_2019 WHERE building_id IS NOT NULL
         GROUP BY building_id) x
 WHERE x.building_id = b.id;
ANALYZE buildings_2019;

COMMIT;

SELECT category, count(*), round(sum(footprint_m2) / 1e6, 2) AS footprint_km2,
       sum(people_2019) AS people_2019
  FROM buildings GROUP BY category ORDER BY count(*) DESC;
SELECT match, count(*), count(*) FILTER (WHERE people > 0) AS inhabited, sum(people) AS people
  FROM buildings_2019 GROUP BY match ORDER BY match;
SELECT count(*) FILTER (WHERE municipal) AS municipal,
       count(*) FILTER (WHERE district_code IS NULL) AS outside_districts
  FROM buildings;
SELECT issue, count(*) FROM building_issues GROUP BY issue ORDER BY issue;
