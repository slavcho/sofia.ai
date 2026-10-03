-- Rebuild city.indicators and city.planning_unit_indicators: Sofiaplan's
-- analyses by planning unit, in one long table.
--
--     psql -v ON_ERROR_STOP=1 -d urbandata -f db/city/indicators.sql
-- One transaction: either everything is rebuilt, or nothing changes.
-- Needs areas.sql first.
--
-- The files do not share the planning units' id: their object_id is a
-- running number of each file. A source unit is ours
--   'id'     by ge_id, where the file has it (prices, floor areas);
--   'name'   by the same name, if the two shapes mostly overlap;
--   'shape'  else by a shape that is nearly the same (90 %).
-- The 2019 files (574 and 583 units) use an older division: units that
-- were redrawn since are left out and counted in indicators.unmatched.
--
-- Not loaded:
--   accessibility-to-employment-by-public-transport-urban-planning-units
--       join_count (0-8) and kgr (0-1.17) are not explained anywhere.
--   number-of-schools-relative-to-residential-area-by-urban-planning-units
--       broj_uch_s is mostly empty and otnosh is often twice rzp_all.
--   morphology-by-urban-planning-units
--       an older division of 253 units; its census figures are in
--       census_addresses, its buildings in buildings.
--   demographic-projection-by-kopralev-for-urban-planning-units
--       the same forecast on the older division; the adjusted one is used.

\set ON_ERROR_STOP on
SET search_path = city, urban, public;
BEGIN;

-- indicator, label, unit, theme, dataset, column, breakdown, data as of,
-- description. A column of '' is filled by its own INSERT below.
CREATE TEMP TABLE defs (indicator text, label text, unit text, theme text, dataset text,
                        field text, breakdown text, as_of date, description text) ON COMMIT DROP;
INSERT INTO defs VALUES
  ('sealed_soil_pct', 'Sealed soil', '%', 'Environment',
   'average-percentage-of-sealed-soil-in-urban-planning-units', 'zapech_perc', '', '2021-01-01',
   'Share of the unit''s land covered by buildings, roads and other sealed surfaces.'),
  ('residential_shaded_mean', 'Shading of residential buildings', 'share', 'Environment',
   'average-sunlight-shading-levels-of-residential-buildings', 'shaded_mean', '', '2021-02-01',
   'Mean "shaded" of the homes in the unit, 0-1, from Sofiaplan''s sunlight model; the period is not given.'),
  ('planned_green_pct', 'Land planned for the green system', '%', 'Master plan',
   'share-of-land-planned-in-the-master-plan-for-green-system-facilities-for-public-use', 'perc_shop', '', '2021-01-01',
   'Share of the unit in green system zones of the 2009 master plan.'),
  ('planned_public_green_pct', 'Land planned for public green space', '%', 'Master plan',
   'share-of-land-planned-in-the-master-plan-for-green-system-facilities-for-public-use', 'perc_shop_publ', '', '2021-01-01',
   'Share of the unit in green system zones of the 2009 master plan meant for public use.'),
  ('master_plan_zone', 'Predominant master plan zone', 'zone', 'Master plan',
   'predominant-functional-zoning-from-the-2009-master-plan-by-urban-planning-units', 'oup_tipologiya', '', '2020-01-01',
   'The zone of the 2009 master plan covering most of the unit (its code, e.g. Жм, Смф, Зс).'),
  ('development_potential', 'Development potential under the master plan', 'class', 'Master plan',
   'development-potential-by-spatial-planning-zones-in-the-2009-master-plan-by-urban-planning-units', 'zastr_potenc_txt', '', '2020-01-01',
   'Whether the master plan zones allow more building than there is.'),
  ('sewer_connected_pct', 'Connected to the sewer network', '%', 'Infrastructure',
   'degree-of-sewer-network-development-by-urban-planning-units', 'conect_san', '', '2021-01-01',
   'Degree to which the unit is served by the sewer network; a few units are above 100.'),
  ('education_facilities', 'Education facilities', 'count', 'Services',
   'concentration-of-educational-infrastructure-by-urban-planning-units', 'numpoints', '', '2021-01-01',
   'Number of education facilities in the unit; the file has only the 264 units with any.'),
  ('healthcare_facilities', 'Healthcare facilities', 'count', 'Services',
   'concentration-of-healthcare-infrastructure-by-urban-planning-units', 'numpoints', '', '2021-01-01',
   'Number of healthcare facilities (hospitals, clinics, practices) in the unit.'),
  ('health_service_facilities', 'Health-related service facilities', 'count', 'Services',
   'concentration-of-health-related-service-facilities-by-urban-planning-units', 'numpoints', '', '2021-01-01',
   'Number of health-related services (pharmacies, laboratories and the like) in the unit.'),
  ('social_services', 'Social services', 'count', 'Services',
   'social-services-concentration-urban-planning-units', 'broi_soc_uslugi', '', NULL,
   'Number of social services in the unit.'),
  ('dkc_unserved_pct', 'Residents without walking access to a DKC', '%', 'Services',
   'population-access-to-diagnostic-and-consultation-centers-by-urban-planning-units', 'percent_unserv', '', '2021-01-01',
   'Share of residents (GRAO, early 2021) with no diagnostic and consultation centre (поликлиника) within walking distance; an older division of 297 units, matched by shape only.'),
  ('school_unserved_pct', 'Residents without walking access to a school', '%', 'Services',
   'pedestrian-access-to-schools-and-municipal-kindergartens-share-of-unserved-population', 'uch_perc', '', NULL,
   'Share of residents with no school within walking distance (Sofiaplan); only the 228 units with residents.'),
  ('kindergarten_unserved_pct', 'Residents without walking access to a municipal kindergarten', '%', 'Services',
   'pedestrian-access-to-schools-and-municipal-kindergartens-share-of-unserved-population', 'dg_perc', '', NULL,
   'Share of residents with no municipal kindergarten within walking distance (Sofiaplan).'),
  ('function_kinds', 'Kinds of functions', 'count', 'Land use',
   'mono-and-polyfunctionality-by-functional-groups-in-urban-planning-units', 'distinct_p', '', '2019-07-19',
   'Number of different groups of functions among the points of interest in the unit.'),
  ('poi_density', 'Density of points of interest', 'per area', 'Land use',
   'mono-and-polyfunctionality-by-functional-groups-in-urban-planning-units', 'poi_per_ar', '', '2019-07-19',
   'Points of interest per unit of area; the area unit is not given.'),
  ('gfa_m2', 'Gross floor area by function', 'm²', 'Land use',
   'plot-area-and-gross-floor-area-by-urban-planning-units-based-on-the-cadastral-map', 'rzp', 'funktyp_gen_txt', '2020-07-01',
   'Gross floor area of the buildings in the unit by their function, from the cadastral map.'),
  ('residential_permits_since_2010', 'Residential building permits since 2010', 'count', 'Housing',
   'number-of-building-permits-issued-after-2010-by-urban-planning-units', 'jil_2010', '', '2020-11-19',
   'Building permits for housing issued from 2010 to the end of 2020.'),
  ('renovation_programme_gfa_m2', 'Floor area in the energy renovation programme', 'm²', 'Housing',
   'gfa-of-energy-renovated-residential-buildings-by-urban-planning-units', 'obshto_rzp', '', '2021-01-31',
   'Gross floor area of the residential buildings that joined the national energy renovation programme (obshto_rzp); not all housing.'),
  ('renovated_gfa_m2', 'Energy-renovated residential floor area', 'm²', 'Housing',
   'gfa-of-energy-renovated-residential-buildings-by-urban-planning-units', 'rzp_sanirani', '', '2021-01-31',
   'Of that floor area, the part already renovated.'),
  ('renovated_gfa_share', 'Share of the programme''s floor area renovated', 'share', 'Housing',
   'gfa-of-energy-renovated-residential-buildings-by-urban-planning-units', '', '', '2021-01-31',
   'renovated_gfa_m2 / renovation_programme_gfa_m2, where the unit has any.'),
  ('potential_residents', 'Residents the planned floor area could house', 'people', 'Housing',
   'potential-additional-population-by-urban-planning-units', '', '', '2021-02-11',
   'Residents at 30, 35 or 40 m² of floor area each (the breakdown), in the residential floor area the zones allow, less 20 %.'),
  ('solid_fuel_households', 'Households heating with solid fuel', 'households', 'Energy',
   'households-using-solid-fuels-for-heating', 'nj17_eq_4i_sum', '', '2011-02-01',
   'Households heating with wood or coal at the 2011 census.'),
  ('heritage_sites', 'Immovable cultural heritage sites', 'count', 'Heritage',
   'number-of-immovable-cultural-heritage-sites-by-urban-planning-units', 'nkc_sum', '', '2020-01-01',
   'Number of immovable cultural heritage sites in the unit.'),
  ('apartment_price_m2', 'Apartment price per m²', 'per m²', 'Housing',
   'property-rental-and-purchase-prices-by-urban-planning-units', 'cena_ap_kv_m', 'godina', '2020-07-05',
   'Mean asking price of apartments per m², by year (2002-2020); the currency is not given.'),
  ('apartment_rent_m2', 'Apartment rent per m²', 'per m² a month', 'Housing',
   'property-rental-and-purchase-prices-by-urban-planning-units', 'naem_ap_kv_m', 'godina', '2020-07-05',
   'Mean asking rent of apartments per m², by year; the currency is not given.'),
  ('office_price_m2', 'Office price per m²', 'per m²', 'Housing',
   'property-rental-and-purchase-prices-by-urban-planning-units', 'cena_ofis_kv_m', 'godina', '2020-07-05',
   'Mean asking price of offices per m², by year.'),
  ('office_rent_m2', 'Office rent per m²', 'per m² a month', 'Housing',
   'property-rental-and-purchase-prices-by-urban-planning-units', 'naem_ofis_kv_m', 'godina', '2020-07-05',
   'Mean asking rent of offices per m², by year.'),
  ('shop_rent_m2', 'Shop rent per m²', 'per m² a month', 'Housing',
   'property-rental-and-purchase-prices-by-urban-planning-units', 'naem_mag_kv_m', 'godina', '2020-07-05',
   'Mean asking rent of shops per m², by year.'),
  ('population_2017', 'Residents in 2017 (forecast base)', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', 'n2017_sum', '', '2017-01-01',
   'Residents at the start of Kopralev''s forecast.'),
  ('population_forecast_low', 'Forecast residents, pessimistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s forecast (2018) by year, pessimistic scenario (pp).'),
  ('population_forecast', 'Forecast residents, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s forecast (2018) by year, realistic scenario (pr).'),
  ('population_forecast_high', 'Forecast residents, optimistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s forecast (2018) by year, optimistic scenario (po).'),
  ('forecast_age_0_2', 'Forecast children aged 0-2, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s realistic forecast by year.'),
  ('forecast_age_3_6', 'Forecast children aged 3-6, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s realistic forecast by year.'),
  ('forecast_age_7_14', 'Forecast children aged 7-14, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s realistic forecast by year.'),
  ('forecast_age_15_18', 'Forecast youth aged 15-18, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s realistic forecast by year.'),
  ('forecast_age_65_plus', 'Forecast residents aged 65+, realistic', 'people', 'Population',
   'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units', '', '', NULL,
   'Kopralev''s realistic forecast by year.'),
  ('energy_population', 'Residents in the energy scenarios', 'people', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: the residents each scenario assumes (nasel). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_heat_demand_mwh', 'Heat demand: heating and hot water', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heating plus hot water (s_mwth). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_space_heating_mwh', 'Heat demand: space heating', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: space heating (sotopl). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_hot_water_mwh', 'Heat demand: hot water', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: domestic hot water (s_bgv). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_district_heating_mwh', 'Heat from district heating', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat supplied by district heating (stec). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_gas_mwh', 'Heat from natural gas', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from natural gas (gaz). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_electric_heating_mwh', 'Heat from electric heating', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from electric heaters (elotop). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_pellets_mwh', 'Heat from pellets', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from pellets (pelet). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_coal_mwh', 'Heat from coal', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from coal (vugl). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_air_heat_pumps_mwh', 'Heat from air heat pumps', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from air-source heat pumps (airtp). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_spest_mwh', 'Heat: "spest" (not explained)', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: a heat source the file calls spest, not explained; it grows like the heat pumps, possibly ground-source ones. The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_solar_thermal_mwh', 'Heat from solar collectors', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: heat from solar thermal collectors (solart). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_solar_pv_mwh', 'Electricity from rooftop solar', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: electricity from photovoltaics (photov). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".'),
  ('energy_electricity_lighting_mwh', 'Electricity for lighting and appliances', 'MWh', 'Energy',
   'energy-development-scenarios-by-urban-planning-units', '', '', '2020-08-11',
   'Sofiaplan''s energy scenarios (2020), per year: electricity for lighting and appliances (elosv; the meaning is inferred from the name). The breakdown is 2017, or the year of the realistic scenario, or the year and "optimistic" or "pessimistic".');

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT d.name AS dataset, f.source_fid, f.properties AS p, f.geom
  FROM urban.features f
  JOIN urban.layers l ON l.id = f.layer_id
  JOIN urban.resources r ON r.id = l.resource_id
  JOIN urban.datasets d ON d.id = r.dataset_id
 WHERE d.name IN (SELECT dataset FROM defs)
   AND l.source_path NOT LIKE '%Ослънчаване%';
CREATE INDEX ON src USING gist (geom);
ANALYZE src;

-- Each source unit's planning unit. Overlap is measured against the
-- larger of the two, so that a unit split in two matches neither half.
CREATE TEMP TABLE unit_match ON COMMIT DROP AS
SELECT s.dataset, s.source_fid,
       coalesce(i.id, n.id, g.id) AS planning_unit_id,
       CASE WHEN i.id IS NOT NULL THEN 'id' WHEN n.id IS NOT NULL THEN 'name'
            WHEN g.id IS NOT NULL THEN 'shape' END AS match
  FROM src s
  LEFT JOIN planning_units i ON i.id::text = s.p->>'ge_id'
  LEFT JOIN planning_units n ON i.id IS NULL AND n.name = btrim(s.p->>'regname')
        AND ST_Area(ST_Intersection(n.geom, s.geom)) >= 0.5 * greatest(ST_Area(n.geom), ST_Area(s.geom))
  LEFT JOIN LATERAL (
        SELECT u.id FROM planning_units u
         WHERE i.id IS NULL AND n.id IS NULL AND u.geom && s.geom
           AND ST_Area(ST_Intersection(u.geom, s.geom)) >= 0.9 * greatest(ST_Area(u.geom), ST_Area(s.geom))
         LIMIT 1) g ON true;

DELETE FROM indicators;

INSERT INTO indicators (id, label, unit, theme, description, data_as_of, source_dataset,
                        source_units, unmatched)
SELECT d.indicator, d.label, d.unit, d.theme, d.description, d.as_of, d.dataset,
       (SELECT count(DISTINCT m.source_fid) FROM unit_match m WHERE m.dataset = d.dataset),
       (SELECT count(DISTINCT m.source_fid) FROM unit_match m
         WHERE m.dataset = d.dataset AND m.planning_unit_id IS NULL)
  FROM defs d;

-- Values that are a column as it is. Several source rows on one unit
-- and breakdown (a few prices are given twice for a year) are averaged.
INSERT INTO planning_unit_indicators (planning_unit_id, indicator, breakdown, value, value_text,
                                      match, source_fid)
SELECT m.planning_unit_id, d.indicator,
       coalesce(btrim(s.p->>d.breakdown), ''),
       avg(CASE WHEN jsonb_typeof(s.p->d.field) = 'number' THEN (s.p->>d.field)::numeric END),
       min(CASE WHEN jsonb_typeof(s.p->d.field) = 'string' THEN nullif(btrim(s.p->>d.field), '') END),
       min(m.match), min(s.source_fid)
  FROM defs d
  JOIN src s ON s.dataset = d.dataset
  JOIN unit_match m ON m.dataset = s.dataset AND m.source_fid = s.source_fid
 WHERE d.field <> '' AND m.planning_unit_id IS NOT NULL
   AND (d.breakdown = '' OR btrim(s.p->>d.breakdown) <> '')
 GROUP BY 1, 2, 3
HAVING count(s.p->>d.field) FILTER (WHERE s.p->>d.field IS NOT NULL) > 0;

-- The development potential's class code goes with its text.
UPDATE planning_unit_indicators v
   SET value = (s.p->>'zastr_potencial')::numeric
  FROM src s
 WHERE v.indicator = 'development_potential' AND s.source_fid = v.source_fid
   AND s.dataset = 'development-potential-by-spatial-planning-zones-in-the-2009-master-plan-by-urban-planning-units';

INSERT INTO planning_unit_indicators (planning_unit_id, indicator, breakdown, value, match, source_fid)
SELECT r.planning_unit_id, 'renovated_gfa_share', '',
       round(r.value / t.value, 4), r.match, r.source_fid
  FROM planning_unit_indicators r
  JOIN planning_unit_indicators t
    ON t.planning_unit_id = r.planning_unit_id AND t.indicator = 'renovation_programme_gfa_m2'
 WHERE r.indicator = 'renovated_gfa_m2' AND t.value > 0;

INSERT INTO planning_unit_indicators (planning_unit_id, indicator, breakdown, value, match, source_fid)
SELECT m.planning_unit_id, 'potential_residents', x.norm || ' m²', (s.p->>x.field)::numeric,
       m.match, s.source_fid
  FROM src s
  JOIN unit_match m ON m.dataset = s.dataset AND m.source_fid = s.source_fid
 CROSS JOIN (VALUES ('30', 'ppl_30kvm_sum'), ('35', 'ppl_35kvm_sum'), ('40', 'ppl_40kvm_sum')) x(norm, field)
 WHERE s.dataset = 'potential-additional-population-by-urban-planning-units'
   AND m.planning_unit_id IS NOT NULL AND s.p->>x.field IS NOT NULL;

-- The forecast's columns are <scenario><age group>_<decade, cut to 3
-- digits> (pr0714_203 is the realistic 7-14 in 2030) and <scenario><year>
-- for the totals. po, pp and pr are taken as optimistic, pessimistic and
-- realistic: in every year pp < pr < po.
INSERT INTO planning_unit_indicators (planning_unit_id, indicator, breakdown, value, match, source_fid)
SELECT m.planning_unit_id, x.indicator, y.year::text,
       (s.p->>(x.prefix || CASE WHEN x.age = '' THEN y.year::text || '_sum'
                                ELSE x.age || '_' || left(y.year::text, 3) || '_sum' END))::numeric,
       m.match, s.source_fid
  FROM src s
  JOIN unit_match m ON m.dataset = s.dataset AND m.source_fid = s.source_fid
 CROSS JOIN (VALUES ('population_forecast_low', 'pp', ''), ('population_forecast', 'pr', ''),
                    ('population_forecast_high', 'po', ''),
                    ('forecast_age_0_2', 'pr', '0002'), ('forecast_age_3_6', 'pr', '0306'),
                    ('forecast_age_7_14', 'pr', '0714'), ('forecast_age_15_18', 'pr', '1518'),
                    ('forecast_age_65_plus', 'pr', '6500')) x(indicator, prefix, age)
 CROSS JOIN (VALUES (2020), (2030), (2040), (2050)) y(year)
 WHERE s.dataset = 'demographic-forecast-by-kopralev-adjusted-to-the-new-urban-planning-units'
   AND m.planning_unit_id IS NOT NULL;

-- The energy scenarios: <field><2017 suffix> for 2017, and for each
-- decade <field>_<yy>_<s>, <field>_<yy><s> or <field><yy><s>, where s is
-- r, o or p. Realistic goes under the bare year, as the forecast's does;
-- only some fields have the other two scenarios. The units are not given:
-- MWh a year, going by s_mwth and the size of the numbers.
INSERT INTO planning_unit_indicators (planning_unit_id, indicator, breakdown, value, match, source_fid)
SELECT m.planning_unit_id, x.indicator, b.breakdown, b.value, m.match, s.source_fid
  FROM src s
  JOIN unit_match m ON m.dataset = s.dataset AND m.source_fid = s.source_fid
 CROSS JOIN (VALUES ('energy_population', 'nasel', 'nasel_17'),
                    ('energy_heat_demand_mwh', 's_mwth', 's_mwth1517'),
                    ('energy_space_heating_mwh', 'sotopl', 'sotopl1517'),
                    ('energy_hot_water_mwh', 's_bgv', 's_bgv15_17'),
                    ('energy_district_heating_mwh', 'stec', 'stec_17'),
                    ('energy_gas_mwh', 'gaz', 'gaz_17'),
                    ('energy_electric_heating_mwh', 'elotop', 'elotop_17'),
                    ('energy_pellets_mwh', 'pelet', 'pelet_17'),
                    ('energy_coal_mwh', 'vugl', 'vugl_15_17'),
                    ('energy_air_heat_pumps_mwh', 'airtp', 'airtp_17'),
                    ('energy_spest_mwh', 'spest', 'spest_17'),
                    ('energy_solar_thermal_mwh', 'solart', 'solart_17'),
                    ('energy_solar_pv_mwh', 'photov', 'photov_17'),
                    ('energy_electricity_lighting_mwh', 'elosv', 'elosv_17')) x(indicator, prefix, base)
 CROSS JOIN LATERAL (
       SELECT '2017' AS breakdown, (s.p->>x.base)::numeric AS value
       UNION ALL
       SELECT y.yy || CASE c.sc WHEN 'r' THEN '' WHEN 'o' THEN ' optimistic' ELSE ' pessimistic' END,
              coalesce(s.p->>(x.prefix || '_' || right(y.yy, 2) || '_' || c.sc),
                       s.p->>(x.prefix || '_' || right(y.yy, 2) || c.sc),
                       s.p->>(x.prefix || right(y.yy, 2) || c.sc))::numeric
         FROM (VALUES ('2030'), ('2040'), ('2050')) y(yy)
        CROSS JOIN (VALUES ('r'), ('o'), ('p')) c(sc)) b
 WHERE s.dataset = 'energy-development-scenarios-by-urban-planning-units'
   AND m.planning_unit_id IS NOT NULL AND b.value IS NOT NULL;

DELETE FROM planning_unit_indicators WHERE value IS NULL AND value_text IS NULL;
ANALYZE planning_unit_indicators;

COMMIT;

SELECT i.theme, i.id, i.source_units, i.unmatched, count(v.*) AS rows,
       count(DISTINCT v.planning_unit_id) AS units, count(DISTINCT v.breakdown) AS breakdowns
  FROM indicators i LEFT JOIN planning_unit_indicators v ON v.indicator = i.id
 GROUP BY i.theme, i.id ORDER BY i.theme, i.id;
SELECT match, count(*) FROM planning_unit_indicators GROUP BY match ORDER BY match;
SELECT issue, indicator, detail FROM indicator_issues ORDER BY issue, indicator;
