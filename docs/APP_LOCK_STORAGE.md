# App-lock attempt persistence (Android)

## Contract

The app creates one `AppLockService` in `lib/main.dart`. It serializes PIN and
biometric verification. Before comparing a PIN, it reserves a guess and awaits
an acknowledged disk commit. The fifth reservation starts the cooldown; a
correct fifth PIN may still clear that reservation. Storage errors refuse the
verification; they do not mean a missing/fresh attempt window.

`appLockSecureStorage` aliases `sharedSecureStorage`, which explicitly sets
`AndroidOptions(resetOnError: false)` for **every app-owned consumer** of the
shared encrypted preferences. In pinned flutter_secure_storage 10.3.1, native
instances are cached by preferences name and `initialize` retains the first
configuration. App-lock-only options are therefore insufficient: the default
`CancelledTurnTombstoneStore.secure().initialize()` read happens earlier in
`main`. Startup, credentials, transcripts, outbox, drafts, share inbox, journals,
compression state, mission chat and agent-runtime cleanup now use one policy,
regardless of which consumer or engine accesses storage first. No warm-up read,
startup reorder, plugin-cache mutation, or namespace migration is needed.

Only destructive recovery changes: unreadable values propagate an error instead
of being silently removed (including other consumers' credentials). Existing
callers retain their error handling; an unreadable startup tombstone can stop
startup rather than erase security state. There is no automatic recovery UX.
The default preferences name, key prefix, ciphers, algorithm migration and
non-Android options are unchanged. Never introduce an unconfigured constructor
or per-call Android option override on this shared store; the source regression
guards the constructor boundary. Injected test adapters remain supported.

PIN salt/hash remain in flutter_secure_storage, including existing SHA-256 to
PBKDF2 migration. Its Android `apply()` writes are **not** used for the attempt
reservation or its resets. Non-Android adapters are unchanged; the injectable
storage constructor parameter is the host-test seam, not the production path.

## Narrow native store

`hermes/app_lock_attempts` is registered in `MainActivity`. `AppLockAttempts`
serializes all channel operations on a process-wide background executor, shared
across Activity recreation. Only the attempt-window and old cooldown keys are
accepted. The store encrypts the whole JSON map using AES-256-GCM, random IVs,
128-bit authentication tags, versioned framing and fixed associated data. The
key is non-exportable AndroidKeyStore material. The app already disables backup;
this change does not change capabilities, permissions or backup policy.

Each mutation writes a new ciphertext to private preferences using
`SharedPreferences.Editor.commit()`. Only a `true` result is acknowledged to
Dart. This includes initialization, reservations, success/expiry resets and
biometric resets. No plaintext PIN or attempt state is persisted. A Dart await
or same-process read-back alone is deliberately not considered durable evidence.

`CommittedAppLockRecord` poisons the process-wide store after a read, crypto or
commit error. This is essential because a failed `commit()` can leave mutated
SharedPreferences memory that was never written to disk. Another Activity or
service instance must not consume that memory as committed state. On process
restart, only the persisted record is loaded. If death occurs after commit but
before acknowledgement, the guess remains consumed without a comparison. If it
occurs before commit, there was no comparison and the previous budget remains.

## Migration and failure policy

On first access, Dart reads both existing encrypted limit keys using the
fail-closed secure-storage configuration. Native initialization commits them
as one encrypted map. It is idempotent and cannot overwrite an existing map.
The old encrypted keys are retained so pre-initialization interruption cannot
lose them. Once initialized, the native map is authoritative; an encrypted
empty map remains after reset, and old keys are never reimported. This preserves
partial budgets and the longest legacy cooldown without resurrecting old state.
Downgrading to an older app that ignores this store is not a supported security
transition; no claim of rollback resistance against privileged data replacement
is made.

A missing preferences record while its Keystore alias exists fails closed,
including a process death between initial key creation and the first commit.
This conservatively refuses verification rather than granting a fresh budget.
Persistent ciphertext/key loss is not automatically repaired or deleted; even
successful biometric authentication does not bypass a failing persistence
operation. Transient failed writes to an existing valid record may recover after
process restart. Recovery UX for irrecoverable state is not added by this change.

## Repeatable verification

Run from the repository root using the existing Flutter/JDK toolchains:

```
flutter test --no-pub test/app_lock_attempt_window_test.dart test/app_lock_android_storage_test.dart test/app_lock_gate_test.dart test/app_lock_cancel_test.dart
flutter analyze --no-pub
python3 tool/qa/test_app_lock_commit.py
(cd android && ./gradlew :app:compileQaDebugKotlin --offline -Pandroid.builder.sdkDownload=false)
python3 tool/qa/test_secure_storage_config.py
flutter test --no-pub
```

The Python runner uses the Kotlin compiler version pinned in Android settings,
already cached Gradle dependencies and `JAVA_HOME`/`java`; it installs nothing.
Its JVM tests execute the production commit-boundary class with injected
cache/disk failures and host JCE encryption. Flutter channel tests execute the
production Dart adapter and actual default startup factory against the pinned
first-config cache contract. Both corrupt legacy keys were reproduced granting
verification before this policy correction, then fail closed with it. A source
guard restricts app-owned constructors to the shared policy; an options-map
comparison checks that only `resetOnError` differs from plugin defaults.

`test_secure_storage_config.py` executes the compiled 10.3.1 Java plugin's real
`initialize`, `read`, `readAll` and error-recovery bytecode. It seeds post-first-
initialization config/preferences state using reflection (no Android Context on
the host), uses host preferences/logging/Base64 substitutes, and reproduces the
unsafe true-first control alongside false-first retention/error propagation for
both legacy keys and unrelated credentials. It is not an end-to-end Android
plugin/MethodChannel startup test; the Flutter factory regression and source
inspection connect that bytecode contract to the actual app's first options.
Source contract assertions and Kotlin compilation cover native wiring and API
shape. These are **host/model/compile gates**, not an Android runtime proof of
Keystore, filesystem failure, process death or biometric hardware behavior.
Emulator/physical-device fault tests and acceptance remain separately owner-gated.
