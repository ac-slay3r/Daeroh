#!/usr/bin/env python3
"""Fail closed unless a direct-release evidence archive has the exact schema."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath

ROOT = "release-evidence"
APKS = (
    "app-arm64-v8a-full-release",
    "app-armeabi-v7a-full-release",
    "app-x86_64-full-release",
)
PUBLIC_APK_FILES = tuple(f"{name}.apk" for name in APKS)
LEAVES = (
    "fullRelease.cdx.json",
    "fullRelease.artifact.json",
    "fullRelease.license-review.json",
    "source-assets.json",
    "public-apk-facts.json",
)
REQUIRED_FILES = {
    "rebuild-comparison.json",
    *{f"artifacts/full/{apk}/{leaf}" for apk in APKS for leaf in LEAVES},
}
MANIFEST = "SHA256SUMS"
CHECKSUM = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$")
MAX_MEMBERS = 128
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024


class ValidationError(ValueError):
    pass


def normalized_name(member: tarfile.TarInfo) -> str:
    raw = member.name
    path = PurePosixPath(raw.rstrip("/"))
    if (
        not raw
        or "\\" in raw
        or path.is_absolute()
        or not path.parts
        or path.parts[0] != ROOT
        or "." in path.parts
        or ".." in path.parts
        or raw.rstrip("/") != path.as_posix()
        or (not member.isdir() and raw.endswith("/"))
        or not (member.isdir() or member.isfile())
        or member.issym()
        or member.islnk()
    ):
        raise ValidationError(f"archive member: {raw}: invalid path or unsupported member type")
    return path.as_posix()


def read_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    if not member.isfile() or member.size < 0 or member.size > MAX_FILE_BYTES:
        raise ValidationError(f"archive member: {member.name}: not a regular file or size outside limit")
    stream = archive.extractfile(member)
    if stream is None:
        raise ValidationError(f"archive member: {member.name}: cannot read member")
    data = stream.read(member.size + 1)
    if len(data) != member.size:
        raise ValidationError(f"archive member: {member.name}: truncated content")
    return data


def parse_manifest(raw: bytes) -> dict[str, str]:
    if len(raw) > 256 * 1024 or b"\x00" in raw:
        raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: oversized or NUL-containing manifest")
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: not ASCII: {error}") from error
    if len(lines) != len(REQUIRED_FILES):
        raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: wrong line count")
    result: dict[str, str] = {}
    for line in lines:
        match = CHECKSUM.fullmatch(line)
        if match is None:
            raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: malformed checksum line")
        digest, relative = match.groups()
        path = PurePosixPath(relative)
        if (
            relative != path.as_posix()
            or path.is_absolute()
            or "." in path.parts
            or ".." in path.parts
            or relative in result
        ):
            raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: invalid or duplicate path: {relative}")
        result[relative] = digest
    if set(result) != REQUIRED_FILES:
        raise ValidationError(f"checksums: {'release-evidence/SHA256SUMS'}: wrong file set")
    return result


def validate_rebuild_report(raw: bytes) -> None:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: invalid JSON or UTF-8: {error}") from error
    canonical = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if not isinstance(value, dict) or canonical != raw:
        raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: not canonical JSON object")
    if (
        value.get("schema") != 1
        or value.get("channel") != "direct-public"
        or value.get("gatePassed") is not True
        or value.get("inputsCryptographicallyPinned") is not False
        or value.get("observedTwoBuildByteIdentity") is not True
        or value.get("byteReproducible") is not False
        or value.get("claim") != "observed-two-build-byte-identical"
    ):
        raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: schema, channel or byte-identity claims do not match policy")
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != len(PUBLIC_APK_FILES):
        raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: wrong artifact list type or length")
    seen = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {
            "name", "byteIdentical", "firstSha256", "secondSha256"
        }:
            raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: malformed artifact record")
        first = artifact["firstSha256"]
        second = artifact["secondSha256"]
        if (
            artifact["byteIdentical"] is not True
            or not isinstance(first, str)
            or re.fullmatch(r"[0-9a-f]{64}", first) is None
            or first != second
        ):
            raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: artifact not byte-identical or hashes invalid")
        seen.append(artifact["name"])
    if tuple(seen) != PUBLIC_APK_FILES:
        raise ValidationError(f"rebuild: {'release-evidence/rebuild-comparison.json'}: wrong artifact names/order")


def validate(archive_path: Path) -> None:
    if (
        not archive_path.is_file()
        or archive_path.is_symlink()
        or archive_path.stat().st_size > MAX_ARCHIVE_BYTES
    ):
        raise ValidationError(f"archive: {archive_path}: missing, linked, non-file or compressed size outside limit")
    try:
        with tarfile.open(archive_path, mode="r|gz") as archive:
            kinds: dict[str, str] = {}
            contents: dict[str, bytes] = {}
            total = 0
            member_count = 0
            for member_count, member in enumerate(archive, start=1):
                if member_count > MAX_MEMBERS:
                    raise ValidationError(f"archive: {archive_path}: too many members")
                name = normalized_name(member)
                if name in kinds:
                    raise ValidationError(f"archive member: {name}: duplicate member")
                kinds[name] = "directory" if member.isdir() else "file"
                if member.isfile():
                    total += member.size
                    if total > MAX_TOTAL_BYTES:
                        raise ValidationError(f"archive: {archive_path}: total uncompressed size outside limit")
                    contents[name] = read_member(archive, member)
            if member_count == 0:
                raise ValidationError(f"archive: {archive_path}: empty archive")
            expected_archive_files = {
                f"{ROOT}/{relative}" for relative in REQUIRED_FILES | {MANIFEST}
            }
            actual_archive_files = {
                name for name, kind in kinds.items() if kind == "file"
            }
            if actual_archive_files != expected_archive_files:
                raise ValidationError(f"archive: {archive_path}: wrong file set; missing={sorted(expected_archive_files - actual_archive_files)}, extra={sorted(actual_archive_files - expected_archive_files)}")
            required_directories = {
                ROOT,
                f"{ROOT}/artifacts",
                f"{ROOT}/artifacts/full",
                *{f"{ROOT}/artifacts/full/{apk}" for apk in APKS},
            }
            actual_directories = {
                name for name, kind in kinds.items() if kind == "directory"
            }
            if actual_directories != required_directories:
                raise ValidationError(f"archive: {archive_path}: wrong directory set; missing={sorted(required_directories - actual_directories)}, extra={sorted(actual_directories - required_directories)}")
            manifest = parse_manifest(contents[f"{ROOT}/{MANIFEST}"])
            for relative, expected_digest in manifest.items():
                data = contents[f"{ROOT}/{relative}"]
                if hashlib.sha256(data).hexdigest() != expected_digest:
                    raise ValidationError(f"checksums: {f'{ROOT}/{relative}'}: SHA-256 mismatch")
            validate_rebuild_report(contents[f"{ROOT}/rebuild-comparison.json"])
    except (OSError, tarfile.TarError) as error:
        raise ValidationError(f"archive: {archive_path}: cannot read gzip tar: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        validate(args.archive)
    except ValidationError as error:
        print(f"ERROR: release evidence archive validation failed: {error}.", file=sys.stderr)
        return 1
    print("Release evidence archive validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
