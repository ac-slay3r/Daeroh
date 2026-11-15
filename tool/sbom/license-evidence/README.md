# Pinned packaged-license evidence

These are verbatim evidence copies, not reconstructed license texts. Names
include the resolved version from `pubspec.lock` or the checked-in resolved
Gradle SBOM. `SHA256SUMS` covers these copies. Package-relative paths below are
relative to that exact version in the local pub cache; no owner-local paths
are published.

| Packaged member | Exact input and license evidence | SPDX |
|---|---|---|
| `DebugProbesKt.bin` | `org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2`, exact member bytes matched the cached JAR; [1.10.2/LICENSE.txt](https://github.com/Kotlin/kotlinx.coroutines/blob/1.10.2/LICENSE.txt), copied as `kotlinx-coroutines-1.10.2-LICENSE.txt` | Apache-2.0 |
| `assets/flutter_assets/AssetManifest.bin` | Generated project asset-name/variant index, not a copied Flutter library. App source and asset selection: repository `pubspec.yaml`, `LICENSE`, `REUSE.toml`. Flutter encodes that index but its tool license does not relicense the listed assets. This catalog assigns the project's GPL terms to its generated metadata, not to any indexed third-party asset. | GPL-3.0-only |
| `assets/flutter_assets/packages/whisper_ggml_plus/assets/models/ggml-silero-v6.2.0.bin` | `whisper_ggml_plus` **1.5.2** `assets/models/ggml-silero-v6.2.0.bin`, byte-equal to the packaged model; package `LICENSE` copied as `whisper_ggml_plus-1.5.2-LICENSE`. The package declares this exact bundled asset in `pubspec.yaml`. Corroborating model-family license: [Silero v6.2/LICENSE](https://github.com/snakers4/silero-vad/blob/v6.2/LICENSE), copied as `silero-vad-v6.2-LICENSE`. The corroborating tag is not claimed to pin conversion bytes; the pub archive pins those. | MIT |
| `assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf` | `cupertino_icons` **1.0.9** `LICENSE`, copied as `cupertino_icons-1.0.9-LICENSE`; exact font bytes matched | MIT |
| `lib/<abi>/libdartjni.so` | `jni` **1.0.0** `LICENSE`, copied as `jni-1.0.0-LICENSE`; package builds this JNI runtime | BSD-3-Clause |
| `lib/<abi>/libdatastore_shared_counter.so` | `androidx.datastore:datastore-core-android:1.1.7`, all three member digests matched its cached `datastore-core-release.aar`. Exact published [POM](https://dl.google.com/dl/android/maven2/androidx/datastore/datastore-core-android/1.1.7/datastore-core-android-1.1.7.pom) declares Apache 2.0. Exact published [sources JAR](https://dl.google.com/dl/android/maven2/androidx/datastore/datastore-core-android/1.1.7/datastore-core-android-1.1.7-sources.jar) contains `androidMain/androidx/datastore/core/SharedCounter.android.kt`: its Apache-2.0 license header and `System.loadLibrary("datastore_shared_counter")` identify the native component. Verbatim source and POM retained here. The AAR/JAR do not embed a standalone full LICENSE file; the source header and exact-version license declaration are the evidence, not a current AndroidX branch. | Apache-2.0 |
| `lib/<abi>/libwhisper.so` | `whisper_ggml_plus` **1.5.2** `LICENSE`, copied as `whisper_ggml_plus-1.5.2-LICENSE`; package `android/src/whisper/CMakeLists.txt` builds the bundled whisper.cpp implementation and Dart opens `libwhisper.so` | MIT |

The catalog deliberately enumerates exact paths; it does not license an entire
`packages/` subtree. JS resources are outside the generator's model/native
inventory, unchanged by this fix. No package version, lock or model is changed.

## Widget artwork

`hermes-console-b06240f-REUSE.toml` and `hermes-console-b06240f-LICENSE` were
read directly from upstream commit
`b06240f4a81d5c70164c9de6516e5adca2447cc2` in
https://github.com/xP3ta/hermes-console. The first covers `android/app/**` with
`GPL-3.0-only`, copyright 2026 XPeta Lab. `widget-origin.json` records the
33 files and the SHA-256 verified equal to their introduction bytes. See
`ASSET_PROVENANCE.md` for their explicit source inventory.
