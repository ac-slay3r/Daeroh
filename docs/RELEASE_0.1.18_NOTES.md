# Daeroh 0.1.18 (4022) — release candidate

## Changes since 0.1.16

- Fix “Send pending”: an unsent placeholder is no longer treated as proof that
  a queued message was delivered. Delivery must be proved by the server before
  the delivered queue entry clears. Ordinary composer behavior is unchanged.
- Pairing and server setup use Daeroh-owned scripts from this repository,
  pinned to a commit. Downloaded script bytes are checked before execution.
- The update button opens https://github.com/ac-slay3r/Daeroh/releases.
- Direct full APKs use the Daeroh release key and an Android v3 signing lineage
  from the historic debug certificate. On supported Android versions this
  permits in-place updates without clearing app data. Rollback to the old
  debug-signed app is deliberately blocked. The arm64 split versionCode is 6022,
  above 0.1.17's 6021.
- Release checks pin binary-path exceptions and bundled license evidence.
  Daeroh logo files are GPL-3.0-only; inherited notices remain in place.

## Known limits and validation boundaries

- Relaxed queue settlement has no clock tolerance. If the phone's clock is
  ahead of the server's, a message already delivered can remain in the queue.
- The multi-row queue rule does not automatically settle attachments. They
  still need their own delivery proof.
- The pairing QR contains a long-lived gateway key. Treat the QR as a secret;
  do not share or publish it.

- Android 10 (API 29) or later is required. Signing-lineage inspection and
  emulator updates are not proof of an update on a physical ARM64 phone.
- Queue recovery does not replay a prompt automatically. A lost confirmation
  still needs authoritative server evidence; do not treat a local placeholder
  or a device-only saved preview as current server truth.
- Saved Chat previews remain encrypted, bounded, display-only device data.
  Clearing one does not delete server history. Canonical recovery may still
  download full history. This is not delta sync or a battery/reconnect cure.
- Synthetic emulator chat acceptance is not live-provider, physical-device,
  Android Keystore hardware, or Termux runtime acceptance. Phone-observed
  disconnect causes not reproduced in a controlled test remain unresolved.
- Two identical local builds establish observed byte identity only. Gradle,
  Maven and the complete Android SDK dependency set are not all content-pinned;
  this is not a general reproducible-build or third-party attestation claim.
- CI verifies source and policy; the owner builds and signs locally. Candidate
  creation does not mean source integration, independent approval, publication,
  or distribution. GitHub Releases is the intended channel for signed full
  APKs only. No Play, QA or debug artifact belongs in that public release.

Exact gate results and any unachieved scenarios belong in the candidate's
private evidence, not in claims inferred from these source notes. Publication
requires independent review and AC's final approval.
