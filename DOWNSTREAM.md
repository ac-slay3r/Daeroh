# Daeroh downstream charter

Daeroh is an opinionated Android downstream of [Hermes Console](https://github.com/xP3ta/hermes-console), not a GitHub-linked fork: the repository is public. Original commit history, eight upstream release tags, licenses, attribution, and upstream documentation remain intact.

## Product direction

Provide a secure, user-controlled mobile cockpit for an existing Hermes Agent and, when explicitly enabled, a local on-phone Hermes runtime. Keep server/admin credentials isolated from local-device capabilities. Prefer small, independently verifiable changes to cosmetic parity work.

## Boundaries

- App-lock gates all entry points, including Android pairing links.
- HTTP/WS to DNS names requires trusted TLS; cleartext is limited to literal private addresses, and redirects cannot evade that policy.
- No automatic upstream merges, app permissions, credential sharing, telemetry, or distribution changes.
- Do not reuse XPeta Lab's Android package identity, release signing certificate, publishing channel, or product branding for Daeroh artifacts.
- Inherited source names and historic documentation remain during bootstrap; do not mass-rename protocols, Kotlin namespaces, or test identifiers just for appearance.

## Repository and releases

- `main` is the stable downstream branch; feature work uses `feat/` or `fix/` branches and review before merging.
- `origin` is the public `ac-slay3r/Daeroh` repository; `upstream` is `xP3ta/hermes-console`, with its push URL disabled.
- Original upstream `v*` tags remain untouched for provenance. Downstream release tags use `daeroh-v*` and must name a verified signed artifact.
- Inherited workflows stay disabled until their secrets, signing, publishing, and authorization assumptions are reviewed. Signed artifacts and keys remain owner-private until explicitly approved for publication.

## Upstream sync

Review upstream changes on a `sync/upstream-*` branch, inspect the imported range, merge with an explicit boundary commit only when appropriate, and rerun affected tests. Cherry-pick isolated fixes if a wholesale merge would import unrelated risk. Never push to upstream.

## Verification

A source-level test pass is not an APK build, device test, or release verification. A distributable APK requires a distinct app ID, Daeroh-controlled signing key, complete artifact inspection, install test, and GPL source availability. Preserve the upstream license and attribution in all forms.
