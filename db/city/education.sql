-- Rebuild city.kindergartens and city.schools from the raw portal data.
-- Needs areas.sql to have run first (districts).
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/education.sql
-- One transaction: either everything is rebuilt, or nothing changes.
--
-- Sources (all Sofiaplan, 2018-08-08):
--   kindergarten-locations-point             dg_points_26_sofpr_20180808             all kindergartens and nurseries
--   municipal-kindergarten-locations-points  dg_points_obshtinski_26_sofpr_20180808  only for osn_fil (main/branch)
--   registration-maps-kindergartens          dg_reg_karti_26_sofpr_20180808          municipal registrations
--   registration-maps-groups-kindergartens   dg_reg_karti_grupi_26_sofpr_20180808    their groups and children
--   school-locations-points                  uchilishta_points_26_sofpr_20180808     schools
--
-- The kindergarten "type" does not follow its own code list
-- (dg_kod_type: 1 ДГ, 2 ДГЯ, 3 ЧДГ, 4 ЧДГЯ, 5 ДЯ): municipal ДГ are 1 or 4,
-- nurseries 2, private ones 1. So the kind is read from the name. The
-- school "type" does follow its list (uchilishta_kod_type).

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset,
       regexp_replace(l.source_path, '^.*__', '') AS file,
       f.source_fid, f.properties AS p,
       ST_GeometryN(f.geom, 1) AS geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('kindergarten-locations-point', 'municipal-kindergarten-locations-points',
                  'registration-maps-kindergartens', 'registration-maps-groups-kindergartens',
                  'school-locations-points');

DELETE FROM kindergartens;
DELETE FROM schools;

-- ----------------------------------------------------- kindergartens

INSERT INTO kindergartens (id, name, number, kind, type_code, funding, funding_code, is_branch,
                           status, note, address, district_code, details_url,
                           geom, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       btrim(regexp_replace(s.p->>'object_nam', '\s+', ' ', 'g')),
       (s.p->>'object_nom')::numeric::integer,
       k.kind,
       s.p->>'type',
       CASE WHEN s.p->>'finansiran' IN ('1', 'Държавно') THEN 'state'
            WHEN s.p->>'finansiran' = '2' THEN 'municipal'
            WHEN s.p->>'finansiran' = '3' THEN 'private' END,
       s.p->>'finansiran',
       s.p->>'object_nam' ~* 'филиал' OR coalesce(m.osn_fil = '2', false),
       -- chek 2 marks the ones the authors could not confirm; their note says why.
       CASE WHEN s.p->>'status' ~* 'закрит' THEN 'closed'
            WHEN s.p->>'chek' = '2' AND k.kind <> 'other' THEN 'doubtful'
            ELSE 'open' END,
       nullif(btrim(s.p->>'zabelezhka'), ''),
       nullif(btrim(s.p->>'adres'), ''),
       s.p->>'kod_rayon',
       s.p->>'detaili',
       s.geom, DATE '2018-08-08', s.dataset, s.source_fid
  FROM src s
  CROSS JOIN LATERAL (
       SELECT CASE WHEN s.p->>'object_nam' ~* '(център|ДДЛРГ)' THEN 'other'
                   WHEN s.p->>'object_nam' ~ '(^|[^[:alpha:]])[ЧС]?ДЯ([^[:alpha:]]|$)' THEN 'nursery'
                   ELSE 'kindergarten' END AS kind) k
  -- The municipal layer is the same points (269 of 276 by name within
  -- 5 m) with osn_fil added: 1 main site, 2 branch.
  LEFT JOIN LATERAL (
       SELECT o.p->>'osn_fil' AS osn_fil
         FROM src o
        WHERE o.file = 'dg_points_obshtinski_26_sofpr_20180808.geojson'
          AND o.p->>'object_nam' = s.p->>'object_nam'
          AND ST_DWithin(o.geom::geography, s.geom::geography, 5)
        LIMIT 1) m ON true
 WHERE s.file = 'dg_points_26_sofpr_20180808.geojson';

-- Each registration map goes to the main site with its number nearest
-- to it (192 of 194 are the nearest point of all anyway). The number is
-- also looked for in the name: ДГ №76 has object_nom 78.
WITH reg AS (
    SELECT (r.p->>'id')::integer AS id,
           (SELECT k.id FROM kindergartens k
             WHERE k.number = (r.p->>'nomer')::integer
                OR k.name ~ ('№ ?' || (r.p->>'nomer')::integer || '([^0-9]|$)')
             ORDER BY k.is_branch, ST_Distance(k.geom::geography, r.geom::geography)
             LIMIT 1) AS kindergarten_id
      FROM src r
     WHERE r.file = 'dg_reg_karti_26_sofpr_20180808.geojson'
), grp AS (
    SELECT (g.p->>'id_dg_reg_karta')::integer AS reg_id,
           sum((g.p->>'broi')::integer) AS groups,
           sum((g.p->>'broi_deca')::integer) AS children,
           sum((g.p->>'broi_deca')::integer) FILTER (WHERE g.p->>'tip' = 'Яслена група') AS nursery_children
      FROM src g
     WHERE g.file = 'dg_reg_karti_grupi_26_sofpr_20180808.json'
     GROUP BY 1
)
UPDATE kindergartens k
   SET registration_id = reg.id, groups = grp.groups, children = grp.children,
       nursery_children = CASE WHEN grp.reg_id IS NOT NULL THEN coalesce(grp.nursery_children, 0) END
  FROM reg LEFT JOIN grp ON grp.reg_id = reg.id
 WHERE k.id = reg.kindergarten_id;

-- ----------------------------------------------------------- schools

INSERT INTO schools (id, name, number, admin_code, kind, funding, funding_code, class_count,
                     note, address, district_code, details_url,
                     geom, data_as_of, source_dataset, source_fid)
SELECT (s.p->>'id')::integer,
       btrim(regexp_replace(s.p->>'object_nam', '\s+', ' ', 'g')),
       -- object_nom is wrong for two schools (7 for "78 СОУ", 120 for
       -- "129 ОУ") and missing for two evening schools, so the number
       -- the name starts with comes first.
       coalesce(substring(btrim(s.p->>'object_nam') FROM '^(\d+) ')::integer,
                (s.p->>'object_nom')::numeric::integer),
       nullif((s.p->>'kodadmin')::integer, 0),
       CASE s.p->>'type' WHEN '1' THEN 'primary' WHEN '2' THEN 'basic' WHEN '3' THEN 'secondary'
                         WHEN '4' THEN 'profiled' WHEN '5' THEN 'vocational' WHEN '6' THEN 'special' END,
       CASE s.p->>'finansiran' WHEN '1' THEN 'state' WHEN '2' THEN 'municipal' WHEN '3' THEN 'private' END,
       s.p->>'finansiran',
       (s.p->>'br_paralel')::integer,
       nullif(btrim(s.p->>'zabelezhka'), ''),
       nullif(btrim(s.p->>'adres'), ''),
       s.p->>'kod_rayon',
       s.p->>'detaili',
       s.geom, DATE '2018-08-08', s.dataset, s.source_fid
  FROM src s
 WHERE s.file = 'uchilishta_points_26_sofpr_20180808.geojson';

COMMIT;

SELECT kind, funding, status, count(*), count(*) FILTER (WHERE is_branch) AS branches,
       count(registration_id) AS registered, sum(children) AS children
  FROM kindergartens GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
SELECT kind, funding, count(*), sum(class_count) AS classes FROM schools GROUP BY 1, 2 ORDER BY 1, 2;
SELECT issue, count(*) FROM education_issues GROUP BY 1 ORDER BY 1;
