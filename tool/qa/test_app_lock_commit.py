#!/usr/bin/env python3
"""Run host JVM fault tests of the production app-lock commit boundary.

Uses only the project's already cached Kotlin compiler (no downloads/SDK changes).
Requires JAVA_HOME or java on PATH and the Gradle dependency cache populated.
This does not exercise AndroidKeyStore, SharedPreferences or a physical device.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"


def artifact(group, name, version, suffix="jar"):
    matches = sorted((CACHE / group / name / version).glob(f"*/{name}-{version}.{suffix}"))
    if not matches:
        raise SystemExit(f"Missing cached {group}:{name}:{version} ({suffix}); no downloads attempted")
    return matches[0]


def main():
    settings = (ROOT / "android/settings.gradle.kts").read_text()
    match = re.search(r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"', settings)
    if match is None:
        raise SystemExit("Cannot resolve the project's Kotlin compiler version")
    version = match[1]
    group = "org.jetbrains.kotlin"
    compiler = artifact(group, "kotlin-compiler-embeddable", version)
    pom = ET.parse(artifact(group, "kotlin-compiler-embeddable", version, "pom"))
    ns = {"m": "http://maven.apache.org/POM/4.0.0"}
    dependencies = [compiler]
    for dep in pom.findall("m:dependencies/m:dependency", ns):
        coordinates = []
        for name in ("groupId", "artifactId", "version"):
            element = dep.find(f"m:{name}", ns)
            if element is None or not element.text:
                raise SystemExit("Invalid cached compiler dependency metadata")
            coordinates.append(element.text)
        dependencies.append(artifact(coordinates[0], coordinates[1], coordinates[2]))
    # Kotlin emits JetBrains nullability annotations into JVM bytecode.
    annotations = sorted((CACHE / "org.jetbrains" / "annotations").glob("*/*/annotations-*.jar"))
    if not annotations:
        raise SystemExit("Missing cached JetBrains annotations")
    dependencies.append(annotations[-1])
    java_home = os.environ.get("JAVA_HOME")
    java = str(Path(java_home) / "bin/java") if java_home else shutil.which("java")
    if not java:
        raise SystemExit("Set JAVA_HOME to an existing JDK; no installation attempted")
    classpath = os.pathsep.join(map(str, dependencies))
    with tempfile.TemporaryDirectory(prefix="app-lock-jvm-", dir=os.environ.get("TMPDIR")) as output:
        subprocess.run([
            java, "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
            "-no-stdlib", "-no-reflect", "-classpath", classpath, "-d", output,
            str(ROOT / "android/app/src/main/kotlin/com/hermesagent/hermes_android/CommittedAppLockRecord.kt"),
            str(ROOT / "tool/qa/AppLockCommitContractTest.kt"),
        ], check=True)
        subprocess.run([
            java, "-cp", output + os.pathsep + classpath,
            "com.hermesagent.hermes_android.AppLockCommitContractTestKt",
        ], check=True)


if __name__ == "__main__":
    main()
