"""Integration control for owner-local final signing in the double-build path."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DoubleBuildSigningStageTest(unittest.TestCase):
    def test_signs_each_split_before_manifest_and_comparison(self) -> None:
        with tempfile.TemporaryDirectory(prefix="daeroh-signing-stage-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.name", "Fixture"], check=True)
            subprocess.run(["git", "-C", str(source), "config", "user.email", "fixture@example.invalid"], check=True)
            shutil.copy2(ROOT / "pubspec.lock", source / "pubspec.lock")
            (source / "pubspec.yaml").write_text("name: fixture\nversion: 1.2.3+4\n")
            (source / "android").mkdir()
            (source / "android/build.gradle").write_text("// fixture\n")
            subprocess.run(["git", "-C", str(source), "add", "."], check=True)
            subprocess.run(["git", "-C", str(source), "commit", "-qm", "fixture"], check=True)
            commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()

            tools = root / "tools"
            tools.mkdir()
            flutter = tools / "flutter"
            flutter.write_text(
                "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
                "if [[ $1 == pub ]]; then exit 0; fi\n"
                "mkdir -p build/app/outputs/flutter-apk\n"
                "for n in app-arm64-v8a-full-release.apk app-armeabi-v7a-full-release.apk app-x86_64-full-release.apk; do printf 'gradle:%s\\n' \"$n\" > build/app/outputs/flutter-apk/$n; done\n"
            )
            flutter.chmod(0o700)
            java = tools / "java"
            java.write_text("#!/bin/sh\nexit 0\n")
            java.chmod(0o700)
            android_home = root / "android-sdk"
            apksigner = android_home / "build-tools/36.0.0/apksigner"
            apksigner.parent.mkdir(parents=True)
            apksigner.write_text(
                "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
                "[[ $1 == sign ]]\n[[ $* == *'--lineage'* ]]\n[[ $* == *'--v1-signing-enabled false'* ]]\n[[ $* == *'--v2-signing-enabled false'* ]]\n[[ $* == *'--v3-signing-enabled true'* ]]\n"
                "out=''; last=''\nfor a in \"$@\"; do [[ $last == --out ]] && out=$a; last=$a; done\n"
                "input=${!#}; cat \"$input\" > \"$out\"; printf 'lineage-final\\n' >> \"$out\"\n"
            )
            apksigner.chmod(0o700)
            key_properties = root / "key.properties"
            key_properties.write_text("storeFile=unused\n")
            keystore = root / "throwaway.p12"
            password = root / "throwaway.password"
            lineage = root / "throwaway.lineage"
            keystore.write_bytes(b"throwaway")
            password.write_text("throwaway\n")
            lineage.write_bytes(b"throwaway-lineage")
            output = root / "output"
            result = subprocess.run(
                ["bash", str(ROOT / "tool/release/double_build.sh"), "direct-public", str(source), commit,
                 str(key_properties), str(output), "ab" * 32, str(keystore), str(password), str(lineage)],
                text=True, capture_output=True,
                env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "ANDROID_HOME": str(android_home),
                     "ANDROID_SDK_ROOT": str(android_home), "JAVA_HOME": str(root / "jdk")},
            )
            artifacts = list((output / "replica-a").glob("*.apk"))
            signed_final = all(path.read_bytes().endswith(b"lineage-final\n") for path in artifacts)
            manifest = (output / "double-build-manifest.json").read_text() if (output / "double-build-manifest.json").exists() else ""
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(artifacts), 3)
        self.assertTrue(signed_final)
        self.assertIn('"replicas"', manifest)
        self.assertIn('"a"', manifest)


if __name__ == "__main__":
    unittest.main()
