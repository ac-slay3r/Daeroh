# Releasing Daeroh

This document describes a future owner-approved procedure. It is not
permission to build, sign, tag, publish, upload, or distribute anything now.

## Public release channel

Daeroh direct releases use reviewed source tags named `daeroh-v*`; the intended
first public release is `daeroh-v0.1.18`. A GitHub Release identifies its exact
source tag and commit, attaches the inspected `full` APK asset(s) and
`SHA256SUMS`, and keeps corresponding GPL-3.0 source available from that tag.
Inherited upstream `v*` tags are provenance, not Daeroh release tags.

Only public, non-secret artifacts belong in the release channel. Never publish
keys, password files, lineage files, mappings, diagnostics, private endpoints,
or QA/debug/profile/Play artifacts.

## Owner-only signing

The Daeroh-controlled RSA-4096 release key and v3 rotation lineage remain on
the owner-controlled machine and private filesystem. CI verifies source and
release policy only: it never receives a key, signs an APK, or uploads a signed
candidate. The historic debug certificate is an accepted lineage predecessor;
it is not a future release signer.

## Source identity

The final local gate queries GitHub for the exact tagged commit and requires a
valid GitHub verification, an authorized author (`ac-slay3r`), and an authorized
committer. `web-flow` is listed as an accepted committer because GitHub records
it as the committer when the authorized author merges a pull request. It is
accepted only together with GitHub verification and an authorized author; it
does not authorize another author's commit.

Before this owner-only operation, obtain the owner-local local-toolchain
launcher; it is deliberately not tracked in this repository. The approved path
is `double_build.sh`: it invokes the launcher-provided Flutter tooling, then
signs each split with the supplied key/password/lineage before comparison and
manifest capture. Do not sign after the double build: that changes bytes the
manifest and final gate deliberately bind. Use private placeholders, never
literal passwords, secrets, or real private paths:

```sh
<owner-local-toolchain-launcher> bash tool/release/double_build.sh \
  direct-public /neutral/clean/Daeroh COMMIT \
  /owner-private/key.properties /owner-private/direct-output \
  34144c8e2c8d1d062c96e5a103e0f37e3d3c80c277c46f7b6c6a4d7cd9d28859 \
  /owner-private/daeroh-release.p12 \
  /owner-private/daeroh-release.password \
  /owner-private/rotation.lineage
```

Inspect package identity, signer, embedded lineage, active signature schemes,
versionCode, ABI/flavor, source binding, and checksums before publication. Use
`full` only; `qa` is emulator-only and never a delivery artifact. Build from a
neutral path outside user homes and reject any shipped binary containing
`/home/`.

## Pinned inspection toolchain

The public verifier has been exercised with a side-by-side, archive-provenanced
inspection toolchain. Obtain it in a new private directory rather than reusing a
host SDK: download Android command-line tools 12.0 from
`https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip`
(SHA-256 `2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258`),
Android build-tools 36.0.0 from
`https://dl.google.com/android/repository/build-tools_r36_linux.zip`
(SHA-256 `5d9ac77fb6ff43d9da518a337b4fcf8f9097113df531d99ccefe80ef7ce8250b`),
and Eclipse Temurin 17.0.21+9 from
`https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz`
(SHA-256 `8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711`,
matching the vendor-published checksum). The non-private example layout below
uses one absolute root, `/opt/daeroh-verifier-toolchain`; choose another empty
absolute directory if needed, but replace that root consistently in every
command. Lay out the Android downloads as
`/opt/daeroh-verifier-toolchain/android-sdk/build-tools/36.0.0` and
`/opt/daeroh-verifier-toolchain/android-sdk/cmdline-tools/latest`, and the JDK
as `/opt/daeroh-verifier-toolchain/jdk17`. Select the freshly unpacked JDK
through both `JAVA_HOME` and `PATH` **before** generating deterministic SDK
metadata that is not present in the build-tools archive (this lists installed
metadata only; it neither accepts licenses nor installs packages):

```sh
export JAVA_HOME=/opt/daeroh-verifier-toolchain/jdk17
export PATH="$JAVA_HOME/bin:$PATH"
/opt/daeroh-verifier-toolchain/android-sdk/cmdline-tools/latest/bin/sdkmanager \
  --sdk_root=/opt/daeroh-verifier-toolchain/android-sdk --list_installed
```

Then record the manifest with the same layout:

```sh
python3 tool/release/record_trusted_toolchain.py \
  --root /opt/daeroh-verifier-toolchain/android-sdk \
  --jdk-root /opt/daeroh-verifier-toolchain/jdk17 \
  --output /opt/daeroh-verifier-toolchain/trusted-public-toolchain.json
```

The recorded command-line-tools tree is
`06973c0511cb548d5904221c176b490b0c213a17062524e12c7e2460af9ed7ad` and the
pinned `apkanalyzer` starts `c3277b8f17d26159`. The reproducibly provisioned
build-tools, JDK `bin`, JDK `lib`, and JDK `conf` trees are pinned in
`release_contract.json`; `conf`, including `conf/security/java.security`, is
part of the authenticated runtime.

## Required real-entrypoint regression gate

Before a release, set `DAEROH_VERIFIER_TOOLCHAIN` to the reviewed pinned
inspection SDK/JDK cache root, `DAEROH_ANDROID_JAR` to the compile-only API 36
`android.jar`, and `DAEROH_LOCAL_TOOLCHAIN_LAUNCHER` to the executable
owner-local toolchain launcher. The launcher is deliberately untracked and must
have its normal full SDK/Flutter environment available. Use generic local paths;
never commit private paths or signing material. From the exact reviewed checkout:

```sh
export DAEROH_VERIFIER_TOOLCHAIN=/absolute/path/to/reviewed-verifier-cache
export DAEROH_ANDROID_JAR=/absolute/path/to/android-36/android.jar
export DAEROH_LOCAL_TOOLCHAIN_LAUNCHER=/absolute/path/to/owner-local-launcher
export DAEROH_RELEASE_GATE=1
"$DAEROH_LOCAL_TOOLCHAIN_LAUNCHER" python3 -m unittest discover -s test -p 'release_real_entrypoints_test.py'
```

A release must not proceed if any test in this module skips or fails. The
always-on explicit-release-gate prerequisite test fails rather than silently
skipping when the real-APK prerequisites are absent. Plain discovery without
these variables skips the real-APK cases; it is not this release gate. These
throwaway-signed host fixtures and recorded GitHub transport test the checker,
not production signing, an app build, or emulator/device acceptance.

## Verified checker scope

A throwaway `full` split set built with `HERMES_LOCAL_AGENT=true`, signed
v3-only with a throwaway predecessor-to-current lineage, passed direct
inspector reinspection with the pinned tools. The pinned analyzer output fixture
covers its implied capped `READ_EXTERNAL_STORAGE` compatibility record and its
`maxSdkVersion` suffixes; normalization accepts only that exact implication and
still requires manifest and policy equality. Wrong package, label, signature
scheme, lineage, predecessor, ABI version code, permissions, native private
path, tag namespace, and JDK configuration drift are rejection controls.

Final public-asset validation has no third-party build attestation. CI verifies
source and policy only; the APKs are built and signed on the owner-controlled
machine and have no CI-built-artifact or third-party build record. The final
gate validates the same five-file snapshot against the reviewed source tag and
commit, signer continuity, measured APK facts, checksums, evidence archive, and
recorded observed two-build byte identity. This is separate from APK inspection:
the builder records direct measurements of the signed APK and an independent
reviewer also measures the signed APK directly.

## Recovery

If the release keystore or password is lost, a future APK cannot update
existing installs in place. If the lineage is lost, the proven material for
future v3-only updates is also lost. Keep offline backups of the keystore,
password, and lineage under AC's control and keep the password in AC's password
vault. Do not distribute these private materials.

For the complete approval and evidence sequence, see
[OPEN_SOURCE_RELEASE_CHECKLIST.md](OPEN_SOURCE_RELEASE_CHECKLIST.md).
