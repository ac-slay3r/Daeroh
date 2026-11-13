import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;

class BridgeReleaseTarget {
  final String version;
  final String sha256;
  final int size;
  final int minAppBuild;
  final bool remote;
  const BridgeReleaseTarget({
    required this.version,
    required this.sha256,
    required this.size,
    required this.minAppBuild,
    required this.remote,
  });
}

typedef BridgeReleaseTargetResolver = Future<BridgeReleaseTarget> Function();
typedef BridgeReleaseDownloader = Future<BridgeRelease> Function(
  BridgeReleaseTarget target,
);

class BridgeRelease {
  final String version;
  final String source;
  final String sha256;
  final int size;
  final int minAppBuild;
  final bool remote;
  const BridgeRelease({
    required this.version,
    required this.source,
    required this.sha256,
    this.size = 0,
    this.minAppBuild = 0,
    required this.remote,
  });
  BridgeReleaseTarget get target => BridgeReleaseTarget(
    version: version,
    sha256: sha256,
    size: size,
    minAppBuild: minAppBuild,
    remote: remote,
  );
}

/// Mobile Bridge updates are packaged with the app. Remote manifests are
/// disabled until Daeroh owns and pins a distribution origin.
class BridgeReleaseChannel {
  static const int maxManifestBytes = 16 * 1024;
  static const int maxPayloadBytes = 512 * 1024;
  static const Duration defaultRequestTimeout = Duration(seconds: 8);

  /// No remote payload exists while the update channel is disabled.
  static final Uri payloadUri = Uri();

  BridgeReleaseChannel({
    Object? httpClient,
    Future<String> Function()? loadPackagedSource,
    Future<int> Function()? loadAppBuild,
    Duration requestTimeout = defaultRequestTimeout,
  }) : _loadPackagedSource =
           loadPackagedSource ??
           (() => rootBundle.loadString('assets/bridge/hermes_bridge.py'));

  final Future<String> Function() _loadPackagedSource;

  static Future<BridgeReleaseTarget> resolveLatestTarget() async =>
      (await BridgeReleaseChannel()._packagedRelease()).target;
  static Future<BridgeRelease> downloadLatestTarget(
    BridgeReleaseTarget target,
  ) => BridgeReleaseChannel()._packagedRelease();
  static Future<BridgeRelease> resolveLatest() =>
      BridgeReleaseChannel()._packagedRelease();
  Future<BridgeReleaseTarget> resolveTarget() async =>
      (await _packagedRelease()).target;
  Future<BridgeRelease> downloadVerified(BridgeReleaseTarget target) =>
      _packagedRelease();
  Future<BridgeRelease> resolve() => _packagedRelease();

  Future<BridgeRelease> _packagedRelease() async {
    final source = await _loadPackagedSource();
    final matches = RegExp(
      r'''^VERSION\s*=\s*["']((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))["']\s*(?:#.*)?$''',
      multiLine: true,
    ).allMatches(source).toList();
    if (matches.length != 1) {
      throw const FormatException('VERSION del Bridge ausente o ambigua.');
    }
    final bytes = utf8.encode(source);
    return BridgeRelease(
      version: matches.single.group(1)!,
      source: source,
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      remote: false,
    );
  }

  void close() {}
}
