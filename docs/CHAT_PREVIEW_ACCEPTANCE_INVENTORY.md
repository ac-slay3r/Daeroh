# Chat preview acceptance inventory

Scope: source/host evidence for the encrypted, display-only newest-100 preview.
This inventory names shipping tests, not reviewer overlays. It does not claim an
APK build, emulator/device behavior, Keystore ciphertext verification, signing,
integration, or distribution approval.

## Commands and observed results

The 553-pass feature result and five mutation controls below are retained
historical evidence for prior candidate `bfd618de`. The current correction adds
two image-boundary controls and replaces the near-cap payload; final exact-head
counts and logs are on this card's review transition, not inferred from that prior
run. Current production changes are confined to saved-preview rendering.

All commands use the approved local launcher:

```sh
LAUNCHER=/home/aconn/projects/Daeroh/tool/qa/with_local_toolchain.sh
export HERMES_LOCAL_AGENT=true
"$LAUNCHER" flutter test --no-pub test/chat_screen_test.dart test/chat_preview_store_test.dart test/settings_history_cleanup_test.dart --reporter expanded
# 553 passed; exit 0 (complete three-file feature/regression group)

"$LAUNCHER" flutter test --no-pub test/chat_screen_test.dart --plain-name 'queued recovery has identical no-side-effect trace with or without cached preview' --reporter expanded
"$LAUNCHER" flutter test --no-pub test/chat_screen_test.dart --plain-name 'target-unbound Stop authority stays byte-identical with or without cached preview' --reporter expanded
"$LAUNCHER" flutter test --no-pub test/settings_history_cleanup_test.dart --plain-name 'la limpieza ya no falla en silencio retira preview y reporta el fallo anterior al borrar LocalTranscript' --reporter expanded
"$LAUNCHER" flutter test --no-pub test/chat_screen_test.dart --plain-name 'cached multirow physical order survives canonical paging and newest100 handoff' --reporter expanded
# Each isolated development control: 1 passed; exit 0.

"$LAUNCHER" flutter analyze --no-pub
"$LAUNCHER" flutter test --no-pub --reporter expanded
# Final committed-HEAD analyzer/full-host results belong to the same-card
# review handoff, with candidate commit/tree and logs. No release approval implied.
```

## Retained mutation sensitivity from prior candidate bfd618de

Each temporary production mutation was restored immediately in that prior batch;
its patch contained tests/documentation only. Each command used the matching isolated
`--plain-name` above and exited 1 on its substantive assertion:

- bypass saved-preview inert renderer: generated-media-card exclusion fails;
- replace pure cached projector with authority-mutating canonical projector:
  target-unbound identity assertion fails;
- increment **only** private Stop revision inside cached projection: the captured
  acquisition-authority continuation becomes invalid (expected true, got false);
- rethrow earlier transcript error before independently retiring preview:
  preview-delete-attempt assertion fails;
- omit chronological-to-newest-first preview reversal: physical Y-order assertion
  fails.

No production hook, timeout increase, arbitrary sleep, or assertion relaxation is
part of these controls. Existing host mocks emit notification initialization and
synthetic failure diagnostics; these are not Android notification acceptance.

## 1. Cold/held/offline/canonical/paging/order/newest-100

- `test/chat_screen_test.dart` — `encrypted preview is render-only before canonical history and never submits`: cold open with held canonical loader; preview paints while authoritative messages remain empty.
- `test/chat_screen_test.dart` — `canonical nonempty history replaces the cached preview without changing submission authority`: nonempty canonical replacement.
- `test/chat_screen_test.dart` — `cached preview remains render-only when canonical history fails offline`: offline canonical failure retains only device preview.
- `test/chat_screen_test.dart` — `cached multirow physical order survives canonical paging and newest100 handoff`: three real cached rows physically ascend on screen (238, 239, 240) before canonical; exact requests `(offset: 0, order: latest, limit: 120)` then `(120, latest, 120)`; exact canonical newest-first IDs 240…121 then 240…1; raw reloaded cache has exactly chronological IDs 141…240.
- `test/chat_screen_test.dart` — `historial anterior ofrece control accesible distinto al final`: canonical earlier-history accessibility control (not itself cached paging evidence).
- `test/chat_screen_test.dart` — `historial compacto canónico muestra el turno más antiguo sin aviso parcial`: canonical oldest-row/order presentation.
- `test/chat_preview_store_test.dart` — `writes bounded encrypted render previews and reads them back`: chronological input retains exactly newest 100 (`m-1` through `m-100`) after a 101-row save.

## 2. Privacy and Stop durable-authority controls

- `test/chat_screen_test.dart` — `actual LocalTranscript privacy checkpoint excludes a revoked cached preview row`: real v2 checkpoint envelope seeded at `beforeChatPush`, real transcript read observed/held/released, matching revoked cached identity excluded while canonical stays held and authoritative messages empty.
- `test/chat_screen_test.dart` — `target-unbound Stop authority stays byte-identical with or without cached preview`: paired actual Chat with anchored **target-unbound** durable tombstone; exact durable string, complete loaded authority map, zero writes, no bound target, no pending cancellation, and equal transcript coverage revision before canonical release. The private Stop revision is not exposed by a test getter: equality is checked through the existing public acquisition's captured authority token held across preview paint. A revision-only mutation invalidates this continuation and fails the control. Its intentional acquisition is released **after** the durable/preview trace is frozen; this is not a cache-triggered operation.

- `test/chat_screen_test.dart` — `cached preview applies Stop suppression without mutating durable authority`: cancelled reply is suppressed in render-only projection; `onCancelledTurn` write count remains zero before and after canonical rows.
- `test/chat_screen_test.dart` — `queued recovery has identical no-side-effect trace with or without cached preview`: paired cache-on/cache-off traces hold canonical history and queue recovery identically and compare send, materialization, tombstone-write, prompt-submission, status, and attachment-upload counts.
- `test/chat_preview_store_test.dart` — `empty accepted projection retires the prior encrypted preview`: an empty privacy-safe projection physically retires the older preview.

## 3. Late privacy and already-visible retirement

- `test/chat_screen_test.dart` — `late privacy await cannot publish a retired scope preview`, `late privacy await cannot publish a retired profile preview`, and `late privacy await cannot publish a retired connection preview`: cleanup during a held real local-transcript privacy read cannot publish a saved row.
- `test/chat_screen_test.dart` — `completed preview scope cleanup automatically removes an already-rendered preview`, `completed preview profile cleanup automatically removes an already-rendered preview`, and `completed preview connection cleanup automatically removes an already-rendered preview`: already-visible preview retirement requires no draft edit or network response.
- `test/chat_preview_store_test.dart` — `profile cleanup keeps the same profile on a neighboring connection`: owner cleanup does not remove a neighbor preview.

## 4. Settings transcript failure, held write, durable delete, delete error, partial failure

- `test/settings_history_cleanup_test.dart` — `la limpieza ya no falla en silencio retira preview y reporta el fallo anterior al borrar LocalTranscript`: actual Settings confirmation flow with seeded transcript and preview; native transcript delete fails; preview native delete independently attempted, raw preview key absent, fresh preview load empty, failed transcript remains, and notice contains exactly the expected one-store failure text.

- `test/settings_history_cleanup_test.dart` — `outbox corrupta marca fallo real y conserva cleanup best-effort de stores`.
- `test/settings_history_cleanup_test.dart` — `la limpieza ya no falla en silencio perder la instancia DESPUÉS de borrar informa de lo ya borrado`.
- `test/settings_history_cleanup_test.dart` — `la limpieza ya no falla en silencio espera la retirada cifrada antes de informar limpieza completada`.
- `test/settings_history_cleanup_test.dart` — `la limpieza ya no falla en silencio informa fallo parcial cuando no puede retirar la vista previa cifrada`.
- `test/chat_preview_store_test.dart` — `remote session deletion clears preview after draft cleanup fails`.
- `test/chat_preview_store_test.dart` — `failed physical profile cleanup is reported and does not poison FIFO`.

## 5. Pending first write, broad cleanup, later reuse, stale deletes, eviction, recreation

- `test/chat_preview_store_test.dart` — `profile cleanup fences a first write not yet visible to readAll`.
- `test/chat_preview_store_test.dart` — `completed cleanup never exposes a stale held write`.
- `test/chat_preview_store_test.dart` — `a queued empty delete cannot erase a later accepted preview`.
- `test/chat_preview_store_test.dart` — `profile cleanup preserves a preview admitted after its cleanup barrier`, `scope cleanup preserves a preview admitted after its cleanup barrier`, `connection cleanup preserves a preview admitted after its cleanup barrier`, and `session cleanup preserves a preview admitted after its cleanup barrier`.
- `test/chat_preview_store_test.dart` — `profile cleanup waits for a held native write then deletes raw storage`.
- `test/chat_preview_store_test.dart` — `profile cleanup keeps the same profile on a neighboring connection` (physical deletion followed by `resetForTesting`, the process-recreation control).
- `test/chat_preview_store_test.dart` — `writes bounded encrypted render previews and reads them back` (bounded newest-100 retention); the accepted eviction policy is oldest-saved, not access-LRU.

## 6. Paired seeded queued-delivery and cached-media trace

- `test/chat_screen_test.dart` — `queued recovery has identical no-side-effect trace with or without cached preview`.
  Seeds durable `chat_turn_outbox_v1` with ambiguous + queued turns and a real cached assistant `MEDIA:/workspace/private/review-preview-only.png` row. Gateway status and canonical history remain held while all compared values are frozen. Both durable client-turn IDs remain present; authoritative messages are empty and `messagesLoaded=false`. Only cache-on paints inert text and neither case creates a generated-media card.

  Global HTTP MockClient intercepts Dashboard token-page/file requests (no real endpoint traffic); Gateway records status, submissions and image/file upload calls. Test-local send/materialization/authority counters and a pre-Chat-screen event subscription record done/queue events. Frozen paired trace includes HTTP requests, done count (zero), queue-change count, in-memory queue IDs, drain suspension, durable outbox IDs/state/queued flags, authority bytes/writes, transcript revision and pipeline state. No media download request, send, materialization, authority write, prompt submission/retry or upload is permitted; both cases have the same single status lookup. Scalars/lists/maps are copied **before** either held lane is released; later legitimate recovery is excluded from comparison. Durable queued presence is not misreported as an already-hydrated in-memory queue.

- `test/chat_screen_test.dart` — `saved user markdown is inert before canonical rich image rendering` and `saved assistant markdown is inert before canonical rich image rendering`: paired actual Chat cache-off/cache-on with canonical history held, visible preview text, empty authoritative messages and `messagesLoaded=false`. A `dart:io HttpOverrides` client intercepts framework `HttpClient.getUrl` image requests missed by package:http. Both frozen pre-canonical traces must be empty; saved rows instantiate neither MarkdownBody nor AttachmentCard. The user fixture includes an attachment marker and legacy local-image path. After canonical publication both roles retain MarkdownBody; canonical user content retains its attachment card and the cache-off canonical image attempts a request. Separate image URLs avoid Flutter's process image cache masking the saved-row control. Baseline user rendering fails with one intercepted image request (an ATTEMPT only, no downloaded bytes); baseline user and assistant rendering also fail the plain-text renderer assertion.

## 7. Canonical aliases, content/metadata/count/complete envelope, global and obsolete-retention bounds

- `test/chat_preview_store_test.dart` — `keeps integer canonical row identities through a safe round trip` and `keeps desktop canonical aliases through a safe round trip`.
- `test/chat_preview_store_test.dart` — `dedupes canonical identity and accepts newer render metadata`, `rejects rows without canonical identity or private render state`, and `oversized text is clipped and a storage failure stays non-fatal`.
- `test/chat_preview_store_test.dart` — `complete near-cap envelope remains within the encrypted session bound`: exact header-crossing list payload is 98,288 bytes, only 16 bytes below the 98,304-byte cap. Current envelope-aware trimming passes. A surgical overlay removing ONLY the complete-envelope trim loop (list-byte trimming unchanged) fails the byte assertion with 98,341 bytes. The previous near-cap payload did not detect that mutation; this replacement does. Production storage remains byte-identical to the prior candidate.
- `test/chat_preview_store_test.dart` — `global bound evicts the oldest saved preview without touching the newest` (1 MiB global bound and oldest-saved eviction), and `newer publication wins when an older secure write finishes last` (obsolete publication retention).

## Acceptance boundary / limits

The seven sections map named shipping assertions to specific source/host contracts;
they are not blanket seven-group approval. Independent exact-head complete-feature
review remains required. This correction changes only saved-preview rendering and
permanent regressions/inventory; canonical rich rendering, storage, recovery and
delivery algorithms are unchanged. Earlier privacy, automatic cleanup, owner,
FIFO and bounds controls remain in place.

Host-widget/store evidence does not establish Android runtime acceptance. No APK
build, Android Keystore/ciphertext check, emulator, physical-device update, signer,
source integration, PR/push/merge, server change or distribution gate was performed.
The final exact-head analyzer and full-suite result are recorded on this same card's
review transition, separately from this assertion inventory.
