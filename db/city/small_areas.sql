-- Rebuild city.census_tracts, city.population_grid, city.polling_sections
-- and city.polling_areas_unplaced.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/small_areas.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql, buildings.sql and census.sql first.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, d.extras->>'Актуален към' AS as_of, f.source_fid, f.properties AS p, f.geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN ('nsi-census-tracts', 'izbori_april_2026', 'electoral_division-zip',
                  'population-in-the-sofia-agglomeration-area-from-the-2011-nsi-census-in-a-1x1-km-grid');

-- Residents and census people as points inside their building outline;
-- an address without an outline stays on the street.
CREATE TEMP TABLE homes ON COMMIT DROP AS
SELECT ST_PointOnSurface(b.geom) AS geom, b.people_2019 AS residents, 0 AS census,
       NULL::integer AS dwellings, NULL::integer AS age_0_14, NULL::integer AS age_65_plus, 0 AS addresses
  FROM buildings b WHERE b.people_2019 > 0
UNION ALL
SELECT coalesce(ST_PointOnSurface(b.geom), a.geom), 0, a.people, a.dwellings, a.age_0_14, a.age_65_plus, 1
  FROM census_addresses a LEFT JOIN buildings b ON b.id = a.building_id;
CREATE INDEX ON homes USING gist (geom);
ANALYZE homes;

-- ---------------------------------------------------------- census tracts

CREATE TEMP TABLE tracts ON COMMIT DROP AS
SELECT s.p->>'ecode_rayon' || '-' || (s.p->>'kontr_r') || '-' || (s.p->>'pr_u') AS id,
       ST_Multi(ST_MakeValid(s.geom)) AS geom, s.p, s.dataset, s.source_fid
  FROM src s WHERE s.dataset = 'nsi-census-tracts';
CREATE INDEX ON tracts USING gist (geom);
ANALYZE tracts;

-- The tracts are drawn tighter than the building outlines: a fifth of
-- the residents' points fall just outside, most within 25 m. A home
-- outside every tract goes to the nearest one within 50 m.
CREATE TEMP TABLE home_tract ON COMMIT DROP AS
SELECT h.*, coalesce(
         (SELECT t.id FROM tracts t WHERE ST_Intersects(t.geom, h.geom) LIMIT 1),
         (SELECT t.id FROM tracts t
           WHERE t.geom && ST_Expand(h.geom, 0.001)
             AND ST_DWithin(t.geom::geography, h.geom::geography, 50)
           ORDER BY t.geom <-> h.geom LIMIT 1)) AS tract_id
  FROM homes h;

DELETE FROM census_tracts;
INSERT INTO census_tracts (id, district_code, ekatte, control_area, tract, geom, area_km2,
                           census_addresses, census_people, dwellings, age_0_14, age_65_plus,
                           residents_2019, data_as_of, source_dataset, source_fid)
SELECT t.id, t.p->>'ecode_rayon', t.p->>'ekatte', t.p->>'kontr_r', t.p->>'pr_u',
       t.geom, round((ST_Area(t.geom::geography) / 1e6)::numeric, 4),
       coalesce(h.addresses, 0), h.census, h.dwellings, h.age_0_14, h.age_65_plus, h.residents,
       '2017-01-01', t.dataset, t.source_fid
  FROM tracts t
  LEFT JOIN (SELECT tract_id, sum(addresses)::integer AS addresses, sum(census)::integer AS census,
                    sum(dwellings)::integer AS dwellings, sum(age_0_14)::integer AS age_0_14,
                    sum(age_65_plus)::integer AS age_65_plus, sum(residents)::integer AS residents
               FROM home_tract GROUP BY tract_id) h ON h.tract_id = t.id;

-- ---------------------------------------------------------- 1 km grid

DELETE FROM population_grid;
INSERT INTO population_grid (id, people, male, female, age_0_14, age_15_64, age_65_plus, method,
                             in_sofia, census_address_people, residents_2019, geom,
                             data_as_of, source_dataset, source_fid)
SELECT s.p->>'grd_id', (s.p->>'tot_p')::integer, (s.p->>'tot_m')::integer, (s.p->>'tot_f')::integer,
       (s.p->>'t_00_14')::integer, (s.p->>'t_15_64')::integer, (s.p->>'t_65_')::integer,
       s.p->>'methd_cl',
       EXISTS (SELECT 1 FROM districts d WHERE ST_Intersects(d.geom, ST_Centroid(s.geom))),
       h.census, h.residents, ST_Multi(s.geom), '2011-02-01', s.dataset, s.source_fid
  FROM src s
  LEFT JOIN LATERAL (
        SELECT sum(x.census)::integer AS census, sum(x.residents)::integer AS residents
          FROM homes x WHERE ST_Intersects(s.geom, x.geom)) h ON true
 WHERE s.dataset = 'population-in-the-sofia-agglomeration-area-from-the-2011-nsi-census-in-a-1x1-km-grid';

-- ---------------------------------------------------------- polling sections

-- The places come as UTM 35N coordinates in a spreadsheet. "Адрес" is
-- mostly "<building>, гр.София, <street>", but some start with the
-- settlement and have no building; the date is an Excel day number.
CREATE TEMP TABLE places ON COMMIT DROP AS
SELECT x.id,
       CASE WHEN x.first !~ '^(гр|с)\.' THEN x.first END AS place,
       CASE WHEN x.first ~ '^(гр|с)\.' THEN x.full
            ELSE nullif(btrim(substr(x.full, length(x.first) + 2)), '') END AS address,
       x.geom, x.data_as_of, x.dataset, x.source_fid
  FROM (
SELECT s.p->>'Номер на секция' AS id,
       btrim(regexp_replace(s.p->>'Адрес', '\s+', ' ', 'g')) AS full,
       btrim(split_part(regexp_replace(s.p->>'Адрес', '\s+', ' ', 'g'), ',', 1)) AS first,
       ST_Transform(ST_SetSRID(ST_MakePoint((s.p->>'x')::float8, (s.p->>'y')::float8), 32635), 4326) AS geom,
       date '1899-12-30' + (s.p->>'Дата на избори')::integer AS data_as_of,
       s.dataset, s.source_fid
  FROM src s WHERE s.dataset = 'izbori_april_2026') x;

-- A section's area is in several pieces, keyed by district name and
-- the number within the district.
CREATE TEMP TABLE section_areas ON COMMIT DROP AS
SELECT d.code AS district_code, (s.p->>'polling_station_number')::integer AS number,
       min(s.p->>'polling_place') AS place,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(s.geom)), 3)) AS geom,
       to_date(substring(min(s.as_of) FROM '\d{2}\.\d{2}\.\d{4}'), 'DD.MM.YYYY') AS as_of
  FROM src s JOIN districts d ON d.name = s.p->>'region'
 WHERE s.dataset = 'electoral_division-zip'
 GROUP BY 1, 2;
CREATE INDEX ON section_areas (district_code, number);

DELETE FROM polling_sections;
INSERT INTO polling_sections (id, district_code, number, place, address, geom, place_district_code,
                              area, residents_2019, mean_distance_m, max_distance_m,
                              data_as_of, area_as_of, source_dataset, source_fid)
SELECT p.id, substr(p.id, 5, 2), substr(p.id, 7, 3)::integer, p.place, p.address, p.geom,
       (SELECT d.code FROM districts d WHERE ST_Contains(d.geom, p.geom) LIMIT 1),
       a.geom, h.residents, h.mean_m, h.max_m,
       p.data_as_of, a.as_of, p.dataset, p.source_fid
  FROM places p
  LEFT JOIN section_areas a ON a.district_code = substr(p.id, 5, 2) AND a.number = substr(p.id, 7, 3)::integer
  LEFT JOIN LATERAL (
        SELECT sum(x.residents)::integer AS residents,
               round(sum(x.residents * ST_Distance(x.geom::geography, p.geom::geography))
                     / nullif(sum(x.residents), 0)) AS mean_m,
               round(max(ST_Distance(x.geom::geography, p.geom::geography))) AS max_m
          FROM homes x WHERE x.residents > 0 AND ST_Intersects(a.geom, x.geom)) h ON true;

DELETE FROM polling_areas_unplaced;
INSERT INTO polling_areas_unplaced (district_code, number, place, geom)
SELECT a.district_code, a.number, a.place, a.geom
  FROM section_areas a
 WHERE NOT EXISTS (SELECT 1 FROM polling_sections s
                    WHERE s.district_code = a.district_code AND s.number = a.number);

ANALYZE census_tracts;
ANALYZE population_grid;
ANALYZE polling_sections;

COMMIT;

SELECT count(*) AS tracts, sum(census_people) AS census_people, sum(residents_2019) AS residents_2019,
       count(*) FILTER (WHERE census_addresses = 0) AS without_addresses
  FROM census_tracts;
SELECT count(*) AS cells, sum(people) AS people, count(*) FILTER (WHERE in_sofia) AS in_sofia,
       sum(people) FILTER (WHERE in_sofia) AS people_in_sofia,
       sum(census_address_people) AS address_people, sum(residents_2019) AS residents_2019
  FROM population_grid;
SELECT count(*) AS sections, count(area) AS with_area, sum(residents_2019) AS residents_2019,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY mean_distance_m) AS median_mean_distance_m,
       (SELECT count(*) FROM polling_areas_unplaced) AS areas_unplaced
  FROM polling_sections;
SELECT issue, count(*) FROM small_area_issues GROUP BY issue ORDER BY issue;
