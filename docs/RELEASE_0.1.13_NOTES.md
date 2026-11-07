# Daeroh 0.1.13

Private in-place update source for `cool.n0thing.daeroh` (`0.1.13+4015`).

Build-code lineage: Flutter split codes derived from build 4015 are expected to
be 6015 for arm64-v8a and 8015 for x86_64, strictly above the known 6014 and
8014 internal candidates; built APK metadata remains a downstream measurement.

- Instances status keeps the instance `/health` probe unscoped, then checks
  session access through the selected named profile route.
- No permissions, signer, package identity, distribution channel, or server
  behavior changes are included.

Host validation is recorded with the source-preparation task; this note is not
build, signing, installation, or distribution evidence.
