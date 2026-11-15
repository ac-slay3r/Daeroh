# Release and distribution

Daeroh has three Android flavors built from one reviewed source commit.
A flavor name is a security boundary, not a rename operation.

| Lane | Flavor | Accepted artifact | Visibility |
|---|---|---|---|
| Google Play | `play` | none | unavailable; Daeroh does not distribute through Google Play |
| GitHub Releases / Obtainium | `full` | three signed split release APKs | public only in the approved publication |
| Emulator QA | `qa` | profile/debug APK | internal only; never public or release evidence |

The reviewed executable policy is `tool/release/release_contract.json`. The
source lock is `pubspec.lock` with SHA-256
`14328be1a42a6839e16931c8953acacdc2b063ce17672521f6687cc1e2644717`.
Changing a lock, signer, authorized source actor or inspection-tool digest
requires a normal source review; release scripts never rewrite those values.
The reviewed contract anchors the Daeroh public signer continuity and public
inspection-tool digests.

## Public-repository CI is verification-only

GitHub Actions artifacts are public-repository downloads for readers of this
repository. They must never carry a signed APK, AAB, keystore, mapping, private
comparison result, or pre-publication candidate. Cross-job artifact transfer is
therefore prohibited for release candidates.

`.github/workflows/build-apk.yml` is CI verification only. It checks the exact
tag/commit, authorized forge actor, lock, checked-in SBOMs, licenses, scanners,
analysis and tests. It has read-only repository permissions, receives no signing
secret, builds no signed candidate, creates no artifact attestation and invokes no
artifact upload/download action. Successful CI is not a build, staging,
publication result.

Sensitive building, comparison and staging stay on one owner-controlled machine
and an owner-controlled local/private filesystem. No helper in this repository
uploads or publishes anything. A separate publication operation is permitted
only after explicit owner approval for the exact channel and exact bytes.

## Reviewed source and signer continuity

The source identity gate requires GitHub verification and binds the forge
`authorLogin` to `ac-slay3r` and `committerLogin` to either `ac-slay3r` or
GitHub's `web-flow` merge committer. `web-flow` never authorizes a different
author. A valid signature from an unlisted actor is rejected. Daeroh release
identities use only `daeroh-v*` tags; inherited upstream `v*` tags are never
Daeroh releases.

The direct inspector anchors the Daeroh release certificate SHA-256
`34144c8e2c8d1d062c96e5a103e0f37e3d3c80c277c46f7b6c6a4d7cd9d28859`, accepts
only the recorded predecessor for v3 rotation, and validates the inspected APK
package against the reviewed Daeroh package ID. Caller-provided expectations
cannot replace those reviewed contract values.

## Private local double build

On GNU/Linux x86-64, export explicit SDK/JDK discovery before invoking the gate:

```bash
export ANDROID_HOME=/absolute/path/to/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/absolute/path/to/jdk
export PATH=/absolute/path/to/flutter/bin:$PATH

bash tool/release/double_build.sh \
  direct-public /absolute/path/to/clean/source COMMIT \
  /absolute/private/key.properties \
  /absolute/private/direct-output \
  34144c8e2c8d1d062c96e5a103e0f37e3d3c80c277c46f7b6c6a4d7cd9d28859 \
  /absolute/private/daeroh-release.p12 \
  /absolute/private/daeroh-release.password \
  /absolute/private/rotation.lineage
```

The script signs each Gradle-produced split *before* it is copied to the
replica: it uses the supplied keystore, password file and lineage with v1/v2
disabled, v3 enabled, and min/rotation SDK 29. Comparison, manifest capture,
source binding and the final checker therefore consume those same final bytes;
do not manually re-sign an output after this command. The script verifies
required commands, preserves Android/JDK discovery through its clean
environment, and gives each replica an isolated `HOME`, `PUB_CACHE` and
`GRADLE_USER_HOME`. It builds into a mode-0700 temporary sibling of the
requested output and atomically renames that sibling only after both builds and
the comparison pass. Before promotion, the same build step writes the canonical
`double-build-manifest.json`: exact source/input identities, build command,
expected signer input, resolved build-tool paths and pre-build hashes (required
unchanged after both replicas), both replicas' artifact names/sizes/hashes, and
the comparison-report hash. Public/Play binding helpers consume that manifest
and reject artifacts not recorded as replica A. The manifest and generated
source binding remain maintainer-only and are excluded from the public evidence
archive. Any failure removes the temporary stage and leaves no output directory
or signed residue.

This manifest is a deterministic local causal record from the orchestrated
build, not cryptographic provenance. A principal that can replace the build
script, tools, artifacts and manifest on the owner machine remains outside this
control; direct signed-APK measurement is the release evidence, with no third-party build record.

Dependency inputs are not all cryptographically pinned: the Gradle distribution
has no `distributionSha256Sum`, Gradle/Maven verification metadata and locks are
absent, and Android packages are not content-pinned as a complete dependency
set. Equal APK output is only an observed two-build byte identity, not a general reproducible-build claim.
The observed two-build comparison does not claim rebuildability by unrelated
builders. Google Play is unavailable for Daeroh; no Play AAB is built, staged,
or published through this policy.

## SBOM and native-license evidence

`tool/sbom/packaged-license-catalog.json` is the reviewed path-to-component
catalog for packaged Flutter/native binaries. Entries are anchored by closed,
ABI-specific path patterns, SPDX expressions and repository evidence paths.
Unknown or overlapping paths remain `NOASSERTION` and force `REVIEW_REQUIRED`;
there is no blanket native-binary allow or suppression. Standard `libapp.so`,
Flutter engine and reviewed sherpa/ONNX/whisper native paths can reach
`COMPLETE` through this explicit evidence.

The catalog and generator are part of the SBOM input fingerprint. All five
checked-in `sbom/*.json` outputs must be regenerated when either changes. CI
regenerates them and rejects any diff.

Evidence tar validation caps compressed size before opening, iterates at most
128 headers in streaming mode, and caps individual and total uncompressed
content before retaining allowed evidence bytes. Duplicate, linked, traversal,
extra and malformed members fail closed.

## Binary path scan exceptions

`validate_public_assets.sh` invokes `scan_binary_paths.py` over every decompressed
APK member. The original `/home/`, `/Users/` and Windows-user bans remain broad.
The inspector has no separate private-path scan; it is not substituted for this
all-member final-boundary check.

`tool/release/binary_path_exceptions.json` is the only exception policy. Unknown
fields, duplicate keys/records, malformed hashes, unsupported member paths and
unknown schemas fail closed, including on APKs with no path hits. Only the exact
three sherpa C-API members listed there were found to contain runner paths in
the blocked 0.1.18 split artifacts. Hashes pin **decompressed** bytes; matching
hashes allow only paths beginning `/home/runner/work/sherpa-onnx/`. A dependency
bump must undergo review and repinning, not a wildcard or automatic update.
Mismatches report the member and expected/observed hashes.

For the three exact `lib/<abi>/libapp.so` members, only one complete literal
`(?:/home/[A-Za-z0-9._-]+|/root|~)/\.hermes/cache/images/` is allowed. Its
`/home/` match must occur at that literal's exact byte offset. Additional paths,
near-misses and duplicate literals fail; Dart source is unchanged. Other members
cannot inherit either exception. Metadata path/IP scanning is unchanged.

Read-only standalone check (also used by the final shell gate):

```bash
python3 tool/release/scan_binary_paths.py /absolute/private/candidate.apk
```

## Eventual public allowlist

After all private gates and explicit owner publication approval, the final
public release may contain exactly these five basenames:

- `SHA256SUMS`
- `app-arm64-v8a-full-release.apk`
- `app-armeabi-v7a-full-release.apk`
- `app-x86_64-full-release.apk`
- `hermes-console-release-evidence.tar.gz`

No AAB, QA/debug/profile APK, mapping, log, keystore or diagnostic bundle is
allowed. `tool/release/validate_public_assets.sh` rejects missing files, extras,
links, directories, checksum drift, signer drift and stale evidence. For the final
gate it copies the allowlisted files into a private snapshot, runs every
cryptographic, structural and APK-evidence check against that one snapshot,
then revalidates and byte-compares the source directory before success.

The final validation command takes only release identity and a runtime manifest
for the reviewed public inspection toolchain; policy, expectations, signer,
executable hashes, Android companion runtime trees and the JDK binary/library
trees are always loaded from the reviewed source. Inspection runs with the
anchored JDK selected through a scrubbed environment:

```bash
python3 tool/release/record_trusted_toolchain.py \
  --root /absolute/path/to/reviewed/android-sdk \
  --jdk-root /absolute/path/to/reviewed/jdk \
  --output /absolute/private/trusted-public-toolchain.json
bash tool/release/validate_public_assets.sh \
  /absolute/private/release-public \
  daeroh-v0.1.18 EXACT_RELEASE_COMMIT \
  /absolute/private/trusted-public-toolchain.json
```

There is no third-party build provenance record for owner-built artifacts. CI verifies source and policy only; it does not build, sign, receive, attest, or upload APKs. The final local validator instead requires the reviewed source tag/commit identity, signer continuity, measured APK metadata, SHA-256 checksums, the evidence archive, and the recorded observed two-build byte identity.

## Operator gate

1. Select one exact reviewed tag/commit and require a clean tree.
2. Pass verification-only CI and local security/policy tests.
3. Build twice in the intended local/private channel with the intended key.
4. Require package, version, ABI/flavor, signer, hash, source binding, SBOM and
   license review to pass; keep all candidate bytes private.
5. Install and smoke-test the exact selected channel artifact.
6. Obtain explicit owner approval for the exact channel and bytes.
7. Only in that approved publication operation, produce/verify provenance and
   publish the exact five-file direct allowlist. Google Play is unavailable;
   never substitute `full`, `play` or `qa` artifacts across lanes.

## Update page build configuration

Direct-distribution builds use the reviewed public update-page default. Any
explicit Flutter `DAEROH_UPDATE_PAGE_URL` override must be approved, valid, and
must not redirect users to another distribution channel.
