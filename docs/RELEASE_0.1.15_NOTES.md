# Daeroh 0.1.15

Private update source for `cool.n0thing.daeroh` (`0.1.15+4017`).

Build-code lineage: Flutter split codes derived from build 4017 are expected to
be 6017 for arm64-v8a and 8017 for x86_64. They are strictly above the
published `0.1.14` arm64-v8a code 6016 and the installed emulator x86_64 code
8016. APK metadata remains a downstream measurement; these expectations are
not measured artifact metadata.

- Home typed text is carried into Chat as an **unsent** draft scoped to the
  same connection and profile when an attachment is handed off.
- Cancelling the picker or returning/back retains the typed Home text.
- The attachment and draft are sent only after the user explicitly sends from
  Chat.
- Host/widget regressions and the PR #18 source review cover this source
  behavior.
- Native picker, emulator, and physical-phone acceptance are not proved by
  this source note. No signing, installation, or publication is proved here.