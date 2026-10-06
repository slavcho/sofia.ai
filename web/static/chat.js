// The chat: ask the model a question about the city; it queries the
// data (POST /api/chat, see web/llm.py) and answers here, showing each
// query it ran.
//
// The conversation lives only in this page for now: chatItems are the
// API's own items (messages, reasoning, tool calls and their outputs),
// sent in full with every question. A turn's items are kept only once it
// ends well, so a stopped or failed turn never leaves a tool call without
// its output, which the API would refuse on the next question.
//
// A tool may also show something on the page (a "view" event): a layer
// drawn from a query (show_on_map), kept in chatViews by call id so it
// can be shown again.
//
// Uses the page's esc() and map; marked and DOMPurify render the answers.

// chatId changes with every new chat, so a turn stopped by it is not kept.
let chatItems = [], chatAbort = null, chatId = 0;
let chatViews = {}, chatShown = null, chatPopup = null;
const CHAT_COLOR = '#e6550d';

const chatEl = id => document.getElementById(id);

function markdown(text) {
  const html = DOMPurify.sanitize(marked.parse(text));
  const div = document.createElement('div');
  div.innerHTML = html;
  div.querySelectorAll('a[href]').forEach(a => { a.target = '_blank'; a.rel = 'noopener'; });
  return div.innerHTML;
}

function addChatMessage(kind, html) {
  const log = chatEl('chat-log'), div = document.createElement('div');
  div.className = `chat-msg ${kind}`;
  div.innerHTML = html;
  log.append(div);
  log.scrollTop = log.scrollHeight;
  return div;
}

// What a tool call did, in a line: the query itself is in the details.
const TOOL_LABELS = {
  run_sql: a => ['Query', a.sql],
  describe_table: a => [`Table ${a.table}`, ''],
  read_data_issues: a => [`Data issues ${(a.numbers || []).join(', ')}`, ''],
  show_on_map: a => [`Map: ${a.title}`, a.sql],
};

function toolLine(callId, name, args) {
  let a = {};
  try { a = JSON.parse(args); } catch (e) { /* shown raw below */ }
  const [label, code] = (TOOL_LABELS[name] || (() => [name, args]))(a);
  const d = document.createElement('details');
  d.className = 'chat-tool running';
  d.dataset.call = callId;
  d.innerHTML = `<summary><span class="label">${esc(label)}</span> <span class="sub status">running…</span></summary>
    ${code ? `<pre>${esc(code)}</pre>` : ''}<div class="result"></div>`;
  return d;
}

function toolResult(d, output) {
  d.classList.remove('running');
  const status = d.querySelector('.status'), result = d.querySelector('.result');
  if (output?.error) {
    d.classList.add('failed');
    status.textContent = 'error';
    result.innerHTML = `<div class="chat-error">${esc(output.error)}</div>`;
  } else if (output?.shown != null) {
    status.textContent = `${output.shown}${output.truncated ? '+' : ''} on the map`;
    result.innerHTML = `${output.note ? `<div class="sub">${esc(output.note)}</div>` : ''}
      <button type="button" data-view="show">Show again</button> <button type="button" data-view="hide">Hide</button>`;
  } else if (output?.columns) {
    status.textContent = `${output.row_count}${output.truncated ? '+' : ''} rows`;
    const rows = output.rows.slice(0, 20);
    result.innerHTML = `<div class="chat-table"><table><thead><tr>${output.columns.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead>
      <tbody>${rows.map(r => `<tr>${r.map(v => `<td>${esc(v)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>
      ${output.rows.length > rows.length ? `<div class="sub">and ${output.rows.length - rows.length} more rows</div>` : ''}`;
  } else {
    status.textContent = 'done';
  }
}

// The server sends "data: <json>\n\n" per event.
async function* chatEvents(response) {
  const reader = response.body.getReader(), decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let end;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const chunk = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      if (chunk.startsWith('data: ')) yield JSON.parse(chunk.slice(6));
    }
  }
}

function setChatBusy(busy) {
  chatEl('chat-send').hidden = busy;
  chatEl('chat-stop').hidden = !busy;
}

async function askChat(question) {
  const id = chatId, user = { role: 'user', content: question };
  const turn = [...chatItems, user], added = [];
  addChatMessage('user', esc(question).replace(/\n/g, '<br>'));
  const answer = addChatMessage('assistant', '<span class="sub">thinking…</span>');
  // The text of the current step; a step after a tool starts a new block.
  let text = '', block = null, failed = null, finished = false;
  const tools = {};
  const log = chatEl('chat-log');
  const atBottom = () => log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  const show = node => { const stick = atBottom(); answer.append(node); if (stick) log.scrollTop = log.scrollHeight; };

  chatAbort = new AbortController();
  setChatBusy(true);
  try {
    const r = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ input: turn }), signal: chatAbort.signal });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || `the server answered ${r.status}`);
    answer.innerHTML = '';
    for await (const e of chatEvents(r)) {
      if (e.type === 'text') {
        if (!block) { block = document.createElement('div'); block.className = 'chat-text'; text = ''; show(block); }
        const stick = atBottom();
        text += e.delta;
        block.innerHTML = markdown(text);
        if (stick) log.scrollTop = log.scrollHeight;
      } else if (e.type === 'tool') {
        block = null;
        show(tools[e.call_id] = toolLine(e.call_id, e.name, e.arguments));
      } else if (e.type === 'view') {
        chatViews[e.call_id] = e.view;
        showChatView(e.call_id);
      } else if (e.type === 'tool_result') {
        if (tools[e.call_id]) toolResult(tools[e.call_id], e.output);
      } else if (e.type === 'items') {
        added.push(...e.items);
      } else if (e.type === 'error') {
        failed = e.message;
      } else if (e.type === 'done') {
        finished = true;
      }
    }
    if (!finished && !failed) failed = 'the connection was lost before the answer was complete';
  } catch (err) {
    failed = err.name === 'AbortError' ? 'stopped' : err.message;
  } finally {
    chatAbort = null;
    setChatBusy(false);
  }
  if (id !== chatId) return;
  if (failed) {
    // Keep the question, so that "go on" or a rephrasing has its context,
    // but nothing of the unfinished answer.
    chatItems = [...chatItems, user];
    answer.querySelectorAll('.chat-tool.running .status').forEach(s => s.textContent = 'not finished');
    show(Object.assign(document.createElement('div'), {
      className: 'chat-error', textContent: `${failed === 'stopped' ? 'Stopped' : 'Failed: ' + failed}. This answer is not kept in the conversation.` }));
  } else {
    chatItems = [...turn, ...added];
  }
}

// ------------------------------------------------------------ the views

// Every coordinate pair in a geometry, for the bounds to zoom to.
function* coordinates(c) {
  if (typeof c[0] === 'number') yield c;
  else for (const x of c) yield* coordinates(x);
}

function addChatLayers() {
  map.addSource('chat', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
  const is = (...types) => ['match', ['geometry-type'], types, true, false];
  map.addLayer({ id: 'chat-fill', type: 'fill', source: 'chat', filter: is('Polygon', 'MultiPolygon'),
                 paint: { 'fill-color': CHAT_COLOR, 'fill-opacity': 0.3 } });
  map.addLayer({ id: 'chat-line', type: 'line', source: 'chat', filter: ['!', is('Point', 'MultiPoint')],
                 paint: { 'line-color': CHAT_COLOR, 'line-width': 2 } });
  map.addLayer({ id: 'chat-point', type: 'circle', source: 'chat', filter: is('Point', 'MultiPoint'),
                 paint: { 'circle-color': CHAT_COLOR, 'circle-radius': 6,
                          'circle-stroke-color': '#fff', 'circle-stroke-width': 1.5 } });
  map.addLayer({ id: 'chat-label', type: 'symbol', source: 'chat',
                 layout: { 'text-field': '', 'text-font': ['Noto Sans Regular'], 'text-size': 12,
                           'text-offset': [0, 1.1], 'text-anchor': 'top', 'text-optional': true },
                 paint: { 'text-color': '#222', 'text-halo-color': '#fff', 'text-halo-width': 1.5 } });
  for (const id of ['chat-fill', 'chat-line', 'chat-point']) {
    map.on('click', id, e => {
      // Several layers may be under the click; one popup is enough.
      if (e.chatHandled) return;
      e.chatHandled = true;
      const p = e.features[0].properties, title = chatViews[chatShown]?.title || '';
      chatPopup?.remove();
      chatPopup = new maplibregl.Popup({ maxWidth: '340px' }).setLngLat(e.lngLat).setHTML(
        `<div class="chat-popup"><b>${esc(title)}</b><dl>${Object.entries(p).map(([k, v]) =>
          `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl></div>`).addTo(map);
    });
    map.on('mouseenter', id, () => map.getCanvas().style.cursor = 'pointer');
    map.on('mouseleave', id, () => map.getCanvas().style.cursor = '');
  }
}

// Draw a view on the map, in place of the one shown before, and zoom to it.
function showChatView(callId) {
  const view = chatViews[callId];
  if (!view) return;
  // The page adds its own layers on load; the chat's go on top of them.
  if (!map.isStyleLoaded() || !map.getSource('stations')) { map.once('idle', () => showChatView(callId)); return; }
  if (!map.getSource('chat')) addChatLayers();
  const color = view.color || CHAT_COLOR;
  map.getSource('chat').setData(view.geojson);
  map.setPaintProperty('chat-fill', 'fill-color', color);
  map.setPaintProperty('chat-line', 'line-color', color);
  map.setPaintProperty('chat-point', 'circle-color', color);
  map.setLayoutProperty('chat-label', 'text-field', view.label_column ? ['to-string', ['get', view.label_column]] : '');
  chatPopup?.remove();
  chatShown = callId;
  const bounds = new maplibregl.LngLatBounds();
  for (const f of view.geojson.features) if (f.geometry) for (const c of coordinates(f.geometry.coordinates)) bounds.extend(c);
  if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 60, maxZoom: 16 });
}

function hideChatView() {
  chatShown = null;
  chatPopup?.remove();
  map.getSource('chat')?.setData({ type: 'FeatureCollection', features: [] });
}

function newChat() {
  if (chatAbort) chatAbort.abort();
  chatId++;
  chatItems = [];
  chatViews = {};
  hideChatView();
  chatEl('chat-log').innerHTML = '';
  chatEl('chat-input').focus();
}

function toggleChat(open) {
  chatEl('chat').hidden = !open;
  chatEl('chat-button').setAttribute('aria-expanded', open);
  // The map's container changes width with the panel.
  map.resize();
  if (open) chatEl('chat-input').focus();
}

function bindChat() {
  const input = chatEl('chat-input');
  chatEl('chat-button').onclick = () => toggleChat(chatEl('chat').hidden);
  chatEl('chat-close').onclick = () => toggleChat(false);
  chatEl('chat-new').onclick = newChat;
  chatEl('chat-stop').onclick = () => chatAbort?.abort();
  chatEl('chat-log').onclick = e => {
    const b = e.target.closest('[data-view]');
    if (!b) return;
    const callId = b.closest('.chat-tool').dataset.call;
    if (b.dataset.view === 'show') showChatView(callId);
    else if (chatShown === callId) hideChatView();
  };
  chatEl('chat-form').onsubmit = e => {
    e.preventDefault();
    const q = input.value.trim();
    if (!q || chatAbort) return;
    input.value = '';
    askChat(q);
  };
  // Enter sends, Shift+Enter starts a new line.
  input.onkeydown = e => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); chatEl('chat-form').requestSubmit(); }
  };
}
