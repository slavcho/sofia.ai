"""Checks on how the chat page shows each tool's result (toolResult in
web/static/chat.js), run in node against a minimal stand-in for the DOM,
and on the id it gives each chat; skipped without node."""

import json
import shutil
import subprocess
import unittest
from pathlib import Path

CHAT_JS = Path(__file__).resolve().parent.parent / "web" / "static" / "chat.js"

# Loads chat.js as the page would (with the page's esc()), shows each
# output on a fake tool line and prints what the line ended up with.
SCRIPT = r"""
const vm = require('vm'), fs = require('fs');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const context = vm.createContext({ esc, console });
vm.runInContext(fs.readFileSync(process.argv.at(-1), 'utf8'), context);
const outputs = JSON.parse(fs.readFileSync(0, 'utf8'));
const results = {};
for (const [name, output] of Object.entries(outputs)) {
  const classes = new Set(['chat-tool', 'running']);
  const status = { textContent: 'running…' }, result = { innerHTML: '' };
  const line = {
    dataset: { call: 'c1' },
    classList: { add: c => classes.add(c), remove: c => classes.delete(c),
                 toggle: (c, on) => on ? classes.add(c) : classes.delete(c) },
    querySelector: s => s === '.status' ? status : s === '.result' ? result : null,
  };
  try {
    context.toolResult(line, output);
    results[name] = { status: status.textContent, html: result.innerHTML, classes: [...classes].sort() };
  } catch (e) {
    results[name] = { thrown: String(e) };
  }
}
console.log(JSON.stringify(results));
"""

OUTPUTS = {
    "run_sql": {"columns": ["code", "name"], "rows": [["M1", "Сливница – Бизнес Парк"]],
                "row_count": 1, "truncated": False},
    "describe_table": {"table": "city.building_metro_access",
                       "about": "Each residential building with its distance to the metro.",
                       "rows_estimate": 61234,
                       "columns": [{"name": "building_id", "type": "bigint", "not_null": True,
                                    "comment": "city.buildings.id"},
                                   {"name": "distance_m", "type": "double precision", "not_null": False,
                                    "comment": None}],
                       "sample": {"columns": ["building_id", "distance_m"], "rows": [[1, 420.5]],
                                  "row_count": 1, "truncated": False}},
    # An undocumented view: no about, no row estimate.
    "describe_undocumented": {"table": "city.v", "about": None, "rows_estimate": None,
                              "columns": [{"name": "a", "type": "int"}],
                              "sample": {"columns": ["a"], "rows": [], "row_count": 0, "truncated": False}},
    "show_on_map": {"shown": 78, "geometry_types": ["POINT"], "columns": ["name"],
                    "extent": [23.2, 42.6, 23.4, 42.7], "truncated": False},
    "show_focus": {"shown_focus": "Metro access"},
    "read_data_issues": {"issues": ["### 1. One\n\nBody."]},
    "error": {"error": '42P01 relation "city.nope" does not exist'},
}


@unittest.skipUnless(shutil.which("node"), "no node")
class ToolResultTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        run = subprocess.run(["node", "-e", SCRIPT, "--", str(CHAT_JS)], input=json.dumps(OUTPUTS),
                             capture_output=True, text=True, timeout=30)
        if run.returncode:
            raise AssertionError(run.stderr)
        cls.results = json.loads(run.stdout)

    def test_no_output_breaks_the_line(self):
        for name, r in self.results.items():
            self.assertNotIn("thrown", r, name)
            self.assertNotIn("running", r["classes"], name)
            self.assertNotIn("undefined", r["status"] + r["html"], name)

    def test_a_query(self):
        r = self.results["run_sql"]
        self.assertEqual(r["status"], "1 rows")
        self.assertIn("Сливница", r["html"])

    def test_a_table_description(self):
        r = self.results["describe_table"]
        self.assertEqual(r["status"], "2 columns, ~61,234 rows")
        self.assertIn("distance_m", r["html"])
        self.assertIn("double precision", r["html"])
        self.assertIn("city.buildings.id", r["html"])

    def test_an_undocumented_table(self):
        self.assertEqual(self.results["describe_undocumented"]["status"], "1 columns")

    def test_the_map(self):
        self.assertEqual(self.results["show_on_map"]["status"], "78 on the map")
        self.assertEqual(self.results["show_focus"]["status"], "shown")

    def test_an_error(self):
        r = self.results["error"]
        self.assertEqual(r["status"], "error")
        self.assertIn("failed", r["classes"])


# The id the page sends with every question (chat_id, kept with it in
# app.questions): a UUID where the browser can make one, which needs a
# secure context; none otherwise, which the server takes too.
UUID_SCRIPT = r"""
const vm = require('vm'), fs = require('fs');
const ids = {};
for (const [name, globals] of Object.entries({ with: { crypto: require('crypto') }, without: {} })) {
  const context = vm.createContext({ console, ...globals });
  vm.runInContext(fs.readFileSync(process.argv.at(-1), 'utf8'), context);
  ids[name] = [vm.runInContext('chatUuid', context), vm.runInContext('newChatUuid()', context)];
}
console.log(JSON.stringify(ids));
"""


@unittest.skipUnless(shutil.which("node"), "no node")
class ChatUuidTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        run = subprocess.run(["node", "-e", UUID_SCRIPT, "--", str(CHAT_JS)],
                             capture_output=True, text=True, timeout=30)
        if run.returncode:
            raise AssertionError(run.stderr)
        cls.ids = json.loads(run.stdout)

    def test_a_new_uuid_for_every_chat(self):
        first, second = self.ids["with"]
        self.assertRegex(first, r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        self.assertNotEqual(first, second)

    def test_none_without_a_secure_context(self):
        self.assertEqual(self.ids["without"], [None, None])


if __name__ == "__main__":
    unittest.main()
