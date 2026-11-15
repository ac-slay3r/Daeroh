#!/usr/bin/env python3
"""Measure one public full-release APK with three independent Android tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

ANDROID = "{http://schemas.android.com/apk/res/android}"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SUPPORTED_ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64"}
ABI_VERSION_CODE_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}
EXPECTED_KEYS = {
    "schema", "flavor", "package", "versionName", "versionCode",
    "abiVersionCodes", "minSdk", "targetSdk", "label", "permissions",
    "forbiddenPermissions", "foregroundServices", "requiredPackageQueries",
}
FACT_KEYS = {
    "schema", "artifact", "flavor", "abi", "package", "versionName",
    "versionCode", "minSdk", "targetSdk", "label", "permissions",
    "foregroundServices", "packageQueries", "debuggable", "testOnly",
    "signerCertificateSha256", "predecessorCertificateSha256", "predecessorCapabilities",
    "signatureSchemes", "verificationSettings",
    "tools",
}
MAX_OUTPUT = 2 * 1024 * 1024
MAX_ENTRIES = 100_000
MAX_UNCOMPRESSED = 2 * 1024 * 1024 * 1024


class InspectionError(ValueError):
    pass


def strict_string(value: Any) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise InspectionError
    return value


def strict_int(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise InspectionError
    return value


def normalize_permissions(value: Any, *, nonempty: bool = True) -> list[dict[str, Any]]:
    if not isinstance(value, list) or (nonempty and not value):
        raise InspectionError
    result = []
    names = set()
    for item in value:
        if isinstance(item, str):
            item = {"name": item}
        if not isinstance(item, dict) or set(item) not in ({"name"}, {"name", "maxSdkVersion"}):
            raise InspectionError
        name = strict_string(item["name"])
        if name in names:
            raise InspectionError
        names.add(name)
        entry: dict[str, Any] = {"name": name}
        if "maxSdkVersion" in item:
            maximum = strict_int(item["maxSdkVersion"])
            if maximum < 1:
                raise InspectionError
            entry["maxSdkVersion"] = maximum
        result.append(entry)
    return sorted(result, key=lambda entry: entry["name"])


def normalize_strings(value: Any, *, nonempty: bool = True) -> list[str]:
    if not isinstance(value, list) or (nonempty and not value):
        raise InspectionError
    result = sorted(strict_string(item) for item in value)
    if len(result) != len(set(result)):
        raise InspectionError
    return result


def normalize_services(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise InspectionError
    result = []
    names = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"name", "types"}:
            raise InspectionError
        name = strict_string(item["name"])
        types = normalize_strings(item["types"])
        if name in names:
            raise InspectionError
        names.add(name)
        result.append({"name": name, "types": types})
    return sorted(result, key=lambda entry: entry["name"])


def expected_facts(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InspectionError from error
    if not isinstance(value, dict) or set(value) != EXPECTED_KEYS:
        raise InspectionError
    if value["schema"] != 1 or value["flavor"] != "full":
        raise InspectionError
    abi_codes = value["abiVersionCodes"]
    version_code = strict_int(value["versionCode"])
    if not isinstance(abi_codes, dict) or set(abi_codes) != SUPPORTED_ABIS:
        raise InspectionError
    normalized_codes = {abi: strict_int(abi_codes[abi]) for abi in sorted(abi_codes)}
    if any(
        code != version_code + ABI_VERSION_CODE_OFFSETS[abi]
        for abi, code in normalized_codes.items()
    ):
        raise InspectionError
    return {
        "schema": 1,
        "flavor": "full",
        "package": strict_string(value["package"]),
        "versionName": strict_string(value["versionName"]),
        "versionCode": version_code,
        "abiVersionCodes": normalized_codes,
        "minSdk": strict_int(value["minSdk"]),
        "targetSdk": strict_int(value["targetSdk"]),
        "label": strict_string(value["label"]),
        "permissions": normalize_permissions(value["permissions"]),
        "forbiddenPermissions": normalize_strings(value["forbiddenPermissions"], nonempty=False),
        "foregroundServices": normalize_services(value["foregroundServices"]),
        "requiredPackageQueries": normalize_strings(value["requiredPackageQueries"], nonempty=False),
    }


def sha256_file(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise InspectionError
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_tool(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise InspectionError
    try:
        if stat.S_ISLNK(path.lstat().st_mode):
            raise InspectionError
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InspectionError from error
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise InspectionError
    return resolved


def run_tool(
    tool: Path,
    arguments: list[str],
    environment: dict[str, str] | None = None,
    *,
    failure: str | None = None,
) -> str:
    try:
        result = subprocess.run(
            [str(tool), *arguments], check=False, capture_output=True, timeout=30, env=environment
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InspectionError(failure or "inspection tool execution failed") from error
    if result.returncode != 0 or len(result.stdout) + len(result.stderr) > MAX_OUTPUT or b"\x00" in result.stdout:
        raise InspectionError(failure or "inspection tool execution failed")
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InspectionError from error


def one(pattern: str, value: str) -> str:
    matches = re.findall(pattern, value, re.MULTILINE)
    if len(matches) != 1:
        raise InspectionError
    return matches[0]


def parse_aapt(value: str) -> dict[str, Any]:
    package = re.findall(
        r"^package:\s+name='([^']+)'\s+versionCode='([0-9]+)'\s+versionName='([^']+)'(?:\s.*)?$",
        value,
        re.MULTILINE,
    )
    if len(package) != 1:
        raise InspectionError
    name, code, version = package[0]
    # aapt emits one permission per physical line. Do not let ``\s`` consume
    # the newline between adjacent records; optional attributes remain on that
    # permission's line and are normalized from the manifest instead.
    raw_permissions = re.findall(r"^uses-permission:[ \t]+name='([^']+)'[^\r\n]*$", value, re.MULTILINE)
    # ``aapt dump badging`` expands compatibility permissions (for example the
    # legacy read-storage companion of a capped write-storage declaration).
    # Normalize those synthetic records away only when aapt labels the same
    # permission as implied in this exact output; manifest parsing remains the
    # authority for declared permission attributes.
    implied = set(re.findall(r"^uses-implied-permission:[ \t]+name='([^']+)'[^\r\n]*$", value, re.MULTILINE))
    permissions = sorted(name for name in raw_permissions if name not in implied)
    native = re.findall(r"^native-code:\s+((?:'[^']+'\s*)+)$", value, re.MULTILINE)
    abis = re.findall(r"'([^']+)'", native[0]) if len(native) == 1 else []
    if len(permissions) != len(set(permissions)) or len(abis) != 1:
        raise InspectionError
    return {
        "package": name,
        "versionName": version,
        "versionCode": int(code),
        "minSdk": int(one(r"^sdkVersion:'([0-9]+)'\s*$", value)),
        "targetSdk": int(one(r"^targetSdkVersion:'([0-9]+)'\s*$", value)),
        "permissions": permissions,
        "abi": abis[0],
    }


def tool_value(value: str) -> str:
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    if len(lines) != 1:
        raise InspectionError
    return strict_string(lines[0])


def parse_analyzer_permissions(value: str, declared: list[dict[str, Any]]) -> list[str]:
    """Normalize pinned apkanalyzer compatibility records, not policy content."""
    parsed: list[tuple[str, int | None]] = []
    for raw in value.splitlines():
        line = raw.strip()
        if not line:
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.]+)(?:' maxSdkVersion='([1-9][0-9]*))?", line)
        if match is None:
            raise InspectionError
        parsed.append((match.group(1), int(match.group(2)) if match.group(2) else None))
    if len({name for name, _ in parsed}) != len(parsed):
        raise InspectionError
    declared_by_name = {entry["name"]: entry.get("maxSdkVersion") for entry in declared}
    normalized = []
    for name, maximum in parsed:
        # apkanalyzer 12.0 reports this legacy companion for a capped write
        # declaration even though it is not declared in the manifest. Accept
        # only that exact documented implication; every other analyzer record
        # must still name a declared manifest permission.
        if name == "android.permission.READ_EXTERNAL_STORAGE":
            if (
                maximum == 28
                and declared_by_name.get("android.permission.WRITE_EXTERNAL_STORAGE") == 28
            ):
                continue
        if declared_by_name.get(name) != maximum:
            raise InspectionError
        normalized.append(name)
    return sorted(normalized)


FOREGROUND_SERVICE_TYPE_BITS = {
    0x1: "dataSync",
    0x2: "mediaPlayback",
    0x80: "microphone",
    0x200: "remoteMessaging",
}


def normalize_manifest_service_types(value: str) -> list[str]:
    if value.startswith("0x"):
        try:
            mask = int(value, 16)
        except ValueError as error:
            raise InspectionError from error
        types = [name for bit, name in FOREGROUND_SERVICE_TYPE_BITS.items() if mask & bit]
        if not types or sum(bit for bit, _ in FOREGROUND_SERVICE_TYPE_BITS.items() if mask & bit) != mask:
            raise InspectionError
        return sorted(types)
    return normalize_strings(value.split("|"))


def manifest_boolean(value: str | None) -> bool:
    if value is None:
        return False
    if value == "true":
        return True
    if value == "false":
        return False
    raise InspectionError


def parse_manifest(value: str) -> dict[str, Any]:
    raw = value.encode()
    if len(raw) > MAX_OUTPUT or b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise InspectionError
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise InspectionError from error
    if root.tag.rsplit("}", 1)[-1] != "manifest":
        raise InspectionError
    uses_sdk = [child for child in root if child.tag.rsplit("}", 1)[-1] == "uses-sdk"]
    applications = [child for child in root if child.tag.rsplit("}", 1)[-1] == "application"]
    if len(uses_sdk) != 1 or len(applications) != 1:
        raise InspectionError
    permissions = []
    queries = []
    for child in root:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag.startswith("uses-permission") and tag != "uses-permission":
            raise InspectionError
        if tag == "uses-permission":
            entry: dict[str, Any] = {"name": strict_string(child.get(f"{ANDROID}name"))}
            maximum = child.get(f"{ANDROID}maxSdkVersion")
            if maximum is not None:
                if not maximum.isdecimal():
                    raise InspectionError
                entry["maxSdkVersion"] = int(maximum)
            permissions.append(entry)
        elif tag == "queries":
            for query in child:
                if query.tag.rsplit("}", 1)[-1] == "package":
                    queries.append(strict_string(query.get(f"{ANDROID}name")))
    package = strict_string(root.get("package"))
    services = []
    for child in applications[0]:
        if child.tag.rsplit("}", 1)[-1] != "service":
            continue
        raw_types = child.get(f"{ANDROID}foregroundServiceType")
        if raw_types:
            name = strict_string(child.get(f"{ANDROID}name"))
            if name.startswith(f"{package}."):
                name = name[len(package):]
            services.append({"name": name, "types": normalize_manifest_service_types(raw_types)})
    return {
        "package": package,
        "versionName": strict_string(root.get(f"{ANDROID}versionName")),
        "versionCode": int(strict_string(root.get(f"{ANDROID}versionCode"))),
        "minSdk": int(strict_string(uses_sdk[0].get(f"{ANDROID}minSdkVersion"))),
        "targetSdk": int(strict_string(uses_sdk[0].get(f"{ANDROID}targetSdkVersion"))),
        "label": strict_string(applications[0].get(f"{ANDROID}label")),
        "permissions": normalize_permissions(permissions, nonempty=False),
        "foregroundServices": normalize_services(services),
        "packageQueries": normalize_strings(queries, nonempty=False),
        "debuggable": manifest_boolean(applications[0].get(f"{ANDROID}debuggable")),
        "testOnly": manifest_boolean(applications[0].get(f"{ANDROID}testOnly")),
    }


def signature_measurement(value: str) -> tuple[str, dict[str, bool]]:
    if "Verifies" not in value.splitlines():
        raise InspectionError
    matches = re.findall(r"^Signer #1 certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)\s*$", value, re.MULTILINE)
    if len(matches) != 1 or re.search(r"^Signer #[2-9][0-9]* ", value, re.MULTILINE):
        raise InspectionError
    digest = matches[0].replace(":", "").lower()
    if SHA256.fullmatch(digest) is None:
        raise InspectionError
    schemes: dict[str, bool] = {}
    for name in ("v1", "v2", "v3"):
        matches = re.findall(
            rf"^Verified using {name} scheme \([^)]*\): (true|false)\s*$",
            value,
            re.MULTILINE,
        )
        if len(matches) != 1:
            raise InspectionError
        schemes[name] = matches[0] == "true"
    return digest, schemes


def lineage_measurement(value: str) -> tuple[str, str, dict[str, bool]]:
    """Return the exact predecessor/current certificate chain embedded in an APK."""
    matches = re.findall(
        r"^Signer #([1-9][0-9]*) in lineage certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)\s*$",
        value,
        re.MULTILINE,
    )
    if len(matches) != 2 or [number for number, _ in matches] != ["1", "2"]:
        raise InspectionError
    digests = tuple(digest.replace(":", "").lower() for _, digest in matches)
    if any(SHA256.fullmatch(digest) is None for digest in digests) or digests[0] == digests[1]:
        raise InspectionError
    capability_names = {
        "installed data": "installedData", "shared UID": "sharedUid",
        "permission": "permission", "rollback": "rollback", "auth": "auth",
    }
    capabilities: dict[str, bool] = {}
    for printed, key in capability_names.items():
        matches = re.findall(
            rf"^Has {re.escape(printed)} capability\s*:\s*(true|false)\s*$",
            value, re.MULTILINE,
        )
        # The embedded lineage prints each capability once per signer. The
        # predecessor is always signer #1, therefore it is the first value.
        if len(matches) != 2:
            raise InspectionError
        capabilities[key] = matches[0] == "true"
    return digests[0], digests[1], capabilities


def signer_digest(value: str) -> str:
    """Return the active signer after validating the complete measurement."""
    return signature_measurement(value)[0]


def validate_apk(path: Path) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
        raise InspectionError
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = set()
            total = 0
            for entry in entries:
                member = PurePosixPath(entry.filename)
                if (
                    not entry.filename or "\\" in entry.filename or member.is_absolute()
                    or "." in member.parts or ".." in member.parts or entry.filename in names
                    or entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16)
                    or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                ):
                    raise InspectionError
                names.add(entry.filename)
                total += entry.file_size
            if len(entries) > MAX_ENTRIES or total > MAX_UNCOMPRESSED or not {"AndroidManifest.xml", "resources.arsc"}.issubset(names) or not any(name.endswith(".dex") for name in names) or archive.testzip() is not None:
                raise InspectionError
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise InspectionError from error


def jar_signature_scheme_present(path: Path) -> bool:
    """Detect embedded v1 JAR signature material independently of SDK selection."""
    try:
        with zipfile.ZipFile(path) as archive:
            names = {entry.filename.upper() for entry in archive.infolist()}
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise InspectionError from error
    if "META-INF/MANIFEST.MF" not in names:
        return False
    stems = {
        name.removeprefix("META-INF/").removesuffix(".SF")
        for name in names
        if name.startswith("META-INF/") and name.endswith(".SF")
    }
    return any(
        f"META-INF/{stem}{extension}" in names
        for stem in stems
        for extension in (".RSA", ".DSA", ".EC")
    )


def inspect(artifact: Path, expected: dict[str, Any], artifact_name: str, abi: str, signer: str, predecessor: str, predecessor_capabilities: dict[str, bool], rotation_min_sdk: int, release_flags: dict[str, bool], aapt: Path, apkanalyzer: Path, apksigner: Path, environment: dict[str, str] | None = None) -> dict[str, Any]:
    if (
        artifact.name != artifact_name or abi not in SUPPORTED_ABIS
        or SHA256.fullmatch(signer) is None or SHA256.fullmatch(predecessor) is None
        or rotation_min_sdk < 1
    ):
        raise InspectionError
    validate_apk(artifact)
    aapt_facts = parse_aapt(run_tool(aapt, ["dump", "badging", str(artifact)], environment))
    analyzer = {
        key: tool_value(run_tool(apkanalyzer, ["manifest", query, str(artifact)], environment))
        for key, query in (
            ("package", "application-id"), ("versionName", "version-name"),
            ("versionCode", "version-code"), ("minSdk", "min-sdk"),
            ("targetSdk", "target-sdk"),
        )
    }
    manifest = parse_manifest(run_tool(apkanalyzer, ["manifest", "print", str(artifact)], environment))
    analyzer_permission_names = parse_analyzer_permissions(
        run_tool(apkanalyzer, ["manifest", "permissions", str(artifact)], environment),
        manifest["permissions"],
    )
    current_output = run_tool(
        apksigner,
        ["verify", "--verbose", "--print-certs", "--min-sdk-version", str(rotation_min_sdk), str(artifact)],
        environment,
        failure="APK rotation minimum SDK verification failed",
    )
    measured_signer, current_schemes = signature_measurement(current_output)
    # apksigner reports the scheme selected for this SDK range.  Inspect the
    # ZIP separately so a valid v1 signature cannot hide behind v3 at API 29.
    current_schemes["v1"] = current_schemes["v1"] or jar_signature_scheme_present(artifact)
    # API 24--27 selects v2 when it exists, unlike the API-29 v3 verifier.
    legacy_output = run_tool(apksigner, ["verify", "--verbose", "--print-certs", "--min-sdk-version", "27", str(artifact)], environment)
    _, legacy_schemes = signature_measurement(legacy_output)
    legacy_schemes["v1"] = current_schemes["v1"]
    try:
        lineage_output = run_tool(apksigner, ["lineage", "--in", str(artifact), "--print-certs"], environment)
        measured_predecessor, lineage_current, measured_capabilities = lineage_measurement(lineage_output)
    except InspectionError as error:
        raise InspectionError("APK signing lineage is missing or invalid") from error
    # Construct all observations before policy comparisons.  Rejections below
    # must always report tool-measured values, never copied expectations.
    measurements = {
        **manifest, "aapt": aapt_facts, "analyzer": analyzer,
        "analyzerPermissions": analyzer_permission_names,
        "signerCertificateSha256": measured_signer,
        "predecessorCertificateSha256": measured_predecessor,
        "predecessorCapabilities": measured_capabilities,
        "signatureSchemes": current_schemes,
        "legacySignatureSchemes": legacy_schemes,
    }
    expected_code = expected["abiVersionCodes"].get(abi)
    if any(
        str(aapt_facts[key]) != analyzer[key] or aapt_facts[key] != manifest[key]
        for key in ("package", "versionName", "minSdk", "targetSdk")
    ):
        raise InspectionError(f"APK manifest tools disagree: measured={measurements!r}")
    def mismatch(message: str, measured: Any, required: Any) -> None:
        raise InspectionError(f"{message} (measured={measured!r}, expected={required!r})")

    if manifest["package"] != expected["package"]:
        mismatch("APK package does not match the release policy", manifest["package"], expected["package"])
    for key, message in (
        ("versionName", "APK versionName does not match the release policy"),
        ("minSdk", "APK minSdk does not match the release policy"),
        ("targetSdk", "APK targetSdk does not match the release policy"),
    ):
        if manifest[key] != expected[key]:
            mismatch(message, manifest[key], expected[key])
    if aapt_facts["versionCode"] != expected_code or manifest["versionCode"] != expected_code or analyzer["versionCode"] != str(expected_code) or aapt_facts["abi"] != abi:
        mismatch("APK ABI versionCode does not match the release policy", {"aapt": aapt_facts["versionCode"], "manifest": manifest["versionCode"], "apkanalyzer": analyzer["versionCode"], "abi": aapt_facts["abi"]}, {"versionCode": expected_code, "abi": abi})
    if manifest["label"] != expected["label"]:
        mismatch("APK label does not match the release policy", manifest["label"], expected["label"])
    manifest_permission_names = [entry["name"] for entry in manifest["permissions"]]
    expected_permission_names = [entry["name"] for entry in expected["permissions"]]
    if aapt_facts["permissions"] != analyzer_permission_names or manifest_permission_names != analyzer_permission_names:
        raise InspectionError(f"APK permission tools disagree: measured={measurements!r}")
    forbidden_permissions = set(expected["forbiddenPermissions"]).intersection(analyzer_permission_names)
    if forbidden_permissions:
        mismatch("APK forbidden permissions does not match the release policy", sorted(forbidden_permissions), [])
    missing_permissions = set(expected_permission_names) - set(manifest_permission_names)
    extra_permissions = set(manifest_permission_names) - set(expected_permission_names)
    if missing_permissions:
        mismatch("APK permissions (missing) does not match the release policy", sorted(missing_permissions), [])
    if extra_permissions:
        mismatch("APK permissions (extra) does not match the release policy", sorted(extra_permissions), [])
    if manifest["permissions"] != expected["permissions"]:
        mismatch("APK permission declarations do not match the release policy", manifest["permissions"], expected["permissions"])
    if manifest["foregroundServices"] != expected["foregroundServices"]:
        mismatch("APK foreground-service declarations do not match the release policy", manifest["foregroundServices"], expected["foregroundServices"])
    if not set(expected["requiredPackageQueries"]).issubset(manifest["packageQueries"]):
        mismatch("APK package queries do not match the release policy", manifest["packageQueries"], expected["requiredPackageQueries"])
    if measured_signer != signer or lineage_current != signer:
        mismatch("APK signer certificate does not match the release policy", {"signer": measured_signer, "lineageCurrent": lineage_current}, signer)
    if measured_predecessor != predecessor:
        mismatch("APK signing lineage predecessor does not match the release policy", measured_predecessor, predecessor)
    if measured_capabilities != predecessor_capabilities:
        mismatch("APK signing lineage predecessor capabilities do not match the release policy", measured_capabilities, predecessor_capabilities)
    if current_schemes != {"v1": False, "v2": False, "v3": True} or legacy_schemes != {"v1": False, "v2": False, "v3": True}:
        mismatch("APK signature schemes do not match the v3-only release policy", {"current": current_schemes, "legacy": legacy_schemes}, {"v1": False, "v2": False, "v3": True})
    for key, label in (("debuggable", "android:debuggable"), ("testOnly", "android:testOnly")):
        if manifest[key] != release_flags[key]:
            mismatch(f"APK {label} does not match the signed-release-apk policy", manifest[key], release_flags[key])
    return {
        "schema": 1,
        "artifact": {"name": artifact.name, "size": artifact.stat().st_size, "sha256": sha256_file(artifact)},
        "flavor": "full", "abi": abi, "package": manifest["package"],
        "versionName": manifest["versionName"], "versionCode": manifest["versionCode"],
        "minSdk": manifest["minSdk"], "targetSdk": manifest["targetSdk"],
        "label": manifest["label"], "permissions": manifest["permissions"],
        "foregroundServices": manifest["foregroundServices"], "packageQueries": manifest["packageQueries"],
        "debuggable": manifest["debuggable"], "testOnly": manifest["testOnly"],
        "signerCertificateSha256": measured_signer,
        "predecessorCertificateSha256": measured_predecessor,
        "predecessorCapabilities": measured_capabilities,
        "signatureSchemes": current_schemes,
        "verificationSettings": {"requiredPackageQueries": expected["requiredPackageQueries"], "rotationMinSdkVersion": rotation_min_sdk},
        "tools": {name: {"path": path.name, "sha256": sha256_file(path)} for name, path in sorted({"aapt": aapt, "apkanalyzer": apkanalyzer, "apksigner": apksigner}.items())},
    }


def canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_exclusive(path: Path, value: dict[str, Any]) -> None:
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
        with os.fdopen(descriptor, "wb") as output:
            output.write(canonical(value))
    except OSError as error:
        raise InspectionError from error


def reviewed_contract(path: Path) -> dict[str, Any]:
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_OUTPUT:
            raise InspectionError
        value = json.loads(path.read_text(encoding="utf-8"))
        record = value["signerContinuity"]["direct-public"]
        signer = strict_string(record["certificateSha256"].lower())
        predecessor = strict_string(record["acceptedPredecessorCertificateSha256"].lower())
        schemes = record["signatureSchemes"]
        capabilities = record["predecessorCapabilities"]
        android = value["android"]
        package = strict_string(android["packageId"])
        release_flags = {key: android[key] for key in ("debuggable", "testOnly")}
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise InspectionError from error
    if (
        value.get("schema") != 1
        or SHA256.fullmatch(signer) is None
        or SHA256.fullmatch(predecessor) is None
        or schemes != {"v1": False, "v2": False, "v3": True, "rotationMinSdkVersion": 29}
        or set(value["android"]) != {"packageId", "versionSource", "debuggable", "testOnly"}
        or release_flags != {"debuggable": False, "testOnly": False}
        or capabilities != {
            "installedData": True, "permission": True, "sharedUid": False,
            "rollback": False, "auth": False,
        }
    ):
        raise InspectionError
    return {
        "certificateSha256": signer,
        "acceptedPredecessorCertificateSha256": predecessor,
        "predecessorCapabilities": capabilities,
        "rotationMinSdkVersion": schemes["rotationMinSdkVersion"],
        "packageId": package,
        "releaseFlags": release_flags,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--expected", type=Path, required=True)
    parser.add_argument("--expected-artifact-name", required=True)
    parser.add_argument("--expected-abi", required=True)
    parser.add_argument("--expected-signer-sha256", required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--aapt", required=True)
    parser.add_argument("--apkanalyzer", required=True)
    parser.add_argument("--apksigner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        signer = strict_string(args.expected_signer_sha256.lower())
        contract = reviewed_contract(args.policy)
        expected = expected_facts(args.expected)
        if signer != contract["certificateSha256"] or expected["package"] != contract["packageId"]:
            raise InspectionError
        facts = inspect(
            args.artifact, expected, args.expected_artifact_name,
            args.expected_abi, signer, contract["acceptedPredecessorCertificateSha256"], contract["predecessorCapabilities"],
            contract["rotationMinSdkVersion"], contract["releaseFlags"],
            resolve_tool(args.aapt), resolve_tool(args.apkanalyzer), resolve_tool(args.apksigner),
        )
        write_exclusive(args.output, facts)
    except (InspectionError, OSError, ValueError) as error:
        detail = str(error) or "invalid APK inspection input"
        print(f"ERROR: public APK inspection failed: {detail}", file=sys.stderr)
        return 1
    print("Public APK inspection passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
