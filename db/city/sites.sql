-- Rebuild city.tent_camp_sites, city.concessions, city.metro_project_areas,
-- city.settlement_boundaries and city.school_property from the raw portal
-- data. Needs areas.sql and education.sql first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/sites.sql
-- One transaction: either everything is rebuilt, or nothing changes.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, f.source_fid, f.properties AS p,
       ST_Multi(ST_CollectionExtract(f.geom, 3)) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('tent-camps', 'granted-concessions', 'terminated-concessions', 'project_metro-zip',
                  'boundaries-of-settlements-in-sofia-municipality-excluding-sofia-city',
                  'construction-boundary-of-sofia-city', 'schools-property-owned');

CREATE FUNCTION pg_temp.given(v text) RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE WHEN btrim(v) IN ('', '-', '---') THEN NULL
                ELSE btrim(regexp_replace(v, '\s+', ' ', 'g')) END $$;

DELETE FROM tent_camp_sites;
DELETE FROM concessions;
DELETE FROM metro_project_areas;
DELETE FROM settlement_boundaries;
DELETE FROM school_property;

-- ---------------------------------------------------------- tent camps

-- Placed by a point inside each site, so a site on a boundary is
-- counted once.
INSERT INTO tent_camp_sites (id, name, function, area_m2, source_district, geom,
                             district_code, neighbourhood_id, planning_unit_id,
                             data_as_of, source_dataset, source_fid)
SELECT (s.p->>'object_id')::integer, pg_temp.given(s.p->>'name_'),
       CASE WHEN s.p->>'function_' ~ '^Парк' THEN 'park'
            WHEN s.p->>'function_' ~ '^Спортно' THEN 'sports facility'
            WHEN s.p->>'function_' ~ '^Учебно' THEN 'school' END,
       round((s.p->>'area_kv_m')::numeric), pg_temp.given(s.p->>'rayon'), s.geom,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, c.pt) LIMIT 1),
       (SELECT n.id FROM neighbourhoods n WHERE ST_Intersects(n.geom, c.pt) LIMIT 1),
       (SELECT u.id FROM planning_units u WHERE ST_Intersects(u.geom, c.pt) LIMIT 1),
       '2021-03-01', s.dataset, s.source_fid
  FROM src s CROSS JOIN LATERAL (SELECT ST_PointOnSurface(s.geom) AS pt) c
 WHERE s.dataset = 'tent-camps';

-- ---------------------------------------------------------- concessions

-- The two files name the same things differently. Neither is dated;
-- both were published on 2026-02-16.
INSERT INTO concessions (id, status, deposit, resource, resource_group, concessionaire, decision,
                         contract_date, in_force_date, term, register_no, note, area_m2, geom,
                         data_as_of, source_dataset, source_fid)
SELECT 'granted-' || (s.p->>'object_id'), 'granted', pg_temp.given(s.p->>'nah_1'), pg_temp.given(s.p->>'pi'),
       pg_temp.given(s.p->>'gr'), pg_temp.given(s.p->>'concesione'), pg_temp.given(s.p->>'rmc'),
       pg_temp.given(s.p->>'data_dogov'), pg_temp.given(s.p->>'data_v_sil'), pg_temp.given(s.p->>'srok'),
       pg_temp.given(s.p->>'partida_nkr'), NULL, round((s.p->>'area_kv_m')::numeric), s.geom,
       DATE '2026-02-16', s.dataset, s.source_fid
  FROM src s WHERE s.dataset = 'granted-concessions'
UNION ALL
SELECT 'terminated-' || (s.p->>'object_id'), 'terminated', pg_temp.given(s.p->>'nahodishte'),
       pg_temp.given(s.p->>'vid'), pg_temp.given(s.p->>'grupa_bogatstvo'), pg_temp.given(s.p->>'koncesioner'),
       pg_temp.given(s.p->>'reshenie'), NULL, NULL, NULL, pg_temp.given(s.p->>'partida_nkr'),
       pg_temp.given(s.p->>'zabelejka'), round((s.p->>'area_kv_m')::numeric), s.geom,
       '2026-02-16', s.dataset, s.source_fid
  FROM src s WHERE s.dataset = 'terminated-concessions';

-- ---------------------------------------------------------- metro projects

-- The dataset names two projects: the line to Slatina (under
-- construction, council decision 104/2019) and the line to Vitosha and
-- the Simeonovo power station (a detailed plan submitted in May 2023).
INSERT INTO metro_project_areas (id, project, approval, area_m2, geom, district_code,
                                 data_as_of, source_dataset, source_fid)
SELECT (s.p->>'rn')::integer,
       CASE WHEN s.p->>'project_name' ~ 'Решение №104' THEN 'line to Slatina'
            ELSE 'line to Vitosha and Simeonovo' END,
       pg_temp.given(s.p->>'project_name'), round(ST_Area(s.geom::geography)::numeric), s.geom,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, ST_PointOnSurface(s.geom)) LIMIT 1),
       '2026-08-28', s.dataset, s.source_fid
  FROM src s WHERE s.dataset = 'project_metro-zip';

-- ---------------------------------------------------------- settlements

-- Settlement 23 has no geometry and is left out.

INSERT INTO settlement_boundaries (id, kind, ekatte, area_ha, geom, district_code,
                                   data_as_of, source_dataset, source_fid)
SELECT CASE WHEN s.dataset = 'construction-boundary-of-sofia-city' THEN 'sofia'
            ELSE 'settlement-' || (s.p->>'id') END,
       CASE WHEN s.dataset = 'construction-boundary-of-sofia-city' THEN 'Sofia city' ELSE 'settlement' END,
       (SELECT t.ekatte FROM census_tracts t
         WHERE ST_Intersects(s.geom, ST_PointOnSurface(t.geom))
         GROUP BY t.ekatte ORDER BY count(*) DESC, t.ekatte LIMIT 1),
       round((ST_Area(s.geom::geography) / 1e4)::numeric, 1), s.geom,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, s.geom)
         ORDER BY ST_Area(ST_Intersection(d.geom, s.geom)) DESC LIMIT 1),
       CASE WHEN s.dataset = 'construction-boundary-of-sofia-city' THEN DATE '2009-11-19' ELSE DATE '2019-01-01' END,
       s.dataset, s.source_fid
  FROM src s
 WHERE s.dataset IN ('boundaries-of-settlements-in-sofia-municipality-excluding-sofia-city',
                     'construction-boundary-of-sofia-city')
   AND s.geom IS NOT NULL;

-- ---------------------------------------------------------- school property

-- The list has the school's name only. A name that starts with a
-- number ("33 ОУ ...") is looked for among the schools with that
-- number, the others among all; the closest name wins.
INSERT INTO school_property (school_id, category, description, data_as_of, source_dataset, source_fid)
SELECT m.school_id,
       CASE s.p->>'layer'
            WHEN 'Държавни училища в частни имоти' THEN 'state school on private land'
            WHEN 'Държавни училища с имоти без данни за собствеността' THEN 'state school, no data on who owns the land'
            WHEN 'Общински училища с имоти без данни за собствеността' THEN 'municipal school, no data on who owns the land'
       END,
       pg_temp.given(s.p->>'description'), '2018-09-04', s.dataset, s.source_fid
  FROM src s
  CROSS JOIN LATERAL (
       SELECT c.id AS school_id FROM schools c
        WHERE c.number = substring(s.p->>'description' FROM '^(\d+) ')::integer
           OR (s.p->>'description' !~ '^\d+ ' AND similarity(lower(c.name), lower(s.p->>'description')) > 0.3)
        ORDER BY similarity(lower(c.name), lower(s.p->>'description')) DESC LIMIT 1) m
 WHERE s.dataset = 'schools-property-owned';

COMMIT;

SELECT function, count(*), round(sum(area_m2) / 1e4, 1) AS ha, count(district_code) AS in_city
  FROM tent_camp_sites GROUP BY 1 ORDER BY 1;
SELECT status, resource, count(*), round(sum(area_m2) / 1e4) AS ha FROM concessions GROUP BY 1, 2 ORDER BY 1, 2;
SELECT project, count(*), sum(area_m2) AS m2 FROM metro_project_areas GROUP BY 1;
SELECT kind, count(*), count(ekatte) AS with_ekatte, round(sum(area_ha)) AS ha FROM settlement_boundaries GROUP BY 1;
SELECT p.description, s.name, p.category FROM school_property p JOIN schools s ON s.id = p.school_id ORDER BY 1;
