# Daeroh 0.1.19 — private source candidate

Version: **0.1.19+4023**. This is not publication or release approval.

## Changes

- Leaving Chat no longer retires the storage owner of a message already queued
  behind a streaming reply. The retained chat owns its deliveries until it is
  disposed or its exact conversation is confirmed deleted. The screen still
  retires its own draft producer when it closes.
- Queued messages admitted after the first turn creates a server conversation
  are saved with that conversation's ID, so reopening that server Chat after a
  process restart can recover the pending text.
- A uniquely delivered queued message can settle when the phone clock is up to
  two minutes ahead of the server. The check still rejects multiple textual
  matches after the captured boundary, missing history boundaries, optimistic
  or inconsistent identities, and attachment turns in the relaxed lane. The
  ordinary single-row path is unchanged. Settling checks history; it never
  resends a prompt.
- The pre-send storage error follows the app's English or Spanish language.
- A cold-restored queue first loads its existing conversation. This preserves
  the prior turn's transcript boundary before sending the next queued message,
  so the live pair can reconcile with its durable rows without a duplicate.
- A confirmed remote session deletion revokes that conversation's local queued
  delivery authority, including proven mobile/server aliases. Late completion
  or acknowledgement callbacks cannot repopulate its outbox. This does not undo
  a prompt already handed to the server before deletion, promise secure erasure
  of storage, or change the server's deletion contract.

## Limits and distribution

- A pending message is not a claim of server delivery. Uncertain delivery still
  requires authoritative evidence or an explicit user decision; no automatic
  replay is added by these fixes.
- Device-only saved previews are not current server truth. Clearing a preview
  remains local-only. Canonical recovery may still download full history; this
  is not delta sync or a battery/reconnect cure.
- The multi-row queue rule does not automatically settle attachments; they
  still require their own delivery proof.
- The pairing QR contains a long-lived gateway key. Treat it as a secret; do
  not share or publish it.
- Android 10 (API 29) or later is required. Signing-lineage inspection and
  emulator updates do not prove an update on a physical ARM64 phone.
- Synthetic emulator chat checks are not live-provider, physical-device,
  hardware-backed Android Keystore, or Termux runtime acceptance. Unreproduced
  phone disconnect causes and reconnect/battery behaviour remain unresolved.
- Two identical local builds establish observed two-build byte identity only.
  Gradle, Maven and the complete Android SDK dependency set are not all
  content-pinned. This is not a general reproducible-build or third-party
  attestation claim, nor does this source correction claim new double builds.
- CI verifies source and policy; owner-authorized release builds/signing are
  separate. GitHub Releases accepts signed full APKs only; no Play, QA or debug
  artifact belongs in that public release.
- This work authorizes only debug emulator test builds. No release key, tag,
  public upload, VPN-share write, or physical-device update is authorized.
- Independent review is required before integration/release. Host tests,
  emulator results, physical-device validation, signing and distribution are
  separate evidence classes. Emulator x86_64 behavior is not ARM64 acceptance.
- GPL notices and source obligations remain unchanged. Keep this source with
  any later owner-approved distribution; do not publish private QA evidence.
