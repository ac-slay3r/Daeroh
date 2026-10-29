# Chat preview acceptance inventory

Scope: source/host evidence for the encrypted, display-only newest-100 preview.
This inventory names shipping tests, not reviewer overlays. It does not claim an
APK build, emulator/device behavior, Keystore ciphertext verification, signing,
integration, or distribution approval.

## Commands and observed results

All commands use the approved local launcher:

```sh
/home/aconn/projects/Daeroh/tool/qa/with_local_toolchain.sh flutter test test/chat_screen_test.dart --reporter expanded
# 492 passed; exit 0

/home/aconn/projects/Daeroh/tool/qa/with_local_toolchain.sh flutter test test/chat_preview_store_test.dart test/settings_history_cleanup_test.dart --reporter expanded
# 56 passed; exit 0
```

The final exact-HEAD analyzer and complete host suite are recorded separately in
the final validation section after the committed candidate exists.

## 1. Cold/held/offline/canonical/paging/order/newest-100

- `test/chat_screen_test.dart` — `encrypted preview is render-only before canonical history and never submits`: cold open with held canonical loader; preview paints while authoritative messages remain empty.
- `test/chat_screen_test.dart` — `canonical nonempty history replaces the cached preview without changing submission authority`: nonempty canonical replacement.
- `test/chat_screen_test.dart` — `cached preview remains render-only when canonical history fails offline`: offline canonical failure retains only device preview.
- `test/chat_screen_test.dart` — `historial anterior ofrece control accesible distinto al final`: canonical offset paging, latest order, and earlier-history control.
- `test/chat_screen_test.dart` — `historial compacto canónico muestra el turno más antiguo sin aviso parcial`: canonical oldest-row/order presentation.
- `test/chat_preview_store_test.dart` — `writes bounded encrypted render previews and reads them back`: chronological input retains exactly newest 100 (`m-1` through `m-100`) after a 101-row save.

## 2. Privacy and Stop durable-authority controls

- `test/chat_screen_test.dart` — `cached preview applies Stop suppression without mutating durable authority`: cancelled reply is suppressed in render-only projection; `onCancelledTurn` write count remains zero before and after canonical rows.
- `test/chat_screen_test.dart` — `queued recovery has identical no-side-effect trace with or without cached preview`: paired cache-on/cache-off traces hold canonical history and queue recovery identically and compare send, materialization, tombstone-write, prompt-submission, status, and attachment-upload counts.
- `test/chat_preview_store_test.dart` — `empty accepted projection retires the prior encrypted preview`: an empty privacy-safe projection physically retires the older preview.

## 3. Late privacy and already-visible retirement

- `test/chat_screen_test.dart` — `late privacy await cannot publish a retired scope preview`, `late privacy await cannot publish a retired profile preview`, and `late privacy await cannot publish a retired connection preview`: cleanup during a held real local-transcript privacy read cannot publish a saved row.
- `test/chat_screen_test.dart` — `completed preview scope cleanup automatically removes an already-rendered preview`, `completed preview profile cleanup automatically removes an already-rendered preview`, and `completed preview connection cleanup automatically removes an already-rendered preview`: already-visible preview retirement requires no draft edit or network response.
- `test/chat_preview_store_test.dart` — `profile cleanup keeps the same profile on a neighboring connection`: owner cleanup does not remove a neighbor preview.

## 4. Settings transcript failure, held write, durable delete, delete error, partial failure

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
  It seeds `chat_turn_outbox_v1` with both an ambiguous unfinished turn and a queued turn carrying image-display metadata, holds the canonical loader and ambiguous status path, then executes cache-on and cache-off cases. Only cache-on renders the saved display row. The paired trace asserts zero additional send attempts, prompt submissions/retries, tombstone writes, attachment materializations, and image/file uploads; both cases make the same single status read.

## 7. Canonical aliases, content/metadata/count/complete envelope, global and obsolete-retention bounds

- `test/chat_preview_store_test.dart` — `keeps integer canonical row identities through a safe round trip` and `keeps desktop canonical aliases through a safe round trip`.
- `test/chat_preview_store_test.dart` — `dedupes canonical identity and accepts newer render metadata`, `rejects rows without canonical identity or private render state`, and `oversized text is clipped and a storage failure stays non-fatal`.
- `test/chat_preview_store_test.dart` — `writes bounded encrypted render previews and reads them back` (count and complete serialized envelope), `global bound evicts the oldest saved preview without touching the newest` (1 MiB global bound and oldest-saved eviction), and `newer publication wins when an older secure write finishes last` (obsolete publication retention).

## Uncovered / limits

No uncovered source/host acceptance group was identified in the listed shipping tests. This inventory deliberately does not substitute host-widget results for Android runtime acceptance: no build, emulator, physical-device, signer, APK, or distribution gate was run for this source-only card.
