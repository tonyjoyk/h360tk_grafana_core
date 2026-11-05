"""Claude wording (story 6.6, AD-32). A fake client; no network, no SDK call."""

from __future__ import annotations

import json
import logging
import unittest
from types import SimpleNamespace

from h360_api import wording
from h360_api.tests.test_ranker import facts_for
from h360_api.tests.test_registry import ask, chat_client

KEY = "sk-ant-test-0000-do-not-log"


class FakeMessages:
    def __init__(self, reply):
        self.reply = reply
        self.calls = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self.reply, BaseException):
            raise self.reply
        text = self.reply(kwargs) if callable(self.reply) else self.reply
        return SimpleNamespace(content=[SimpleNamespace(type="text", text=text)])


class FakeClaude:
    def __init__(self, reply):
        self.messages = FakeMessages(reply)
        self.keys = []

    def factory(self, api_key):
        self.keys.append(api_key)
        return self


def sent_sentences(kwargs) -> dict:
    return json.loads(kwargs["messages"][0]["content"])["sentences"]


def polite(kwargs) -> str:
    """Rewrites each sentence with a one-word prefix, keeping numbers and placeholders."""
    return json.dumps({k: "So, " + v[0].lower() + v[1:] for k, v in sent_sentences(kwargs).items()})


class ClaudeModeTests(unittest.TestCase):
    def compose(self, reply, chip="why_control_low", org=11):
        fake = FakeClaude(reply)
        facts = facts_for(chip, org)
        answer = wording.compose(facts, KEY, "claude-sonnet-5-5", fake.factory)
        return answer, fake, facts

    def test_good_rewrite_is_claude_mode(self):
        answer, fake, facts = self.compose(polite)
        self.assertEqual(answer["mode"], "claude")
        self.assertEqual(len(fake.messages.calls), 1)
        call = fake.messages.calls[0]
        self.assertEqual(call["model"], "claude-sonnet-5-5")
        self.assertEqual(call["timeout"], 8.0)
        self.assertTrue(answer["reasons"][0]["text"].startswith("So, "))
        self.assertIn("PHC-E", answer["also_check"])  # names restored after the call
        self.assertIsNotNone(answer["reasons"][0]["evidence"])  # the evidence is never sent, never lost
        self.assertEqual(wording.check_answer(answer, facts), [])
        self.assertEqual(answer["honesty"], wording.HONESTY)

    def test_payload_has_no_names_ids_rows_or_honesty(self):
        _answer, fake, _facts = self.compose(polite, chip="visit_first", org=10)
        payload = json.dumps(fake.messages.calls[0], default=str)
        for secret in ("PHC-E", "PHC-F", "District-D", "org_unit_id", "patient_id", KEY, "2% to 12%"):
            self.assertNotIn(secret, payload)
        self.assertNotIn("47", json.dumps(sent_sentences(fake.messages.calls[0])))
        self.assertIn("{p", payload)

    def test_numbers_and_title_are_never_sent_for_rewrite_beyond_the_sentences(self):
        _answer, fake, _facts = self.compose(polite)
        keys = set(sent_sentences(fake.messages.calls[0]))
        self.assertEqual(keys, {"r0_text", "r0_what_to_do", "r1_text", "r1_what_to_do", "r2_text",
                                "r2_what_to_do", "also_check"})

    def test_changed_number_falls_back(self):
        def change(kwargs):
            s = sent_sentences(kwargs)
            s["r0_text"] = s["r0_text"].replace("308", "309")
            return json.dumps(s)

        answer, _fake, _facts = self.compose(change)
        self.assertEqual(answer["mode"], "offline_fallback")
        self.assertTrue(answer["reasons"][0]["text"].startswith("Many BP readings sit just under 140: 308 of 130–139"))

    def test_invented_number_falls_back(self):
        def add(kwargs):
            s = sent_sentences(kwargs)
            s["r0_what_to_do"] += " Aim for 80%."
            return json.dumps(s)

        self.assertEqual(self.compose(add)[0]["mode"], "offline_fallback")

    def test_banned_words_fall_back(self):
        for word in ("will", "guarantees", "Guaranteed"):
            def bad(kwargs, word=word):
                s = sent_sentences(kwargs)
                s["r1_what_to_do"] = f"This {word} help."
                return json.dumps(s)

            with self.subTest(word=word):
                self.assertEqual(self.compose(bad)[0]["mode"], "offline_fallback")

    def test_long_sentence_falls_back(self):
        def long(kwargs):
            s = sent_sentences(kwargs)
            s["r1_what_to_do"] = " ".join(["step"] * 25) + "."
            return json.dumps(s)

        self.assertEqual(self.compose(long)[0]["mode"], "offline_fallback")

    def test_dropped_placeholder_or_key_falls_back(self):
        def drop_ph(kwargs):
            s = sent_sentences(kwargs)
            s["also_check"] = s["also_check"].replace("{p0}", "the clinic")
            return json.dumps(s)

        def drop_key(kwargs):
            s = sent_sentences(kwargs)
            s.pop("r0_text")
            return json.dumps(s)

        self.assertEqual(self.compose(drop_ph)[0]["mode"], "offline_fallback")
        self.assertEqual(self.compose(drop_key)[0]["mode"], "offline_fallback")

    def test_failures_fall_back(self):
        for reply in (TimeoutError("timed out"), RuntimeError("boom " + KEY), "not json", "{\"r0_text\": 3}"):
            with self.subTest(reply=type(reply).__name__):
                answer, _fake, _facts = self.compose(reply)
                self.assertEqual(answer["mode"], "offline_fallback")
                self.assertEqual(answer["honesty"], wording.HONESTY)

    def test_factory_failure_falls_back(self):
        def broken(_key):
            raise RuntimeError("no sdk")

        answer = wording.compose(facts_for("why_control_low", 3), KEY, "m", broken)
        self.assertEqual(answer["mode"], "offline_fallback")

    def test_no_key_never_calls_claude(self):
        fake = FakeClaude(polite)
        answer = wording.compose(facts_for("why_control_low", 3), "", "m", fake.factory)
        self.assertEqual(answer["mode"], "offline")
        self.assertEqual(fake.keys, [])

    def test_key_never_logged(self):
        with self.assertLogs("h360_api.chat", level="WARNING") as captured:
            self.compose(RuntimeError("401 bad key " + KEY))
        self.assertTrue(captured.output)
        self.assertFalse(any(KEY in line for line in captured.output))
        self.assertFalse(any("bad key" in line for line in captured.output))


class ClaudeEndpointTests(unittest.TestCase):
    def test_endpoint_uses_claude_when_the_key_is_set(self):
        fake = FakeClaude(polite)
        client, _db = chat_client(api_key=KEY, claude_factory=fake.factory)
        chips = client.get("/chat/chips", params={"org_unit_id": "11"}).json()
        self.assertEqual(chips["mode"], "claude")
        res = ask(client, {"chip_id": "why_control_low", "org_unit_id": "11", "reporting_month": "2026-10-01"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()["mode"], "claude")
        self.assertNotIn(KEY, res.text)
        self.assertEqual(fake.keys, [KEY])

    def test_endpoint_falls_back_on_timeout(self):
        fake = FakeClaude(TimeoutError("slow"))
        client, _db = chat_client(api_key=KEY, claude_factory=fake.factory)
        res = ask(client, {"chip_id": "who_to_call", "org_unit_id": "3", "reporting_month": "2026-10-01"})
        body = res.json()
        self.assertEqual(body["mode"], "offline_fallback")
        self.assertEqual(body["plan"]["total"], 1421)
        self.assertNotIn(KEY, res.text)

    def test_real_client_is_configured_for_one_try_in_8_seconds(self):
        client = wording.make_claude_client(KEY)
        self.assertEqual(client.max_retries, 0)
        self.assertEqual(client.timeout, 8.0)
        self.assertNotIn(KEY, repr(client))


if __name__ == "__main__":
    unittest.main()
