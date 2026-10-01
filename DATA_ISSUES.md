# Data issues

Problems found in the source data of https://urbandata.sofia.bg/, one entry
per kind of problem. Single rows that show the problem are listed by the
issue views in the database (`city.metro_issues`, `city.area_issues`); this
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
