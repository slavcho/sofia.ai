// The drawer under the map: a sortable table of the schools,
// kindergartens, parks, stations, public transport stops and lines, areas
// or data issues in view (or in the whole city), with a CSV download of
// exactly what it shows.
//
// Uses the page's data and functions (schools, kgs, parks, stations,
// transitStops, transitRoutes, areaCache, allIssues, select*), so it is
// loaded before the page's script but only called once the data is in.

const DATE_COLUMNS = [
  { label: 'Data as of', value: p => p.data_as_of, csvOnly: true },
  { label: 'Source', value: p => p.source, csvOnly: true },
];
const districtName = code => {
  const d = areaCache.district?.features.find(f => f.properties.id === code);
  return d ? d.properties.name : code;
};
const planned = id => document.getElementById(id).checked;

// rows(): [{ p: properties, geometry, open() }]; noun: for the count and
// the file name.
const LISTS = {
  schools: {
    label: 'Schools', noun: 'schools',
    rows: () => schools.features.map(f => ({ p: f.properties, geometry: f.geometry,
                                             open: () => selectSchool(f.properties.id) })),
    columns: [
      { label: 'Name', value: p => p.name },
      { label: 'Kind', value: p => SCHOOL_KIND[p.kind] || p.kind },
      { label: 'Funding', value: p => p.funding },
      { label: 'Classes', value: p => p.class_count, num: true },
      { label: 'District', value: p => districtName(p.district_code) },
      { label: 'Address', value: p => p.address },
      // From the city's catchment list (2026) and the residents (2019).
      { label: 'Catchment children', value: p => p.catchment_children, num: true },
      { label: 'Median distance (m)', value: p => p.catchment_median_m, num: true },
      { label: 'Nearest school for', num: true, suffix: '%',
        value: p => p.catchment_nearest_share == null ? null : Math.round(p.catchment_nearest_share * 100) },
      ...DATE_COLUMNS],
  },
  kindergartens: {
    label: 'Kindergartens', noun: 'kindergartens',
    rows: () => kgs.features.map(f => ({ p: f.properties, geometry: f.geometry,
                                         open: () => selectKindergarten(f.properties.id) })),
    columns: [
      { label: 'Name', value: p => p.name },
      { label: 'Kind', value: p => KG_KIND[p.kind] || p.kind },
      { label: 'Funding', value: p => p.funding },
      { label: 'Status', value: p => p.status },
      { label: 'Groups', value: p => p.groups, num: true },
      { label: 'Registered children', value: p => p.children, num: true },
      { label: 'District', value: p => districtName(p.district_code) },
      { label: 'Address', value: p => p.address },
      ...DATE_COLUMNS],
  },
  parks: {
    label: 'Parks', noun: 'parks',
    rows: () => parks.features
      .filter(f => f.properties.status === 'existing' || planned('show-planned-parks'))
      .map(f => ({ p: f.properties, geometry: f.geometry, open: () => selectPark(f.properties.id) })),
    columns: [
      { label: 'Name', value: p => p.name },
      { label: 'Kind', value: p => PARK_KIND[p.kind] || p.kind },
      { label: 'Status', value: p => p.status },
      { label: 'Area (m²)', value: p => p.area_m2 == null ? null : Math.round(p.area_m2), num: true },
      { label: 'Entrances', value: p => p.entrances, num: true },
      ...DATE_COLUMNS],
  },
  stations: {
    label: 'Metro stations', noun: 'stations',
    rows: () => stations.features
      .filter(f => f.properties.status === 'existing' || planned('show-planned'))
      .map(f => ({ p: f.properties, geometry: f.geometry, open: () => selectStation(f.properties.id) })),
    columns: [
      { label: 'Name', value: p => p.name },
      { label: 'Lines', value: p => arr(p.lines).join(' ') },
      { label: 'Status', value: p => p.status },
      { label: 'Entrances', value: p => p.entrances, num: true },
      { label: 'Wheelchair entrances', value: p => p.wheelchair_entrances, num: true },
      ...DATE_COLUMNS],
  },
  // Public transport loads on first use; the list asks for it too.
  'transit-stops': {
    label: 'Public transport stops', noun: 'stops',
    empty: () => transitStops ? '' : (loadTransit().catch(() => {}), 'Loading the timetable…'),
    rows: () => !transitStops ? [] : transitStops.features.map(f => ({ p: f.properties, geometry: f.geometry,
                                                    open: () => selectTransitStop(f.properties.id) })),
    columns: [
      { label: 'Name', value: p => p.name },
      { label: 'Code', value: p => p.code },
      { label: 'Modes', value: p => arr(p.modes).join(' ') },
      { label: 'Lines', value: p => arr(p.routes).join(' ') },
      // Departures an hour, all lines and both directions (timetable 2026).
      { label: 'Weekday 7–9', value: p => p.peak_per_hour, num: true },
      { label: 'Weekday 20–23', value: p => p.evening_per_hour, num: true },
      { label: 'Saturday 10–18', value: p => p.saturday_per_hour, num: true },
      { label: 'Sunday 10–18', value: p => p.sunday_per_hour, num: true },
      { label: 'Night 1–4', value: p => p.night_per_hour, num: true },
      ...DATE_COLUMNS],
  },
  'transit-routes': {
    label: 'Public transport lines', noun: 'lines',
    empty: () => transitRoutes ? '' : (loadTransit().catch(() => {}), 'Loading the timetable…'),
    rows: () => !transitRoutes ? [] : transitRoutes.features.map(f => ({ p: f.properties, geometry: f.geometry,
                                                      open: () => selectTransitRoute(f.properties.id) })),
    columns: [
      { label: 'Line', value: p => p.name },
      { label: 'Mode', value: p => p.night ? 'night bus' : MODE_LABEL[p.mode] },
      { label: 'Route', value: p => p.long_name },
      { label: 'Weekday trips', value: p => p.trips_weekday, num: true },
      { label: 'Saturday trips', value: p => p.trips_saturday, num: true },
      { label: 'Sunday trips', value: p => p.trips_sunday, num: true },
      ...DATE_COLUMNS],
  },
  // The areas shown on the map, with the metric they are coloured by.
  areas: {
    label: 'Areas', noun: () => ({ district: 'districts', neighbourhood: 'neighbourhoods',
                                   planning_unit: 'planning-units' })[areaKind] || 'areas',
    empty: () => areaKind ? '' : 'This focus does not colour any areas; pick one that does from All topics.',
    rows: () => !areaKind || !areaCache[areaKind] ? [] : areaCache[areaKind].features.map(f => ({
      p: f.properties, geometry: f.geometry, open: () => selectArea(areaKind, f.properties.id) })),
    columns: () => {
      const key = areaMetric, m = METRICS[key];
      return [
        { label: 'Name', value: p => p.name },
        { label: 'Residents', value: p => p.population, num: true },
        { label: 'Residents per km²', value: p => p.density, num: true },
        // Density is already a column of its own.
        ...key === 'density' ? [] : [{ label: m.label, num: true,
          value: p => p[key] == null ? null : m.pct ? Math.round(p[key] * 1000) / 10 : p[key],
          suffix: m.pct ? '%' : '', plain: m.plain }]];
    },
  },
  // Follows the source filter of the data issues panel.
  issues: {
    label: 'Data issues', noun: 'data-issues',
    rows: () => {
      const source = document.getElementById('issue-source').value;
      return allIssues.filter(i => !source || i.source === source).map(i => ({
        p: i, geometry: i.lon == null ? null : { type: 'Point', coordinates: [+i.lon, +i.lat] },
        open: () => openIssue(i) }));
    },
    columns: [
      { label: 'Source', value: i => i.source },
      { label: 'Issue', value: i => i.issue },
      { label: 'Area', value: i => i.area_kind ? (i.name || KIND_LABEL[i.area_kind] + ' #' + i.area_id) : '' },
      { label: 'Detail', value: i => i.detail }],
  },
};
const LIST_SCOPES = ['view', 'all'];
const MAX_ROWS = 500;     // drawn in the table; the CSV has them all

let listName = 'schools', listScope = 'view', listSort = { col: 0, dir: 1 }, listRows = [];
// A row click moves the map to that row; the list stays as it was for
// that move, so the row does not jump away from under the pointer.
let listHold = false;

const columnsOf = l => (typeof l.columns === 'function' ? l.columns() : l.columns);
const nounOf = l => (typeof l.noun === 'function' ? l.noun() : l.noun);

// [west, south, east, north] of a geometry, kept on it once worked out.
function bboxOf(g) {
  if (g._bbox) return g._bbox;
  const b = [Infinity, Infinity, -Infinity, -Infinity];
  const walk = c => typeof c[0] === 'number'
    ? (b[0] = Math.min(b[0], c[0]), b[1] = Math.min(b[1], c[1]), b[2] = Math.max(b[2], c[0]), b[3] = Math.max(b[3], c[1]))
    : c.forEach(walk);
  walk(g.coordinates);
  return (g._bbox = b);
}

// In view: whatever lies (or reaches) inside the map's view, at any
// zoom; without a location, only in the whole city.
function inView(row, bounds) {
  if (!row.geometry) return false;
  const [w, s, e, n] = bboxOf(row.geometry);
  return w <= bounds.getEast() && e >= bounds.getWest() && s <= bounds.getNorth() && n >= bounds.getSouth();
}

function renderList() {
  const l = LISTS[listName]; if (!l) return;
  const cols = columnsOf(l), shown = cols.filter(c => !c.csvOnly);
  const bounds = map.getBounds();
  listRows = l.rows().filter(r => listScope === 'all' || inView(r, bounds));
  const c = cols[listSort.col] || cols[0];
  const key = r => c.value(r.p);
  listRows.sort((a, b) => {
    const x = key(a), y = key(b);
    if (x == null || x === '') return 1;
    if (y == null || y === '') return -1;
    return listSort.dir * (c.num ? x - y : String(x).localeCompare(String(y), 'bg'));
  });
  const noun = nounOf(l).replace(/-/g, ' ');
  document.getElementById('list-count').textContent =
    `${listRows.length.toLocaleString()} ${noun}${listScope === 'view' ? ' in view' : ' in the city'}` +
    (listRows.length > MAX_ROWS ? ` · first ${MAX_ROWS} shown, the CSV has all` : '');
  const empty = l.empty?.() || (listRows.length ? '' : 'None here.');
  // Thousands separators in the table only; the CSV keeps plain numbers.
  const cell = (col, p) => {
    const v = col.value(p);
    if (v == null || v === '') return '';
    return esc(col.num && !col.plain && typeof v === 'number' ? v.toLocaleString() : v) + (col.suffix || '');
  };
  document.getElementById('list-table').innerHTML = empty ? `<caption class="empty">${esc(empty)}</caption>` :
    `<thead><tr>${shown.map(col => {
      const i = cols.indexOf(col), arrow = i === listSort.col ? (listSort.dir > 0 ? ' ▲' : ' ▼') : '';
      return `<th data-col="${i}" class="${col.num ? 'num' : ''}">${esc(col.label)}${arrow}</th>`;
    }).join('')}</tr></thead><tbody>` +
    listRows.slice(0, MAX_ROWS).map((r, n) => `<tr data-row="${n}">${shown.map(col =>
      `<td class="${col.num ? 'num' : ''}">${cell(col, r.p)}</td>`).join('')}</tr>`).join('') + '</tbody>';
  document.querySelectorAll('#list-scope button').forEach(b => b.setAttribute('aria-pressed', b.dataset.scope === listScope));
}

function downloadList() {
  const l = LISTS[listName], cols = columnsOf(l);
  const q = v => { const s = v == null ? '' : String(v); return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const csv = [cols.map(c => q(c.label)), ...listRows.map(r => cols.map(c => q(c.value(r.p))))]
    .map(row => row.join(',')).join('\r\n');
  // The byte order mark makes Excel read the file as UTF-8 (Cyrillic).
  const url = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
  const a = Object.assign(document.createElement('a'), { href: url,
    download: `sofia-${nounOf(l)}-${listScope === 'view' ? 'in-view' : 'whole-city'}-${new Date().toISOString().slice(0, 10)}.csv` });
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function setList(name, scope) {
  if (LISTS[name] && name !== listName) { listName = name; listSort = { col: 0, dir: 1 }; }
  if (LIST_SCOPES.includes(scope)) listScope = scope;
  document.getElementById('list-name').value = listName;
  renderList();
}

function foldDrawer(folded) {
  document.getElementById('drawer').classList.toggle('folded', folded);
  document.getElementById('list-fold').textContent = folded ? '▴' : '▾';
  document.getElementById('list-fold').title = folded ? 'Show the list' : 'Hide the list';
  map.resize();
}

function bindList() {
  const name = document.getElementById('list-name');
  name.innerHTML = Object.entries(LISTS).map(([k, l]) => `<option value="${k}">${esc(l.label)}</option>`).join('');
  name.onchange = () => setList(name.value);
  document.getElementById('list-scope').onclick = e => {
    const b = e.target.closest('[data-scope]'); if (b) setList(listName, b.dataset.scope);
  };
  document.getElementById('list-csv').onclick = downloadList;
  document.getElementById('list-fold').onclick = () =>
    foldDrawer(!document.getElementById('drawer').classList.contains('folded'));
  document.getElementById('list-table').onclick = e => {
    const th = e.target.closest('th[data-col]');
    if (th) {
      const col = +th.dataset.col;
      listSort = { col, dir: listSort.col === col ? -listSort.dir : 1 };
      return renderList();
    }
    const tr = e.target.closest('tr[data-row]');
    if (tr) { listHold = true; listRows[+tr.dataset.row].open(); setTimeout(() => listHold = false, 3000); }
  };
  map.on('moveend', () => {
    if (listHold) { listHold = false; return; }
    if (listScope === 'view') renderList();
  });
  ['show-planned', 'show-planned-parks', 'issue-source'].forEach(id =>
    document.getElementById(id).addEventListener('change', renderList));
}
