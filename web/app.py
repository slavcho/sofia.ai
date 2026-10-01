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
from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, Response

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")
HERE = Path(__file__).resolve().parent

app = FastAPI(title="sofia.ai")


def json_query(sql: str, params: dict | None = None) -> Response:
    """Run a query that returns one json value as text, and pass it through.

    Building the JSON in PostGIS avoids parsing and re-serialising every
    geometry in Python.
    """
    with psycopg.connect(DSN, options="-c search_path=city,public") as conn:
        (body,) = conn.execute(sql, params or {}).fetchone()
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
