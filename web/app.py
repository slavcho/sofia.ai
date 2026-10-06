"""Map UI and GeoJSON API over the curated city.* schema.

Run from the repository root:
    uvicorn web.app:app --reload
then open http://127.0.0.1:8000/

The database connection is the same as load_db.py: $DATABASE_URL, or the
local default with the password taken from ~/.pgpass.
"""

import json
import logging
import os
import re
from pathlib import Path

import psycopg
from fastapi import Body, FastAPI, HTTPException, Path as PathParam, Query
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from web import llm

DSN = os.environ.get("DATABASE_URL", "host=127.0.0.1 dbname=urbandata user=urbanuser")
HERE = Path(__file__).resolve().parent
log = logging.getLogger("uvicorn.error")

app = FastAPI(title="sofia.ai")
# The GeoJSON compresses about tenfold (the public transport stops are 1.5 MB).
app.add_middleware(GZipMiddleware, minimum_size=1000)
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


# The focuses: ready-made views of the map. The built-in ones are kept in
# focuses.json, read on every request so that an edit shows on reload.
# Only their shape is checked here; whether their layers, metrics and
# lists exist is checked by the page (checkFocus in focuses.js), which
# knows them.
BUILTIN_FOCUSES = HERE / "focuses.json"
FOCUS_ID = re.compile(r"^[a-z0-9-]{1,64}$")


def focus_problems(f) -> list[str]:
    """What is wrong with the shape of a focus; empty if nothing."""
    if not isinstance(f, dict):
        return ["not an object"]
    errors = []
    if not isinstance(f.get("id"), str) or not FOCUS_ID.match(f["id"]):
        errors.append("needs an id of lowercase letters, digits and dashes")
    if not isinstance(f.get("title"), str) or not f["title"]:
        errors.append("needs a title")
    for key in ("category", "question", "list", "listScope", "drawer", "panel"):
        if f.get(key) is not None and not isinstance(f[key], str):
            errors.append(f"{key} is not a string")
    if not isinstance(f.get("layers"), list) or not all(isinstance(k, str) for k in f["layers"]):
        errors.append("layers is not a list of strings")
    areas = f.get("areas")
    if areas is not None and not (isinstance(areas, dict) and isinstance(areas.get("kind"), str)
                                  and isinstance(areas.get("metric", ""), str)):
        errors.append("areas needs a kind and a metric")
    zoom = f.get("minZoom")
    if zoom is not None and (isinstance(zoom, bool) or not isinstance(zoom, (int, float))):
        errors.append("minZoom is not a number")
    return errors


def stored_focuses(conn) -> list[tuple[str, dict]]:
    """The focuses in app.focuses shown to everyone, as (id, definition)."""
    return conn.execute("""
        SELECT id, definition FROM app.focuses
         WHERE owner IS NULL
         ORDER BY created_at, id
    """).fetchall()


def merge_focuses(builtin: list[dict], stored: list[tuple[str, dict]]) -> list[dict]:
    """The built-in focuses, then the stored ones that neither take a
    built-in id nor are badly shaped; those are logged and left out."""
    taken = {f["id"] for f in builtin}
    merged = list(builtin)
    for id, definition in stored:
        f = {**definition, "id": id}
        problems = ["takes the id of a built-in focus"] if id in taken else focus_problems(f)
        if problems:
            log.warning("focus %s left out: %s", id, "; ".join(problems))
            continue
        merged.append(f)
    return merged


# Without the database, or without the app schema, the built-in focuses
# are still served, so the page always has its menu.
@app.get("/api/focuses")
def focuses():
    doc = json.loads(BUILTIN_FOCUSES.read_text())
    try:
        with psycopg.connect(DSN) as conn:
            stored = stored_focuses(conn)
    except (psycopg.OperationalError, psycopg.errors.UndefinedTable) as e:
        log.warning("only the built-in focuses: %s", e)
        stored = []
    return {**doc, "focuses": merge_focuses(doc["focuses"], stored)}


CHAT_ITEMS = {"message", "function_call", "function_call_output", "reasoning"}
MAX_CHAT_ITEMS = 1000


def chat_problems(items) -> list[str]:
    """What is wrong with a conversation sent by the page; empty if
    nothing. Only items the page got from us, or the user's own messages,
    may be in it: a system or developer message would override the prompt."""
    if not isinstance(items, list) or not items:
        return ["input is not a list of items"]
    if len(items) > MAX_CHAT_ITEMS:
        return [f"the conversation has more than {MAX_CHAT_ITEMS} items; start a new one"]
    errors = []
    for i, item in enumerate(items):
        kind = item.get("type", "message") if isinstance(item, dict) else None
        if kind not in CHAT_ITEMS:
            errors.append(f"item {i} is not one of {', '.join(sorted(CHAT_ITEMS))}")
        elif kind == "message" and item.get("role") not in ("user", "assistant"):
            errors.append(f"item {i} is a message from neither the user nor the assistant")
    last = items[-1]
    if not (isinstance(last, dict) and last.get("type", "message") == "message" and last.get("role") == "user"):
        errors.append("the last item is not the user's message")
    return errors


MAX_CATALOG = 20_000     # characters; it goes into every prompt


def catalog_problems(catalog) -> list[str]:
    """What is wrong with the page's account of what its map can show
    (see llm.catalog_section); empty if nothing."""
    if not isinstance(catalog, dict):
        return ["catalog is not an object"]
    strings = lambda v: isinstance(v, list) and all(isinstance(x, str) for x in v)
    entry = lambda x: (isinstance(x, dict) and isinstance(x.get("key"), str)
                       and isinstance(x.get("label"), str)
                       and (x.get("kinds") is None or strings(x["kinds"])))
    errors = [f"catalog {name} is not a list of keys with labels"
              for name in ("layers", "metrics", "lists")
              if not (isinstance(catalog.get(name, []), list) and all(map(entry, catalog.get(name, []))))]
    if not strings(catalog.get("area_kinds", [])):
        errors.append("catalog area_kinds is not a list of strings")
    if len(json.dumps(catalog, ensure_ascii=False)) > MAX_CATALOG:
        errors.append(f"catalog is longer than {MAX_CATALOG} characters")
    return errors


# One turn of the chat, as server-sent events (see llm.run_turn); the
# page keeps the conversation and sends all of it every time.
@app.post("/api/chat")
def chat(body: dict = Body(...)):
    items = body.get("input")
    catalog = body.get("catalog")
    problems = chat_problems(items) + (catalog_problems(catalog) if catalog is not None else [])
    if problems:
        raise HTTPException(400, "; ".join(problems))

    def events():
        try:
            for event in llm.run_turn(items, catalog=catalog):
                yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"
        except Exception as e:
            log.exception("chat turn failed")
            yield f"data: {json.dumps({'type': 'error', 'message': f'the server failed: {e}'})}\n\n"

    # The events must reach the page as they come, not when the turn ends.
    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


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
                       'property', p.category,
                       -- the city's catchment (2026); children NULL where
                       -- the 2019 residents do not reach (DATA_ISSUES #41)
                       'catchment_addresses', c.addresses,
                       'catchment_buildings', NULLIF(k.buildings, 0),
                       'catchment_children', CASE WHEN k.buildings > 0 THEN k.children END,
                       'catchment_median_m', k.median_distance_m,
                       'catchment_nearest_share', round(k.buildings_nearest::numeric / NULLIF(k.buildings, 0), 3),
                       'data_as_of', s.data_as_of,
                       'source', s.source_dataset || ' #' || s.source_fid)) AS feature
          FROM schools s
          LEFT JOIN catchment_schools c ON c.school_id = s.id
          LEFT JOIN catchment_school_children k ON k.list_id = c.list_id
          LEFT JOIN school_property p ON p.school_id = s.id
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


# Departures per hour in the windows of transit_access.sql: weekday
# 07-09 and 20-23, weekend 10-18, weekday nights 01-04.
TRANSIT_WINDOWS = """
    round(sum(departures) FILTER (WHERE day = 'weekday' AND hour BETWEEN 7 AND 8) / 2.0, 1) AS peak_per_hour,
    round(sum(departures) FILTER (WHERE day = 'weekday' AND hour BETWEEN 20 AND 22) / 3.0, 1) AS evening_per_hour,
    round(sum(departures) FILTER (WHERE day = 'saturday' AND hour BETWEEN 10 AND 17) / 8.0, 1) AS saturday_per_hour,
    round(sum(departures) FILTER (WHERE day = 'sunday' AND hour BETWEEN 10 AND 17) / 8.0, 1) AS sunday_per_hour,
    round(sum(departures) FILTER (WHERE day = 'weekday' AND hour BETWEEN 1 AND 3) / 3.0, 1) AS night_per_hour
"""


@app.get("/api/transit/stops")
def transit_stops():
    # Every stop in the timetable, the never served ones too (they are a
    # data issue); the lines are those calling on any reference day.
    return json_query(feature_collection(f"""
        SELECT json_build_object(
                   'type', 'Feature',
                   'geometry', ST_AsGeoJSON(s.geom, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'code', s.code, 'name', s.name, 'modes', s.modes,
                       'served', s.served, 'metro_station_id', s.metro_station_id,
                       'peak_per_hour', coalesce(h.peak_per_hour, 0),
                       'evening_per_hour', coalesce(h.evening_per_hour, 0),
                       'saturday_per_hour', coalesce(h.saturday_per_hour, 0),
                       'sunday_per_hour', coalesce(h.sunday_per_hour, 0),
                       'night_per_hour', coalesce(h.night_per_hour, 0),
                       'routes', coalesce(r.names, '[]'),
                       'data_as_of', s.data_as_of, 'source', s.source_dataset)) AS feature
          FROM transit_stops s
          LEFT JOIN (SELECT stop_id, {TRANSIT_WINDOWS} FROM transit_stop_hours GROUP BY stop_id) h
                 ON h.stop_id = s.id
          LEFT JOIN LATERAL (
                SELECT json_agg(t.name ORDER BY t.mode, length(t.name), t.name) AS names
                  FROM transit_routes t
                 WHERE t.id IN (SELECT unnest(x.route_ids) FROM transit_stop_hours x WHERE x.stop_id = s.id)
          ) r ON true
         ORDER BY s.id
    """))


@app.get("/api/transit/routes")
def transit_routes():
    # Simplified to about 10 m; the lines without trips have no shape.
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(r.geom, 0.0001), 5)::json,
                   'properties', json_build_object(
                       'id', r.id, 'name', r.name, 'long_name', r.long_name, 'mode', r.mode,
                       'color', '#' || coalesce(r.color, '9aa0a8'),
                       'text_color', '#' || coalesce(r.text_color, 'ffffff'),
                       'night', r.night, 'trips_weekday', r.trips_weekday,
                       'trips_saturday', r.trips_saturday, 'trips_sunday', r.trips_sunday,
                       'data_as_of', r.data_as_of, 'source', r.source_dataset)) AS feature
          FROM transit_routes r
         WHERE r.geom IS NOT NULL
         ORDER BY r.mode, length(r.name), r.name
    """))


@app.get("/api/live/vehicles")
def live_vehicles():
    # The vehicles of the latest successful fetch (poll_live.py), each with
    # its latest report of the 3 minutes before it: one that has not
    # reported for longer has left service or lost its signal. The delay
    # is the latest prediction for the stop it is heading to, less the
    # timetable.
    body = json_query("""
        WITH f AS (SELECT max(fetched_at) AS at FROM live.fetches
                    WHERE feed = 'vehicle-positions' AND error IS NULL),
        v AS (SELECT DISTINCT ON (p.vehicle_id) p.*
                FROM live.vehicle_positions p, f
               WHERE p.recorded_at > f.at - interval '3 minutes' AND p.recorded_at <= f.at + interval '1 minute'
               ORDER BY p.vehicle_id, p.recorded_at DESC)
        SELECT json_build_object(
                   'type', 'FeatureCollection',
                   'fetched_at', (SELECT at FROM f),
                   'features', coalesce(json_agg(json_build_object(
                       'type', 'Feature',
                       'geometry', json_build_object('type', 'Point',
                                                     'coordinates', json_build_array(round(v.lon::numeric, 6), round(v.lat::numeric, 6))),
                       'properties', json_build_object(
                           'id', v.vehicle_id, 'route_id', v.route_id, 'trip_id', v.trip_id,
                           'line', r.name, 'long_name', r.long_name, 'mode', r.mode, 'night', r.night,
                           'color', '#' || coalesce(r.color, '9aa0a8'),
                           'stop_id', v.stop_id, 'stop', s.stop_name, 'status', v.status,
                           'speed', v.speed, 'occupancy', v.occupancy, 'congestion', v.congestion,
                           'recorded_at', v.recorded_at,
                           'delay_s', extract(epoch FROM a.last_predicted - a.scheduled)::integer,
                           'scheduled', a.scheduled, 'predicted', a.last_predicted)
                   ) ORDER BY r.mode, v.vehicle_id), '[]'))::text
          FROM v
          LEFT JOIN transit_routes r ON r.id = v.route_id
          LEFT JOIN gtfs.stops s ON s.stop_id = v.stop_id
          LEFT JOIN LATERAL (SELECT x.last_predicted, x.scheduled FROM live.stop_arrivals x
                              WHERE x.trip_id = v.trip_id AND x.stop_id = v.stop_id
                                AND x.service_date >= (v.recorded_at AT TIME ZONE 'Europe/Sofia')::date - 1
                              ORDER BY x.last_seen DESC LIMIT 1) a ON true
    """)
    # Changes every minute; the browser must not keep it.
    body.headers["Cache-Control"] = "no-store"
    return body


@app.get("/api/transit/stops/{stop_id}")
def transit_stop(stop_id: str = PathParam(pattern=r"^[A-Za-z0-9_-]{1,32}$")):
    # The lines calling here and the departures in each clock hour of the
    # reference days (by line, for the card's timetable).
    return json_query("""
        SELECT (SELECT json_build_object(
                    'id', s.id, 'name', s.name,
                    'days', (SELECT json_object_agg(d.day, d.date) FROM transit_days d),
                    'routes', (SELECT json_agg(json_build_object(
                                   'id', r.id, 'name', r.name, 'mode', r.mode,
                                   'color', '#' || coalesce(r.color, '9aa0a8'),
                                   'text_color', '#' || coalesce(r.text_color, 'ffffff'),
                                   'headsigns', (SELECT json_agg(DISTINCT x.headsign) FROM transit_departures x
                                                  WHERE x.stop_id = s.id AND x.route_id = r.id),
                                   'weekday', (SELECT count(*) FROM transit_departures x
                                                WHERE x.stop_id = s.id AND x.route_id = r.id AND x.day = 'weekday'))
                                   ORDER BY r.mode, length(r.name), r.name)
                                 FROM transit_routes r
                                WHERE r.id IN (SELECT unnest(h.route_ids) FROM transit_stop_hours h WHERE h.stop_id = s.id)),
                    'hours', (SELECT json_object_agg(d.day, (
                                  SELECT json_agg(coalesce(h.departures, 0) ORDER BY g.hour)
                                    FROM generate_series(0, 23) g(hour)
                                    LEFT JOIN transit_stop_hours h
                                           ON h.stop_id = s.id AND h.day = d.day AND h.hour = g.hour))
                                FROM transit_days d))
                  FROM transit_stops s
                 WHERE s.id = %(id)s)::text
    """, {"id": stop_id})


@app.get("/api/transit/issues")
def transit_issues():
    # Placed at the stop; the feed's and the lines' issues have no place.
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail,
                   'stop_id', i.stop_id, 'route_id', i.route_id,
                   'lon', round(ST_X(s.geom)::numeric, 6),
                   'lat', round(ST_Y(s.geom)::numeric, 6))
                   ORDER BY i.issue, i.stop_id, i.route_id), '[]')::text
          FROM transit_issues i
          LEFT JOIN transit_stops s ON s.id = i.stop_id
    """)


@app.get("/api/buildings/tiles/{z}/{x}/{y}.pbf")
def building_tiles(z: int = PathParam(ge=15, le=22), x: int = PathParam(ge=0), y: int = PathParam(ge=0)):
    # 265,000 outlines are too many for one GeoJSON, so vector tiles,
    # drawn from zoom 15 (a zoom 14 tile is 250 kB). The panel blocks, renovations and BREEAM
    # certificates are flags here; the card has the details.
    with psycopg.connect(DSN, options="-c search_path=city,public") as conn:
        (body,) = conn.execute("""
            WITH t AS (SELECT ST_TileEnvelope(%(z)s, %(x)s, %(y)s) AS env),
            b AS (
              SELECT b.id, b.category, b.floors, b.municipal, b.people_2019,
                     (SELECT sum(c.people) FROM census_addresses c WHERE c.building_id = b.id) AS people_2011,
                     EXISTS (SELECT FROM panel_buildings p WHERE p.building_id = b.id) AS panel,
                     EXISTS (SELECT FROM renovations r WHERE r.building_id = b.id) AS renovated,
                     EXISTS (SELECT FROM breeam_buildings e WHERE e.building_id = b.id) AS breeam,
                     s.shaded_mean,
                     ST_AsMVTGeom(ST_Transform(b.geom, 3857), t.env, 4096, 16) AS geom
                FROM buildings b
               CROSS JOIN t
                LEFT JOIN building_shading s ON s.building_id = b.id
               WHERE b.geom && ST_Transform(t.env, 4326))
            SELECT ST_AsMVT(b, 'buildings', 4096, 'geom', 'id') FROM b
        """, {"z": z, "x": x, "y": y}).fetchone()
    return Response(content=bytes(body or b""), media_type="application/vnd.mapbox-vector-tile",
                     headers={"Cache-Control": "max-age=3600"})


@app.get("/api/master-plan/tiles/{z}/{x}/{y}.pbf")
def master_plan_tiles(z: int = PathParam(ge=11, le=22), x: int = PathParam(ge=0), y: int = PathParam(ge=0)):
    # 12,700 zones are 5.7 MB of GeoJSON, so vector tiles like the buildings.
    with psycopg.connect(DSN, options="-c search_path=city,public") as conn:
        (body,) = conn.execute("""
            WITH t AS (SELECT ST_TileEnvelope(%(z)s, %(x)s, %(y)s) AS env),
            z AS (
              SELECT z.id, z.plan, z.code, z.name, z.zone_group, z.special_rules, z.area_ha,
                     ST_AsMVTGeom(ST_Transform(z.geom, 3857), t.env, 4096, 16) AS geom
                FROM master_plan_zones z
               CROSS JOIN t
               WHERE z.geom && ST_Transform(t.env, 4326))
            SELECT ST_AsMVT(z, 'zones', 4096, 'geom', 'id') FROM z
        """, {"z": z, "x": x, "y": y}).fetchone()
    return Response(content=bytes(body or b""), media_type="application/vnd.mapbox-vector-tile",
                     headers={"Cache-Control": "max-age=3600"})


# One zone with its outline and the district it is mostly in, for the card.
@app.get("/api/master-plan/zones/{zone_id}")
def master_plan_zone(zone_id: int):
    return json_query("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', z.id,
                   'geometry', ST_AsGeoJSON(z.geom, 6)::json,
                   'properties', json_build_object(
                       'id', z.id, 'plan', z.plan, 'code', z.code, 'name', z.name,
                       'zone_group', z.zone_group, 'special_rules', z.special_rules,
                       'area_ha', z.area_ha,
                       'district', (SELECT d.name FROM districts d
                                     WHERE ST_Intersects(d.geom, ST_PointOnSurface(z.geom)) LIMIT 1),
                       'data_as_of', z.data_as_of,
                       'source', z.source_dataset || ' #' || z.source_fid))::text
          FROM master_plan_zones z WHERE z.id = %(id)s
    """, {"id": zone_id})


@app.get("/api/buildings/{building_id}")
def building(building_id: int):
    # One outline of the cadastral plan with everything tied to it: the
    # 2019 buildings, the 2011 census addresses, panel block, renovation,
    # BREEAM certificate, shading and data issues.
    return json_query("""
        SELECT (SELECT json_build_object(
                    'id', b.id, 'function', b.function, 'category', b.category,
                    'ownership', b.ownership, 'municipal', b.municipal,
                    'municipal_part', b.municipal_part,
                    'floors', b.floors, 'floors_text', b.floors_text,
                    'footprint_m2', b.footprint_m2, 'region_label', b.region_label,
                    'district', (SELECT d.name FROM districts d WHERE d.code = b.district_code),
                    'neighbourhood_id', b.neighbourhood_id,
                    'neighbourhood', (SELECT n.name FROM neighbourhoods n WHERE n.id = b.neighbourhood_id),
                    'planning_unit_id', b.planning_unit_id,
                    'sofiaplan', (SELECT json_agg(json_build_object(
                                      'id', s.id, 'match', s.match, 'distance_m', s.distance_m,
                                      'cadastre_ref', s.cadastre_ref, 'people', s.people,
                                      'households', s.households, 'apartments', s.apartments,
                                      'floors', s.floors, 'built_year', s.built_year) ORDER BY s.id)
                                    FROM buildings_2019 s WHERE s.building_id = b.id),
                    'census', (SELECT json_agg(json_build_object(
                                   'id', c.id, 'address', concat_ws(' ', c.street, c.number),
                                   'match', c.match, 'distance_m', c.distance_m,
                                   'people', c.people, 'dwellings', c.dwellings,
                                   'age_0_14', c.age_0_14, 'age_65_plus', c.age_65_plus,
                                   'edu_1', c.edu_1, 'built_year', c.built_year) ORDER BY c.street, c.number)
                                 FROM census_addresses c WHERE c.building_id = b.id),
                    'panel', (SELECT json_agg(json_build_object(
                                  'system', p.panel_system, 'people', p.people,
                                  'apartments', p.apartments, 'floors', p.floors))
                                FROM panel_buildings p WHERE p.building_id = b.id),
                    'renovations', (SELECT json_agg(json_build_object(
                                        'id', r.id, 'status', r.status, 'stage', r.stage,
                                        'address', r.address, 'association', r.association,
                                        'match', r.match))
                                      FROM renovations r WHERE r.building_id = b.id),
                    'breeam', (SELECT json_agg(json_build_object(
                                   'name', e.name, 'title', e.title, 'stage', e.stage,
                                   'distance_m', e.distance_m))
                                 FROM breeam_buildings e WHERE e.building_id = b.id),
                    'shading', (SELECT row_to_json(s) FROM building_shading s WHERE s.building_id = b.id),
                    'issues', (SELECT json_agg(json_build_object('issue', i.issue, 'detail', i.detail))
                                 FROM building_issues i WHERE i.cadastre_id = b.id),
                    'bbox', json_build_array(ST_XMin(b.geom), ST_YMin(b.geom),
                                             ST_XMax(b.geom), ST_YMax(b.geom)),
                    'data_as_of', b.data_as_of,
                    'source', b.source_dataset || ' #' || b.source_fid)
                  FROM buildings b
                 WHERE b.id = %(id)s)::text
    """, {"id": building_id})


@app.get("/api/buildings-issues")
def building_issues():
    # The cadastre's, the census's and the attached registers' issues, at
    # a point; those with an outline open its card.
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail, 'source', i.source,
                   'building_id', i.cadastre_id,
                   'lon', round(ST_X(i.pt)::numeric, 6), 'lat', round(ST_Y(i.pt)::numeric, 6))
                   ORDER BY i.source, i.issue, i.detail), '[]')::text
          FROM (SELECT 'Buildings' AS source, issue, detail, cadastre_id, ST_PointOnSurface(geom) AS pt
                  FROM building_issues
                UNION ALL
                SELECT 'Census 2011', issue, detail, NULL, geom FROM census_issues
                UNION ALL
                SELECT 'Buildings', e.issue, e.detail,
                       (SELECT b.id FROM buildings b WHERE ST_Intersects(b.geom, e.geom) LIMIT 1),
                       ST_PointOnSurface(e.geom)
                  FROM building_extra_issues e) i
    """)


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
                       'assigned_farther_share', c.assigned_farther_share,
                       'transit_share_400', t.transit_share_400,
                       'frequent_share', t.frequent_share,
                       'evening_share', t.evening_share,
                       'saturday_share', t.saturday_share,
                       'sunday_share', t.sunday_share,
                       'night_share', t.night_share,
                       'median_peak_per_hour', t.median_peak_per_hour,
                       'sofiaplan_transit_share_400', t.sofiaplan_transit_share_400,
                       'census_people', n.census_people,
                       'people_per_dwelling', n.people_per_dwelling,
                       'census_share_0_14', n.census_share_0_14,
                       'census_share_65_plus', n.census_share_65_plus,
                       'higher_education_share', n.higher_education_share,
                       'born_abroad_share', n.born_abroad_share,
                       'median_built_year', n.median_built_year,
                       'residents_2019_vs_census', n.residents_2019_vs_census,
                       'residential_mean_floors', b.residential_mean_floors,
                       'floor_area_per_resident', round(b.floor_area_m2 / nullif(a.population, 0)))::jsonb
                   -- a function takes at most 100 arguments, so the rest is a second object
                   || jsonb_build_object(
                       'lights_per_km2', round(l.street_lights / nullif(a.area_km2, 0)),
                       'light_led_share', l.led_share, 'light_poor_share', l.poor_share,
                       'light_not_working_share', l.not_working_share,
                       'plan_residential_share', p.residential_share, 'plan_green_share', p.green_share,
                       'plan_production_share', p.production_share,
                       'playground_share_300', y.playground_share_300,
                       'children_playground_share_300', y.children_playground_share_300,
                       'children_per_playground', y.children_per_playground,
                       'market_share_1000', y.market_share_1000,
                       'tent_camp_m2_per_resident', round(coalesce(tc.area_m2, 0) / nullif(a.population, 0), 2)))
                   AS feature
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
          LEFT JOIN area_transit_access t
                 ON t.area_kind = %(kind)s AND t.area_id = a.{a['key']}::text
          LEFT JOIN area_census n
                 ON n.area_kind = %(kind)s AND n.area_id = a.{a['key']}::text
          LEFT JOIN area_buildings b
                 ON b.area_kind = %(kind)s AND b.area_id = a.{a['key']}::text
          LEFT JOIN area_lighting l
                 ON l.area_kind = %(kind)s AND l.area_id = a.{a['key']}::text
          LEFT JOIN area_amenity_access y
                 ON y.area_kind = %(kind)s AND y.area_id = a.{a['key']}::text
          LEFT JOIN area_tent_camps tc
                 ON tc.area_kind = %(kind)s AND tc.area_id = a.{a['key']}::text
          LEFT JOIN (SELECT area_id,
                            round(sum(area_ha) FILTER (WHERE zone_group IN ('residential', 'central', 'mixed'))
                                  / sum(area_ha), 4) AS residential_share,
                            round(sum(area_ha) FILTER (WHERE zone_group IN ('green', 'forest and nature'))
                                  / sum(area_ha), 4) AS green_share,
                            round(sum(area_ha) FILTER (WHERE zone_group = 'production') / sum(area_ha), 4)
                                  AS production_share
                       FROM area_master_plan WHERE area_kind = %(kind)s GROUP BY area_id) p
                 ON p.area_id = a.{a['key']}::text
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
                    'transit_access', (SELECT row_to_json(t) FROM area_transit_access t
                                        WHERE t.area_kind = %(kind)s AND t.area_id = a.{a['key']}::text),
                    'census', (SELECT row_to_json(n) FROM area_census n
                                WHERE n.area_kind = %(kind)s AND n.area_id = a.{a['key']}::text),
                    'buildings', (SELECT row_to_json(b) FROM area_buildings b
                                   WHERE b.area_kind = %(kind)s AND b.area_id = a.{a['key']}::text),
                    'master_plan', (SELECT json_agg(json_build_object('group', m.zone_group, 'area_ha', m.area_ha)
                                                   ORDER BY m.area_ha DESC)
                                      FROM area_master_plan m
                                     WHERE m.area_kind = %(kind)s AND m.area_id = a.{a['key']}::text),
                    'lighting', (SELECT row_to_json(l) FROM area_lighting l
                                  WHERE l.area_kind = %(kind)s AND l.area_id = a.{a['key']}::text),
                    'amenities', (SELECT row_to_json(y) FROM area_amenity_access y
                                   WHERE y.area_kind = %(kind)s AND y.area_id = a.{a['key']}::text),
                    'tent_camps', (SELECT row_to_json(tc) FROM area_tent_camps tc
                                    WHERE tc.area_kind = %(kind)s AND tc.area_id = a.{a['key']}::text),
                    'indicators', (SELECT json_agg(json_build_object(
                                        'id', i.id, 'label', i.label, 'unit', i.unit, 'theme', i.theme,
                                        'data_as_of', i.data_as_of, 'breakdown', v.breakdown,
                                        'value', round(v.value, 4), 'value_text', v.value_text)
                                        ORDER BY i.theme, i.id, v.breakdown)
                                     FROM planning_unit_indicators v JOIN indicators i ON i.id = v.indicator
                                    WHERE %(kind)s = 'planning_unit'
                                      AND v.planning_unit_id::text = a.{a['key']}::text),
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


# Sofiaplan's analyses by planning unit (indicators.sql).
@app.get("/api/indicators")
def indicators():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'id', i.id, 'label', i.label, 'unit', i.unit, 'theme', i.theme,
                   'description', i.description, 'data_as_of', i.data_as_of,
                   'source', i.source_dataset, 'source_units', i.source_units,
                   'unmatched', i.unmatched,
                   'breakdowns', (SELECT json_agg(DISTINCT v.breakdown)
                                    FROM planning_unit_indicators v WHERE v.indicator = i.id))
                   ORDER BY i.theme, i.id), '[]')::text
          FROM indicators i
    """)


# One indicator's values as {planning unit id: value}, for colouring the
# map. per: divide by another indicator of the same unit, of the same
# breakdown or of none: the forecast for 2030 per resident of 2017, the
# heat from district heating in 2050 per the heat demand of 2050.
@app.get("/api/indicators/{indicator}")
def indicator_values(indicator: str = PathParam(pattern=r"^[a-z0-9_]+$"),
                     breakdown: str = "",
                     per: str = Query("", pattern=r"^[a-z0-9_]*$")):
    return json_query("""
        SELECT CASE WHEN EXISTS (SELECT 1 FROM indicators WHERE id = %(id)s)
               THEN coalesce(json_object_agg(v.planning_unit_id::text,
                        CASE WHEN %(per)s = '' THEN round(v.value, 4)
                             ELSE round(v.value / nullif(d.value, 0), 4) END), '{}')::text END
          FROM planning_unit_indicators v
          LEFT JOIN planning_unit_indicators d
                 ON d.planning_unit_id = v.planning_unit_id AND d.indicator = %(per)s
                AND d.breakdown IN ('', v.breakdown)
         WHERE v.indicator = %(id)s AND v.breakdown = %(breakdown)s AND v.value IS NOT NULL
           AND (%(per)s = '' OR d.value > 0)
    """, {"id": indicator, "breakdown": breakdown, "per": per})


# The census tracts with the census 2011 and the 2019 residents summed by
# address; shares only where at least 20 people were counted.
@app.get("/api/census-tracts")
def census_tracts():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', t.id,
                   'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(t.geom, 0.00002), 5)::json,
                   'properties', json_build_object(
                       'id', t.id, 'district_code', t.district_code, 'area_km2', t.area_km2,
                       'census_addresses', t.census_addresses, 'census_people', t.census_people,
                       'dwellings', t.dwellings, 'age_0_14', t.age_0_14, 'age_65_plus', t.age_65_plus,
                       'residents_2019', t.residents_2019,
                       'share_65_plus', CASE WHEN t.census_people >= 20
                                        THEN round(t.age_65_plus::numeric / t.census_people, 3) END,
                       'density', round(coalesce(t.residents_2019, 0) / nullif(t.area_km2, 0)),
                       'data_as_of', t.data_as_of)) AS feature
          FROM census_tracts t
    """))


# The 2011 census in 1 km cells, only those where people live.
@app.get("/api/population-grid")
def population_grid():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', g.id,
                   'geometry', ST_AsGeoJSON(g.geom, 5)::json,
                   'properties', json_build_object(
                       'id', g.id, 'people', g.people, 'male', g.male, 'female', g.female,
                       'age_0_14', g.age_0_14, 'age_15_64', g.age_15_64, 'age_65_plus', g.age_65_plus,
                       'method', g.method, 'in_sofia', g.in_sofia,
                       'census_address_people', g.census_address_people,
                       'residents_2019', g.residents_2019, 'data_as_of', g.data_as_of)) AS feature
          FROM population_grid g
         WHERE g.people > 0
    """))


@app.get("/api/polling-sections")
def polling_sections():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', s.id::bigint,
                   'geometry', ST_AsGeoJSON(s.geom, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'district_code', s.district_code, 'number', s.number,
                       'place', s.place, 'address', s.address,
                       'residents_2019', s.residents_2019, 'mean_distance_m', s.mean_distance_m,
                       'max_distance_m', s.max_distance_m, 'has_area', s.area IS NOT NULL)) AS feature
          FROM polling_sections s
    """))


# Traction rectifier stations (ТИС) of the trams and trolleybuses.
@app.get("/api/rectifier-stations")
def rectifier_stations():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', s.id,
                   'geometry', ST_AsGeoJSON(s.geom, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'name', s.name, 'built', s.built, 'address', s.address,
                       'district', d.name, 'data_as_of', s.data_as_of,
                       'source', s.source_dataset || ' #' || s.source_fid)) AS feature
          FROM rectifier_stations s LEFT JOIN districts d ON d.code = s.district_code
    """))


# Playgrounds from the municipal register (amenities.sql).
@app.get("/api/playgrounds")
def playgrounds():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', p.id,
                   'geometry', ST_AsGeoJSON(p.geom, 6)::json,
                   'properties', json_build_object(
                       'id', p.id, 'number', p.number, 'location', p.location, 'status', p.status,
                       'measure', p.measure, 'managed_by', p.managed_by, 'ownership', p.ownership,
                       'age_groups', p.age_groups, 'area_m2', p.area_m2, 'area_source', p.area_source,
                       'meets_regulation', p.meets_regulation, 'shade', p.shade, 'built', p.built,
                       'equipment', p.equipment, 'note', p.note, 'district', d.name,
                       'data_as_of', p.data_as_of,
                       'source', p.source_dataset || ' #' || p.source_fid)) AS feature
          FROM playgrounds p LEFT JOIN districts d ON d.code = p.district_code
    """))


# Municipal markets (amenities.sql).
@app.get("/api/markets")
def markets():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', m.id,
                   'geometry', ST_AsGeoJSON(m.geom, 6)::json,
                   'properties', json_build_object(
                       'id', m.id, 'name', m.name, 'operator', m.operator, 'address', m.address,
                       'website', m.website, 'note', m.note, 'district', d.name,
                       'data_as_of', m.data_as_of,
                       'source', m.source_dataset || ' #' || m.source_fid)) AS feature
          FROM markets m LEFT JOIN districts d ON d.code = m.district_code
    """))


# Sites set aside for tent camps (sites.sql).
@app.get("/api/tent-camps")
def tent_camps():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', t.id,
                   'geometry', ST_AsGeoJSON(t.geom, 6)::json,
                   'properties', json_build_object(
                       'id', t.id, 'name', t.name, 'function', t.function, 'area_m2', t.area_m2,
                       'district', d.name, 'data_as_of', t.data_as_of,
                       'source', t.source_dataset || ' #' || t.source_fid)) AS feature
          FROM tent_camp_sites t LEFT JOIN districts d ON d.code = t.district_code
    """))


# Mining concessions, granted and terminated (sites.sql).
@app.get("/api/concessions")
def concessions():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', row_number() OVER (ORDER BY c.id),
                   'geometry', ST_AsGeoJSON(c.geom, 6)::json,
                   'properties', json_build_object(
                       'id', c.id, 'status', c.status, 'deposit', c.deposit, 'resource', c.resource,
                       'resource_group', c.resource_group, 'concessionaire', c.concessionaire,
                       'decision', c.decision, 'contract_date', c.contract_date,
                       'in_force_date', c.in_force_date, 'term', c.term, 'register_no', c.register_no,
                       'note', c.note, 'area_m2', c.area_m2, 'data_as_of', c.data_as_of,
                       'source', c.source_dataset || ' #' || c.source_fid)) AS feature
          FROM concessions c
    """))


# Land taken by the new metro extensions (sites.sql).
@app.get("/api/metro-projects")
def metro_projects():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', m.id,
                   'geometry', ST_AsGeoJSON(m.geom, 6)::json,
                   'properties', json_build_object(
                       'id', m.id, 'project', m.project, 'approval', m.approval, 'area_m2', m.area_m2,
                       'district', d.name, 'data_as_of', m.data_as_of,
                       'source', m.source_dataset || ' #' || m.source_fid)) AS feature
          FROM metro_project_areas m LEFT JOIN districts d ON d.code = m.district_code
    """))


# Construction boundaries of Sofia city and the villages (sites.sql).
@app.get("/api/settlement-boundaries")
def settlement_boundaries():
    return json_query(feature_collection("""
        SELECT json_build_object(
                   'type', 'Feature',
                   'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(s.geom, 0.00005), 5)::json,
                   'properties', json_build_object(
                       'id', s.id, 'kind', s.kind, 'ekatte', s.ekatte, 'area_ha', s.area_ha,
                       'data_as_of', s.data_as_of)) AS feature
          FROM settlement_boundaries s
    """))


# One section with its area, for the card.
@app.get("/api/polling-sections/{section_id}")
def polling_section(section_id: str = PathParam(pattern=r"^\d{9}$")):
    return json_query("""
        SELECT json_build_object(
                   'type', 'Feature', 'id', s.id,
                   'geometry', ST_AsGeoJSON(s.area, 6)::json,
                   'properties', json_build_object(
                       'id', s.id, 'district_code', s.district_code, 'district', d.name,
                       'number', s.number, 'place', s.place, 'address', s.address,
                       'lon', round(ST_X(s.geom)::numeric, 6), 'lat', round(ST_Y(s.geom)::numeric, 6),
                       'place_district', pd.name,
                       'residents_2019', s.residents_2019, 'mean_distance_m', s.mean_distance_m,
                       'max_distance_m', s.max_distance_m, 'data_as_of', s.data_as_of,
                       'area_as_of', s.area_as_of, 'source', s.source_dataset))::text
          FROM polling_sections s
          LEFT JOIN districts d ON d.code = s.district_code
          LEFT JOIN districts pd ON pd.code = s.place_district_code
         WHERE s.id = %(id)s
    """, {"id": section_id})


# The census tracts', the grid's and the polling sections' issues, at a
# point; a polling section's open its card.
@app.get("/api/small-areas/issues")
def small_area_issues():
    return json_query("""
        SELECT coalesce(json_agg(json_build_object(
                   'issue', i.issue, 'detail', i.detail,
                   'source', CASE WHEN i.kind LIKE 'polling%%' THEN 'Elections' ELSE 'Small areas' END,
                   'polling_section_id', CASE WHEN i.kind = 'polling_section' THEN i.id END,
                   'layer', CASE i.kind WHEN 'census_tract' THEN 'census-tracts'
                                        WHEN 'grid' THEN 'population-grid' ELSE 'polling-places' END,
                   'lon', round(ST_X(ST_PointOnSurface(i.geom))::numeric, 6),
                   'lat', round(ST_Y(ST_PointOnSurface(i.geom))::numeric, 6))
                   ORDER BY i.kind, i.issue, i.id), '[]')::text
          FROM small_area_issues i
    """)
