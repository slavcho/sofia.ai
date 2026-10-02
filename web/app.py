"""Map UI and GeoJSON API over the curated city.* schema.

Run from the repository root:
    uvicorn web.app:app --reload
then open http://127.0.0.1:8000/

The database connection is the same as load_db.py: $DATABASE_URL, or the
local default with the password taken from ~/.pgpass.
"""

import os
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Path as PathParam, Query
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")
HERE = Path(__file__).resolve().parent

app = FastAPI(title="sofia.ai")
# Only web/static, so that the app's own source is not served.
app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")


def json_query(sql: str, params: dict | None = None) -> Response:
    """Run a query that returns one json value as text, and pass it through.

    Building the JSON in PostGIS avoids parsing and re-serialising every
    geometry in Python.
    """
    with psycopg.connect(DSN, options="-c search_path=city,public") as conn:
        (body,) = conn.execute(sql, params or {}).fetchone()
    if body is None:
        raise HTTPException(404)
    return Response(content=body, media_type="application/json")


def feature_collection(features_sql: str) -> str:
    """Wrap a query whose rows have a `feature` json column."""
    return f"""
        SELECT json_build_object(
                   'type', 'FeatureCollection',
                   'features', coalesce(json_agg(t.feature), '[]'))::text
          FROM ({features_sql}) t
    """


@app.get("/")
def index():
    return FileResponse(HERE / "index.html")


@app.get("/api/metro/lines")
def metro_lines():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'code', l.code, 'name', l.name, 'color', l.color,
                   'opened', l.opened, 'source', l.source,
                   'stations', (SELECT count(*) FROM metro_station_lines sl
                                 WHERE sl.line_code = l.code))
                   ORDER BY l.code), '[]')::text
          FROM metro_lines l
    """)


@app.get("/api/metro/stations")
def metro_stations(shape: str = Query("point", pattern="^(point|outline)$")):
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', s.id,
                   'geometry', ST_AsGeoJSON(CASE WHEN %(outline)s THEN s.outline
                                                 ELSE s.point END, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'code', s.code, 'name', s.name,
                       'status', s.status,
                       'lines', coalesce(l.lines, '{}'),
                       'color', coalesce(l.color, '#8a8f98'),
                       'entrances', e.n, 'wheelchair_entrances', e.wheelchair,
                       'area_m2', s.area_m2, 'name_source', s.name_source,
                       'data_as_of', s.data_as_of,
                       'source', s.source_dataset || ' #' || s.source_fid)) AS feature
          FROM metro_stations s
          LEFT JOIN LATERAL (
               SELECT array_agg(ml.code ORDER BY ml.code) AS lines,
                      (array_agg(ml.color ORDER BY ml.code))[1] AS color
                 FROM metro_station_lines sl
                 JOIN metro_lines ml ON ml.code = sl.line_code
                WHERE sl.station_id = s.id) l ON true
          LEFT JOIN LATERAL (
               SELECT count(*) AS n,
                      count(*) FILTER (WHERE en.wheelchair = 'yes') AS wheelchair
                 FROM metro_entrances en
                WHERE en.station_id = s.id) e ON true
         ORDER BY s.id
    """), {"outline": shape == "outline"})


@app.get("/api/metro/entrances")
def metro_entrances():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', e.id,
                   'geometry', ST_AsGeoJSON(e.geom, 6)::json,
                   'properties', json_build_object(
                       'id', e.id, 'station_id', e.station_id,
                       'station_name', e.station_name, 'name', e.name,
                       'wheelchair', coalesce(e.wheelchair, 'unknown'),
                       'access_note', e.access_note,
                       'distance_m', e.distance_m,
                       'data_as_of', e.data_as_of,
                       'source', e.source_dataset || ' #' || e.source_fid)) AS feature
          FROM metro_entrances e
         ORDER BY e.id
    """))


@app.get("/api/metro/tracks")
def metro_tracks():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', t.id,
                   'geometry', ST_AsGeoJSON(t.geom, 6)::json,
                   'properties', json_build_object(
                       'id', t.id, 'status', t.status, 'length_m', t.length_m,
                       'data_as_of', t.data_as_of,
                       'source', t.source_dataset || ' #' || t.source_fid)) AS feature
          FROM metro_tracks t
         ORDER BY t.id
    """))


@app.get("/api/metro/issues")
def metro_issues():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail,
                   'station_id', i.station_id, 'entrance_id', i.entrance_id,
                   'lon', round(ST_X(p.geom)::numeric, 6),
                   'lat', round(ST_Y(p.geom)::numeric, 6))
                   ORDER BY i.issue, i.station_id, i.entrance_id), '[]')::text
          FROM metro_issues i
          LEFT JOIN metro_stations s ON s.id = i.station_id
          LEFT JOIN metro_entrances e ON e.id = i.entrance_id
          CROSS JOIN LATERAL (SELECT coalesce(s.point, e.geom) AS geom) p
    """)


@app.get("/api/metro/stations/{station_id}/catchment")
def metro_station_catchment(station_id: int):
    return json_query("""
        SELECT (SELECT row_to_json(c) FROM station_catchment c
                 WHERE c.station_id = %(id)s)::text
    """, {"id": station_id})


@app.get("/api/parks")
def parks():
    # Simplified to about 5 m, as the areas.
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(p.outline, 0.00005), 6)::json,
                   'properties', json_build_object(
                       'id', p.id, 'name', p.name, 'name_source', p.name_source,
                       'kind', coalesce(p.kind, 'unclassified'), 'zone_code', p.zone_code,
                       'status', p.status, 'realization', p.realization,
                       'area_m2', p.area_m2, 'tree_cover_pct', p.tree_cover_pct,
                       'entrances', (SELECT count(*) FROM park_entrances e WHERE e.park_id = p.id),
                       'data_as_of', p.data_as_of,
                       'source', p.source_dataset || ' #' || p.source_fid)) AS feature
          FROM parks p
         ORDER BY p.area_m2 DESC
    """))


@app.get("/api/parks/entrances")
def park_entrances():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', e.id,
                   'geometry', ST_AsGeoJSON(e.geom, 6)::json,
                   'properties', json_build_object(
                       'id', e.id, 'park_id', e.park_id, 'park_name', p.name,
                       'park_status', p.status,
                       'kind', coalesce(e.kind, 'unknown'), 'reglament', e.reglament,
                       'note', e.note, 'distance_m', e.distance_m,
                       'data_as_of', e.data_as_of,
                       'source', e.source_dataset || ' #' || e.source_fid)) AS feature
          FROM park_entrances e
          LEFT JOIN parks p ON p.id = e.park_id
         ORDER BY e.id
    """))


@app.get("/api/parks/issues")
def park_issues():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail,
                   'park_id', i.park_id, 'park_entrance_id', i.entrance_id,
                   'lon', round(ST_X(g.geom)::numeric, 6),
                   'lat', round(ST_Y(g.geom)::numeric, 6))
                   ORDER BY i.issue, i.park_id, i.entrance_id), '[]')::text
          FROM park_issues i
          LEFT JOIN parks p ON p.id = i.park_id
          LEFT JOIN park_entrances e ON e.id = i.entrance_id
          CROSS JOIN LATERAL (SELECT coalesce(ST_PointOnSurface(p.outline), e.geom) AS geom) g
    """)


@app.get("/api/kindergartens")
def kindergartens():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', k.id,
                   'geometry', ST_AsGeoJSON(k.geom, 6)::json,
                   'properties', json_build_object(
                       'id', k.id, 'name', k.name, 'number', k.number, 'kind', k.kind,
                       'funding', coalesce(k.funding, 'unknown'), 'funding_code', k.funding_code,
                       'is_branch', k.is_branch, 'status', k.status, 'note', k.note,
                       'address', k.address, 'district_code', k.district_code,
                       'details_url', k.details_url, 'groups', k.groups, 'children', k.children,
                       'nursery_children', k.nursery_children,
                       'data_as_of', k.data_as_of,
                       'source', k.source_dataset || ' #' || k.source_fid)) AS feature
          FROM kindergartens k
         ORDER BY k.id
    """))


@app.get("/api/schools")
def schools():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', s.id,
                   'geometry', ST_AsGeoJSON(s.geom, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'name', s.name, 'number', s.number, 'admin_code', s.admin_code,
                       'kind', s.kind, 'funding', coalesce(s.funding, 'unknown'),
                       'funding_code', s.funding_code, 'class_count', s.class_count,
                       'note', s.note, 'address', s.address, 'district_code', s.district_code,
                       'details_url', s.details_url,
                       'data_as_of', s.data_as_of,
                       'source', s.source_dataset || ' #' || s.source_fid)) AS feature
          FROM schools s
         ORDER BY s.id
    """))


@app.get("/api/education/issues")
def education_issues():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail,
                   'kindergarten_id', i.kindergarten_id, 'school_id', i.school_id,
                   'lon', round(ST_X(g.geom)::numeric, 6),
                   'lat', round(ST_Y(g.geom)::numeric, 6))
                   ORDER BY i.issue, i.kindergarten_id, i.school_id), '[]')::text
          FROM education_issues i
          LEFT JOIN kindergartens k ON k.id = i.kindergarten_id
          LEFT JOIN schools s ON s.id = i.school_id
          CROSS JOIN LATERAL (SELECT coalesce(k.geom, s.geom) AS geom) g
    """)


@app.get("/api/schools/catchment-issues")
def school_catchment_issues():
    # Placed at the school; the list school with no 2018 school has no place.
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail, 'school_id', c.school_id,
                   'lon', round(ST_X(s.geom)::numeric, 6),
                   'lat', round(ST_Y(s.geom)::numeric, 6))
                   ORDER BY i.issue, i.list_id, i.district_code, i.street), '[]')::text
          FROM catchment_issues i
          JOIN catchment_schools c ON c.list_id = i.list_id
          LEFT JOIN schools s ON s.id = c.school_id
    """)


@app.get("/api/schools/{school_id}/catchment")
def school_catchment(school_id: int):
    # The list's addresses of the school (one point per address point) and
    # the 2019 children in the buildings that take them.
    return json_query("""
        SELECT (SELECT json_build_object(
                    'list_name', c.name, 'match', c.match,
                    'addresses', c.addresses, 'located', c.located,
                    'buildings', k.buildings, 'children', k.children,
                    'median_distance_m', k.median_distance_m,
                    'buildings_nearest', k.buildings_nearest,
                    'data_as_of', c.data_as_of, 'source', c.source_dataset,
                    'points', (SELECT coalesce(json_agg(json_build_array(
                                         round(ST_X(p.geom)::numeric, 6), round(ST_Y(p.geom)::numeric, 6))), '[]')
                                 FROM (SELECT DISTINCT ON (a.address_fid) a.geom FROM catchment_addresses a
                                        WHERE a.list_school_id = c.list_id AND a.geom IS NOT NULL
                                        ORDER BY a.address_fid) p))
                  FROM catchment_schools c
                  JOIN catchment_school_children k ON k.list_id = c.list_id
                 WHERE c.school_id = %(id)s
                 ORDER BY c.list_id LIMIT 1)::text
    """, {"id": school_id})


# Area kinds: table, key column, the table linking the area to the
# districts it lies in (none for a district), and kind-specific fields.
AREAS = {
    "district": {
        "table": "districts", "key": "code", "links": None,
        "extra": """json_build_object('name_latin', a.name_latin,
                        'population_nsi', a.population_nsi,
                        'boundary_diff_km2', a.boundary_diff_km2)""",
    },
    "neighbourhood": {
        "table": "neighbourhoods", "key": "id",
        "links": ("neighbourhood_districts", "neighbourhood_id"),
        "extra": "json_build_object('kind', a.kind, 'type_code', a.type_code)",
    },
    "planning_unit": {
        "table": "planning_units", "key": "id",
        "links": ("planning_unit_districts", "planning_unit_id"),
        "extra": "json_build_object('district_label', a.district_label)",
    },
}
AREA_KIND = "^(district|neighbourhood|planning_unit)$"


@app.get("/api/areas/issues")
def area_issues():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail, 'name', i.name,
                   'area_kind', i.area_kind, 'area_id', i.area_id)
                   ORDER BY i.issue, i.area_kind, i.area_id), '[]')::text
          FROM area_issues i
         WHERE i.area_kind IN ('district', 'neighbourhood', 'planning_unit')
    """)


@app.get("/api/areas/{kind}")
def areas(kind: str = PathParam(pattern=AREA_KIND)):
    a = AREAS[kind]
    # Simplified to about 5 m: the planning units are 3 MB of GeoJSON in
    # full detail, 0.8 MB simplified, with no visible difference.
    return json_query(feature_collection(f"""
        SELECT json_build_object(
                   'type', 'Feature',
                   'id', a.{a['key']}::integer,
                   'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(a.geom, 0.00005), 5)::json,
                   'properties', json_build_object(
                       'id', a.{a['key']}::text, 'name', a.name,
                       'population', a.population, 'area_km2', a.area_km2,
                       'density', round(a.population / nullif(a.area_km2, 0)),
                       'share_500', m.share_500, 'share_1000', m.share_1000,
                       'planned_share_500', m.planned_share_500,
                       'planned_share_1000', m.planned_share_1000,
                       'gain_500', m.planned_share_500 - m.share_500,
                       'park_share_300', k.share_300, 'park_share_800', k.share_800,
                       'city_park_share_800', k.city_park_share_800,
                       'sofiaplan_park_share', g.sofiaplan_share,
                       'kindergarten_share_500', e.kindergarten_share_500,
                       'municipal_kindergarten_share_500', e.municipal_kindergarten_share_500,
                       'school_share_800', e.school_share_800,
                       'registered_per_child', e.registered_per_child,
                       'sofiaplan_school_share_800', s.sofiaplan_share_800,
                       'assigned_school_share_800', c.assigned_share_800,
                       'assigned_farther_share', c.assigned_farther_share)) AS feature
          FROM {a['table']} a
          LEFT JOIN area_metro_access m
                 ON m.area_kind = %(kind)s AND m.area_id = a.{a['key']}::text
          LEFT JOIN area_park_access k
                 ON k.area_kind = %(kind)s AND k.area_id = a.{a['key']}::text
          LEFT JOIN park_access_agreement g
                 ON g.area_kind = %(kind)s AND g.area_id = a.{a['key']}::text
          LEFT JOIN area_education_access e
                 ON e.area_kind = %(kind)s AND e.area_id = a.{a['key']}::text
          LEFT JOIN school_access_agreement s
                 ON s.area_kind = %(kind)s AND s.area_id = a.{a['key']}::text
          LEFT JOIN area_school_catchment c
                 ON c.area_kind = %(kind)s AND c.area_id = a.{a['key']}::text
         ORDER BY a.{a['key']}
    """), {"kind": kind})


@app.get("/api/areas/{kind}/{area_id}")
def area(kind: str = PathParam(pattern=AREA_KIND), area_id: str = PathParam(pattern=r"^\d+$")):
    a = AREAS[kind]
    if a["links"]:
        links, fk = a["links"]
        districts = f"""(SELECT json_agg(json_build_object(
                             'code', x.district_code, 'name', d.name,
                             'share', x.share, 'population', x.population,
                             'main', x.district_code = a.district_code)
                             ORDER BY x.share DESC)
                           FROM {links} x JOIN districts d ON d.code = x.district_code
                          WHERE x.{fk} = a.id)"""
    else:
        districts = "NULL"
    return json_query(f"""
        SELECT (SELECT json_build_object(
                    'kind', %(kind)s::text, 'id', a.{a['key']}::text,
                    'name', a.name,
                    'population', a.population, 'area_km2', a.area_km2,
                    'density', round(a.population / nullif(a.area_km2, 0)),
                    'extra', {a['extra']},
                    'access', (SELECT row_to_json(m) FROM area_metro_access m
                                WHERE m.area_kind = %(kind)s AND m.area_id = a.{a['key']}::text),
                    'park_access', (SELECT row_to_json(k) FROM area_park_access k
                                     WHERE k.area_kind = %(kind)s AND k.area_id = a.{a['key']}::text),
                    'park_agreement', (SELECT row_to_json(g) FROM park_access_agreement g
                                        WHERE g.area_kind = %(kind)s AND g.area_id = a.{a['key']}::text),
                    'education_access', (SELECT row_to_json(e) FROM area_education_access e
                                          WHERE e.area_kind = %(kind)s AND e.area_id = a.{a['key']}::text),
                    'school_agreement', (SELECT row_to_json(s) FROM school_access_agreement s
                                          WHERE s.area_kind = %(kind)s AND s.area_id = a.{a['key']}::text),
                    'school_catchment', (SELECT row_to_json(c) FROM area_school_catchment c
                                          WHERE c.area_kind = %(kind)s AND c.area_id = a.{a['key']}::text),
                    'districts', {districts},
                    'issues', (SELECT json_agg(json_build_object('issue', i.issue, 'detail', i.detail))
                                 FROM area_issues i
                                WHERE i.area_kind = %(kind)s AND i.area_id = a.{a['key']}::text),
                    'bbox', json_build_array(ST_XMin(a.geom), ST_YMin(a.geom),
                                             ST_XMax(a.geom), ST_YMax(a.geom)),
                    'data_as_of', a.data_as_of,
                    'source', a.source_dataset || ' #' || a.source_fid)
                  FROM {a['table']} a
                 WHERE a.{a['key']}::text = %(id)s)::text
    """, {"kind": kind, "id": area_id})
