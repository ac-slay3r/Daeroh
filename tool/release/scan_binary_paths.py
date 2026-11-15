#!/usr/bin/env python3
"""Scan every decompressed APK member; exceptions are closed reviewed policy."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

DEFAULT_POLICY = Path(__file__).with_name("binary_path_exceptions.json")
PER_MEMBER_LIMIT = 128 * 1024 * 1024
TOTAL_LIMIT = 2 * 1024 * 1024 * 1024
# Preserve the original all-member ban, including even bare /home/ and /Users/.
PATTERN = re.compile(rb"(?:/home/|/Users/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+)")
ABIS = r"(?:arm64-v8a|armeabi-v7a|x86_64)"
SHERPA_MEMBER = re.compile(rf"lib/{ABIS}/libsherpa-onnx-(?:c-api|cxx-api)\.so")
APP_MEMBER = re.compile(rf"lib/{ABIS}/libapp\.so")
RUNNER_PREFIX = b"/home/runner/work/sherpa-onnx/"
IMAGE_LITERAL = rb"(?:/home/[A-Za-z0-9._-]+|/root|~)/\.hermes/cache/images/"


class PathScanError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PathScanError(f"duplicate exception policy field: {key}")
        result[key] = value
    return result


def load_policy(path: Path) -> dict:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
            raise PathScanError("invalid binary path exception policy file")
        policy = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, ValueError) as error:
        raise PathScanError(f"invalid binary path exception policy: {error}") from error
    if (not isinstance(policy, dict) or set(policy) != {"schema", "sherpa", "imageCacheRegexMembers"}
            or type(policy["schema"]) is not int or policy["schema"] != 1
            or not isinstance(policy["sherpa"], list)
            or not isinstance(policy["imageCacheRegexMembers"], list)):
        raise PathScanError("invalid binary path exception policy fields")
    members = set()
    for record in policy["sherpa"]:
        if (not isinstance(record, dict) or set(record) != {"member", "sha256"}
                or not isinstance(record["member"], str)
                or SHERPA_MEMBER.fullmatch(record["member"]) is None
                or not isinstance(record["sha256"], str)
                or re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None
                or record["member"] in members):
            raise PathScanError("invalid sherpa exception policy record")
        members.add(record["member"])
    members = set()
    for member in policy["imageCacheRegexMembers"]:
        if (not isinstance(member, str) or APP_MEMBER.fullmatch(member) is None
                or member in members):
            raise PathScanError("invalid image-cache exception policy record")
        members.add(member)
    return policy


def scan_member(member: str, data: bytes, policy: dict) -> None:
    matches = list(PATTERN.finditer(data))
    sherpa = next((r for r in policy["sherpa"] if r["member"] == member), None)
    if sherpa is not None:
        observed = hashlib.sha256(data).hexdigest()
        if observed != sherpa["sha256"]:
            raise PathScanError(f"private build path in APK member {member}: matched={matches[0].group() if matches else b''!r}; reason=sherpa decompressed SHA-256 mismatch; expected={sherpa['sha256']} observed={observed}")
    literal_start = data.find(IMAGE_LITERAL)
    literal_count = data.count(IMAGE_LITERAL)
    for match in matches:
        start = match.start()
        matched = data[start:start + 256].split(b"\x00", 1)[0]
        if sherpa is not None and data.startswith(RUNNER_PREFIX, start):
            continue
        if (member in policy["imageCacheRegexMembers"] and literal_count == 1
                and start == literal_start + IMAGE_LITERAL.index(b"/home/")):
            continue
        raise PathScanError(f"private build path in APK member {member}: matched={matched!r}; reason=not an exact reviewed path exception")


def scan_apk(path: Path, policy_path: Path = DEFAULT_POLICY) -> None:
    policy = load_policy(policy_path)  # Validate even when an APK has zero hits.
    total = 0
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            if member.file_size > PER_MEMBER_LIMIT:
                raise PathScanError(f"member exceeds decompressed scan limit: {member.filename}")
            total += member.file_size
            if total > TOTAL_LIMIT:
                raise PathScanError("APK exceeds total decompressed scan limit")
            with archive.open(member) as stream:
                data = stream.read(PER_MEMBER_LIMIT + 1)
            if len(data) != member.file_size or len(data) > PER_MEMBER_LIMIT:
                raise PathScanError(f"member decompressed size mismatch: {member.filename}")
            scan_member(member.filename, data, policy)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    args = parser.parse_args()
    try:
        scan_apk(args.apk, args.policy)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Binary path scan passed: {args.apk.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
