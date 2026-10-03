# Data issues

Problems found in the source data of https://urbandata.sofia.bg/, one entry
per kind of problem. Single rows that show the problem are listed by the
issue views in the database (`city.metro_issues`, `city.area_issues`,
`city.park_issues`, `city.education_issues`, `city.catchment_issues`,
`city.transit_issues`, `city.building_issues`, `city.census_issues`,
`city.building_extra_issues`, `city.indicator_issues`,
`city.small_area_issues`); this
file records what we know about each kind: where it comes from, what it
affects, and what we did about it.

Status:

- **open**: not resolved; results that depend on it may be wrong.
- **worked around**: the source is still wrong, but the `city` schema
  corrects or compensates for it (the entry says how).
- **flagged**: cannot be corrected from the data we have; the affected rows
  are listed by an issue view so they are not mistaken for facts.

When you add an entry, give it the next number and keep the fields.

## Summary

| #  | Issue | Area | Status |
|----|-------|------|--------|
| 1  | Five unnamed "existing" stations, two not built | metro | worked around |
| 2  | Station codes lost their Cyrillic prefix | metro | worked around |
| 3  | 2019 station point for Витоша is 576 m off | metro | worked around |
| 4  | Many stations have no name | metro | flagged |
| 5  | Lines and their stations are not in the data | metro | worked around |
| 6  | 2020 entrances near the later Line 3 НДК | metro | worked around |
| 7  | No entrances for Line 3 and Обеля | metro | flagged |
| 8  | Dataset `districts` holds neighbourhoods | areas | worked around |
| 9  | Neighbourhoods and planning units cross district borders | areas | flagged |
| 10 | Planning unit district labels disagree with location | areas | flagged |
| 11 | Neighbourhoods without a name | areas | flagged |
| 12 | Latin letter inside a Cyrillic neighbourhood name | areas | open |
| 13 | District boundaries changed since 2017 | areas | flagged |
| 14 | Building residents cover only the city itself | population | flagged |
| 15 | Building residents disagree with NSI by district | population | flagged |
| 16 | 2020 parks layer dropped parks that still have entrances | parks | worked around |
| 17 | "realiz" marks real parks as not built | parks | flagged |
| 18 | Entrance codes are not explained | parks | worked around |
| 19 | Entrances with no park within 30 m | parks | flagged |
| 20 | Existing gardens without entrances | parks | flagged |
| 21 | Most parks have no name | parks | flagged |
| 22 | Parks layer includes places that may not be public | parks | open |
| 23 | Sofiaplan's park access method is not documented | parks | flagged |
| 24 | Kindergarten type codes contradict their own code list | education | worked around |
| 25 | Kindergarten numbers that contradict the name | education | worked around |
| 26 | Funding codes that are unknown or contradict the name | education | flagged |
| 27 | Closed and unconfirmed kindergartens in the layer | education | worked around |
| 28 | Registration maps are incomplete | education | flagged |
| 29 | School admin codes shared or missing | education | flagged |
| 30 | Schools with 0 classes | education | flagged |
| 31 | Kindergartens outside their stated district | education | flagged |
| 32 | Kindergartens and schools are as of 2018 | education | open |
| 33 | Sofiaplan's 2021 not-served method is not documented | education | flagged |
| 34 | Sofiaplan's 2019 school reach has sites we lack | education | open |
| 35 | Areas where Sofiaplan's not-served shares and ours disagree | education | open |
| 36 | The school catchment list has no key to the address points | education | worked around |
| 37 | The list repeats some streets under two names | education | open |
| 38 | List schools missing from or renamed in the 2018 schools | education | open |
| 39 | Some places are assigned to a school over 5 km away | education | not an error |
| 40 | Estate blocks have one address point but many entrances | education | open |
| 41 | The catchment list, the schools and the residents are of different years | education | open |
| 42 | No accessibility data in the timetable | transit | flagged |
| 43 | Trips have no direction | transit | flagged |
| 44 | A fifth of the stops are never served | transit | flagged |
| 45 | One stop has an id per mode | transit | worked around |
| 46 | 63 lines have no trips | transit | flagged |
| 47 | Metro station names differ from Sofiaplan's | transit | worked around |
| 48 | All stop times are estimates | transit | flagged |
| 49 | The calendar reaches two years back | transit | not an error |
| 50 | The live feeds are single snapshots | transit | open |
| 51 | The cadastral plan is archived and undated | buildings | flagged |
| 52 | The building layers share no identifier | buildings | worked around |
| 53 | 2019 building centroids lie outside their outlines | buildings | worked around |
| 54 | Building functions mix two classifications | buildings | worked around |
| 55 | Floor counts that are not numbers | buildings | flagged |
| 56 | Cadastre district labels disagree with location | buildings | flagged |
| 57 | Outlines smaller than 1 m² | buildings | flagged |
| 58 | Census counts withheld as -1 | census | worked around |
| 59 | Census dwelling codes are not documented | census | open |
| 60 | The census addresses hold 91 % of the 2011 population | census | flagged |
| 61 | Census address points lie at the street, not the building | census | worked around |
| 62 | Census district codes disagree with location | census | flagged |
| 63 | The census and the 2019 buildings put people in different outlines | census | open |
| 64 | The renovation register has addresses only | buildings | flagged |
| 65 | Renovation stage codes are not documented | buildings | open |
| 66 | The shade model's facades and buildings do not link | buildings | open |
| 67 | The BREEAM layer has no rating | buildings | open |
| 68 | Indicator files do not carry the planning unit id | indicators | worked around |
| 69 | The 2019 indicator files use an older division | indicators | flagged |
| 70 | Most indicator files cover only part of the units | indicators | flagged |
| 71 | Prices have no currency and some are duplicated | indicators | worked around |
| 72 | Forecast scenario codes are not documented | indicators | worked around |
| 73 | Sewer connection above 100 % | indicators | flagged |
| 74 | Indicator files left out | indicators | open |
| 75 | DKC access is on an older division of 297 units | indicators | flagged |
| 76 | Census tracts are drawn tighter than the buildings | small areas | worked around |
| 77 | 191 census tracts are coded for another district | small areas | flagged |
| 78 | The grid and the address census disagree at the edges | small areas | flagged |
| 79 | Polling places come as UTM coordinates with loose addresses | elections | worked around |
| 80 | Polling places and section areas are of different dates | elections | flagged |
| 81 | Some polling places lie far from their section | elections | flagged |

## Metro

### 1. Five unnamed "existing" stations, two not built

- **Status:** worked around.
- **Source:** `subway-stations`, file `mgt_metro_spirki_26_sofpr_20210308`
  (station outlines, 2021).
- **What:** five outlines have `layer = existing` but no code and no name,
  and no 2019 station point lies within 50 m of them. Line 3 is the only
  line without codes, so `metro.sql` put them all on M3. Checked by the
  project owner on 2026-10-01:

  | id | lat, lon | reality |
  |----|----------|---------|
  | 65 | 42.70541, 23.35962 | exists: Стадион Георги Аспарухов |
  | 66 | 42.70863, 23.36916 | exists: Бесарабия |
  | 67 | 42.71064, 23.38314 | exists: Генерал Владимир Вазов |
  | 68 | 42.70479, 23.39088 | not built; probably planned |
  | 62 | 42.69195, 23.34298 | not built, between Театрална and Орлов мост; probably planned |

- **Impact:** before the fix, ids 62 and 68 counted as existing stations in
  walking access. In Средец, the share of residents within 500 m of a
  station drops from 88% to 80% with the fix.
- **Handling:** `db/city/metro_fixes.csv` names 65–67 and sets 62 and 68 to
  `planned`. Still open: the Line 3 track (two lines of about 15.8 km, one
  per direction) runs on to 68 and is marked `existing` all the way, so
  the unbuilt part cannot be told apart without splitting it.
- **Check:** `metro_issues`, "station without a name".

### 2. Station codes lost their Cyrillic prefix

- **Status:** worked around.
- **Source:** `subway-stations`, 2021 outlines, field `stancia`.
- **What:** codes read `??11` instead of `МС11`; the Cyrillic was lost to an
  encoding conversion.
- **Handling:** `metro.sql` rebuilds the code as `'МС' || <number>`.

### 3. 2019 station point for Витоша is 576 m off

- **Status:** worked around.
- **Source:** `subway-stations`, file `mgt_metro_spirki_25_sofpr_20190000`.
- **What:** the point named Витоша is not at the station, so the name could
  not be matched to its 2021 outline (station id 29).
- **Handling:** `db/city/metro_fixes.csv` sets the name.

### 4. Many stations have no name

- **Status:** flagged.
- **Source:** `subway-stations`. The 2021 outlines have no names; names
  come only from the 2019 points within 50 m.
- **What:** 27 stations have no name, all of them planned (two of them from
  issue 1).
- **Check:** `metro_issues`, "station without a name".

### 5. Lines and their stations are not in the data

- **Status:** worked around.
- **What:** the portal has stations and track, but not which line serves a
  station, line names, colours or opening dates. Line 3 stations have no
  codes at all.
- **Handling:** `metro.sql` seeds the lines from the Metropoliten EAD network
  map (source marked on each row) and assigns stations by code ranges.

### 6. 2020 entrances near the later Line 3 НДК

- **Status:** worked around.
- **Source:** `metro-stations-entrances`, OSM snapshot of 2020-04-02.
- **What:** the "НДК" entrances of Line 2 lie next to the Line 3 НДК outline,
  which opened later, and the nearest outline was the wrong one.
- **Handling:** entrances only go to stations on lines already open on the
  snapshot date.

### 7. No entrances for Line 3 and Обеля

- **Status:** flagged.
- **Source:** `metro-stations-entrances` (OSM, 2020-04-02).
- **What:** 16 existing stations have no entrances: all of Line 3, which
  opened after the snapshot, and Обеля.
- **Impact:** wheelchair access is unknown there, not absent.
- **Check:** `metro_issues`, "existing station without entrances".

## Areas

### 8. Dataset `districts` holds neighbourhoods

- **Status:** worked around.
- **What:** the dataset with the slug `districts` contains the квартали
  (`kvartali_26_sofpr_20190101`), not the 24 райони. The districts are in
  `regions_sofia-zip` (2026) and `districts-of-sofia-municipality` (2017).
- **Handling:** `areas.sql` reads each layer by dataset and file name.

### 9. Neighbourhoods and planning units cross district borders

- **Status:** flagged.
- **What:** the layers come from different sources and do not nest: 26
  neighbourhoods and 52 planning units lie in more than one district (the
  main part under 90%).
- **Handling:** every part is kept in `neighbourhood_districts` and
  `planning_unit_districts` with its share of area and residents; the
  largest is the main district.
- **Check:** `area_issues`, "… in several districts".

### 10. Planning unit district labels disagree with location

- **Status:** flagged.
- **Source:** `urban-planning-units`, field `rajon`.
- **What:** in 55 planning units the district named in the source is not
  where the unit lies. The labels also have spelling variants (подуене for
  Подуяне, студентска for Студентски), which the check ignores.
- **Check:** `area_issues`, "planning unit label disagrees with its location".

### 11. Neighbourhoods without a name

- **Status:** flagged.
- **What:** 5 neighbourhoods have no name (`---`). One of them (id 284) is a
  1,078 km² remainder covering most of the municipality outside the city.
- **Check:** `area_issues`, "neighbourhood without a name".

### 12. Latin letter inside a Cyrillic neighbourhood name

- **Status:** open.
- **Source:** `districts` (квартали), field `kvname`.
- **What:** neighbourhood 12, "С. СВЕТОВРАЧEНЕ", has a Latin E. Searching
  for the name in Cyrillic does not find it. (The Latin "III" in
  "В.З. КИНОЦЕНТЪРА III ЧАСТ" is a Roman numeral and is fine.)
- **Handling:** to do: replace Latin look-alike letters in Cyrillic words in
  `areas.sql`, and flag them in `area_issues`.

### 13. District boundaries changed since 2017

- **Status:** flagged.
- **What:** 5 districts differ by at least 0.01 km² from the 2017 NAG
  boundaries (Витоша and Панчарево 0.66 km², Люлин 0.45, Овча купел 0.39,
  Банкя 0.06). Data drawn on the old boundaries may be assigned differently.
- **Check:** `area_issues`, "district boundary changed since 2017";
  `districts.boundary_diff_km2`.

## Population

### 14. Building residents cover only the city itself

- **Status:** flagged.
- **Source:** `building-centroids-resident-count-800-m` (2019).
- **What:** residents are given almost only for buildings in the city of
  Sofia (EKATTE 68134). Банкя and Нови Искър have none, Панчарево 176.
- **Impact:** per-area figures there (population, metro access) say
  nothing; they are not zero in reality.

### 15. Building residents disagree with NSI by district

- **Status:** flagged.
- **Source:** buildings 2019 against `nsi-control-areas` (2017).
- **What:** 11 districts differ by more than 10%, e.g. Люлин 165k against
  110k, Студентски 22k against 50k, Искър 76k against 61k. The NSI control
  areas were checked and lie in the districts they are coded to, so the
  difference is in the sources, not in our matching.
- **Impact:** absolute numbers per district are uncertain; shares within one
  source (such as metro access) are more reliable than totals.
- **Check:** `area_issues`, "population differs from NSI";
  `districts.population_nsi`.

## Parks

### 16. 2020 parks layer dropped parks that still have entrances

- **Status:** worked around.
- **Source:** `public-parks-and-gardens`, files `parkove_gradini_26_sofpr_20200914`
  and `parkove_gradini_26_sofpr_20191001`; `park-and-garden-entrances` 2020.
- **What:** 189 of the 1,641 entrances of 2020 lie more than 30 m from any
  2020 park; 186 of them lie on a 2019 park and match a 2019 entrance.
  The 2020 layer follows the master plan zones and has lost parks such as
  Врана, most of Гео Милев, Негован, Слатинска река and the Позитано
  gardens.
- **Handling:** `parks.sql` adds the 36 parks of 2019 that are less than
  10 % covered by 2020 parks and have a 2020 entrance within 30 m. They
  have `data_as_of` 2019-10-01, no zone and no realization.

### 17. "realiz" marks real parks as not built

- **Status:** flagged.
- **Source:** `public-parks-and-gardens` 2020, field `realiz` (0, 1, 2).
- **What:** the field is not explained. All 573 parks with 0 have no
  entrances (`entr` is empty, and 1 for all others), so `parks.sql` takes 0
  as planned and 1 and 2 as existing. But 7 "planned" parks have
  entrances, among them parts of Западен парк, Какач and Горна баня,
  which exist.
- **Impact:** some existing green space counts as planned, so walking
  access is a little understated; with the planned parks it rises only
  from 53.7 % to 54.4 % within 300 m.
- **Check:** `park_issues`, "planned park with entrances".

### 18. Entrance codes are not explained

- **Status:** worked around (`size`), open (`reglament`).
- **Source:** `park-and-garden-entrances` 2020, fields `size` (1–3) and
  `reglament` (1, 2).
- **What:** the 2019 entrances say in words what the 2020 ones code.
  Within 5 m, 410 of 413 size 1 are "главен", 491 of 494 size 2
  "второстепенен", size 3 "нерегламентиран". The 2019 words have typos
  (главем, главех, гллавен, второстпенен). `reglament` does not follow
  `size` (38 main entrances have 2) and has no 2019 counterpart.
- **Handling:** `park_entrances.kind` is main / secondary / unofficial;
  `reglament` is kept as the raw code.

### 19. Entrances with no park within 30 m

- **Status:** flagged.
- **What:** 46 entrances are 30–417 m from the nearest park, most of them
  next to parks drawn smaller than they are. Sofiaplan counted them (see
  issue 23); `park_access.sql` does not, as their park is unknown.
- **Check:** `park_issues`, "entrance without a park".

### 20. Existing gardens without entrances

- **Status:** flagged.
- **What:** 26 small existing gardens (152–11,642 m²) have no entrance;
  some lie 2 km from the nearest one. They count for the distance to a
  park's edge, not to an entrance.
- **Check:** `park_issues`, "existing park without entrances".

### 21. Most parks have no name

- **Status:** flagged.
- **Source:** the 2020 parks have no name field; names come from the 2019
  outline covering most of each park.
- **What:** 149 of 392 existing parks have a name; 15 existing city parks
  do not. Large parks are cut into pieces that share a name (Борисова
  градина is 9).
- **Check:** `park_issues`, "city park without a name".

### 22. Parks layer includes places that may not be public

- **Status:** open.
- **Source:** `public-parks-and-gardens` 2019, the parks without `function_`.
- **What:** among the 2019 parks added by issue 16 are school yards (8 СОУ,
  46 ОУ — written "0У" with a zero —, 142 СОУ), the НСА sports complex,
  София Тех Парк and the two Sofia Airport parks.
- **Impact:** if they are fenced, access near them is overstated.
- **Handling:** to do: check which are open and mark the others.

### 23. Sofiaplan's park access method is not documented

- **Status:** flagged.
- **Source:** `housing-units-with-walking-access-to-parks-and-gardens` and
  `housing-units-without-…` (2021).
- **What:** neither the distance nor how it was measured is stated. From
  the data: every "with" building has an entrance within 356 m in a
  straight line and some "without" ones are 265 m from one, so it is most
  likely 300 m along footpaths from the building outline, to any entrance.
  The people field `ppl_sgr_30` is not explained; the 132,070 points hold
  1.5 M people against 1.13 M in our 2019 buildings, and cover the
  villages too.
- **Handling:** compared point by point in `park_access_sofiaplan`; no
  contradiction found (no "with" building lacks an entrance within 400 m).
- **Check:** `park_access_agreement`.

## Kindergartens and schools

### 24. Kindergarten type codes contradict their own code list

- **Status:** worked around.
- **Source:** `kindergarten-locations-point` (2018-08-08), field `type`;
  `kindergarten-type` (`dg_kod_type`: 0 other, 1 ДГ, 2 ДГЯ, 3 ЧДГ, 4 ЧДГЯ, 5 ДЯ).
- **What:** municipal kindergartens (ДГ) have type 1 or 4, municipal
  nurseries (ДЯ, СДЯ) have 2, private ones (ЧДГ) have 1, and 126 points
  have no type. Type 4 should be a private kindergarten with a nursery.
- **Handling:** `education.sql` reads the kind from the name: ДЯ, СДЯ and
  ЧДЯ are nurseries; family-type centres, the ДДЛРГ children's home and
  the children's centre in Надежда are "other"; the rest are
  kindergartens. The raw code stays in `type_code`. The school types
  (`uchilishta_kod_type`) do follow their list.

### 25. Kindergarten numbers that contradict the name

- **Status:** worked around.
- **Source:** `kindergarten-locations-point`, field `object_nom`.
- **What:** ДГ №76 "Сърничка" has number 78, ДГ №139 "Панорама" has 39 and
  СДЯ №41 has 0. Matching by number puts the registration of ДГ №76 on
  the wrong kindergarten, or on none.
- **Handling:** the registration maps are matched by the number in the
  name too, nearest main site first. All 194 end up on the kindergarten
  whose name carries their number, at 0 m.
- **Check:** `education_issues`, "number contradicts the name".

### 26. Funding codes that are unknown or contradict the name

- **Status:** flagged.
- **Source:** `kindergarten-locations-point` and `school-locations-points`,
  field `finansiran` (1 state, 2 municipal, 3 private, by the names).
- **What:** ДГ №60 "Бор" and ДГ №112 "Детски свят" (special needs) have
  code 4, which is not explained. Първа английска езикова гимназия and the
  practice building of НПГПТО "М. В. Ломоносов" have none. ЧДГ "В парка",
  ЧДГ "Светлина" and Частно ОУ "Д-р Мария Монтесори" are private by name
  but municipal by code.
- **Impact:** small. The two code 4 kindergartens count as kindergartens,
  but not as municipal ones.
- **Check:** `education_issues`, "unknown funding code" and "private by
  name, not by funding".

### 27. Closed and unconfirmed kindergartens in the layer

- **Status:** worked around.
- **Source:** `kindergarten-locations-point`, fields `chek`, `status` and
  `zabelezhka`.
- **What:** 9 points have `chek` 2. 3 private kindergartens are marked
  "закрита". The notes say the authors could not confirm 5 others
  (СДЯ №44, СДЯ №48, СДЯ №56, ЧДГ "Палави крачета", the ДГ №121 branch in
  Доброславци), and one is a care centre.
- **Handling:** `status` is closed or doubtful. Only open kindergartens
  count in `building_education_access`.
- **Check:** `education_issues`, "kindergarten closed or doubtful".

### 28. Registration maps are incomplete

- **Status:** flagged.
- **Source:** `registration-maps-kindergartens` and
  `registration-maps-groups-kindergartens` (2018-08-08).
- **What:** the maps cover 194 municipal kindergartens, not the nurseries
  or private ones. ДГ №197 "Китна градина" has a map but no groups. Three
  open "municipal" main sites have no map: the kindergarten for children
  with impaired hearing, and the two private ones from issue 26.
  `broi_deca` is not explained: it could be places or enrolled children.
- **Handling:** where there are no groups the child counts are NULL, not
  0. `registered_children` in `area_education_access` is only a hint of
  capacity.
- **Check:** `education_issues`, "registration without groups" and
  "municipal kindergarten without a registration map".

### 29. School admin codes shared or missing

- **Status:** flagged.
- **Source:** `school-locations-points`, field `kodadmin` (the ministry code).
- **What:** 6 schools have 0, among them four special schools (ЦСОП) and
  two private ones. Five codes are shared by two points each. Two are
  buildings of one school (НПГПТО "Ломоносов", "Веда"), and Уланова has
  two names. But 19 СУ and 132 СУ share 2209132, and 129 ОУ and 175 ОУ
  share 2203175: the code belongs to one of them.
- **Impact:** none yet. It will matter when schools are linked by code to
  other data (e.g. the ministry's).
- **Check:** `education_issues`, "school without an admin code" and "admin
  code shared by schools".

### 30. Schools with 0 classes

- **Status:** flagged.
- **Source:** `school-locations-points`, field `br_paralel`.
- **What:** 65 of 275 schools have 0. Most are private or state (35
  private, 22 state), but 8 are municipal. 0 most likely means not filled
  in.
- **Impact:** `class_count` cannot be used as a size of a school yet.
- **Check:** `education_issues`, "school with no classes".

### 31. Kindergartens outside their stated district

- **Status:** flagged.
- **Source:** `kindergarten-locations-point`, field `kod_rayon`.
- **What:** ЧЦДГ "Еко Дара" and ЧЦДГ "Германи" say Витоша (17) but lie in
  Панчарево (23). ЧДГ "В парка" says Лозенец (09) but lies in Триадица
  (10). Either the point or the code is wrong.
- **Check:** `education_issues`, "outside its district".

### 32. Kindergartens and schools are as of 2018

- **Status:** open.
- **Source:** all the education layers are dated 2018-08-08.
- **What:** kindergartens opened since then, the new municipal ones among
  them, are missing, and some closed ones may still be there.
- **Impact:** access is likely understated in the newer parts of the
  city.
- **Handling:** to do: find a newer list (the municipal register, or the
  ministry's for schools).

### 33. Sofiaplan's 2021 not-served method is not documented

- **Status:** flagged.
- **Source:** `pedestrian-access-to-schools-and-municipal-kindergartens-share-of-unserved-population`
  (2021, 228 areas).
- **What:** the distance is not given. Their city share not served (14.8 %
  for municipal kindergartens, 23.4 % for schools) lies between ours at
  400 m (19.5 %, 30.7 %) and 500 m (10.3 %, 16.1 %) straight. Per area, ours
  at 500 m correlates at 0.93 and 0.87. That fits a 500 m walk. Their
  `ppl_all` totals 1.52 M against 1.13 M in our buildings; `dens30_ppl` is
  not explained.
- **Handling:** compared at both 400 and 500 m in
  `education_unserved_sofiaplan`, by share, not by people.

### 34. Sofiaplan's 2019 school reach has sites we lack

- **Status:** open.
- **Source:** `school-accessibility-400-800-1200-2000-m`, file
  `uchilishta_merged_400_800_1200m_25_sofpr_20190000` (despite the name,
  there is no 2000 m area).
- **What:** walking is never shorter than a straight line, yet 25 of the
  15,572 buildings they put within 400 m of a school are farther from any
  of our 275 schools. 13 are in Горубляне, up to 928 m from our nearest
  school (82 ОУ, 84 ОУ). 11 are near the Американски колеж, and one is in
  Дружба 2. 63 buildings are similar at 800 m. Sofiaplan had a school site
  there that the 2018 points do not.
- **Handling:** to do: find which school it is.
- **Check:** `school_access_agreement`, `sofiaplan_only_400`.

### 35. Areas where Sofiaplan's not-served shares and ours disagree

- **Status:** open.
- **Source:** as issue 33.
- **What:** Sofiaplan's figure first, then ours at 500 m straight:
  - ж.к. Яворов: 12 % of people not served by a school, against 84 %.
  - м. Триъгълника (Надежда): 66 % for schools, against 0 %.
  - Карпузица – изток: 65 % for schools, against 0 %.
  - ЦГЧ зони Б2: 1 % for kindergartens, against 61 %.
  
  In the first and last, one of the two sets lacks a school or a
  kindergarten; in the middle two, ours has one theirs did not.
- **Not an issue:** Факултета. Both find most of it without a
  kindergarten nearby: 78 % of people for Sofiaplan, 91 % for us. With
  3,213 children aged 0–14 and no registered places, it is the largest gap
  in the city. Both rest on municipal data, so it is worth a check on
  the ground.
- **Check:** `education_unserved_sofiaplan`.

### 36. The school catchment list has no key to the address points

- **Status:** worked around.
- **Source:** urbandata.sofia.bg, `addresses-and-associated-schools`
  (list as of 2026-06-30) and `address_sofia-zip` (address points).
- **What:** the list gives the school per address as free text: town,
  street or estate, number, and entrance. Neither file has a shared id,
  and the address points lack the GRAO street code. Street names differ
  in form ("УЛ.3005-ТА (717 ЛЮЛИН)", "КВ.", "МЕСТН.") and some are cut
  short ("УЛ.МИМИ БАЛКАНСКА(ИВ.НЕД.-ШАБЛ").
- **Handling:** `school_catchments.sql` matches on normalised names in
  four passes: street and number; estate and block; then the bracketed or
  ordinal alternative name, first among streets and then among estates.
  94.1 % of the 106,629 rows are placed. The other 6,262 are in 881
  street groups. The largest are бул. Княз Ал. Дондуков-Корсаков (117),
  бул. Лазар Михайлов (111) and Мими Балканска (94). Alternative-name
  matches are mostly suburban and the least sure: the median distance
  to the school is 896 m, against 524 m for street matches.
- **Check:** `catchment_issues` ('address not among the address points').

### 37. The list repeats some streets under two names

- **Status:** open.
- **Source:** as issue 36.
- **What:** one street appears twice with different schools, e.g.
  "УЛ.МАЛИНА" and "УЛ.МАЛИНА (233-ТА)", or "747-МА" under both
  "(ГОРНА БАНЯ)" and "(ОВЧА КУПЕЛ)". Both rows land on the same address
  point, so that point has two schools.
- **Handling:** kept as the list has it; a building takes the nearer
  address row.

### 38. List schools missing from or renamed in the 2018 schools

- **Status:** open.
- **Source:** as issue 36, and the 2018 schools (issue 32).
- **What:** 204 ОУ (524 addresses) is not among the 2018 schools. 92 ОУ
  and 148 ОУ are matched by number only: in 2018 they were СОУ, and the
  2018 name of 148 also includes 157-ма гимназия. The СОУ → СУ renaming
  came after the 2016 Preschool and School Education Act.
- **Handling:** the list keeps 204 ОУ with no school; its buildings have
  a catchment but no distance.
- **Check:** `catchment_issues` ('list school …').

### 39. Some places are assigned to a school over 5 km away

- **Status:** not an error.
- **Source:** as issue 36.
- **What:** villages and outlying quarters with no school of their own
  are assigned to a far one: Долни Богров → 85 СУ (515 addresses,
  6.5 km), Мало Бучино → 72 ОУ (471, 5.4 km), Желява → 115 ОУ (222,
  6.7 km), Сеславци → 117 СУ (56, 5.4 km). The list says this; it is a
  fact about access, not a data problem. Also "ГР.СОФИЯ → 26 СУ" has 5
  addresses about 7 km away; that may be a match error.
- **Check:** `catchment_issues` ('addresses over 5 km from their school').

### 40. Estate blocks have one address point but many entrances

- **Status:** open.
- **Source:** as issue 36, and the 2019 residents per building.
- **What:** a building takes the catchment of the nearest placed address
  within 30 m (the median gap is 5 m). In the estates there is one
  address point per block and one list row per entrance: Ж.К. Младост 3
  has 331 rows on 94 points. A long block's building points are 30–100 m
  from that one point, so only 66 % of Младост's 13,208 children have a
  known catchment, against 93.6 % city-wide.
- **Handling:** left unknown, because a wider radius would pick up the
  neighbouring block's catchment. To do: match the building to the
  block by number instead of by distance.
- **Check:** `area_school_catchment` (`known_share`).

### 41. The catchment list, the schools and the residents are of different years

- **Status:** open.
- **Source:** list 2026-06-30, schools 2018, residents 2019.
- **What:** new streets and blocks built after 2019 have no residents.
  Schools opened since 2018 (e.g. 204 ОУ) have no location. The 2019
  residents per building cover the city proper only, so 24 list schools
  that serve only the towns and villages (Банкя, Нови Искър, Владая,
  Лозен, …) have no children counted, and those places are missing from
  the area shares.
- **Handling:** shown with each figure's date.

## Public transport

All from the static GTFS timetable (dataset gtfs-static, published by
Theoremus for the Center for Urban Mobility, valid 2026-09-28 ..
2027-09-28, downloaded 2026-09-28), as loaded by `load_gtfs.py` and
interpreted by `db/city/transit.sql`.

### 42. No accessibility data in the timetable

- **Status:** flagged.
- **What:** all 29,400 trips have `wheelchair_accessible` 0 ("no
  information"), and stops.txt has no `wheelchair_boarding` column. The
  feed cannot say which lines run low-floor vehicles or which stops can
  be used from a wheelchair.
- **Handling:** we say nothing about step-free travel by bus, tram or
  trolleybus. Step-free metro entrances come from Sofiaplan (see the
  metro section).
- **Check:** `transit_issues` ('no accessibility data').

### 43. Trips have no direction

- **Status:** flagged.
- **What:** `direction_id` is empty on every trip. The two directions of
  a line can only be told apart by the headsign or the shape.
- **Handling:** frequencies are counted over both directions together:
  "12 departures an hour" at a stop pair served both ways is about 6 each
  way.
- **Check:** `transit_issues` ('no trip direction').

### 44. A fifth of the stops are never served

- **Status:** flagged.
- **What:** 1,149 of the 4,414 stop ids have no stop time at all. Merged
  into stops as people see them, 671 of 3,521 stops have no trip on any
  reference day. 186 stops are named "ВРЕМЕННА" (temporary), none of
  them served: left over from past road works.
- **Handling:** only served stops count for access; the others are
  listed so a stop on the map is not taken for a working one.
- **Check:** `transit_issues` ('stop never served', 'temporary stop').

### 45. One stop has an id per mode

- **Status:** worked around.
- **What:** a pole served by buses and trolleybuses is two stops,
  A0328 and TB0328, with the same code 0328 on the sign. 830 codes are
  shared like this. The farthest pair is 82 m apart (МС МУСАГЕНИЦА); most
  are within a few metres.
- **Handling:** `transit_stops` merges them by the code. Metro stations
  keep their stop_id, as their codes (1, 18, 303) could clash.
- **Check:** `transit_issues` ('one stop under several ids').

### 46. 63 lines have no trips

- **Status:** flagged.
- **What:** 63 of 204 routes have no trip in the feed at all: most are
  replacement lines for road works (names with ТМ/TM, Т, Tb), seasonal
  lines (Банкя, Врана, Витоша) and some numbered lines (1, 3, 4, 5, 7,
  8, 10, 12, 14). Whether they run is not in the timetable.
- **Handling:** they are kept in `transit_routes` with 0 trips and no
  line, and counted nowhere.
- **Check:** `transit_issues` ('line without trips').

### 47. Metro station names differ from Sofiaplan's

- **Status:** worked around.
- **What:** 14 of the 50 metro stations are named differently in the
  timetable and in Sofiaplan's station outlines: abbreviations (НДК /
  Национален дворец на културата, ГЕН. / Генерал), extra words (Бул.
  България, Сердика 1, ИЕЦ - Цариградско шосе), and one other name:
  Sofiaplan's "Красно село" on Line 3 is "ЦАР БОРИС III" in the
  timetable. "ТЕAТРАЛНА" is spelled with a Latin A.
- **Handling:** stops are matched to station outlines by location
  (within 300 m; all 50 match, the farthest is 44 m).
- **Check:** `transit_issues` ('metro name differs', 'Latin letter in a
  Cyrillic name').

### 48. All stop times are estimates

- **Status:** flagged.
- **What:** every stop time has `timepoint` 0: the times are
  approximate, not the published schedule a driver keeps to.
- **Handling:** counts per hour are reliable; the exact minute is not.
- **Check:** `transit_issues` ('all times are estimates').

### 49. The calendar reaches two years back

- **Status:** not an error.
- **What:** the feed is valid from 2026-09-28, but `calendar_dates`
  starts on 2024-08-12: 18,266 past dates of 2,341 services. There is no
  calendar.txt; every service lists its dates.
- **Handling:** only the reference days are used (`transit_days`: Tuesday
  2026-10-06, Saturday 2026-10-10, Sunday 2026-10-11).
- **Check:** `transit_issues` ('calendar from before the feed').

### 50. The live feeds are single snapshots

- **Status:** open.
- **What:** the vehicle positions, trip updates and alerts datasets are
  GTFS-realtime protobuf files captured once by `sync.py`. One snapshot
  says where the vehicles were at one moment, not how punctual they are.
- **Handling:** not loaded. Punctuality needs the feeds polled over
  weeks.

## Buildings

### 51. The cadastral plan is archived and undated

- **Status:** flagged.
- **What:** `cad_plan_sgr-zip` is the *archived* cadastral plan: "the
  content of the cadastral plan before the cadastral map came into
  force". The portal dates it 08.09.2026, which is when it was
  published, not what it shows. Buildings put up since are missing: 23
  of the 34 BREEAM buildings (most of them new) have no outline within
  30 m, and 466 inhabited buildings of 2019 (17,961 people) have none
  within 10 m.
- **Handling:** `city.buildings.data_as_of` is the publication date;
  the table comment says what it is. Measures weighted by residents
  still use the 2019 centroids, which do not depend on the outlines.
- **Check:** `building_issues` ('inhabited building of 2019 missing
  from the cadastral plan'), `building_extra_issues` ('BREEAM building
  far from any outline').

### 52. The building layers share no identifier

- **Status:** worked around.
- **What:** `rn` is a running number in each file (the municipal
  buildings' rn 655 is not the plan's rn 655), and none of the 7,718
  municipal outlines is identical to a plan outline. Sofiaplan's 2019
  buildings carry the cadastral number (`id_kk`), but the plan does not.
- **Handling:** joined by location: a point inside each municipal
  outline (6,499 plan outlines are municipal; 894 municipal ones fall in
  none) and each 2019 centroid (see 53). The plan's outlines do not
  overlap, so a point lies in at most one.

### 53. 2019 building centroids lie outside their outlines

- **Status:** worked around.
- **What:** of the 158,684 Sofiaplan buildings, 123,191 centroids lie
  in a plan outline, 25,582 lie within 10 m of one and 9,911 farther.
  The two drawings are offset by a few metres in places; some buildings
  are newer than the plan (51).
- **Handling:** `buildings_2019.match` is 'inside', 'nearest' (within
  10 m) or 'none', with the distance. Several 2019 buildings may share
  one outline (up to 10); the outline gets their sums.
- **Check:** `building_issues` for the inhabited 'none' ones.

### 54. Building functions mix two classifications

- **Status:** worked around.
- **What:** 218 different `functional_type` values: an old list in
  capitals (СГРАДИ ЖИЛИЩНИ, СГРАДИ, ОБСЛУЖВАЩИ И СПОМАГАТЕЛНИ) beside a
  finer one (Къщи, Сгради многожилищни, Трансформаторни постове), with
  variants in spelling and spacing. 3,398 buildings have "---".
- **Handling:** `buildings.category` groups them into 11 categories
  (residential, ancillary, industry, commercial, public, utility,
  education, health, transport, agriculture, other) by our own rules in
  `buildings.sql`; the source value stays in `function`. "---" is NULL.
- **Check:** `building_issues` ('building without a function').

### 55. Floor counts that are not numbers

- **Status:** flagged.
- **What:** `numer_of_floors` is text: 1,414 values like "1/2", "2/3",
  "3/2", "1 1/2" whose meaning is not given (perhaps floors above/below
  ground, or a half floor), and 4,138 negative ones (-1 to -3), which
  look like underground-only structures (garages).
- **Handling:** `floors` is set only for whole numbers, negative kept;
  the text is in `floors_text`. Floor area estimates use positive
  floors only.
- **Check:** `building_issues` ('floor count is not a number').

### 56. Cadastre district labels disagree with location

- **Status:** flagged.
- **What:** 123 outlines are labelled with a district they do not lie
  in, mostly at three borders: ПАНЧАРЕВО for buildings in Младост (54),
  ОВЧА КУПЕЛ in Красна поляна (46), МЛАДОСТ in Искър (22).
- **Handling:** the district is taken from the location; the label is
  kept as `region_label`.
- **Check:** `building_issues` ('district label disagrees with its
  location').

### 57. Outlines smaller than 1 m²

- **Status:** flagged.
- **What:** 150 outlines are under 1 m², 21 of them under 0.01 m²:
  slivers, not buildings.
- **Handling:** kept, as they are in the source.
- **Check:** `building_issues` ('outline smaller than 1 m²').

### 64. The renovation register has addresses only

- **Status:** flagged.
- **What:** the 288 entries of the register (2020-07-03) have no
  coordinates; addresses are free text in several styles ("УЛ.ЦАР ИВАН
  АСЕН II № 8-10", "ж.к. Дружба 1, , бл. 167", "ул.,,Черковна № 66\"").
- **Handling:** found among the census addresses (`census.sql`) by
  street and number, else by housing estate and block number when only
  one estate of the district fits. 241 found, 239 of them with an
  outline; 47 not found.
- **Check:** `building_extra_issues` ('renovated building not found
  among the census addresses').

### 65. Renovation stage codes are not documented

- **Status:** open.
- **What:** `stage_contract` is 1–5 (or empty) for the approved entries,
  with no explanation; the other date fields are mostly empty.
- **Handling:** kept as `renovations.stage`; not interpreted.

### 66. The shade model's facades and buildings do not link

- **Status:** open.
- **What:** `building-solar-irradiance` has buildings (`senki_sgr`, id
  and elevation only), units by floor (`senki_sos`, 740,487, with
  `shaded` 0–1) and facade segments (`senki_sos_fasadi`, 2,985,830).
  The facades' `ap_id` is not the units' `id` (on a sample the shade
  values do not correlate), and the units' `building_id` is not the
  `senki_sgr` id in any documented way. What period `shaded` is the
  share of is not said.
- **Handling:** unit points are summed per plan outline by location
  (`building_shading`, 38,317 buildings, 657,427 units); the facades are
  not loaded.

### 67. The BREEAM layer has no rating

- **Status:** open.
- **What:** the 34 entries say what and where the building is and its
  stage (project, under construction, in use), but not the BREEAM
  rating; most other fields (energy and water savings, materials) are
  empty.
- **Handling:** the non-empty fields are kept in `breeam_buildings.details`.

## Census

### 58. Census counts withheld as -1

- **Status:** worked around.
- **What:** in `population-data`, education and country-of-birth counts
  are -1 at 62,588 of the 90,897 addresses: small counts that NSI
  withholds for privacy. Ages and sexes are always given, and add up.
- **Handling:** -1 is NULL. Shares (higher education, born abroad) are
  over the addresses where all of their counts are given.

### 59. Census dwelling codes are not documented

- **Status:** open.
- **What:** the fields `nj12_1..5`, `nj16_eq_1..3` and `nj17_eq_*`
  describe dwellings (they add up to the dwelling count), probably
  type, heating and fuel, but no code list is published.
- **Handling:** not loaded. They would answer how many homes still burn
  solid fuel.

### 60. The census addresses hold 91 % of the 2011 population

- **Status:** flagged.
- **What:** the addresses add up to 1,177,165 people; the 2011 census
  counted 1,291,591 in the Sofia municipality. The rest were presumably
  not geocoded. Sofiaplan's 2019 buildings hold 1,127,756.
- **Handling:** `area_census` gives both counts side by side.

### 61. Census address points lie at the street, not the building

- **Status:** worked around.
- **What:** only 40,430 of the 90,897 address points lie inside a plan
  outline; most are on the street front.
- **Handling:** the outline the point is in, else the nearest
  residential one within 20 m, else the nearest of any kind within
  20 m (a garage is often the nearest). 1,248 inhabited addresses
  (20,786 people) have none.
- **Check:** `census_issues` ('inhabited census address without a
  building outline').

### 62. Census district codes disagree with location

- **Status:** flagged.
- **What:** 690 addresses carry a district code (`ecode_rayon`) other
  than the district they lie in, mostly along borders (Витоша /
  Панчарево 97, Овча купел 25). 118 addresses share an NSI building id
  with another.
- **Check:** `census_issues`.

### 63. The census and the 2019 buildings put people in different outlines

- **Status:** open.
- **What:** Sofiaplan's 2019 counts are the census counts attached to
  their own building centroids: where both reach the same outline they
  agree in 27,659 of 29,849 cases. But 23,469 outlines have census
  residents (237,382 people) and no 2019 ones, and 3,498 the reverse.
  Address points and centroids land in neighbouring outlines,
  especially in blocks of flats with one address and several sections.
- **Handling:** none yet. Per building, use one source at a time; per
  area both agree to within a few percent (`area_census`).

## Planning-unit indicators

### 68. Indicator files do not carry the planning unit id

- **Status:** worked around.
- **What:** each of Sofiaplan's per-unit files numbers its units afresh
  (`object_id`, a UUID `id`); neither is the `object_id` of the unit
  division (`ge_26_sofpr_20200616`) that `city.planning_units` is built
  from. Only the price and floor-area files carry `ge_id`, which is.
- **Handling:** `indicators.sql` matches by `ge_id`; else by the same
  `regname` if the two shapes overlap by half of the larger; else by a
  shape overlapping 90 % of the larger. `planning_unit_indicators.match`
  says which rule was used.

### 69. The 2019 indicator files use an older division

- **Status:** flagged.
- **What:** the mono- and polyfunctionality file (2019-07-19) has 574
  units of an older division; 44 of them were redrawn since and match
  no current unit.
- **Handling:** they are left out rather than spread over the new
  units. **Check:** `indicator_issues` ('source units not found among
  the planning units').

### 70. Most indicator files cover only part of the units

- **Status:** flagged.
- **What:** prices exist for about 140 of 564 units, education
  facilities for the 264 units with any, walking access to schools for
  the 228 units with residents, the residential shading for 299 and the
  sewer connection for 351. A missing unit is "no data", not zero.
- **Check:** `indicator_issues` ('indicator covers only part of the
  planning units').

### 71. Prices have no currency and some are duplicated

- **Status:** worked around.
- **What:** the purchase and rent prices (2002-2020) do not say their
  currency or whether the rent is monthly; the values suggest euro per
  m² and per month. 18 (unit, year) pairs appear twice.
- **Handling:** the duplicates are averaged; the unit is shown as
  "per m²" without a currency. Some values are implausible (an office
  at 2 per m², a shop rent of 0.03) and are kept as given.

### 72. Forecast scenario codes are not documented

- **Status:** worked around.
- **What:** Kopralev's forecast has columns `po…`, `pp…` and `pr…` for
  2020-2050 and age groups 0-2, 3-6, 7-14, 15-18 and 65+, with no
  legend. The decade is cut to three digits (`pr0714_203` = 2030).
- **Handling:** taken as optimistic, pessimistic and realistic, since
  pp < pr < po in every year (a test checks it). The age groups are
  loaded for the realistic scenario only.

### 73. Sewer connection above 100 %

- **Status:** flagged.
- **What:** `conect_san` is above 100 in three units (up to 105 %);
  213 units have no value.
- **Check:** `indicator_issues` ('percentage outside 0-100').

### 74. Indicator files left out

- **Status:** open.
- **What:** not loaded because they cannot be read reliably:
  - access to employment by public transport: `join_count` (0-8) and
    `kgr` (0-1.17) are not explained;
  - number of schools relative to residential area: `broj_uch_s` is
    mostly empty and `otnosh` is often twice `rzp_all`;
  - morphology: an older division of 253 units, whose figures we have
    by building and address anyway;
  - Kopralev's forecast on the older division (the adjusted one is
    loaded).
- **Handling:** none; ask Sofiaplan for the field descriptions.

### 75. DKC access is on an older division of 297 units

- **Status:** flagged.
- **What:** Sofiaplan's walking access to the DKC polyclinics (early
  2021) has 297 unnamed units; 245 match a current planning unit by
  shape (90 % overlap), 52 match none.
- **Handling:** the 52 are left out of `dkc_unserved_pct`.
  **Check:** `indicator_issues`.

## Small areas

### 76. Census tracts are drawn tighter than the buildings

- **Status:** worked around.
- **What:** the NSI census tracts (2017) leave gaps along the streets
  and are drawn inside the cadastral outlines: a point on the surface
  of an inhabited building falls outside every tract for 5,360
  buildings (231,040 residents of 2019), 4,728 of them within 25 m.
- **Handling:** `small_areas.sql` puts such a home in the nearest tract
  within 50 m; the tracts then hold 98.5 % of the census addresses'
  people and 98.6 % of the 2019 residents.

### 77. 191 census tracts are coded for another district

- **Status:** flagged.
- **What:** `ecode_rayon` names a district other than the one the tract
  lies in for 191 of 6,103 tracts. As with the census addresses (#62)
  most are along district borders.
- **Check:** `small_area_issues` ('census tract coded for another
  district').

### 78. The grid and the address census disagree at the edges

- **Status:** flagged.
- **What:** NSI's 1 km grid holds 1,292,702 people in the cells whose
  centre is in Sofia, the official 2011 count; the census addresses
  hold 1,177,165 (#60). In 24 cells with 200 people or more the two
  differ by more than half, mostly villages and edges of the city
  that the address file lacks. `methd_cl` (A or empty) is not
  explained.
- **Check:** `small_area_issues` ('grid cell: census by address far
  from the grid').

## Elections

### 79. Polling places come as UTM coordinates with loose addresses

- **Status:** worked around.
- **What:** `izbori_april_2026` is a spreadsheet with x and y in UTM
  zone 35N (EPSG:32635), which is not stated; the date is an Excel day
  number. "Адрес" is usually "<building>, гр.София, <street>", but some
  start with the settlement and have no building, and some contain
  line breaks.
- **Handling:** the zone was confirmed by every place falling in
  Sofia, in the district of its section number but two (#81). Place
  and address are split at the first comma unless the text starts
  with "гр." or "с.".

### 80. Polling places and section areas are of different dates

- **Status:** flagged.
- **What:** the places are of the 19 April 2026 election, the section
  areas of the August 2026 division. 9 sections have no area (mostly
  hospitals and other special sections) and 2 areas have no place.
  The areas are joined to the places by district name and the number
  within the district (digits 5-6 and 7-9 of the section number).
- **Check:** `small_area_issues`.

### 81. Some polling places lie far from their section

- **Status:** flagged.
- **What:** 14 polling places are more than 1 km from their section's
  area, and 2 sections of Студентски vote in Оборище. Some may be
  real (a school serving several sections), some a mismatch of dates
  (#80).
- **Check:** `small_area_issues` ('polling place far from its
  section', 'polling place in another district than its section').

## Energy

### 82. The energy scenarios' fields and units are not explained

- **Status:** worked around.
- **What:** Sofiaplan's energy scenarios by planning unit (2020-08-11)
  have some 130 fields named like `stec_30_r`, `sotopl1517`,
  `elotop_30r`, with no description and no unit. The suffixes are
  read as 2017 and as the realistic, optimistic and pessimistic
  scenario of 2030, 2040 and 2050; the size of the numbers and
  `s_mwth` suggest MWh a year. `elosv` is read as electricity for
  lighting and appliances. `spest` grows like the heat pumps but is
  not named after anything we can tell, so it is kept as "spest".
  Only some fields have the optimistic and pessimistic scenarios.
- **Handling:** `indicators.sql` loads 14 `energy_*` indicators; the
  realistic scenario goes under the bare year, the others under
  "<year> optimistic" / "<year> pessimistic". The descriptions say
  what is inferred. Ask Sofiaplan for the field list.

### 83. The energy scenarios use the older division of 574 units

- **Status:** flagged.
- **What:** as #69: 44 of the 574 units were redrawn since and match
  no current unit, so 530 of 564 units have energy figures.
- **Check:** `indicator_issues` ('source units not found among the
  planning units').

### 84. Heat demand is not always heating plus hot water

- **Status:** flagged.
- **What:** everywhere else `s_mwth` = `sotopl` + `s_bgv`, but in 16
  (unit, scenario) pairs it is not: 13 units in the optimistic 2050,
  off by up to 5,300 MWh in either direction, and one small unit in
  all three 2050 scenarios. In 2017 the sources of heat (without
  rooftop solar, which is electricity) add up to 97.8 % of the city's
  demand; the rest is presumably wood, which has no field.
- **Handling:** the values are kept as given.
  **Check:** `indicator_issues` ('heat demand is not heating plus
  hot water').

### 85. District heating supplies more than the heat demand

- **Status:** flagged.
- **What:** district heating (`stec`) is one of the sources of the
  heat demand, yet it is above the demand in 38 units in 2017, 29 in
  2030, 20 in 2040 and 12 in 2050, up to 11 times; 4 units have
  district heating and no demand at all. Probably the district heat
  includes offices, schools and other non-residential buildings,
  while the demand is that of the homes.
- **Handling:** the values are kept as given, so the district heating
  share on the map can be above 100 %.
  **Check:** `indicator_issues` ('district heating supplies more than
  the heat demand').
