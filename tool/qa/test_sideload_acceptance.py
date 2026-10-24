#!/usr/bin/env python3
"""Unit tests for the pure helpers in sideload_acceptance.py (no device)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import sideload_acceptance as sa  # noqa: E402

UI = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node class="android.view.View" text="" content-desc="agent online · b0b" bounds="[0,0][100,40]"/>
  <node class="android.view.View" text="" content-desc="Chat: weekly plan" bounds="[0,50][100,90]"/>
  <node class="android.view.View" text="" content-desc="Chat: router notes" bounds="[0,100][100,140]"/>
  <node class="android.widget.EditText" text="sk-SECRET-VALUE" content-desc="" bounds="[0,150][300,200]"/>
  <node class="android.widget.Button" text="" content-desc="Send message" bounds="[300,150][360,210]"/>
</hierarchy>"""


class HelperTests(unittest.TestCase):
    def test_text_field_values_are_never_retained(self):
        nodes = sa.parse_ui(UI)
        field = next(n for n in nodes if n.editable)
        self.assertEqual(field.text, "")
        self.assertNotIn("SECRET", repr(nodes))

    def test_home_state(self):
        self.assertEqual(
            sa.home_state(sa.parse_ui(UI)),
            {"agent_online": True, "conversations": 2, "library_error": False},
        )

    def test_reply_must_not_be_the_prompt(self):
        prompt = "Reply with exactly: DAEROH-ACCEPT-ABC123"
        only_prompt = [sa.Node(prompt, "View", (0, 0, 1, 1), False)]
        self.assertFalse(sa.has_reply(only_prompt, "DAEROH-ACCEPT-ABC123", prompt))
        with_reply = only_prompt + [sa.Node("DAEROH-ACCEPT-ABC123", "View", (0, 0, 1, 1), False)]
        self.assertTrue(sa.has_reply(with_reply, "DAEROH-ACCEPT-ABC123", prompt))

    def test_center_and_prefix(self):
        send = sa.find_prefix(sa.parse_ui(UI), "Send message")
        assert send is not None
        self.assertEqual(send.center, (330, 180))
        self.assertIsNone(sa.find_prefix(sa.parse_ui(UI), "New chat"))

    def test_badging_and_signer(self):
        badging = (
            "package: name='cool.n0thing.daeroh' versionCode='6013' versionName='0.1.12'\n"
            "native-code: 'x86_64'\n"
        )
        self.assertEqual(
            sa.parse_badging(badging),
            {"package": "cool.n0thing.daeroh", "version_code": 6013, "abis": ["x86_64"]},
        )
        self.assertEqual(
            sa.parse_signer("Signer #1 certificate SHA-256 digest: 6fdcf871"), "6fdcf871"
        )

    def test_adb_text_rejects_shell_metacharacters(self):
        self.assertEqual(sa.adb_text("Reply with exactly: X-1"), "Reply%swith%sexactly:%sX-1")
        for bad in ["a;rm", "a$(x)", "a'b", "a&b"]:
            with self.assertRaises(ValueError):
                sa.adb_text(bad)


if __name__ == "__main__":
    unittest.main()
