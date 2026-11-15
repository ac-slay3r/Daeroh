# Open-source release checklist

This is the future Daeroh direct-distribution gate. Completing or reading these
steps does **not** authorize a build, signing operation, tag, GitHub Release, or
upload. Each such action needs separate owner approval for the exact source,
artifact, and public channel.

## 1. Pin the public source

- [ ] Start from one reviewed, clean commit on `main`; retain GPL-3.0 source
  correspondence for that exact commit.
- [ ] Assign a downstream-only tag matching `daeroh-v*`; the intended first
  public tag is `daeroh-v0.1.18`. Do not treat inherited upstream `v*` tags as
  Daeroh releases.
- [ ] Record the tag, commit SHA, version name, and monotonically higher Android
  versionCode in the release notes and artifact evidence.
- [ ] Use a neutral build location: source checkout, `HOME`, `PUB_CACHE`, and
  Gradle home must be outside user-home paths. Reject a candidate if a shipped
  binary contains `/home/`.

## 2. Verify before owner-local signing

- [ ] Run the reviewed, verification-only CI and local policy checks. CI checks
  source and policy only; it does not build, sign, receive, upload, retain, or
  attest release artifacts. Owner-built APKs have no third-party build record.
- [ ] Build only the `full` flavor in the approved owner-local environment. Do
  not substitute `qa`, debug, profile, or Play artifacts for public delivery.
- [ ] Inspect the candidate APK(s) for package identity, versionCode, ABI/flavor,
  signer, hashes, source binding, SBOM, license notices, and the neutral-path
  requirement. A hash sidecar does not replace signer inspection.
- [ ] Perform the required install/update validation separately from host and
  emulator checks; an emulator result is not physical-device acceptance.

## 3. Sign on the owner machine only

- [ ] The Daeroh release key and rotation lineage stay only on the
  owner-controlled machine and private filesystem. They never enter Git,
  GitHub Actions, CI logs, tickets, release assets, or another machine.
- [ ] Use the Daeroh RSA-4096 release signer (certificate SHA-256
  `34144c8e2c8d1d062c96e5a103e0f37e3d3c80c277c46f7b6c6a4d7cd9d28859`) with
  the private v3 lineage (lineage SHA-256
  `8eb73cd934dd5fec70154bae3a5ecc76471e5306f495af0012ddb0bf7ede134d`).
  The accepted predecessor is the historic debug certificate
  `6fdcf87166ea101eeb9a5d205d48dda1fb688db5faad4b42ddf16d26cd62e848`.
- [ ] Sign v3 only with minimum and rotation-minimum SDK 29; do not use the
  historic debug keystore for future release signing. The lineage preserves the
  required installed-data and signature-permission compatibility while denying
  rollback, shared-UID, and authenticator authority to the predecessor.
- [ ] Obtain the owner-local local-toolchain launcher (it is not tracked in this
  repository) and run it with private placeholders only; never paste a
  password, key, or real private path into commands, logs, shell history, or
  documentation:

  ```sh
  <owner-local-toolchain-launcher> apksigner sign \
    --ks /owner-private/daeroh-release.p12 \
    --ks-key-alias daeroh-release \
    --ks-pass file:/owner-private/daeroh-release.password \
    --lineage /owner-private/rotation.lineage \
    --min-sdk-version 29 \
    --rotation-min-sdk-version 29 \
    --v1-signing-enabled false \
    --v2-signing-enabled false \
    --v3-signing-enabled true \
    --out /owner-private/Daeroh-full-release.apk \
    /owner-private/Daeroh-full-unsigned.apk
  ```

## 4. Publish only after exact approval

- [ ] Obtain explicit owner approval for the exact tag, APK bytes, checksums,
  source commit, and GitHub Releases channel.
- [ ] Create the approved `daeroh-v*` source tag and attach the inspected `full`
  APK asset(s) and `SHA256SUMS`. The release notes must identify the exact source
  tag and commit so recipients can obtain corresponding GPL-3.0 source.
- [ ] Publish only public, non-secret release material. Never attach keystores,
  password files, lineage files, mappings, diagnostics, test logs, private
  endpoints, QA/debug/profile artifacts, or Play artifacts.
- [ ] Preserve the GPL-3.0 license, required upstream attribution, source
  notices, and the source correspondence for every distributed APK.

## Recovery warning

**Loss of the Daeroh release keystore or its password prevents an in-place
update over existing installs.** Loss of the lineage also removes the
rotation material needed for future v3-only updates. Keep offline backups of
all three private materials under AC's control and retain the password in AC's
password vault; do not distribute any of them.
