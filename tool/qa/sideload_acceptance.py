#!/usr/bin/env python3
"""Emulator acceptance gate for a Daeroh sideload update.

Updates an already-configured emulator install in place and passes only if the
installed-app path works end to end:

  identity   same package, same signer, higher versionCode, ABI matches device
  update     `adb install -r` over the existing app; app-private sentinel kept
  launch     cold start reaches Home with "agent online"
  history    Home lists server conversations without a library error
  send       a new chat sends a probe and receives the assistant's reply
  recovery   that chat and reply survive a cold restart
  crashes    crash-buffer query succeeds and contains no package entries

Run through the toolchain wrapper so adb/aapt/apksigner are on PATH:

  tool/qa/with_local_toolchain.sh python3 tool/qa/sideload_acceptance.py \
      --baseline <previous-release-x86_64.apk> \
      --candidate build/app/outputs/flutter-apk/app-x86_64-full-release.apk

--baseline restores the previous release in place first (data kept), so the
gate is repeatable for the same candidate.

Privacy: never prints text-field contents, message bodies other than the
generated probe token, credentials, or hostnames. UI dumps stay in a private
temp dir that is removed on exit. Emulator only: refuses physical devices.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

PACKAGE = "cool.n0thing.daeroh"
DATA_DIR = f"/data/user/0/{PACKAGE}/files"


# ── pure helpers (unit-tested) ────────────────────────────────────────────


@dataclass
class Node:
    text: str
    cls: str
    bounds: tuple[int, int, int, int]
    editable: bool
    assistant: bool = False

    @property
    def center(self) -> tuple[int, int]:
        a, b, c, d = self.bounds
        return (a + c) // 2, (b + d) // 2


def parse_ui(xml_text: str) -> list[Node]:
    nodes: list[Node] = []
    def visit(n: ET.Element, assistant: bool = False) -> None:
        if n.tag != "node":
            for child in n:
                visit(child, assistant)
            return
        assistant = assistant or n.attrib.get("content-desc") == "Assistant response"
        nums = [int(x) for x in re.findall(r"\d+", n.attrib.get("bounds", ""))]
        if len(nums) == 4:
            cls = n.attrib.get("class", "")
            editable = cls.endswith("EditText")
            # Text-field values may be secrets; never keep them.
            label = "" if editable else (
                n.attrib.get("text") or n.attrib.get("content-desc") or ""
            )
            a, b, c, d = nums
            nodes.append(Node(label, cls, (a, b, c, d), editable, assistant))
        for child in n:
            visit(child, assistant)
    visit(ET.fromstring(xml_text))
    return nodes


def find_prefix(nodes: list[Node], prefix: str) -> Node | None:
    return next((n for n in nodes if n.text.startswith(prefix)), None)


def home_state(nodes: list[Node]) -> dict:
    return {
        "agent_online": any("agent online" in n.text for n in nodes),
        "conversations": sum(n.text.startswith("Chat:") for n in nodes),
        "library_error": any("could not be refreshed" in n.text for n in nodes),
    }


def find_probe_conversation(nodes: list[Node], token: str) -> Node | None:
    """Find the persisted server-library row for the exact probe conversation."""
    return next((n for n in nodes if not n.editable and
                 n.text.startswith("Chat:") and token in n.text), None)


def has_reply(nodes: list[Node], token: str, prompt: str) -> bool:
    """Require the exact answer inside the assistant-role accessibility group."""
    return any(n.assistant and not n.editable and
               not n.cls.endswith('Button') and n.text.strip() == token
               for n in nodes)


def parse_badging(text: str) -> dict:
    m = re.search(r"package: name='([^']+)' versionCode='(\d+)'", text)
    abis = re.findall(r"'([^']+)'", next(
        (l for l in text.splitlines() if l.startswith("native-code:")), ""))
    return {
        "package": m.group(1) if m else None,
        "version_code": int(m.group(2)) if m else None,
        "abis": abis,
    }


def parse_signer(text: str) -> str | None:
    m = re.search(r"^Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]{64})$", text, re.M)
    return m.group(1).lower() if m else None


def baseline_upgrade_order(baseline: int | None, installed: int | None,
                           candidate: int | None) -> bool:
    """Allow repeated candidate acceptance, but never install a newer APK over it."""
    return (baseline is not None and installed is not None and candidate is not None
            and baseline < candidate and baseline <= installed <= candidate)


def adb_text(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9 :._-]+", value):
        raise ValueError("probe text must stay adb-input safe")
    return value.replace(" ", "%s")


# ── device driver ─────────────────────────────────────────────────────────


@dataclass
class Gate:
    results: list[tuple[str, bool, str]] = field(default_factory=list)

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append((name, ok, detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""),
              flush=True)
        return ok

    @property
    def passed(self) -> bool:
        return bool(self.results) and all(ok for _, ok, _ in self.results)


class Device:
    def __init__(self, serial: str | None, tmp: str):
        self.base = ["adb"] + (["-s", serial] if serial else [])
        self.tmp = tmp

    def run(self, *args: str, check: bool = True, timeout: int = 120) -> str:
        r = subprocess.run(self.base + list(args), capture_output=True, text=True,
                           timeout=timeout)
        if check and r.returncode != 0:
            raise RuntimeError(f"adb {args[0]} failed ({r.returncode})")
        return r.stdout.replace("\r", "")

    def sh(self, cmd: str, check: bool = True) -> str:
        return self.run("shell", cmd, check=check)

    def ui(self, attempts: int = 6) -> list[Node]:
        for _ in range(attempts):
            self.sh("uiautomator dump /sdcard/acceptance-ui.xml >/dev/null 2>&1", check=False)
            xml = self.sh("cat /sdcard/acceptance-ui.xml", check=False)
            self.sh("rm -f /sdcard/acceptance-ui.xml", check=False)
            if xml.lstrip().startswith("<?xml"):
                try:
                    return parse_ui(xml)
                except ET.ParseError:
                    pass
            time.sleep(2)
        return []

    def tap(self, node: Node) -> None:
        x, y = node.center
        self.sh(f"input tap {x} {y}")

    def wait_for(self, predicate, timeout: float, interval: float = 3):
        deadline = time.monotonic() + timeout
        nodes: list[Node] = []
        while time.monotonic() < deadline:
            nodes = self.ui()
            if predicate(nodes):
                return nodes
            time.sleep(interval)
        return None

    def screenshot(self, path: str) -> None:
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "wb") as fh:
            os.fchmod(fh.fileno(), 0o600)
            subprocess.run(self.base + ["exec-out", "screencap", "-p"], stdout=fh,
                           timeout=30, check=False)

    def installed_version(self) -> int | None:
        m = re.search(r"versionCode=(\d+)", self.sh(f"dumpsys package {PACKAGE}", check=False))
        return int(m.group(1)) if m else None

    def installed_signer(self) -> str | None:
        path = self.sh(f"pm path {PACKAGE}", check=False).strip().splitlines()
        base = next((p.split(":", 1)[1] for p in path if p.endswith("base.apk")), None)
        if not base:
            return None
        local = os.path.join(self.tmp, "installed.apk")
        self.run("pull", base, local, timeout=180)
        return parse_signer(tool("apksigner", "verify", "--print-certs", local))


def tool(name: str, *args: str) -> str:
    if not shutil.which(name):
        raise RuntimeError(f"{name} not on PATH; run via tool/qa/with_local_toolchain.sh")
    return subprocess.run([name, *args], capture_output=True, text=True,
                          check=True, timeout=180).stdout


# ── acceptance flow ───────────────────────────────────────────────────────


def accept(args: argparse.Namespace, tmp: str) -> Gate:
    gate = Gate()
    dev = Device(args.serial, tmp)

    # identity
    if not gate.check("device is an emulator",
                      dev.sh("getprop ro.kernel.qemu", check=False).strip() == "1"
                      or dev.sh("getprop ro.boot.qemu", check=False).strip() == "1"):
        return gate
    cand = parse_badging(tool("aapt", "dump", "badging", args.candidate))
    abi = dev.sh("getprop ro.product.cpu.abi").strip()
    before = dev.installed_version()
    installed_signer = dev.installed_signer() if before is not None else None
    candidate_signer = parse_signer(tool("apksigner", "verify", "--print-certs", args.candidate))
    gate.check("candidate package", cand["package"] == PACKAGE)
    gate.check("candidate ABI matches device", abi in cand["abis"], abi)
    gate.check("existing configured install present", before is not None,
               "acceptance updates in place; configure the emulator first")
    gate.check("valid signer continuity", bool(installed_signer) and
               installed_signer == candidate_signer)
    base: dict = {}
    base_signer: str | None = None
    if args.baseline:
        # Roll back to the previous release in place (data kept) so the same
        # candidate can be accepted repeatedly, e.g. pre- and post-merge.
        base = parse_badging(tool("aapt", "dump", "badging", args.baseline))
        base_signer = parse_signer(tool("apksigner", "verify", "--print-certs", args.baseline))
        gate.check("baseline package", base["package"] == PACKAGE)
        gate.check("baseline ABI matches device", abi in base["abis"], abi)
        gate.check("baseline version before candidate",
                   baseline_upgrade_order(base["version_code"], before,
                                          cand["version_code"]))
        gate.check("baseline signer continuity", bool(installed_signer) and
                   installed_signer == base_signer == candidate_signer)
    else:
        gate.check("versionCode strictly higher", before is not None and
                   cand["version_code"] is not None and cand["version_code"] > before)
    if not gate.passed:
        return gate

    # Plant before *any* install; rollback must preserve the configured data too.
    uid = re.search(r"uid:(\d+)", dev.sh(f"cmd package list packages -U {PACKAGE}"))
    dev.run("root", check=False)
    dev.run("wait-for-device")
    nonce = secrets.token_hex(8)
    sentinel = f"{DATA_DIR}/acceptance-sentinel"
    dev.sh(f"mkdir -p {DATA_DIR} && printf {nonce} > {sentinel}"
           + (f" && chown {uid.group(1)}:{uid.group(1)} {sentinel}" if uid else ""))
    if args.baseline:
        out = dev.run("install", "-r", "-d", args.baseline, timeout=300, check=False)
        if not gate.check("baseline restored in place",
                          "Success" in out
                          and dev.installed_version() == base["version_code"],
                          f"versionCode {base['version_code']}"):
            return gate
        gate.check("baseline data preserved", dev.sh(f"cat {sentinel}", check=False).strip() == nonce)
        gate.check("baseline installed signer", dev.installed_signer() == base_signer)
        if not gate.passed:
            return gate

    # update in place with an app-private sentinel
    dev.run("logcat", "-b", "all", "-c", check=False)
    out = dev.run("install", "-r", args.candidate, timeout=300, check=False)
    gate.check("install -r over existing", "Success" in out)
    gate.check("installed versionCode", dev.installed_version() == cand["version_code"])
    gate.check("installed candidate signer", dev.installed_signer() == candidate_signer)
    gate.check("app-private data preserved",
               dev.sh(f"cat {sentinel}", check=False).strip() == nonce)
    if not gate.passed:
        return gate
    dev.sh(f"rm -f {sentinel}", check=False)

    # cold launch → Home
    dev.sh(f"am force-stop {PACKAGE}")
    dev.sh(f"monkey -p {PACKAGE} -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1",
           check=False)
    nodes = dev.wait_for(lambda n: home_state(n)["agent_online"]
                         and home_state(n)["conversations"] > 0, args.home_timeout)
    state = home_state(nodes or dev.ui())
    gate.check("cold launch reaches Home online", state["agent_online"])
    gate.check("Home lists server conversations", state["conversations"] > 0,
               f"{state['conversations']} shown")
    gate.check("no session-library error", not state["library_error"])
    if not gate.passed:
        return gate

    # new chat → probe → assistant reply
    token = f"DAEROH-ACCEPT-{nonce[:6].upper()}"
    prompt = f"Reply with exactly: {token}"
    menu = find_prefix(dev.ui(), "Open navigation menu")
    if menu:
        dev.tap(menu)
        time.sleep(1.5)
    new_chat = find_prefix(dev.ui(), "New chat")
    if new_chat is None:
        gate.check("new chat opened", False)
        return gate
    dev.tap(new_chat)
    time.sleep(3)
    field_ = next((n for n in dev.ui() if n.editable), None)
    if field_ is None:
        gate.check("composer found", False)
        return gate
    dev.tap(field_)
    time.sleep(0.8)
    dev.sh(f"input text {adb_text(prompt)}")
    time.sleep(1)
    send = find_prefix(dev.ui(), "Send message")
    if send is None:
        gate.check("send button found", False)
        return gate
    dev.tap(send)
    got = dev.wait_for(lambda n: has_reply(n, token, prompt), args.reply_timeout, 5)
    nodes = got or dev.ui()
    gate.check("assistant reply received", got is not None)
    gate.check("no send/storage error",
               not any("stored securely" in n.text or "wasn't sent" in n.text for n in nodes))

    # restart and crashes
    dev.sh(f"am force-stop {PACKAGE}")
    dev.sh(f"monkey -p {PACKAGE} -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1",
           check=False)
    restarted = dev.wait_for(lambda n: home_state(n)["agent_online"],
                             args.home_timeout)
    gate.check("cold restart reaches Home", restarted is not None)
    if not gate.passed:
        return gate
    persisted = dev.wait_for(lambda n: find_probe_conversation(n, token) is not None,
                             args.home_timeout)
    gate.check("probe chat survives cold restart", persisted is not None)
    if not gate.passed:
        return gate
    assert persisted is not None
    row = find_probe_conversation(persisted, token)
    assert row is not None
    dev.tap(row)
    gate.check("probe reply survives cold restart",
               dev.wait_for(lambda n: has_reply(n, token, prompt),
                            args.home_timeout) is not None)
    # A failed logcat command must fail the gate, never masquerade as zero crashes.
    crashes = dev.run("logcat", "-d", "-b", "crash").count(PACKAGE)
    gate.check("no crash-buffer entries", crashes == 0, f"{crashes} entries")
    return gate


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("--candidate", required=True, help="candidate APK for the emulator ABI")
    ap.add_argument("--baseline", help="previous release APK to restore in place first")
    ap.add_argument("--serial", help="adb serial (default: the only device)")
    ap.add_argument("--home-timeout", type=int, default=45)
    ap.add_argument("--reply-timeout", type=int, default=150)
    ap.add_argument("--artifacts", help="directory for a failure screenshot and summary")
    args = ap.parse_args(argv)

    tmp = tempfile.mkdtemp(prefix="daeroh-accept-")
    os.chmod(tmp, 0o700)
    try:
        try:
            gate = accept(args, tmp)
        except (RuntimeError, subprocess.SubprocessError) as exc:
            gate = Gate()
            gate.check("acceptance run", False, str(exc))
        if args.artifacts:
            os.makedirs(args.artifacts, exist_ok=True)
            os.chmod(args.artifacts, 0o700)
            summary_path = os.path.join(args.artifacts, "acceptance.json")
            with os.fdopen(os.open(summary_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "w") as fh:
                os.fchmod(fh.fileno(), 0o600)
                json.dump({"passed": gate.passed,
                           "checks": [{"name": n, "ok": ok, "detail": d}
                                      for n, ok, d in gate.results]}, fh, indent=2)
            if not gate.passed:
                Device(args.serial, tmp).screenshot(
                    os.path.join(args.artifacts, "failure.png"))
        print("ACCEPTANCE", "PASSED" if gate.passed else "FAILED",
              f"({sum(ok for _, ok, _ in gate.results)}/{len(gate.results)} checks)")
        return 0 if gate.passed else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
