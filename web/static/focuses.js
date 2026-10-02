// Focuses: ready-made views of the map, one per question a user may work
// on today. They are plain data, so that new ones (later written by an
// LLM from a question) can be checked against the layers, area kinds and
// metrics we actually have before they are shown.

const FOCUS_CATEGORIES = ['Education', 'Transport', 'Green spaces', 'Technical'];

// Keys of the layer toggles in the sidebar (data-key).
const FOCUS_LAYERS = ['stations', 'outlines', 'entrances', 'tracks', 'planned-stations',
                      'parks', 'park-entrances', 'planned-parks', 'kindergartens', 'schools'];
const FOCUS_AREA_KINDS = ['district', 'neighbourhood', 'planning_unit'];

// Planned parks stay off: they are master plan zones, much of it forest.
const ALL_LAYERS = FOCUS_LAYERS.filter(k => k !== 'planned-parks');

const FOCUSES = [
  { id: 'overview', category: null, title: 'Overview',
    question: 'Metro, parks, kindergartens and schools on one map.',
    layers: ALL_LAYERS, areas: null },
  { id: 'data-issues', category: 'Technical', title: 'Data issues',
    question: 'Where are the source data missing, wrong, or in disagreement with each other?',
    layers: ALL_LAYERS, areas: null, panel: 'issues' },
];

// Problems with a focus, as a list of messages; empty if it can be shown.
function checkFocus(f, metrics) {
  const errors = [];
  if (!f.id || !f.title) errors.push('needs an id and a title');
  if (f.category != null && !FOCUS_CATEGORIES.includes(f.category)) errors.push(`unknown category ${f.category}`);
  (f.layers || []).filter(k => !FOCUS_LAYERS.includes(k)).forEach(k => errors.push(`unknown layer ${k}`));
  if (f.areas) {
    if (!FOCUS_AREA_KINDS.includes(f.areas.kind)) errors.push(`unknown area kind ${f.areas.kind}`);
    if (f.areas.metric && !metrics[f.areas.metric]) errors.push(`unknown metric ${f.areas.metric}`);
  }
  if (f.panel && f.panel !== 'issues') errors.push(`unknown panel ${f.panel}`);
  return errors;
}
