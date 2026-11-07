#!/usr/bin/env python3
"""Pinned secure-storage Java bytecode contract, host only; no downloads.

Run compileQaDebugKotlin offline first to produce current plugin classes.
Uses Android SDK API signatures but host substitutes for preferences and Log/
Base64. This verifies actual cached initialize + corruption recovery bytecode,
not Android Keystore, process startup, hardware, or filesystem durability.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[2]


def main():
    packages = json.loads((ROOT / '.dart_tool/package_config.json').read_text())
    package = next(p for p in packages['packages'] if p['name'] == 'flutter_secure_storage')
    plugin = Path(unquote(urlparse(package['rootUri']).path))
    if not re.search(r'^version:\s*10\.3\.1\s*$', (plugin / 'pubspec.yaml').read_text(), re.M):
        raise SystemExit('Contract must be re-reviewed for a different plugin version')
    properties = dict(line.split('=', 1) for line in (ROOT / 'android/local.properties').read_text().splitlines() if '=' in line)
    platforms = sorted((Path(properties['sdk.dir']) / 'platforms').glob('android-*/android.jar'))
    if not platforms:
        raise SystemExit('Existing Android SDK signatures required; no installation attempted')
    android = platforms[-1]
    classes = ROOT / 'build/flutter_secure_storage/intermediates/javac/debug/compileDebugJavaWithJavac/classes'
    if not (classes / 'com/it_nomads/fluttersecurestorage/FlutterSecureStorage.class').is_file():
        raise SystemExit('Run offline Android compile first; missing pinned plugin classes')
    home = os.environ.get('JAVA_HOME')
    javac = str(Path(home) / 'bin/javac') if home else shutil.which('javac')
    java = str(Path(home) / 'bin/java') if home else shutil.which('java')
    if not javac or not java:
        raise SystemExit('Existing JDK required; set JAVA_HOME')
    bytecode = classes / 'com/it_nomads/fluttersecurestorage/FlutterSecureStorage.class'
    print('Plugin 10.3.1 bytecode SHA256:', hashlib.sha256(bytecode.read_bytes()).hexdigest(), flush=True)
    print('Android signatures:', android, flush=True)
    with tempfile.TemporaryDirectory(prefix='secure-storage-host-', dir=os.environ.get('TMPDIR')) as tmp:
        out = Path(tmp)
        util = out / 'android/util'
        util.mkdir(parents=True)
        (util / 'Log.java').write_text('''package android.util;
public class Log {
  public static int e(String tag, String text, Throwable error) { return 0; }
  public static int w(String tag, String text) { return 0; }
}
''')
        (util / 'Base64.java').write_text('''package android.util;
public class Base64 {
  public static byte[] decode(String text, int flags) {
    return java.util.Base64.getDecoder().decode(text);
  }
}
''')
        cp = os.pathsep.join(map(str, [classes, android]))
        subprocess.run([javac, '-cp', cp, '-d', tmp, str(util / 'Log.java'), str(util / 'Base64.java'), str(ROOT / 'tool/qa/SecureStorageConfigContractTest.java')], check=True)
        subprocess.run([java, '-cp', tmp + os.pathsep + cp, 'SecureStorageConfigContractTest'], check=True)


if __name__ == '__main__':
    main()
