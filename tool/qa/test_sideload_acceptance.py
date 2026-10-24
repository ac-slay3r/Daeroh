#!/usr/bin/env python3
"""Unit tests for the pure helpers in sideload_acceptance.py (no device)."""

import argparse
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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
        with_reply = only_prompt + [sa.Node("DAEROH-ACCEPT-ABC123", "View", (0, 0, 1, 1), False, True)]
        self.assertTrue(sa.has_reply(with_reply, "DAEROH-ACCEPT-ABC123", prompt))

    def test_xml_assistant_role_is_inherited_but_not_from_sibling(self):
        token = "DAEROH-ACCEPT-ABC123"
        xml = f'''<hierarchy><node bounds="[0,0][10,10]" content-desc="Error: {token}"/>
        <node bounds="[0,0][10,10]" content-desc="Assistant response"><node bounds="[0,0][10,10]" text="{token}"/></node></hierarchy>'''
        self.assertTrue(sa.has_reply(sa.parse_ui(xml), token, 'Reply with exactly: ' + token))
        self.assertFalse(sa.has_reply(sa.parse_ui(xml.replace('Assistant response', 'Sending')), token, 'Reply with exactly: ' + token))

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
        self.assertEqual(sa.parse_signer("Signer #1 certificate SHA-256 digest: " + "a" * 64), "a" * 64)
        for invalid in ("", "Signer #1 certificate SHA-256 digest: 6fdcf871", "Signer #1 certificate SHA-256 digest: " + "g" * 64):
            self.assertIsNone(sa.parse_signer(invalid))

    def test_token_in_error_or_unverified_bubble_is_not_assistant_reply(self):
        token = "DAEROH-ACCEPT-ABC123"
        prompt = f"Reply with exactly: {token}"
        nodes = [sa.Node(prompt, "View", (0, 0, 1, 1), False),
                 sa.Node(f"Error: {token} wasn't sent", "View", (0, 0, 1, 1), False),
                 sa.Node(token, "View", (0, 0, 1, 1), False)]
        self.assertFalse(sa.has_reply(nodes, token, prompt))

    def test_crash_buffer_query_failure_cannot_look_like_zero_crashes(self):
        failed = subprocess.CompletedProcess(['adb', 'logcat'], 1, stdout='', stderr='')
        with patch.object(sa.subprocess, 'run', return_value=failed):
            with self.assertRaisesRegex(RuntimeError, 'adb logcat failed'):
                sa.Device(None, '/unused').run('logcat', '-d', '-b', 'crash')

    def test_persisted_probe_must_be_a_server_chat_row(self):
        token = "DAEROH-ACCEPT-ABC123"
        error = sa.Node(f"Error: {token} was not sent", "View", (0, 0, 1, 1), False)
        other = sa.Node("Chat: Weekly plan, 2 messages", "View", (0, 0, 1, 1), False)
        row = sa.Node(f"Chat: Provide {token}, 2 messages", "View", (0, 0, 1, 1), False)
        self.assertIsNone(sa.find_probe_conversation([error, other], token))
        self.assertIs(sa.find_probe_conversation([error, other, row], token), row)

    def test_baseline_upgrade_order_allows_reaccepting_same_candidate_version(self):
        self.assertTrue(sa.baseline_upgrade_order(6012, 6013, 6013))
        self.assertTrue(sa.baseline_upgrade_order(6012, 6012, 6013))
        self.assertFalse(sa.baseline_upgrade_order(6013, 6013, 6013))
        self.assertFalse(sa.baseline_upgrade_order(6012, 6014, 6013))
        self.assertFalse(sa.baseline_upgrade_order(6012, None, 6013))

    def test_baseline_preflight_and_sentinel_span_both_installs(self):
        class FakeDevice:
            commands = []
            version = 20
            sentinel = ""
            lose_on_rollback = False
            def __init__(self, *args): pass
            def sh(self, cmd, check=True):
                if "getprop ro.kernel.qemu" in cmd: return "1"
                if "getprop ro.product.cpu.abi" in cmd: return "x86_64"
                if "cmd package list" in cmd: return "package:cool.n0thing.daeroh uid:10001"
                if "printf" in cmd: self.sentinel = cmd.split("printf ")[1].split(" >")[0]
                if "cat " in cmd: return self.sentinel
                return ""
            def installed_version(self): return self.version
            def installed_signer(self): return "a" * 64
            def run(self, *cmd, **kw):
                self.commands.append(cmd)
                if cmd[:2] == ("install", "-r"):
                    self.version = 10 if "baseline" in cmd[-1] else 30
                    if self.version == 10 and self.lose_on_rollback:
                        self.sentinel = ""
                    return "Success"
                return ""
            def ui(self): return []
            def wait_for(self, *args): return None
        device = FakeDevice()
        args = argparse.Namespace(serial=None, baseline="baseline.apk", candidate="candidate.apk", home_timeout=0, reply_timeout=0)
        def tool(name, *cmd):
            if name == "aapt":
                version = 10 if "baseline" in cmd[-1] else 30
                return f"package: name='cool.n0thing.daeroh' versionCode='{version}'\nnative-code: 'x86_64'"
            return "Signer #1 certificate SHA-256 digest: " + "a" * 64
        with patch.object(sa, "Device", return_value=device), patch.object(sa, "tool", side_effect=tool):
            with tempfile.TemporaryDirectory() as tmp:
                gate = sa.accept(args, tmp)
        self.assertEqual(len([c for c in device.commands if c[:2] == ("install", "-r")]), 2)
        self.assertIn("baseline data preserved", [name for name, _, _ in gate.results])
        lost = FakeDevice()
        lost.commands = []
        lost.lose_on_rollback = True
        with patch.object(sa, "Device", return_value=lost), patch.object(sa, "tool", side_effect=tool):
            with tempfile.TemporaryDirectory() as tmp:
                failed = sa.accept(args, tmp)
        self.assertFalse(failed.passed)
        self.assertEqual(len([c for c in lost.commands if c[:2] == ("install", "-r")]), 1)

    def test_rejects_invalid_baseline_identity_or_signer_before_install(self):
        class FakeDevice:
            commands = []
            def __init__(self, *args): pass
            def sh(self, cmd, check=True):
                return "1" if "qemu" in cmd else "x86_64"
            def installed_version(self): return 20
            def installed_signer(self): return "a" * 64
            def run(self, *cmd, **kw): self.commands.append(cmd); return "Success"
        args = argparse.Namespace(serial=None, baseline="baseline.apk", candidate="candidate.apk")
        for bad in ("package: name='other.app' versionCode='10'\nnative-code: 'x86_64'", "package: name='cool.n0thing.daeroh' versionCode='10'\nnative-code: 'x86_64'"):
            dev = FakeDevice(); dev.commands = []
            def tool(name, *cmd):
                if name == "aapt": return bad if "baseline" in cmd[-1] else "package: name='cool.n0thing.daeroh' versionCode='30'\nnative-code: 'x86_64'"
                return "Signer #1 certificate SHA-256 digest: " + ("b" if "baseline" in cmd[-1] else "a") * 64
            with patch.object(sa, "Device", return_value=dev), patch.object(sa, "tool", side_effect=tool):
                sa.accept(args, "unused")
            self.assertFalse(any(c[0] == "install" for c in dev.commands))
        dev = FakeDevice(); dev.commands = []
        with patch.object(sa, "Device", return_value=dev), patch.object(sa, "tool", side_effect=lambda name, *cmd: (
            "package: name='cool.n0thing.daeroh' versionCode='30'\nnative-code: 'x86_64'"
            if name == "aapt" else "Signer #1 certificate SHA-256 digest: invalid"
        )):
            failed = sa.accept(args, "unused")
        self.assertFalse(failed.passed)
        self.assertFalse(any(c[0] == "install" for c in dev.commands))

    def test_failure_screenshot_is_private_even_with_permissive_umask(self):
        class FakeProcess:
            def __init__(self, *args, **kw): kw['stdout'].write(b"png")
        with tempfile.TemporaryDirectory() as tmp, patch.object(sa.subprocess, "run", side_effect=FakeProcess):
            path = os.path.join(tmp, "failure.png")
            old = os.umask(0)
            try: sa.Device(None, tmp).screenshot(path)
            finally: os.umask(old)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_adb_text_rejects_shell_metacharacters(self):
        self.assertEqual(sa.adb_text("Reply with exactly: X-1"), "Reply%swith%sexactly:%sX-1")
        for bad in ["a;rm", "a$(x)", "a'b", "a&b"]:
            with self.assertRaises(ValueError):
                sa.adb_text(bad)


if __name__ == "__main__":
    unittest.main()
