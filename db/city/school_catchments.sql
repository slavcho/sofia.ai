-- Rebuild city.catchment_schools and city.catchment_addresses: the
-- city's assigned-school list placed on the official address points.
-- Needs education.sql and areas.sql to have run first.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/school_catchments.sql
--
-- Sources:
--   addresses-and-associated-schools  addresses-and-associated-schools.xlsx  the list, as of 2026-06-30
--   address_sofia-zip                 address_sofia.geojson                  the address points (2026)
--
-- The two share no key (the list's GRAO street code is not on the
-- points), so an address is found by district, town, street and number:
--   street            the street name and house number as given
--   block             an estate, quarter or locality (Ж.К., КВ., МЕСТН.) and
--                     block: the list puts the block in "Номер", the points
--                     in "block"; or its number when the point has no street
--                     (м. Радеви круши 119)
--   alternative_name  a street given with a second name, "ЕМИЛИЯН СТАНЕВ
--                     (490-ТА)" or "640-ТА ОВЧА КУПЕЛ", found by either
-- A street (УЛ., БУЛ., ПЛ.) is only looked for among streets and an area
-- only among areas: Ж.К.ГОЦЕ ДЕЛЧЕВ 113 is block 113, not бул. Гоце
-- Делчев 113. A name with no prefix may be either.
-- Nothing is guessed beyond that: an address not found stays unplaced.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
-- A numbered street: 490-ТА, 8-МА, 1-ВА, 2-РА.
\set ordinal '\\m\\d+-?(?:ТА|МА|ВА|РА|ТИ|МИ|ВИ|РИ)\\M'
\set months 'ЯНУАРИ|ФЕВРУАРИ|МАРТ|АПРИЛ|МАЙ|ЮНИ|ЮЛИ|АВГУСТ|СЕПТЕМВРИ|ОКТОМВРИ|НОЕМВРИ|ДЕКЕМВРИ'
BEGIN;

-- A name reduced to letters and digits, without the "ул."-type prefix.
CREATE FUNCTION pg_temp.name_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(upper(regexp_replace(
               regexp_replace(coalesce(t, ''), '^\s*(ж\.\s*к|ул|бул|кв|пл|м|в\.\s*з|местн|мах)\.\s*', '', 'i'),
               '[^[:alnum:]]', '', 'g')), '')
$$;
-- "008А" and "8а" are the same number.
CREATE FUNCTION pg_temp.num_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(upper(regexp_replace(btrim(coalesce(t, '')), '^0+', '')), '')
$$;

CREATE TEMP TABLE list ON COMMIT DROP AS
SELECT f.source_fid, f.properties AS p, d.name AS dataset
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name = 'addresses-and-associated-schools';

CREATE TEMP TABLE pts ON COMMIT DROP AS
SELECT f.source_fid,
       dist.code AS district_code,
       upper(regexp_replace(f.properties->>'settlement', '^(гр|с)\.\s*', '')) AS town,
       pg_temp.name_key(f.properties->>'street') AS street,
       pg_temp.name_key(f.properties->>'lareaunit') AS area,
       pg_temp.num_key(f.properties->>'streetnum') AS num,
       pg_temp.num_key(f.properties->>'block') AS block,
       upper(coalesce(f.properties->>'entrance', '')) AS entrance,
       f.geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
  LEFT JOIN districts dist ON dist.name = f.properties->>'region'
 WHERE d.name = 'address_sofia-zip'
   AND l.source_path LIKE '%.geojson';
CREATE INDEX ON pts (district_code, town, street, num);
CREATE INDEX ON pts (district_code, town, area, block);
ANALYZE pts;

-- Names of places rather than streets: districts, neighbourhoods,
-- estates and towns. "ЕДЕЛВАЙС (ОВЧА КУПЕЛ)" says where the street is;
-- the bracketed part is not another name for it.
CREATE TEMP TABLE place_names ON COMMIT DROP AS
SELECT pg_temp.name_key(name) AS k FROM districts
UNION SELECT pg_temp.name_key(name) FROM neighbourhoods
UNION SELECT area FROM pts
UNION SELECT pg_temp.name_key(town) FROM pts;

-- The list rows with their keys. The town drops the quarter after the
-- comma (ГР.СОФИЯ,КВ.ДРАГАЛЕВЦИ): the points have it as plain София.
CREATE TEMP TABLE rows ON COMMIT DROP AS
SELECT (l.p->>'OBJECTID')::integer AS id, l.source_fid, l.dataset, l.p,
       l.p->>'Код на район' AS district_code,
       upper(regexp_replace(l.p->>'Име на населено място', '^(ГР|С)\.|,.*$', '', 'g')) AS town,
       pg_temp.name_key(l.p->>'Наименование на пътна артерия') AS name,
       pg_temp.num_key(l.p->>'Номер') AS num,
       upper(coalesce(l.p->>'Вход', '')) AS entrance,
       CASE WHEN l.p->>'Наименование на пътна артерия' ~ '^\s*(УЛ|БУЛ|ПЛ)\.' THEN 'street'
            WHEN l.p->>'Наименование на пътна артерия' ~ '^\s*(Ж\.\s*К|КВ|М|МЕСТН|МЕСТНОСТ|МАХ|В\.\s*З|ПРОМ)[. ]' THEN 'area'
       END AS kind,
       -- The other names, tried in this order: the name without the
       -- brackets and "N-ТА", the bracketed part, and the street number N
       -- on its own. In "640-ТА ОВЧА КУПЕЛ" the words after the number name
       -- the area, not a street (there is a бул. Овча купел), so only the
       -- number is tried; the same for "ЕДЕЛВАЙС (ОВЧА КУПЕЛ)", whose
       -- bracketed part comes after the street name. The number alone is
       -- not tried for "301-ВА А", a street of its own (301А), nor for a
       -- date such as "23-ТИ ДЕКЕМВРИ".
       ARRAY(SELECT k FROM unnest(ARRAY[
                 CASE WHEN l.p->>'Наименование на пътна артерия' !~ ('^(УЛ\.)?\s*' || :'ordinal') THEN
                 pg_temp.name_key(regexp_replace(regexp_replace(l.p->>'Наименование на пътна артерия',
                                  '\(.*\)', '', 'g'), :'ordinal', '', 'g')) END,
                 CASE WHEN b.part ~ '\d'
                        OR (b.part !~* '^\s*(в\.\s*з|м|местн|кв|ж\.\s*к|мах|мал)\.'
                            AND pg_temp.name_key(b.part) NOT IN (SELECT k FROM place_names WHERE k IS NOT NULL)) THEN
                 pg_temp.name_key(regexp_replace(b.part, :'ordinal', '', 'g')) END,
                 CASE WHEN l.p->>'Наименование на пътна артерия' !~ (:'ordinal' || '\s+([А-Я]\M|' || :'months' || ')') THEN
                 substring(substring(l.p->>'Наименование на пътна артерия' from :'ordinal') from '\d+') END])
                 WITH ORDINALITY AS t(k, n)
              WHERE k IS NOT NULL
                AND k IS DISTINCT FROM pg_temp.name_key(l.p->>'Наименование на пътна артерия')
              ORDER BY n) AS alt_names
  FROM list l
  CROSS JOIN LATERAL (SELECT substring(l.p->>'Наименование на пътна артерия' from '\((.*)\)') AS part) b;

-- One point per row: the earliest match and name, then the same
-- entrance, then the building's own point (no entrance), then the
-- lowest id so that a rebuild picks the same.
CREATE TEMP TABLE found ON COMMIT DROP AS
SELECT DISTINCT ON (r.id) r.id, m.match, m.source_fid AS address_fid, m.geom
  FROM rows r
  CROSS JOIN LATERAL (
       SELECT 'street' AS match, 1 AS pass, 0 AS alt, p.* FROM pts p
        WHERE r.kind IS DISTINCT FROM 'area'
          AND p.district_code = r.district_code AND p.town = r.town AND p.street = r.name AND p.num = r.num
       UNION ALL
       SELECT 'block', 2, 0, p.* FROM pts p
        WHERE r.kind IS DISTINCT FROM 'street'
          AND p.district_code = r.district_code AND p.town = r.town AND p.area = r.name
          AND (p.block = r.num OR (p.street IS NULL AND p.block IS NULL AND p.num = r.num))
       UNION ALL
       SELECT 'alternative_name', 3, array_position(r.alt_names, p.street), p.* FROM pts p
        WHERE r.kind IS DISTINCT FROM 'area'
          AND p.district_code = r.district_code AND p.town = r.town AND p.street = ANY (r.alt_names) AND p.num = r.num
       UNION ALL
       SELECT 'alternative_name', 3, array_position(r.alt_names, p.area), p.* FROM pts p
        WHERE r.kind IS DISTINCT FROM 'street'
          AND p.district_code = r.district_code AND p.town = r.town AND p.area = ANY (r.alt_names)
          AND (p.block = r.num OR (p.street IS NULL AND p.block IS NULL AND p.num = r.num))) m
 ORDER BY r.id, m.pass, m.alt, m.entrance = r.entrance DESC, m.entrance = '' DESC, m.source_fid::integer;

DELETE FROM catchment_addresses;
DELETE FROM catchment_schools;

INSERT INTO catchment_schools (list_id, name, addresses, located, data_as_of, source_dataset)
SELECT (r.p->>'ИД на прилежащо училище')::integer, min(r.p->>'Прилежащо училище'),
       count(*), count(f.id), DATE '2026-06-30', min(r.dataset)
  FROM rows r LEFT JOIN found f ON f.id = r.id
 GROUP BY 1;

INSERT INTO catchment_addresses (id, list_school_id, border_list_ids, district_code, town, street,
                                 number, entrance, match, address_fid, geom,
                                 data_as_of, source_dataset, source_fid)
SELECT r.id, (r.p->>'ИД на прилежащо училище')::integer,
       coalesce(string_to_array(regexp_replace(r.p->>'ИД на гранични прилежащи училища', '\s', '', 'g'), ',')::integer[], '{}'),
       r.district_code, r.p->>'Име на населено място', r.p->>'Наименование на пътна артерия',
       r.p->>'Номер', r.p->>'Вход', f.match, f.address_fid, f.geom,
       DATE '2026-06-30', r.dataset, r.source_fid
  FROM rows r LEFT JOIN found f ON f.id = r.id;

-- The list school among our 2018 points, by the number its name starts
-- with: ours numbers are not reliable (78 СУ is stored as 7). Of several
-- with that number, the one of the same type (НУ primary, ОУ basic, СУ
-- secondary or profiled), then the one nearest the addresses it takes.
UPDATE catchment_schools c
   SET school_id = m.id, match = m.match
  FROM (SELECT c.list_id, s.id,
               CASE WHEN s.type_agrees THEN 'number_and_type' ELSE 'number' END AS match
          FROM catchment_schools c
          CROSS JOIN LATERAL (SELECT ST_Centroid(ST_Collect(a.geom)) AS geom
                                FROM catchment_addresses a WHERE a.list_school_id = c.list_id) ctr
          CROSS JOIN LATERAL (
               SELECT s.id,
                      CASE substring(c.name from '^\d+\.\s*(\S+)')
                           WHEN 'НУ' THEN s.kind = 'primary'
                           WHEN 'ОУ' THEN s.kind = 'basic' WHEN 'ОбУ' THEN s.kind = 'basic'
                           ELSE s.kind IN ('secondary', 'profiled') END AS type_agrees
                 FROM schools s
                WHERE substring(s.name from '^(\d+)') = substring(c.name from '^(\d+)')
                ORDER BY 2 DESC, ST_Distance(s.geom::geography, ctr.geom::geography) NULLS LAST
                LIMIT 1) s) m
 WHERE c.list_id = m.list_id;

COMMIT;

SELECT coalesce(match, 'not found') AS match, count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM catchment_addresses GROUP BY 1 ORDER BY 2 DESC;
SELECT coalesce(match, 'not found') AS school_match, count(*) FROM catchment_schools GROUP BY 1;
SELECT issue, count(*) FROM catchment_issues GROUP BY 1 ORDER BY 1;
