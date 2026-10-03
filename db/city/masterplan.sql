-- Rebuild city.master_plan_zones and city.area_master_plan.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/masterplan.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql first.
--
-- Sources (Sofiaplan, section urban-planning):
--   spatial-planning-zones-from-the-2009-master-plan            12,306 zones
--   long-term-spatial-planning-zones-from-the-2009-master-plan     413 zones
-- The intersection of the two (12,711) adds nothing that these lack.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, d.extras->>'Актуален към' AS as_of, f.source_fid, f.properties AS p,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(f.geom), 3)) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('spatial-planning-zones-from-the-2009-master-plan',
                  'long-term-spatial-planning-zones-from-the-2009-master-plan');

-- Groups by the code's prefix. The long-term codes are partly upper
-- case (СМФ2д, ЖМ1д), so the patterns ignore case. Order matters:
-- Смф and Са before the agricultural С.
CREATE FUNCTION pg_temp.zone_group(code text) RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE
        WHEN code ~* '^Ж' THEN 'residential'
        WHEN code ~* '^Ц' THEN 'central'
        WHEN code ~* '^Смф' THEN 'mixed'
        WHEN code ~* '^О' THEN 'public services'
        WHEN code ~* '^П' THEN 'production'
        WHEN code ~* '^(Са|Тск)' THEN 'sport'
        WHEN code ~* '^(З|Тзв|Тго|Тгп|Тзсп|Тбз|Тгр|Тдр)' THEN 'green'
        WHEN code ~* '^(Г|Р)' THEN 'forest and nature'
        WHEN code ~* '^С' THEN 'agriculture'
        WHEN code ~* '^(Тти|Тжп|Ттр)' THEN 'transport'
        WHEN code ~* '^Трк' THEN 'water'
        WHEN code ~* '^(Твк|Тел|Тп)' THEN 'utilities'
        WHEN code ~* '^(Тди|Тсм)' THEN 'mining and landfills'
        ELSE 'special' END $$;

DELETE FROM area_master_plan;
DELETE FROM master_plan_zones;

INSERT INTO master_plan_zones (id, plan, code, name, zone_group, special_rules, area_ha, geom,
                               data_as_of, source_dataset, source_fid)
SELECT CASE WHEN s.dataset LIKE 'long-term%' THEN 100000 ELSE 0 END + (s.p->>'object_id')::integer,
       CASE WHEN s.dataset LIKE 'long-term%' THEN 'long-term' ELSE '2009' END,
       btrim(s.p->>'new_end'),
       btrim(regexp_replace(s.p->>'type_', '^\d+\.\S+\s*-\s*', '')),
       pg_temp.zone_group(btrim(s.p->>'new_end')),
       btrim(s.p->>'new_end') LIKE '%*',
       round((ST_Area(s.geom::geography) / 1e4)::numeric, 4),
       s.geom, '2009-01-01', s.dataset, s.source_fid
  FROM src s
 WHERE NOT ST_IsEmpty(s.geom);

-- The 2009 zones only: the long-term ones lie over them.
INSERT INTO area_master_plan (area_kind, area_id, zone_group, area_ha)
SELECT x.kind, x.id, z.zone_group,
       round(sum(ST_Area(CASE WHEN ST_CoveredBy(z.geom, x.geom) THEN z.geom
                              ELSE ST_Intersection(z.geom, x.geom) END::geography)::numeric) / 1e4, 2)
  FROM (SELECT 'district' AS kind, code AS id, geom FROM districts
        UNION ALL SELECT 'neighbourhood', id::text, geom FROM neighbourhoods
        UNION ALL SELECT 'planning_unit', id::text, geom FROM planning_units) x
  JOIN master_plan_zones z ON z.plan = '2009' AND ST_Intersects(z.geom, x.geom)
 GROUP BY 1, 2, 3;

ANALYZE master_plan_zones;

COMMIT;

SELECT plan, zone_group, count(*) AS zones, round(sum(area_ha)) AS ha
  FROM master_plan_zones GROUP BY 1, 2 ORDER BY 1, 4 DESC;
SELECT area_kind, count(DISTINCT area_id) AS areas, round(sum(area_ha)) AS ha
  FROM area_master_plan GROUP BY 1;
