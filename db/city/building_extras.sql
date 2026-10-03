-- Rebuild what other datasets say about single buildings: panel blocks,
-- the renovation register, BREEAM certificates and shading.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/building_extras.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql, buildings.sql and census.sql first.
--
-- Sources:
--   population-statistics-for-panel-apartment-buildings-sofia-city  sgradi_panel_25_sofpr_20190122  (no geometry)
--   registry-of-renovated-buildings   registar_npeemjs_sanirani_sgr_26_sofpl_20200703  (addresses only)
--   breeam-certified-buildings        sgr_breeam_20201000
--   building-solar-irradiance         senki_sos_20200701  shade per unit and floor
--
-- Not used from building-solar-irradiance: senki_sgr (one point per
-- building of the model, with its elevation above sea level only),
-- senki_sos_fasadi (3 million facade segments; their ap_id is not the
-- unit id of senki_sos, so they cannot be tied to the units) and
-- senki_ge (by planning unit, belongs with the planning unit indicators).

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, regexp_replace(l.source_path, '^.*[_/]', '') AS file,
       f.source_fid, f.properties AS p,
       CASE WHEN GeometryType(f.geom) = 'MULTIPOINT' THEN ST_GeometryN(f.geom, 1) ELSE f.geom END AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('population-statistics-for-panel-apartment-buildings-sofia-city',
                  'registry-of-renovated-buildings', 'breeam-certified-buildings')
    OR (d.name = 'building-solar-irradiance' AND l.source_path LIKE '%senki_sos_20200701%');
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

DELETE FROM panel_buildings;
DELETE FROM renovations;
DELETE FROM breeam_buildings;
DELETE FROM building_shading;

-- --------------------------------------------------------- panel blocks

-- The source has the cadastral number in parts, which Sofiaplan's 2019
-- buildings have joined as id_kk; each matches exactly one.
INSERT INTO panel_buildings (id, sofiaplan_id, building_id, panel_system, cadastre_ref,
                             people, apartments, floors, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer, b.id, b.building_id,
       nullif(regexp_replace(btrim(s.p->>'pan_nomen'), '\s+', ' ', 'g'), ''),
       x.ref,
       (s.p->>'nn_people_')::numeric::integer,
       nullif((s.p->>'appcount')::numeric, 0)::integer,
       nullif((s.p->>'floorcount')::numeric, 0)::integer,
       DATE '2019-01-22', s.dataset, s.source_fid
  FROM src s
 CROSS JOIN LATERAL (SELECT concat_ws('.', s.p->>'ekatte', (s.p->>'cadregion')::numeric::integer,
                                      (s.p->>'cadimmovab')::numeric::integer,
                                      (s.p->>'cadbuildin')::numeric::integer) AS ref) x
  LEFT JOIN buildings_2019 b ON b.cadastre_ref = x.ref
 WHERE s.dataset = 'population-statistics-for-panel-apartment-buildings-sofia-city';

-- ------------------------------------------------- renovation register

-- Street names and numbers as comparable keys: capitals, no type prefix
-- (ул., бул., ж.к., кв.), Roman numerals as digits (Надежда IV and
-- Надежда 4), Latin look-alikes as Cyrillic, nothing but letters and
-- digits, no leading zeros.
CREATE FUNCTION pg_temp.street_key(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(regexp_replace(
           regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
             regexp_replace(upper(btrim(v)), '^(УЛ|БУЛ|Ж\.?\s*К|КВ|ПЛ)[.\s]+', ''),
             '\s+[IІ][VУ]$', '4'), '\s+[VУ]$', '5'), '\s+[IІ]{3}$', '3'),
             '\s+[IІ]{2}$', '2'), '\s+[IІ]$', '1'),
           '[^А-ЯA-Z0-9]', '', 'g'), '')
$$;
CREATE FUNCTION pg_temp.number_key(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  -- "8-10" is taken as 8: a building on several numbers is listed under one.
  SELECT nullif(regexp_replace(translate(upper(regexp_replace(split_part(v, '-', 1), '[^[:alnum:]]', '', 'g')),
                                         'ABEKMHOPCTX', 'АВЕКМНОРСТХ'), '^0+', ''), '')
$$;

CREATE TEMP TABLE census_keys ON COMMIT DROP AS
SELECT a.id, a.district_label AS district_code, a.building_id, a.geom,
       a.street ~ '^(Ж\.|КВ\.)' AS estate,
       pg_temp.street_key(a.street) AS street, pg_temp.number_key(a.number) AS number
  FROM census_addresses a;
CREATE INDEX ON census_keys (district_code, number);
ANALYZE census_keys;

CREATE TEMP TABLE reg ON COMMIT DROP AS
SELECT s.*, (s.p->>'id')::integer AS id, btrim(s.p->>'address') AS address,
       (SELECT d.code FROM districts d
         WHERE upper(d.name) = upper(btrim(substring(s.p->>'address' FROM '^Район\s+([^,]+),')))) AS district_code,
       pg_temp.street_key(substring(s.p->>'address' FROM '(?:ж\.к\.|кв\.)\s*([^,]+)')) AS estate,
       pg_temp.street_key((regexp_match(s.p->>'address', ',\s*([^,]*?)\s*№\s*([^,]+)'))[1]) AS street,
       pg_temp.number_key((regexp_match(s.p->>'address', ',\s*([^,]*?)\s*№\s*([^,]+)'))[2]) AS number,
       pg_temp.number_key(substring(s.p->>'address' FROM 'бл\.\s*([^,]+)')) AS block
  FROM src s WHERE s.dataset = 'registry-of-renovated-buildings';

-- The same street and number in the same district; failing that, the
-- block number in a housing estate of the same district whose name is
-- the register's or begins with it ("Дружба 1" is "ДРУЖБА" in the
-- census), as long as only one estate fits.
INSERT INTO renovations (id, status, stage, address, association, association_reg,
                         census_address_id, building_id, match, geom, district_code,
                         data_as_of, source_dataset, source_fid)
SELECT r.id, nullif(btrim(r.p->>'status'), ''), (r.p->>'stage_contract')::integer, r.address,
       nullif(btrim(r.p->>'name_ss'), ''), nullif(btrim(r.p->>'reg_nr_ss'), ''),
       coalesce(st.id, bl.id),
       coalesce(st.building_id, bl.building_id),
       CASE WHEN st.id IS NOT NULL THEN 'street' WHEN bl.id IS NOT NULL THEN 'block' ELSE 'none' END,
       coalesce(st.geom, bl.geom),
       r.district_code, DATE '2020-07-03', r.dataset, r.source_fid
  FROM reg r
  LEFT JOIN LATERAL (SELECT c.id, c.building_id, c.geom FROM census_keys c
                      WHERE c.district_code = r.district_code AND c.number = r.number
                        AND c.street = r.street AND NOT c.estate
                      ORDER BY c.id LIMIT 1) st ON true
  LEFT JOIN LATERAL (SELECT c.id, c.building_id, c.geom FROM census_keys c
                      WHERE st.id IS NULL AND r.block IS NOT NULL AND r.estate IS NOT NULL
                        AND c.district_code = r.district_code AND c.number = r.block AND c.estate
                        AND (c.street = r.estate OR r.estate LIKE c.street || '%'
                             OR c.street LIKE r.estate || '%')
                        AND (SELECT count(DISTINCT c2.street) FROM census_keys c2
                              WHERE c2.district_code = r.district_code AND c2.number = r.block AND c2.estate
                                AND (c2.street = r.estate OR r.estate LIKE c2.street || '%'
                                     OR c2.street LIKE r.estate || '%')) = 1
                      ORDER BY c.id LIMIT 1) bl ON true;

-- --------------------------------------------------------------- BREEAM

INSERT INTO breeam_buildings (id, name, title, stage, details, building_id, distance_m, geom,
                              district_code, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       nullif(regexp_replace(btrim(s.p->>'name'), '\s+', ' ', 'g'), ''),
       nullif(regexp_replace(btrim(s.p->>'ime'), '\s+', ' ', 'g'), ''),
       nullif(btrim(s.p->>'etap'), ''),
       jsonb_strip_nulls(s.p - 'id' - 'name' - 'ime' - 'etap'),
       CASE WHEN n.d <= 30 THEN n.id END,
       CASE WHEN n.d <= 30 THEN round(n.d::numeric, 1) END,
       s.geom,
       (SELECT d.code FROM districts d WHERE ST_Intersects(d.geom, s.geom) ORDER BY d.code LIMIT 1),
       DATE '2020-10-01', s.dataset, s.source_fid
  FROM src s
  LEFT JOIN LATERAL (SELECT c.id, ST_Distance(c.geom::geography, s.geom::geography) AS d
                       FROM buildings c ORDER BY c.geom <-> s.geom LIMIT 1) n ON true
 WHERE s.dataset = 'breeam-certified-buildings';

-- -------------------------------------------------------------- shading

INSERT INTO building_shading (building_id, units, units_rated, shaded_mean, shaded_min,
                              shaded_max, data_as_of, source_dataset)
SELECT c.id, count(*), count(x.v),
       round(avg(x.v), 3), round(min(x.v), 3), round(max(x.v), 3),
       DATE '2020-07-01', min(s.dataset)
  FROM src s
  JOIN buildings c ON ST_Intersects(c.geom, s.geom)
 CROSS JOIN LATERAL (SELECT (s.p->>'shaded')::numeric AS v) x
 WHERE s.dataset = 'building-solar-irradiance'
 GROUP BY c.id;

COMMIT;

SELECT count(*) AS panel, count(sofiaplan_id) AS in_2019, count(building_id) AS with_outline
  FROM panel_buildings;
SELECT status, match, count(*), count(building_id) AS with_outline
  FROM renovations GROUP BY status, match ORDER BY status, match;
SELECT count(*) AS breeam, count(building_id) AS with_outline FROM breeam_buildings;
SELECT count(*) AS shaded_buildings, sum(units) AS units, round(avg(shaded_mean), 3) AS mean
  FROM building_shading;
SELECT issue, count(*) FROM building_extra_issues GROUP BY issue ORDER BY issue;
