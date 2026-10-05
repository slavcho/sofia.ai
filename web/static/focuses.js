// Focuses: ready-made views of the map, one per question a user may work
// on today. They are plain data, so that new ones (later written by an
// LLM from a question) can be checked against the layers, area kinds and
// metrics we actually have before they are shown.
//
// The focuses and their categories come from GET /api/focuses (the
// built-in ones are in web/focuses.json) and are set on load.
// The overview leaves out the planned parks (master plan zones, much of
// it forest), the public transport (3,500 stops and 140 lines) and the
// 265,000 buildings, which would bury the rest; the layers that cover
// the whole map come with their own focus.
let FOCUSES = [], FOCUS_CATEGORIES = [];

// Keys of the layer toggles in the sidebar (data-key).
const FOCUS_LAYERS = ['stations', 'outlines', 'entrances', 'tracks', 'planned-stations',
                      'parks', 'park-entrances', 'planned-parks', 'kindergartens', 'schools',
                      'transit-stops', 'transit-routes', 'live-vehicles', 'buildings',
                      'census-tracts', 'population-grid', 'polling-places', 'rectifier-stations', 'master-plan',
                      'playgrounds', 'markets', 'tent-camps', 'metro-projects', 'concessions', 'settlements'];
const FOCUS_AREA_KINDS = ['district', 'neighbourhood', 'planning_unit'];

// Problems with a focus, as a list of messages; empty if it can be shown.
// list: which table the drawer shows (a key of LISTS in list.js);
// listScope: 'view' or 'all'; drawer: 'open' or 'folded'; minZoom: the
// map zooms in at least this far, where the focus's points are drawn.
function checkFocus(f, metrics, lists) {
  const errors = [];
  if (!f.id || !f.title) errors.push('needs an id and a title');
  if (f.category != null && !FOCUS_CATEGORIES.includes(f.category)) errors.push(`unknown category ${f.category}`);
  (f.layers || []).filter(k => !FOCUS_LAYERS.includes(k)).forEach(k => errors.push(`unknown layer ${k}`));
  if (f.areas) {
    if (!FOCUS_AREA_KINDS.includes(f.areas.kind)) errors.push(`unknown area kind ${f.areas.kind}`);
    if (f.areas.metric && !metrics[f.areas.metric]) errors.push(`unknown metric ${f.areas.metric}`);
    const kinds = metrics[f.areas.metric]?.kinds;
    if (kinds && !kinds.includes(f.areas.kind)) errors.push(`metric ${f.areas.metric} is not given by ${f.areas.kind}`);
  }
  if (f.panel && f.panel !== 'issues') errors.push(`unknown panel ${f.panel}`);
  if (f.list && !lists[f.list]) errors.push(`unknown list ${f.list}`);
  if (f.listScope && !['view', 'all'].includes(f.listScope)) errors.push(`unknown list scope ${f.listScope}`);
  if (f.drawer && !['open', 'folded'].includes(f.drawer)) errors.push(`unknown drawer state ${f.drawer}`);
  if (f.minZoom != null && !(f.minZoom >= 0 && f.minZoom <= 22)) errors.push(`bad minimum zoom ${f.minZoom}`);
  return errors;
}
