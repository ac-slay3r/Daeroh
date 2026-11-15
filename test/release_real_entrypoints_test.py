"""Real APK field negatives through both production release entry points.

Run with DAEROH_VERIFIER_TOOLCHAIN (the reviewed SDK/JDK cache),
DAEROH_ANDROID_JAR (compile-only android-36/android.jar), and
DAEROH_LOCAL_TOOLCHAIN_LAUNCHER set. The launcher must have its normal full
SDK/Flutter environment available. Missing prerequisites skip cleanly.

The APKs use binary manifests and disposable signatures, following the independent
reviewer's aapt fixture technique. They are NONFUNCTIONAL host fixtures, not app
builds or release evidence. Build/license sidecars are synthetic checker inputs.
Only two certificate anchors change in a push-disabled throwaway source clone;
all production executable bytes, tool pins and other policy constraints remain
unchanged. GitHub HTTPS is recorded transport, not a replacement identity validator.
The two explicitly named inspector-only rows use recorded tool outputs; they are
not claimed as isolated real-APK final-boundary coverage.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[1]
PYTHON = sys.executable
sys.path.insert(0, str(ROOT / "tool/release"))
sys.path.insert(0, str(ROOT / "test"))
import inspect_public_apk as inspector


def release_tag(root: Path) -> str:
    """Return the Daeroh release tag for the pubspec version under test."""
    versions = [
        match.group(1)
        for match in (
            re.fullmatch(r"version:\s*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+(?:0|[1-9][0-9]*)\s*(?:#.*)?", line)
            for line in (root / "pubspec.yaml").read_text(encoding="utf-8").splitlines()
        )
        if match
    ]
    if len(versions) != 1:
        raise AssertionError(f"expected exactly one pubspec version line, found {len(versions)}")
    return f"daeroh-v{versions[0]}"

APKS = {
    "app-arm64-v8a-full-release.apk": "arm64-v8a",
    "app-armeabi-v7a-full-release.apk": "armeabi-v7a",
    "app-x86_64-full-release.apk": "x86_64",
}
LAUNCHER = Path(os.environ.get("DAEROH_LOCAL_TOOLCHAIN_LAUNCHER", "/nonexistent"))
TOOLCHAIN = Path(os.environ.get("DAEROH_VERIFIER_TOOLCHAIN", "/nonexistent"))
SDK = TOOLCHAIN / "android-sdk"
JDK = TOOLCHAIN / "jdk17"
ANDROID_JAR = Path(os.environ.get("DAEROH_ANDROID_JAR", "/nonexistent"))
AAPT = SDK / "build-tools/36.0.0/aapt"
APKSIGNER = SDK / "build-tools/36.0.0/apksigner"
ANALYZER = SDK / "cmdline-tools/latest/bin/apkanalyzer"
CAPABILITIES = {"installedData": True, "permission": True, "sharedUid": False, "rollback": False, "auth": False}

# Explicit coverage inventory, not derived from the upstream table. Adding an
# upstream row without a real test or a reasoned exemption must fail completeness.
REAL_ROWS = {
    "package": "APK package does not match",
    "application label": "APK label does not match",
    "versionName": "APK versionName does not match",
    "per-ABI versionCode": "APK ABI versionCode does not match",
    "minSdk": "APK minSdk does not match",
    "targetSdk": "APK targetSdk does not match",
    "permissions (extra)": "APK permissions (extra) does not match",
    "permissions (missing)": "APK permissions (missing) does not match",
    "forbidden permissions": "APK forbidden permissions does not match",
    "foreground services": "APK foreground-service declarations do not match",
    "required package queries": "APK package queries do not match",
    "signer certificate": "APK signer certificate does not match",
    "predecessor certificate": "APK signing lineage predecessor does not match",
    **{f"lineage capability {name}": "APK signing lineage predecessor capabilities do not match" for name in CAPABILITIES},
    "signature scheme v1": "APK signature schemes do not match the v3-only release policy",
    "signature scheme v2": "APK signature schemes do not match the v3-only release policy",
    "release artifact debuggable": "APK android:debuggable does not match",
    "release artifact test-only": "APK android:testOnly does not match",
}
INSPECTOR_ONLY_ROWS = {
    "signature scheme v3": (
        "test_inspector_only_v3_absence_recorded_outputs",
        "A real v2-only APK has no embedded v3 lineage, so it fails the earlier lineage check, not the isolated scheme comparison.",
    ),
    "rotation min SDK": (
        "test_inspector_only_rotation_min_sdk_recorded_argv",
        "The final CLI fixes SDK29 in the reviewed policy; changing a signing target does not reliably cause an isolated SDK29 verification failure. Recorded argv-sensitive inspection tests the setting without claiming a real final-CLI row.",
    ),
}
EXTRA_CASES = {
    "missing lineage": "APK signing lineage is missing or invalid",
    "legacy-only-v2": "APK signature schemes do not match the v3-only release policy",
}
FIXTURE = None
TEMPORARY = None


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def run(command, *, cwd=None, env=None):
    return subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=False, capture_output=True, text=True, timeout=120)


def checked(command, **kwargs):
    result = run(command, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture():
    global FIXTURE, TEMPORARY
    prerequisites = (LAUNCHER, AAPT, APKSIGNER, ANALYZER, ANDROID_JAR, JDK / "bin/keytool")
    if not all(p.is_file() for p in prerequisites):
        raise unittest.SkipTest("set DAEROH_LOCAL_TOOLCHAIN_LAUNCHER, DAEROH_VERIFIER_TOOLCHAIN and DAEROH_ANDROID_JAR for real APK entrypoint fixtures")
    if FIXTURE is None:
        TEMPORARY = tempfile.TemporaryDirectory(prefix="daeroh-real-entrypoints-")
        FIXTURE = RealEntrypointFixture(Path(TEMPORARY.name))
    return FIXTURE


def tearDownModule():
    global FIXTURE, TEMPORARY
    if TEMPORARY is not None:
        TEMPORARY.cleanup()
    FIXTURE = TEMPORARY = None


class RealEntrypointFixture:
    """Real signed variants and freshly measured sidecars, never a validator shim."""

    def __init__(self, temporary):
        self.root = temporary / "source"
        checked(["git", "clone", "--no-hardlinks", ROOT, self.root])
        # A local clone alone tests HEAD, silently losing uncommitted production
        # mutations. Snapshot tracked working bytes so this harness exercises the
        # source under test, including changes in a mutation-test scratch copy.
        tracked = checked(["git", "ls-files", "-z"], cwd=ROOT).stdout.split("\0")
        for relative in filter(None, tracked):
            source, target = ROOT / relative, self.root / relative
            if source.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
            elif not source.exists():
                target.unlink(missing_ok=True)
        self.git("remote", "set-url", "--push", "origin", "DISABLED")
        self.git("config", "user.name", "Daeroh")
        self.git("config", "user.email", "daeroh@local.invalid")
        self.public = temporary / "public"
        self.public.mkdir()
        self.keys = temporary / "keys"
        self.keys.mkdir()
        self.wrapper = temporary / "recorded-github"
        self.wrapper.mkdir()
        (self.wrapper / "sitecustomize.py").write_text('''import json, os, urllib.request
class Response:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self):
        return json.dumps({'sha': os.environ['DAEROH_FIXTURE_COMMIT'], 'author': {'login': 'ac-slay3r'}, 'committer': {'login': 'web-flow'}, 'commit': {'verification': {'verified': True, 'reason': 'valid'}}}).encode()
def recorded_urlopen(request, *args, **kwargs):
    if request.full_url == 'https://api.github.com/repos/ac-slay3r/Daeroh/commits/' + os.environ['DAEROH_FIXTURE_COMMIT']:
        return Response()
    raise OSError('recorded fixture refuses other network')
urllib.request.urlopen = recorded_urlopen
''', encoding="utf-8")
        self.make_keys()
        contract_path = self.root / "tool/release/release_contract.json"
        contract = json.loads(contract_path.read_text())
        direct = contract["signerContinuity"]["direct-public"]
        direct["certificateSha256"] = self.signer
        direct["acceptedPredecessorCertificateSha256"] = self.predecessor
        contract_path.write_bytes(canonical(contract))
        # Include newly tracked working-tree files absent from the clone's HEAD.
        self.git("add", "--", *filter(None, tracked))
        self.git("commit", "-m", "test: snapshot tested source with throwaway release signer")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.tag = release_tag(self.root)
        self.git("tag", self.tag)
        self.expected = temporary / "expected.json"
        checked([PYTHON, self.root / "tool/release/write_full_expectations.py", "--pubspec", self.root / "pubspec.yaml", "--gradle", self.root / "android/app/build.gradle.kts", "--manifest", self.root / "android/app/src/main/AndroidManifest.xml", "--policy", self.root / "tool/release/full_release_policy.json", "--output", self.expected])
        self.expectations = json.loads(self.expected.read_text())
        self.toolchain = temporary / "trusted-toolchain.json"
        checked([PYTHON, self.root / "tool/release/record_trusted_toolchain.py", "--root", SDK, "--jdk-root", JDK, "--output", self.toolchain])
        identities = checked(
            [PYTHON, "-c", "import json, sys; from pathlib import Path; import play_build_binding; print(json.dumps(play_build_binding.source_and_inputs(Path(sys.argv[1]))))", self.root],
            env={**os.environ, "PYTHONPATH": str(self.root / "tool/release")},
        )
        self.source, self.inputs = json.loads(identities.stdout)
        self.variants = {}
        self.fact_cache = {}
        self.measurements = {}
        self.make_assets()

    def git(self, *args):
        return checked(["git", "-c", "commit.gpgsign=false", *args], cwd=self.root, env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")})

    def launch(self, *args):
        # SDK discovery is the launcher's normal full SDK, but signing and
        # inspection programs are explicitly from the unchanged verifier cache.
        return checked([LAUNCHER, *args], env={**os.environ, "JAVA_HOME": str(JDK)})

    def signer_args(self, name):
        return ["--ks", self.keys / f"{name}.p12", "--ks-key-alias", name, "--ks-type", "PKCS12", "--ks-pass", "pass:changeit", "--key-pass", "pass:changeit"]

    def make_keys(self):
        digests = {}
        for name in ("old", "new", "foreign"):
            self.launch(JDK / "bin/keytool", "-genkeypair", "-keystore", self.keys / f"{name}.p12", "-storetype", "PKCS12", "-storepass", "changeit", "-keypass", "changeit", "-alias", name, "-keyalg", "RSA", "-keysize", "2048", "-dname", f"CN=throwaway-{name}", "-validity", "2")
            result = self.launch(JDK / "bin/keytool", "-list", "-v", "-keystore", self.keys / f"{name}.p12", "-storetype", "PKCS12", "-storepass", "changeit", "-alias", name)
            digests[name] = next(line.split(":", 1)[1].strip().replace(":", "").lower() for line in result.stdout.splitlines() if line.strip().startswith("SHA256:"))
        self.signer, self.predecessor = digests["new"], digests["old"]
        for old, new, name in (("old", "new", "lineage"), ("foreign", "new", "foreign-predecessor"), ("old", "foreign", "foreign-current")):
            self.launch(APKSIGNER, "rotate", "--out", self.keys / name, "--old-signer", *self.signer_args(old), "--set-installed-data", "true", "--set-permission", "true", "--set-shared-uid", "false", "--set-rollback", "false", "--set-auth", "false", "--new-signer", *self.signer_args(new))
        for cap, option in (("installedData", "installed-data"), ("permission", "permission"), ("sharedUid", "shared-uid"), ("rollback", "rollback"), ("auth", "auth")):
            self.launch(APKSIGNER, "lineage", "--in", self.keys / "lineage", "--out", self.keys / f"cap-{cap}", "--signer", *self.signer_args("old"), f"--set-{option}", str(not CAPABILITIES[cap]).lower())

    def unsigned(self, abi, **changes):
        x = self.expectations | changes
        xml = f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package={quoteattr(x["package"])} android:versionCode="{x["abiVersionCodes"][abi]}" android:versionName={quoteattr(x["versionName"])}><uses-sdk android:minSdkVersion="{x["minSdk"]}" android:targetSdkVersion="{x["targetSdk"]}"/>'
        for p in x["permissions"]:
            xml += '<uses-permission android:name=' + quoteattr(p["name"]) + (f' android:maxSdkVersion="{p["maxSdkVersion"]}"' if "maxSdkVersion" in p else "") + '/>'
        xml += '<queries>' + ''.join('<package android:name=' + quoteattr(q) + '/>' for q in x['requiredPackageQueries']) + '</queries>'
        xml += '<application android:label=' + quoteattr(x['label']) + f' android:debuggable="{str(x.get("debuggable", False)).lower()}" android:testOnly="{str(x.get("testOnly", False)).lower()}">'
        for s in x["foregroundServices"]:
            xml += '<service android:name=' + quoteattr(s["name"]) + ' android:foregroundServiceType=' + quoteattr('|'.join(s["types"])) + '/>'
        xml += '</application></manifest>'
        directory = self.keys / f"unsigned-{abi}-{hashlib.sha256(xml.encode()).hexdigest()[:12]}"
        directory.mkdir(exist_ok=True)
        source = directory / "AndroidManifest.xml"
        source.write_text(xml)
        resources = directory / "res/values"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / "strings.xml").write_text('<resources><string name="dummy">fixture</string></resources>')
        apk = directory / "unsigned.apk"
        self.launch(AAPT, "package", "-f", "-M", source, "-S", directory / "res", "-I", ANDROID_JAR, "-F", apk)
        with zipfile.ZipFile(apk, "a", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("classes.dex", b"dex\n035\x00" + b"\x00" * 128)
            archive.writestr(f"lib/{abi}/libapp.so", b"nonfunctional host fixture")
        return apk

    def sign_apk(self, unsigned, name, mode="control"):
        output = self.keys / f"{name}.apk"
        command = [APKSIGNER, "sign", "--out", output]
        older = mode in ("signature scheme v1", "signature scheme v2", "legacy-only-v2")
        if older:
            command += self.signer_args("old") + ["--next-signer"]
        command += self.signer_args("foreign" if mode == "signer certificate" else "new")
        command += ["--v1-signing-enabled", str(mode == "signature scheme v1").lower(), "--v2-signing-enabled", str(mode in ("signature scheme v2", "legacy-only-v2")).lower(), "--v3-signing-enabled", "true", "--v4-signing-enabled", "false", "--min-sdk-version", "23" if mode == "signature scheme v1" else "29", "--rotation-min-sdk-version", "29"]
        if mode != "missing lineage":
            lineage = "foreign-current" if mode == "signer certificate" else "foreign-predecessor" if mode == "predecessor certificate" else f"cap-{mode.split()[-1]}" if mode.startswith("lineage capability ") else "lineage"
            command += ["--lineage", self.keys / lineage]
        self.launch(*command, unsigned)
        return output

    def make_assets(self):
        base = {name: self.sign_apk(self.unsigned(abi), f"control-{abi}") for name, abi in APKS.items()}
        self.variants["control"] = base
        x = self.expectations
        changes = {
            "package": {"package": "invalid.example.fixture"},
            "application label": {"label": "Wrong Fixture Label"},
            "versionName": {"versionName": "9.9.9"},
            "per-ABI versionCode": {"abiVersionCodes": {abi: code + 1 for abi, code in x["abiVersionCodes"].items()}},
            "minSdk": {"minSdk": x["minSdk"] + 1},
            "targetSdk": {"targetSdk": 28},
            "permissions (extra)": {"permissions": x["permissions"] + [{"name": "android.permission.ACCESS_FINE_LOCATION"}]},
            "permissions (missing)": {"permissions": [p for p in x["permissions"] if p["name"] != "android.permission.INTERNET"]},
            "forbidden permissions": {"permissions": x["permissions"] + [{"name": "android.permission.READ_PHONE_STATE"}]},
            "foreground services": {"foregroundServices": [{"name": ".WrongService", "types": ["dataSync"]}]},
            "required package queries": {"requiredPackageQueries": ["org.fdroid.fdroid"]},
            "release artifact debuggable": {"debuggable": True},
            "release artifact test-only": {"testOnly": True},
        }
        first, abi = next(iter(APKS.items()))
        for index, mode in enumerate(REAL_ROWS | EXTRA_CASES):
            # Code negatives change ALL ABI codes; flags and R1 likewise use a
            # complete real set. Other negatives isolate one ARM64 artifact.
            all_abis = mode in ("per-ABI versionCode", "release artifact debuggable", "release artifact test-only", "signature scheme v1")
            variant = dict(base)
            for name, architecture in APKS.items():
                if name == first or all_abis:
                    unsigned = self.unsigned(architecture, **changes.get(mode, {}))
                    variant[name] = self.sign_apk(unsigned, f"case-{index}-{architecture}", mode)
            self.variants[mode] = variant
            if mode == "per-ABI versionCode":
                for name, architecture in APKS.items():
                    self.variants[f"versionCode-{architecture}"] = base | {name: variant[name]}

    def inspector_command(self, name, output):
        return [PYTHON, self.root / "tool/release/inspect_public_apk.py", "--artifact", self.public / name, "--expected", self.expected, "--expected-artifact-name", name, "--expected-abi", APKS[name], "--expected-signer-sha256", self.signer, "--policy", self.root / "tool/release/release_contract.json", "--aapt", AAPT, "--apkanalyzer", ANALYZER, "--apksigner", APKSIGNER, "--output", output]

    def measured_sidecar(self, name):
        """Serialize observations, not acceptance, for a deliberately invalid APK.

        Policy-enforcing inspection cannot emit accepted facts for a bad APK.
        Here the binary manifest, signature and lineage are freshly read using
        real tools and production parsers, without a policy comparison. This is
        fixture evidence construction ONLY; both entry points independently run
        the unmodified enforcing inspector. No expected field is substituted for
        an observation. Missing lineage is represented as unknown, not invented.
        """
        artifact = self.public / name
        key = (name, sha(artifact))
        if key in self.fact_cache:
            return self.fact_cache[key]
        env = {**os.environ, "JAVA_HOME": str(JDK)}
        def tool(path, *args):
            return self.launch(path, *args).stdout
        manifest = inspector.parse_manifest(tool(ANALYZER, "manifest", "print", artifact))
        signer, current = inspector.signature_measurement(tool(APKSIGNER, "verify", "--verbose", "--print-certs", "--min-sdk-version", "29", artifact))
        _, legacy = inspector.signature_measurement(tool(APKSIGNER, "verify", "--verbose", "--print-certs", "--min-sdk-version", "27", artifact))
        current["v1"] = current["v1"] or inspector.jar_signature_scheme_present(artifact)
        lineage = run([APKSIGNER, "lineage", "--in", artifact, "--print-certs"], env=env)
        if lineage.returncode:
            predecessor, capabilities = None, None
        else:
            predecessor, _, capabilities = inspector.lineage_measurement(lineage.stdout)
        value = {"schema": 1, "artifact": {"name": name, "size": artifact.stat().st_size, "sha256": key[1]}, "flavor": "full", "abi": APKS[name], **manifest, "signerCertificateSha256": signer, "predecessorCertificateSha256": predecessor, "predecessorCapabilities": capabilities, "signatureSchemes": current, "verificationSettings": {"requiredPackageQueries": self.expectations["requiredPackageQueries"], "rotationMinSdkVersion": 29}, "tools": {n: {"path": p.name, "sha256": sha(p)} for n, p in {"aapt": AAPT, "apkanalyzer": ANALYZER, "apksigner": APKSIGNER}.items()}}
        self.fact_cache[key] = value
        self.measurements[key] = {"current": current, "legacy": legacy}
        return value

    def install_variant(self, variant):
        for name, source in self.variants[variant].items():
            shutil.copy2(source, self.public / name)
        evidence = self.public.parent / "release-evidence"
        if evidence.exists():
            shutil.rmtree(evidence)
        evidence.mkdir()
        report = {"schema": 1, "channel": "direct-public", "gatePassed": True, "inputsCryptographicallyPinned": False, "observedTwoBuildByteIdentity": True, "byteReproducible": False, "claim": "observed-two-build-byte-identical", "artifacts": [{"name": n, "byteIdentical": True, "firstSha256": sha(self.public / n), "secondSha256": sha(self.public / n)} for n in APKS]}
        (evidence / "rebuild-comparison.json").write_bytes(canonical(report))
        self.archived = {}
        for name in APKS:
            facts = self.measured_sidecar(name)
            self.archived[name] = facts
            d = evidence / f"artifacts/full/{Path(name).stem}"
            d.mkdir(parents=True)
            common = {"inputFingerprint": self.inputs["buildInputsSha256"], "sourceCommit": self.source["commit"]}
            components = [{"id": "pkg:fixture", "license": "MIT", "evidence": "LICENSE"}]
            assets = [{"path": "assets/fixture", "license": "MIT", "evidence": "LICENSE"}]
            packaged = [{"path": "lib/fixture.so", "license": "MIT", "evidence": "LICENSE"}]
            docs = {"public-apk-facts.json": facts, "fullRelease.cdx.json": {"schema": 1, "metadata": common, "components": components}, "fullRelease.artifact.json": {"schema": 1, **common, "artifact": {"name": name, "sha256": sha(self.public / name)}, "packagedEntries": packaged}, "source-assets.json": {"schema": 1, **common, "assets": assets}, "fullRelease.license-review.json": {"schema": 1, "status": "COMPLETE", **common, "dependencyComponents": components, "sourceAssets": assets, "packagedEntries": packaged, "unresolved": []}}
            for leaf, value in docs.items():
                (d / leaf).write_bytes(canonical(value))
        (evidence / "SHA256SUMS").write_text(''.join(f"{sha(p)}  {p.relative_to(evidence).as_posix()}\n" for p in sorted(evidence.rglob('*')) if p.is_file()))
        with tarfile.open(self.public / "hermes-console-release-evidence.tar.gz", "w:gz") as archive:
            archive.add(evidence, arcname="release-evidence")
        (self.public / "SHA256SUMS").write_text(''.join(f"{sha(self.public / n)}  {n}\n" for n in (*APKS, "hermes-console-release-evidence.tar.gz")))

    def environment(self):
        return {**os.environ, "JAVA_HOME": str(JDK), "PYTHONPATH": str(self.wrapper), "PYTHONDONTWRITEBYTECODE": "1", "DAEROH_FIXTURE_COMMIT": self.commit}


class _RealEntrypointMixin:
    def invoke(self, f):
        raise NotImplementedError

    def test_v3_only_control_passes_with_fresh_measured_facts(self):
        f = fixture()
        f.install_variant("control")
        for name in APKS:
            output = f.public.parent / f"control-{name}.json"
            output.unlink(missing_ok=True)
            result = f.launch(*f.inspector_command(name, output))
            self.assertEqual(result.returncode, 0, result.stderr)
            # Measurement serialization must match actual enforcing inspection
            # exactly for valid inputs, including tool hashes and split codes.
            self.assertEqual(output.read_bytes(), canonical(f.archived[name]))
            self.assertEqual(f.archived[name]["versionCode"], f.expectations["abiVersionCodes"][APKS[name]])
        result = self.invoke(f)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_variant_rejected(self, variant, diagnostic):
        f = fixture()
        f.install_variant(variant)
        result = self.invoke(f)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("archived APK facts differ", result.stderr)
        if variant.startswith("lineage capability "):
            cap = variant.split()[-1]
            measured = f.archived[next(iter(APKS))]["predecessorCapabilities"]
            self.assertEqual(measured, CAPABILITIES | {cap: not CAPABILITIES[cap]})
            self.assertIn(f"measured={measured!r}", result.stderr)

    def test_real_v1_plus_v3_rejected_with_fresh_facts(self):
        """R1: real old--next-signer--new, v1 on/v2 off/v3 on, restricted lineage."""
        self.assert_variant_rejected("signature scheme v1", REAL_ROWS["signature scheme v1"])
        f = fixture()
        with tarfile.open(f.public / "hermes-console-release-evidence.tar.gz") as archive:
            for name in APKS:
                raw = archive.extractfile(f"release-evidence/artifacts/full/{Path(name).stem}/public-apk-facts.json").read()
                facts = json.loads(raw)
                self.assertEqual(facts["artifact"]["sha256"], sha(f.public / name))
                self.assertEqual(facts["signatureSchemes"], {"v1": True, "v2": False, "v3": True})
                self.assertEqual(facts["predecessorCapabilities"], CAPABILITIES)
                # Prove v1 is cryptographically valid, not just ZIP metadata.
                output = f.launch(APKSIGNER, "verify", "--verbose", "--print-certs", "--min-sdk-version", "23", "--max-sdk-version", "23", f.public / name).stdout
                old, schemes = inspector.signature_measurement(output)
                self.assertEqual(old, f.predecessor)
                self.assertTrue(schemes["v1"])

    def test_legacy_only_v2_is_rejected_even_when_sdk29_selects_v3(self):
        f = fixture()
        f.install_variant("legacy-only-v2")
        first = next(iter(APKS))
        measured = f.measurements[(first, sha(f.public / first))]
        self.assertFalse(measured["current"]["v2"])
        self.assertTrue(measured["legacy"]["v2"])
        self.assertTrue(measured["current"]["v3"])
        result = self.invoke(f)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(EXTRA_CASES["legacy-only-v2"], result.stderr)
        self.assertIn(f"measured={measured!r}", result.stderr)


class ProductionProvenanceCliRealEntrypointsTest(_RealEntrypointMixin, unittest.TestCase):
    def test_real_generator_output_assembled_then_provenance_validated(self):
        """Real indented generator output must cross the final provenance boundary."""
        f = fixture()
        f.install_variant("control")
        environment = {**os.environ, "HERMES_LOCAL_AGENT": "true",
                       "SBOM_GIT_COMMIT": f.commit,
                       "RELEASE_INPUT_FINGERPRINT": f.inputs["buildInputsSha256"]}
        checked([LAUNCHER, "flutter", "pub", "get"], cwd=f.root, env=environment)
        inputs = f.public.parent / "release-evidence"
        (inputs / "SHA256SUMS").unlink()
        for name in APKS:
            directory = inputs / f"artifacts/full/{Path(name).stem}"
            checked([LAUNCHER, PYTHON, f.root / "tool/sbom/generate.py",
                     "--variant", "fullRelease", "--artifact", f.public / name,
                     "--output-dir", directory], cwd=f.root, env=environment)
            raw = (directory / "fullRelease.license-review.json").read_bytes()
            self.assertNotEqual(raw, canonical(json.loads(raw)), "exercise the generator's real indented encoding")
            self.assertEqual(json.loads(raw)["status"], "COMPLETE")
        with tempfile.TemporaryDirectory(prefix="assembled-generator-") as temporary:
            output = Path(temporary) / "assembled"
            checked([PYTHON, f.root / "tool/release/assemble_evidence_archive.py",
                     "--input-directory", inputs, "--output-directory", output])
            shutil.copy2(output / "hermes-console-release-evidence.tar.gz", f.public)
            result = self.invoke(f)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Public APK provenance validation passed.", result.stdout)

    def invoke(self, f):
        return run([PYTHON, f.root / "tool/release/validate_public_apk_provenance.py", "--archive", f.public / "hermes-console-release-evidence.tar.gz", "--asset-directory", f.public, "--trusted-toolchain", f.toolchain], env=f.environment())


class FinalPublicAssetsShellRealEntrypointsTest(_RealEntrypointMixin, unittest.TestCase):
    def invoke(self, f):
        return run(["bash", f.root / "tool/release/validate_public_assets.sh", f.public, f.tag, f.commit, f.toolchain], env=f.environment())


def row_test_name(row):
    return "test_real_field_" + ''.join(c if c.isalnum() else '_' for c in row)


# Separate named tests ensure the inventory maps to actual executed assertions
# at BOTH entry points rather than a decorative list beside an unrelated loop.
for row, diagnostic in (REAL_ROWS | {"missing lineage": EXTRA_CASES["missing lineage"]}).items():
    if row == "signature scheme v1":
        continue  # dedicated R1 test above is stronger than the generic row
    def field_test(self, row=row, diagnostic=diagnostic):
        if row == "per-ABI versionCode":
            for abi in APKS.values():
                with self.subTest(abi=abi):
                    self.assert_variant_rejected(f"versionCode-{abi}", diagnostic)
        else:
            self.assert_variant_rejected(row, diagnostic)
    field_test.__doc__ = f"Real APK {row}; assert its diagnostic through the production entry point."
    setattr(_RealEntrypointMixin, row_test_name(row), field_test)


class InspectorOnlyExemptionsTest(unittest.TestCase):
    def test_inspector_only_v3_absence_recorded_outputs(self):
        """Inspector-only: v3 absence cannot be isolated from embedded-lineage loss.

        Recorded tools keep lineage independently present to reach the scheme
        comparison. This is NOT real signed-APK or final-entrypoint evidence.
        """
        import release_safety_gate_test as safety
        helper = safety.ReleaseInspectorFieldCompletenessTest()
        with tempfile.TemporaryDirectory(prefix="inspector-only-v3-") as temporary:
            root = Path(temporary)
            _, public, _, _, expected, toolchain = helper.fixture(root)
            manifest = json.loads(toolchain.read_text())
            tools = {name: Path(manifest["root"]) / record["path"] for name, record in manifest["tools"].items()}
            apk = public / next(iter(APKS))
            result = run([PYTHON, ROOT / "tool/release/inspect_public_apk.py", "--artifact", apk, "--expected", expected, "--expected-artifact-name", apk.name, "--expected-abi", APKS[apk.name], "--expected-signer-sha256", helper.signer, "--policy", expected.with_name("release-contract.json"), "--aapt", tools["aapt"], "--apkanalyzer", tools["apkanalyzer"], "--apksigner", tools["apksigner"], "--output", root / "facts.json"], env={**os.environ, "RECORDED_MUTATION": "scheme-v3"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("APK signature schemes", result.stderr)
        self.assertIn("'v3': False", result.stderr)

    def test_inspector_only_rotation_min_sdk_recorded_argv(self):
        """Inspector-only: recorded verifier is argv-sensitive to SDK29 vs SDK28.

        Production final entry points pin 29; this does not pretend a real
        signing-target mutation independently reaches that comparison.
        """
        import release_safety_gate_test as safety
        helper = safety.ReleaseInspectorFieldCompletenessTest()
        helper.test_rotation_min_sdk_is_argv_sensitive_and_reports_the_rotation_failure()


class ReleaseGatePrerequisitesTest(unittest.TestCase):
    def test_explicit_release_gate_has_real_entrypoint_prerequisites(self):
        """Always on: an explicit release gate must never silently skip real APKs."""
        if os.environ.get("DAEROH_RELEASE_GATE") == "1":
            prerequisites = (LAUNCHER, AAPT, APKSIGNER, ANALYZER, ANDROID_JAR, JDK / "bin/keytool")
            self.assertTrue(
                all(path.is_file() for path in prerequisites),
                "DAEROH_RELEASE_GATE=1 requires DAEROH_LOCAL_TOOLCHAIN_LAUNCHER, "
                "DAEROH_VERIFIER_TOOLCHAIN and DAEROH_ANDROID_JAR; real entrypoint tests must not skip",
            )


class RealEntrypointCompletenessTest(unittest.TestCase):
    def test_real_rows_plus_explicit_inspector_only_rows_equal_field_table(self):
        import release_safety_gate_test as safety
        table = safety.ReleaseInspectorFieldCompletenessTest.IDENTITY_FIELDS
        rows = {field for field, _, _ in table}
        self.assertEqual(len(rows), len(table), "duplicate upstream field row")
        self.assertFalse(set(REAL_ROWS) & set(INSPECTOR_ONLY_ROWS))
        self.assertEqual(set(REAL_ROWS) | set(INSPECTOR_ONLY_ROWS), rows)
        for cls in (ProductionProvenanceCliRealEntrypointsTest, FinalPublicAssetsShellRealEntrypointsTest):
            for row in REAL_ROWS:
                name = "test_real_v1_plus_v3_rejected_with_fresh_facts" if row == "signature scheme v1" else row_test_name(row)
                self.assertTrue(callable(getattr(cls, name, None)), (cls.__name__, row))
        for row, (test, reason) in INSPECTOR_ONLY_ROWS.items():
            method = getattr(InspectorOnlyExemptionsTest, test, None)
            self.assertTrue(callable(method), row)
            self.assertIn("Inspector-only", method.__doc__)
            self.assertTrue(reason)


if __name__ == "__main__":
    unittest.main()
