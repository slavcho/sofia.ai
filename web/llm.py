"""The chat: one turn of a conversation with the model over OpenAI's
Responses API, with the tools of web/llm_tools.py.

The conversation lives in the page, not here: the page sends every item
so far (the API's own input items) and gets back, as events, the text as
it is written, the tools as they run and the new items to keep. The API
does not store anything either (store=False); the model's reasoning goes
back and forth encrypted, so it is not lost between the steps of a turn
or between turns.

$OPENAI_API_KEY is needed; $OPENAI_MODEL and $OPENAI_REASONING_EFFORT
change the model and how hard it thinks.
"""

import json
import logging
import os
import re
from collections.abc import Iterator

import openai
import psycopg

from web import llm_tools

MODEL = os.environ.get("OPENAI_MODEL", "gpt-6.1-sol")
REASONING_EFFORT = os.environ.get("OPENAI_REASONING_EFFORT", "medium")
MAX_STEPS = 16        # model calls in one turn; each may run several tools
log = logging.getLogger("uvicorn.error")


def strict_object(properties: dict) -> dict:
    """A strict JSON schema: every property required, nothing else allowed."""
    return {"type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False}


TOOLS = [
    {
        "type": "function", "name": "run_sql", "strict": True,
        "description": (
            "Run one read-only PostgreSQL/PostGIS query (a SELECT or WITH ... SELECT) and get its "
            f"rows, at most {llm_tools.MAX_ROWS}. Geometries come back as type, size and a point. "
            f"Queries are stopped after {llm_tools.TIMEOUT}. On an error, read it and fix the query."),
        "parameters": strict_object({"sql": {"type": "string", "description": "The query."}}),
    },
    {
        "type": "function", "name": "describe_table", "strict": True,
        "description": ("The columns of a table or view with their types and documentation, what "
                        "the table is, its size and three sample rows. Use it before querying a "
                        "table whose columns you are not sure of."),
        "parameters": strict_object({"table": {"type": "string", "description": "schema.table, e.g. city.schools"}}),
    },
    {
        "type": "function", "name": "read_data_issues", "strict": True,
        "description": ("The full entries of DATA_ISSUES.md: where a known problem in the source data "
                        "comes from, what it affects and how it was handled. Read the ones that "
                        "touch the data behind an answer before relying on it."),
        "parameters": strict_object({"numbers": {"type": "array", "items": {"type": "integer"},
                                                 "description": "Issue numbers from the index."}}),
    },
    {
        "type": "function", "name": "show_on_map", "strict": True,
        "description": (
            "Draw the rows of a read-only query on the user's map, as one layer over what is "
            "there, and zoom to them. The query must return the geometry as a column named geom; "
            "every other column is shown when a feature is clicked and in the list under the "
            f"map, so name them for a reader. At most {llm_tools.MAX_FEATURES} rows are drawn. "
            "You get back how many were drawn and where, not the rows."),
        "parameters": strict_object({
            "sql": {"type": "string", "description": "The query, with a geom column."},
            "title": {"type": "string", "description": "What the layer shows, in a few words."},
            "color": {"type": ["string", "null"], "description": "#rrggbb, or null for the default."},
            "label_column": {"type": ["string", "null"],
                             "description": "A column to write next to each feature, or null."},
        }),
    },
]

COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")


def show_on_map(a: dict) -> dict:
    """Run the query for the map; the layer goes to the page as the
    result's "view", which the model does not see."""
    result, geojson = llm_tools.query_geojson(a["sql"])
    if geojson is None:
        return result
    label = a.get("label_column")
    if label and label not in result["columns"]:
        result["note"] = (result.get("note", "") + f"; no column {label} to label with").lstrip("; ")
        label = None
    color = a.get("color") if COLOR.match(a.get("color") or "") else None
    return {**result, "view": {"kind": "layer", "title": a["title"], "color": color,
                               "label_column": label, "geojson": json.loads(geojson)}}


SERVER_TOOLS = {
    "run_sql": lambda a: llm_tools.run_sql(a["sql"]),
    "describe_table": lambda a: llm_tools.describe_table(a["table"]),
    "read_data_issues": lambda a: llm_tools.read_data_issues(a["numbers"]),
    "show_on_map": show_on_map,
}


def call_tool(name: str, arguments: str, tools: dict = SERVER_TOOLS) -> dict:
    """Run a tool the model called; any failure becomes an error it can read."""
    if name not in tools:
        return {"error": f"there is no tool {name}"}
    try:
        return tools[name](json.loads(arguments or "{}"))
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        return {"error": f"bad arguments for {name}: {e}"}
    except Exception as e:
        log.exception("tool %s failed", name)
        return {"error": f"{name} failed: {e}"}


# ------------------------------------------------------------ the prompt

def section(text: str, heading: str) -> str:
    """A ## section of a markdown file, without its heading."""
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else ""


ROLE = """\
You are the analyst of sofia.ai, a project that makes the open data of
the city of Sofia, Bulgaria (https://urbandata.sofia.bg/) understandable
and actionable for its residents and the municipality. You answer
questions about the city by querying a PostGIS database built from that
data.

How to work:
- Look before you answer: query the data rather than relying on what you
  know about Sofia. Run as many queries as the question needs, starting
  small (counts, a few rows) before the full answer.
- Prefer the curated city.* tables and views; fall back to urban.* (the
  raw portal data) only for what city.* does not have.
- Keep queries cheap: the database has millions of rows. Use the spatial
  indexes and aggregate in SQL rather than fetching rows to count them.
- Answer in English, in short markdown: the answer first, then how you
  got it. Names of places may stay in Bulgarian, as in the data.
- Say which datasets (and tables) an answer comes from and how old their
  data is, and mark what is a fact from the data and what is your
  inference.
- If the data cannot answer the question, say so and say what is missing,
  rather than guessing.
- The user sees a map of Sofia next to this chat. When an answer is about
  places (where something is, which areas stand out), show them with
  show_on_map, and say in the answer what the layer shows. One layer is
  shown at a time; a new one replaces the last."""


_tables = None


def tables_summary() -> str:
    """The schema summary, read once per process (restart the server after
    a schema change); without the database it says so and is read again
    on the next turn."""
    global _tables
    if _tables is None:
        try:
            with llm_tools.connect() as conn:
                _tables = llm_tools.schema_summary(conn)
        except psycopg.OperationalError as e:
            log.warning("no schema for the prompt: %s", e)
            return f"(The database cannot be reached: {e})"
    return _tables


def base_instructions() -> str:
    """The prompt, the same for every turn so the API can cache it: the
    role, the project's principles, every table and the index of the
    known data issues."""
    readme = (llm_tools.ROOT / "README.md").read_text()
    return "\n\n".join([
        ROLE,
        "# Principles\n\n" + section(readme, "Principles for agents"),
        "# The data\n\n" + section(readme, "The data"),
        "# Querying\n\n" + section(readme, "Querying"),
        "# Tables and views\n\nEvery column is listed; describe_table gives what they mean.\n\n"
        + tables_summary(),
        "# Known data issues\n\nRead an entry with read_data_issues before relying on data it "
        "touches.\n\n" + llm_tools.data_issue_index(),
    ])


# -------------------------------------------------------------- the turn

def client() -> openai.OpenAI:
    # The SDK retries connection errors, 429 and 5xx with back-off.
    return openai.OpenAI(max_retries=3, timeout=180)


def run_turn(items: list[dict], api=None, tools: dict = SERVER_TOOLS,
             instructions: str | None = None) -> Iterator[dict]:
    """Continue the conversation `items` (ending with the user's message)
    until the model answers without calling a tool.

    Yields events for the page:
      {"type": "text", "delta": "..."}                 the answer as it is written
      {"type": "tool", "call_id", "name", "arguments"} a tool is about to run
      {"type": "view", "call_id", "view"}              what the tool shows on the page
      {"type": "tool_result", "call_id", "output"}     ... and what it gave the model
      {"type": "items", "items": [...]}                to append to the conversation
      {"type": "error", "message": "..."}              the turn stopped
      {"type": "done"}                                 the turn is over
    """
    try:
        api = api or client()
    except openai.OpenAIError as e:
        yield {"type": "error", "message": f"cannot use the OpenAI API: {e}"}
        return
    instructions = instructions if instructions is not None else base_instructions()
    items = list(items)
    for _ in range(MAX_STEPS):
        response = None
        try:
            stream = api.responses.create(
                model=MODEL, instructions=instructions, input=items, tools=TOOLS,
                reasoning={"effort": REASONING_EFFORT}, store=False,
                include=["reasoning.encrypted_content"],
                # Drop the oldest items rather than fail when the
                # conversation outgrows the context window.
                truncation="auto", stream=True)
            for event in stream:
                if event.type == "response.output_text.delta":
                    yield {"type": "text", "delta": event.delta}
                elif event.type == "response.completed":
                    response = event.response
                elif event.type in ("response.failed", "response.incomplete"):
                    r = event.response
                    reason = (r.error and r.error.message) or (
                        r.incomplete_details and r.incomplete_details.reason) or event.type
                    yield {"type": "error", "message": f"the model stopped: {reason}"}
                    return
                elif event.type == "error":
                    yield {"type": "error", "message": f"the model failed: {event.message}"}
                    return
        except openai.APIError as e:
            log.warning("OpenAI API error: %s", e)
            yield {"type": "error", "message": f"the OpenAI API failed: {e}"}
            return
        if response is None:
            yield {"type": "error", "message": "the model's answer was cut off"}
            return

        output = [item.to_dict() for item in response.output]
        items += output
        yield {"type": "items", "items": output}
        calls = [i for i in output if i["type"] == "function_call"]
        if not calls:
            yield {"type": "done"}
            return
        for call in calls:
            yield {"type": "tool", "call_id": call["call_id"], "name": call["name"],
                   "arguments": call["arguments"]}
            result = call_tool(call["name"], call["arguments"], tools)
            # What the page should show (a map layer) is for the page only.
            view = result.pop("view", None) if isinstance(result, dict) else None
            if view:
                yield {"type": "view", "call_id": call["call_id"], "view": view}
            yield {"type": "tool_result", "call_id": call["call_id"], "output": result}
            item = {"type": "function_call_output", "call_id": call["call_id"],
                    "output": json.dumps(result, ensure_ascii=False)}
            items.append(item)
            yield {"type": "items", "items": [item]}
    yield {"type": "error", "message": f"stopped after {MAX_STEPS} steps without an answer; "
                                       "ask again, perhaps more narrowly"}
