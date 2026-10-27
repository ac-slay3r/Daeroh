# Daeroh 0.1.14

Private in-place update source for `cool.n0thing.daeroh` (`0.1.14+4016`).

Build-code lineage: Flutter split codes derived from build 4016 are expected to
be 6016 for arm64-v8a and 8016 for x86_64, strictly above the known 6015 and
8015 internal candidates; built APK metadata remains a downstream measurement.

- Provider OAuth polling is bounded and single-flight, pauses when its surface
  is no longer foreground/current, and uses elapsed expiry. Expiry stops polling
  and displays the expired UI; safe route closure/navigation applies on user exit
  or successful flow completion.
- No server or credential change is included.
- No live third-party provider login, device, or phone proof is included yet.

Host validation is recorded with the source-preparation task; this note is not
build, signing, installation, or distribution evidence.
