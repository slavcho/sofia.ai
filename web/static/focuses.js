// Focuses: ready-made views of the map, one per question a user may work
// on today. They are plain data, so that new ones (later written by an
// LLM from a question) can be checked against the layers, area kinds and
// metrics we actually have before they are shown.

const FOCUS_CATEGORIES = ['Education', 'Transport', 'Green spaces', 'Population', 'Technical'];

// Keys of the layer toggles in the sidebar (data-key).
const FOCUS_LAYERS = ['stations', 'outlines', 'entrances', 'tracks', 'planned-stations',
                      'parks', 'park-entrances', 'planned-parks', 'kindergartens', 'schools'];
const FOCUS_AREA_KINDS = ['district', 'neighbourhood', 'planning_unit'];

// Planned parks stay off: they are master plan zones, much of it forest.
const ALL_LAYERS = FOCUS_LAYERS.filter(k => k !== 'planned-parks');

const FOCUSES = [
  { id: 'overview', category: null, title: 'Overview',
    question: 'Metro, parks, kindergartens and schools on one map.',
    layers: ALL_LAYERS, areas: null, list: 'schools', drawer: 'folded' },
  { id: 'school-catchments', category: 'Education', title: 'School catchments',
    question: 'Is the school each child is assigned to also the nearest one, and how far is it?',
    layers: ['schools'], areas: { kind: 'neighbourhood', metric: 'assigned_farther_share' },
    list: 'schools', drawer: 'open', minZoom: 12 },
  { id: 'school-walk', category: 'Education', title: 'Walking distance to schools',
    question: 'Where do children aged 0–14 live more than 800 m from any school for grades 1–7?',
    layers: ['schools'], areas: { kind: 'neighbourhood', metric: 'school_share_800' },
    list: 'areas', drawer: 'open', minZoom: 12 },
  { id: 'kindergartens', category: 'Education', title: 'Kindergartens',
    question: 'Where do children live more than 500 m from a kindergarten?',
    layers: ['kindergartens'], areas: { kind: 'neighbourhood', metric: 'kindergarten_share_500' },
    list: 'kindergartens', drawer: 'open', minZoom: 12 },
  { id: 'kindergarten-places', category: 'Education', title: 'Kindergarten places',
    question: 'How many children are registered in municipal kindergartens per child aged 0–14 living in each district?',
    layers: ['kindergartens'], areas: { kind: 'district', metric: 'registered_per_child' },
    list: 'areas', drawer: 'open' },
  { id: 'sofiaplan-schools', category: 'Education', title: "Schools: Sofiaplan's measure",
    question: "How does Sofiaplan's walking distance to schools (2019) compare with our straight-line one?",
    layers: ['schools'], areas: { kind: 'neighbourhood', metric: 'sofiaplan_school_share_800' },
    list: 'areas', drawer: 'open', minZoom: 12 },
  { id: 'metro-access', category: 'Transport', title: 'Metro access',
    question: 'How many residents live within 500 m of a metro station?',
    layers: ['stations', 'outlines', 'entrances', 'tracks'],
    areas: { kind: 'neighbourhood', metric: 'share_500' }, list: 'stations', drawer: 'open' },
  { id: 'planned-metro', category: 'Transport', title: 'Planned metro',
    question: 'Which neighbourhoods gain the most from the planned stations?',
    layers: ['stations', 'outlines', 'entrances', 'tracks', 'planned-stations'],
    areas: { kind: 'neighbourhood', metric: 'gain_500' }, list: 'stations', drawer: 'open' },
  { id: 'park-access', category: 'Green spaces', title: 'Park access',
    question: 'How many residents live within 300 m of a park entrance?',
    layers: ['parks', 'park-entrances'], areas: { kind: 'neighbourhood', metric: 'park_share_300' },
    list: 'parks', drawer: 'open' },
  { id: 'city-parks', category: 'Green spaces', title: 'City parks',
    question: 'Who lives within 800 m of one of the large city parks?',
    layers: ['parks'], areas: { kind: 'neighbourhood', metric: 'city_park_share_800' },
    list: 'parks', drawer: 'open' },
  { id: 'sofiaplan-parks', category: 'Green spaces', title: "Parks: Sofiaplan's measure",
    question: "Which neighbourhoods have walking access to green space according to Sofiaplan (2021), and does it agree with ours?",
    layers: ['parks'], areas: { kind: 'neighbourhood', metric: 'sofiaplan_park_share' },
    list: 'areas', drawer: 'open' },
  { id: 'density', category: 'Population', title: 'Population density',
    question: 'Where do the residents live? Residents per km² of each planning unit (2019).',
    layers: [], areas: { kind: 'planning_unit', metric: 'density' },
    list: 'areas', drawer: 'open' },
  { id: 'data-issues', category: 'Technical', title: 'Data issues',
    question: 'Where are the source data missing, wrong, or in disagreement with each other?',
    layers: ALL_LAYERS, areas: null, panel: 'issues',
    list: 'issues', listScope: 'all', drawer: 'open' },
];

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
  }
  if (f.panel && f.panel !== 'issues') errors.push(`unknown panel ${f.panel}`);
  if (f.list && !lists[f.list]) errors.push(`unknown list ${f.list}`);
  if (f.listScope && !['view', 'all'].includes(f.listScope)) errors.push(`unknown list scope ${f.listScope}`);
  if (f.drawer && !['open', 'folded'].includes(f.drawer)) errors.push(`unknown drawer state ${f.drawer}`);
  if (f.minZoom != null && !(f.minZoom >= 0 && f.minZoom <= 22)) errors.push(`bad minimum zoom ${f.minZoom}`);
  return errors;
}
