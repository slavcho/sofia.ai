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
// Uses the page's esc(); marked and DOMPurify render the answers.

// chatId changes with every new chat, so a turn stopped by it is not kept.
let chatItems = [], chatAbort = null, chatId = 0;

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
};

function toolLine(name, args) {
  let a = {};
  try { a = JSON.parse(args); } catch (e) { /* shown raw below */ }
  const [label, code] = (TOOL_LABELS[name] || (() => [name, args]))(a);
  const d = document.createElement('details');
  d.className = 'chat-tool running';
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
        show(tools[e.call_id] = toolLine(e.name, e.arguments));
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

function newChat() {
  if (chatAbort) chatAbort.abort();
  chatId++;
  chatItems = [];
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
