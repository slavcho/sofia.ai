"""Checks on the chat loop (web/llm.py) against a fake OpenAI API that
replays scripted streams; nothing is sent to OpenAI."""

import json
import unittest
from types import SimpleNamespace
from unittest import mock

import httpx
import openai

from web import llm


class Item(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


def message(text):
    return Item(type="message", role="assistant", content=[{"type": "output_text", "text": text}])


def call(name, arguments, call_id="c1"):
    return Item(type="function_call", name=name, arguments=json.dumps(arguments), call_id=call_id)


def completed(*items, text=""):
    """The events of one streamed response."""
    events = [SimpleNamespace(type="response.output_text.delta", delta=d) for d in text.split("|") if d]
    return events + [SimpleNamespace(type="response.completed", response=SimpleNamespace(output=list(items)))]


class FakeAPI:
    """Hands out the scripted streams in order and keeps every request."""

    def __init__(self, *streams):
        self.streams, self.requests = list(streams), []
        self.responses = self

    def create(self, **request):
        self.requests.append({**request, "input": list(request["input"])})
        stream = self.streams.pop(0)
        if isinstance(stream, Exception):
            raise stream
        return iter(stream)


def turn(api, items=None, tools=None):
    items = items or [{"role": "user", "content": "How many metro lines?"}]
    return list(llm.run_turn(items, api=api, tools=tools or {}, instructions="test"))


class RunTurnTest(unittest.TestCase):
    def test_a_plain_answer(self):
        api = FakeAPI(completed(message("Four."), text="Fo|ur."))
        events = turn(api)
        self.assertEqual(events, [
            {"type": "text", "delta": "Fo"}, {"type": "text", "delta": "ur."},
            {"type": "items", "items": [message("Four.").to_dict()]},
            {"type": "done"}])
        request = api.requests[0]
        self.assertFalse(request["store"])
        self.assertEqual(request["include"], ["reasoning.encrypted_content"])
        self.assertEqual(request["instructions"], "test")

    def test_a_tool_is_run_and_its_output_sent_back(self):
        api = FakeAPI(completed(Item(type="reasoning", encrypted_content="xyz"),
                                call("count", {"what": "lines"})),
                      completed(message("Four.")))
        events = turn(api, tools={"count": lambda a: {"n": 4, "what": a["what"]}})
        output = {"type": "function_call_output", "call_id": "c1",
                  "output": json.dumps({"n": 4, "what": "lines"})}
        self.assertIn({"type": "tool", "call_id": "c1", "name": "count",
                       "arguments": '{"what": "lines"}'}, events)
        self.assertIn({"type": "tool_result", "call_id": "c1", "output": {"n": 4, "what": "lines"}}, events)
        self.assertIn({"type": "items", "items": [output]}, events)
        self.assertEqual(events[-1], {"type": "done"})
        # The second request carries the reasoning, the call and its output.
        second = api.requests[1]["input"]
        self.assertEqual([i.get("type") for i in second[1:]], ["reasoning", "function_call", "function_call_output"])
        self.assertEqual(second[1]["encrypted_content"], "xyz")

    def test_the_items_rebuild_the_conversation(self):
        api = FakeAPI(completed(call("count", {})), completed(message("Four.")))
        items = [{"role": "user", "content": "How many metro lines?"}]
        events = turn(api, items, tools={"count": lambda a: {"n": 4}})
        kept = items + [i for e in events if e["type"] == "items" for i in e["items"]]
        self.assertEqual(kept[:-1], api.requests[1]["input"])
        self.assertEqual(kept[-1]["type"], "message")

    def test_several_calls_in_one_step(self):
        api = FakeAPI(completed(call("count", {}, "a"), call("count", {}, "b")), completed(message("Done.")))
        events = turn(api, tools={"count": lambda a: {"n": 4}})
        self.assertEqual([e["call_id"] for e in events if e["type"] == "tool_result"], ["a", "b"])

    def test_tool_failures_go_back_to_the_model(self):
        def broken(a):
            raise RuntimeError("boom")
        api = FakeAPI(completed(call("nope", {}, "a"), call("broken", {}, "b"),
                                Item(type="function_call", name="count", arguments="{bad", call_id="c")),
                      completed(message("Sorry.")))
        events = turn(api, tools={"broken": broken, "count": lambda a: {}})
        results = {e["call_id"]: e["output"]["error"] for e in events if e["type"] == "tool_result"}
        self.assertEqual(results["a"], "there is no tool nope")
        self.assertEqual(results["b"], "broken failed: boom")
        self.assertTrue(results["c"].startswith("bad arguments for count"))
        self.assertEqual(events[-1], {"type": "done"})

    def test_the_steps_are_capped(self):
        api = FakeAPI(*[completed(call("count", {})) for _ in range(llm.MAX_STEPS)])
        events = turn(api, tools={"count": lambda a: {}})
        self.assertEqual(len(api.requests), llm.MAX_STEPS)
        self.assertEqual(events[-1]["type"], "error")
        self.assertIn("steps", events[-1]["message"])

    def test_an_api_error_ends_the_turn(self):
        request = httpx.Request("POST", "https://api.openai.com/v1/responses")
        error = openai.APIConnectionError(request=request)
        events = turn(FakeAPI(error))
        self.assertEqual(events[-1]["type"], "error")
        self.assertIn("the OpenAI API failed", events[-1]["message"])

    def test_a_failed_response_ends_the_turn(self):
        failed = SimpleNamespace(type="response.failed", response=SimpleNamespace(
            error=SimpleNamespace(message="overloaded"), incomplete_details=None))
        self.assertEqual(turn(FakeAPI([failed]))[-1], {"type": "error", "message": "the model stopped: overloaded"})

    def test_a_stream_without_its_end_is_an_error(self):
        events = turn(FakeAPI([SimpleNamespace(type="response.output_text.delta", delta="Fo")]))
        self.assertEqual(events[-1], {"type": "error", "message": "the model's answer was cut off"})

    def test_a_view_goes_to_the_page_not_to_the_model(self):
        api = FakeAPI(completed(call("show", {})), completed(message("Shown.")))
        events = turn(api, tools={"show": lambda a: {"shown": 2, "view": {"kind": "layer"}}})
        self.assertIn({"type": "view", "call_id": "c1", "view": {"kind": "layer"}}, events)
        self.assertIn({"type": "tool_result", "call_id": "c1", "output": {"shown": 2}}, events)
        self.assertEqual(api.requests[1]["input"][-1]["output"], '{"shown": 2}')
        kinds = [e["type"] for e in events]
        self.assertLess(kinds.index("view"), kinds.index("tool_result"))


class ShowOnMapTest(unittest.TestCase):
    GEOJSON = '{"type": "FeatureCollection", "features": []}'
    RESULT = {"shown": 1, "geometry_types": ["POINT"], "columns": ["name"],
              "extent": [23.3, 42.7, 23.3, 42.7], "truncated": False}

    def show(self, **args):
        args = {"sql": "SELECT ...", "title": "Stations", "color": None, "label_column": None, **args}
        with mock.patch("web.llm.llm_tools.query_geojson", return_value=(dict(self.RESULT), self.GEOJSON)):
            return llm.show_on_map(args)

    def test_the_layer_is_the_view(self):
        r = self.show(color="#E6550D", label_column="name")
        self.assertEqual(r.pop("view"), {"kind": "layer", "title": "Stations", "color": "#E6550D",
                                         "label_column": "name",
                                         "geojson": {"type": "FeatureCollection", "features": []}})
        self.assertEqual(r, self.RESULT)

    def test_a_bad_color_or_label_is_dropped(self):
        r = self.show(color="red", label_column="nope")
        self.assertIsNone(r["view"]["color"])
        self.assertIsNone(r["view"]["label_column"])
        self.assertEqual(r["note"], "no column nope to label with")

    def test_an_error_has_no_view(self):
        with mock.patch("web.llm.llm_tools.query_geojson", return_value=({"error": "bad"}, None)):
            self.assertEqual(llm.show_on_map({"sql": "x", "title": "t"}), {"error": "bad"})


class PromptTest(unittest.TestCase):
    def test_the_prompt_has_the_principles_and_the_issue_index(self):
        prompt = llm.base_instructions()
        self.assertIn("Cite the source", prompt)
        self.assertIn("# Tables and views", prompt)
        self.assertIn("| 1 ", prompt)

    def test_section(self):
        self.assertEqual(llm.section("# T\n\n## A\n\none\n\n## B\n\ntwo\n", "A"), "one")
        self.assertEqual(llm.section("## B\n\ntwo\n", "B"), "two")

    def test_tool_schemas_are_strict(self):
        for tool in llm.TOOLS:
            p = tool["parameters"]
            self.assertTrue(tool["strict"])
            self.assertEqual(sorted(p["required"]), sorted(p["properties"]), tool["name"])
            self.assertIs(p["additionalProperties"], False)
            self.assertIn(tool["name"], llm.SERVER_TOOLS)


if __name__ == "__main__":
    unittest.main()
