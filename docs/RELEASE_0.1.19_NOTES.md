# Daeroh 0.1.19 — private source candidate

Version: **0.1.19+4023**. This is not publication or release approval.

## Changes

- Leaving Chat no longer retires the storage owner of a message already queued
  behind a streaming reply. The retained chat owns its deliveries until it is
  disposed. The screen still retires its own draft producer when it closes.
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

## Limits and distribution

- A pending message is not a claim of server delivery. Uncertain delivery still
  requires authoritative evidence or an explicit user decision; no automatic
  replay is added by these fixes.
- Device-only saved previews are not current server truth. Clearing a preview
  remains local-only, and cleanup/deletion fences continue to revoke producers.
- This work authorizes only debug emulator test builds. No release key, tag,
  public upload, VPN-share write, or physical-device update is authorized.
- Independent review is required before integration/release. Host tests,
  emulator results, physical-device validation, signing and distribution are
  separate evidence classes. Emulator x86_64 behavior is not ARM64 acceptance.
- GPL notices and source obligations remain unchanged. Keep this source with
  any later owner-approved distribution; do not publish private QA evidence.
