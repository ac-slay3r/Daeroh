# Daeroh 0.1.17 — private source candidate

Private update source for `cool.n0thing.daeroh` (`0.1.17+4021`). Package,
registered/display/bundle names, signing policy and dependencies are unchanged.

The source build number is 4021. Flutter's split-APK rule assigns arm64-v8a
`2 * 1000 + buildNumber`, so the expected arm64 versionCode is 6021. This is
an expectation only and must be measured on the actual artifact. It does not
establish compatibility with an installed app. An in-place update separately
requires matching package and signer plus a strictly higher versionCode against
the exact target install.

## Included

- A queue-only correction that refuses to settle a queued message from an
  unsent placeholder row; it requires durable evidence of delivery while
  preserving normal composer behavior.
- A Daeroh-owned setup command that downloads commit-pinned repository scripts
  over HTTPS and verifies their SHA-256 before use.

## Unchanged and not claimed

- No server, credential, pairing-protocol, prompt-replay, diagnostic, package,
  signing, or distribution change is included.
- Host tests and source review do not prove emulator or physical-device
  behavior. No APK build, signing, installation, source integration, CI,
  distribution, or publication is established here.

## Source provenance

- Verified merged main base: `a0038a3975d425cc1d473e03b5046b0eaccf93d1`.
- The base merge contains PR #21 reviewed head
  `fc68e9cfe4bfb8b0d75ac037049e5416706e4bfc` and PR #22 final head
  `04de6a27a0337a82b209d36ff71e75f6b3dacec7`.
- This preparation changes only version/release metadata and generated source
  SBOMs. Independent review, artifact measurement, signing, runtime acceptance
  and distribution are separate downstream gates.
