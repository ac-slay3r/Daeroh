# Daeroh 0.1.16 — private source candidate

Private update source for `cool.n0thing.daeroh` (`0.1.16+4020`). Package,
registered/display/bundle names, signing policy and dependencies are unchanged.

The source build number is 4020, following inspected local source/diagnostic
versions through 4019. Expected split versionCodes are 6020 for arm64-v8a and
8020 for x86_64; these are expectations only and must be measured on the actual
artifacts. They do not establish compatibility with any installed app. An
in-place update separately requires matching package and signer plus a strictly
higher versionCode against the exact target install.

## Included

- A small encrypted, device-only saved Chat preview, bounded to at most the
  newest 100 messages. The preview is explicitly nonauthoritative: it is not
  current server truth and cannot prove delivery, completion or active work.
- Saved user and assistant content is inert display data before canonical
  history arrives: no prompt send/replay, media download, tool activation or
  operational-state restoration from the preview.
- Saved-preview cleanup is local-only and never deletes server history.

## Unchanged and not claimed

- Normal canonical recovery/delivery remains authoritative and may still
  download full history. This is not delta sync or a bandwidth guarantee.
- No battery-policy cure, reconnect/banner change, terminal-authority change,
  server/snapshot change, authentication or pairing change is included.
- Host tests and source review do not prove live Android Keystore/ciphertext,
  emulator or physical-device behavior. No APK build, signing, installation,
  source integration, CI, distribution or publication is established here.

## Source provenance

- Downstream base: `f04b7a1fe3e4f924852cc801aa4ced515bda53dc`.
- Reviewed cache implementation: `b7c4ae3d967cd685b14297c6f7e8b1dd795f13f4`,
  tree `a3efb6affaa596747bc25529f8b63c67bd4b4d74`, approved in `t_3c763509`.
- This preparation changes only version/release metadata and generated source
  SBOMs. The reviewed implementation, tests and seven-group inventory remain
  unchanged. Cumulative independent review is required before integration;
  artifact measurement, signing, runtime acceptance and distribution are
  separate downstream gates.
