# Data issues

Problems found in the source data of https://urbandata.sofia.bg/, one entry
per kind of problem. Single rows that show the problem are listed by the
issue views in the database (`city.metro_issues`, `city.area_issues`,
`city.park_issues`, `city.education_issues`); this
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
