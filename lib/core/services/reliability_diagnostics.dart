import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sentry/sentry.dart';

import '../utils/transport_privacy.dart';

/// Build-time configuration for the self-hosted diagnostics collector.
///
/// The DSN is intentionally supplied as a `--dart-define`; production routing
/// details never live in source control. An empty define means diagnostics are
/// unavailable and no Sentry client is initialized.
@immutable
final class ReliabilityDiagnosticsConfig {
  const ReliabilityDiagnosticsConfig(this.dsn);

  static const fromEnvironment = ReliabilityDiagnosticsConfig(
    String.fromEnvironment('DAEROH_DIAGNOSTICS_DSN'),
  );

  final String dsn;

  bool get isConfigured => _originForDsn(dsn) != null;

  /// Exact ingestion route derived from the validated DSN. Sentry must not be
  /// able to use this client for another otherwise-secure destination.
  Uri? get envelopeUri {
    if (!isConfigured) return null;
    final uri = Uri.parse(dsn);
    final path = uri.pathSegments;
    return uri.replace(
      userInfo: '',
      pathSegments: [
        ...path.sublist(0, path.length - 1),
        'api',
        path.last,
        'envelope',
        '',
      ],
      query: null,
      fragment: null,
    );
  }

  static Uri? _originForDsn(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.isEmpty ||
        uri.host.isEmpty ||
        uri.userInfo.isEmpty ||
        uri.userInfo.contains(':') ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uri.userInfo) ||
        uri.pathSegments.isEmpty ||
        !RegExp(r'^\d+$').hasMatch(uri.pathSegments.last) ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }

    final origin = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
    try {
      TransportPrivacy.requireAllowed(origin);
      return Uri.parse(origin);
    } on ArgumentError {
      return null;
    }
  }
}

/// Sentry's protocol is used only for GlitchTip compatibility. This client is
/// the network boundary: it rejects unapproved hosts, proxies, redirects, and
/// every request after consent is revoked.
@visibleForTesting
final class ReliabilityDiagnosticsHttpClient extends http.BaseClient {
  ReliabilityDiagnosticsHttpClient(this._canSend, {required this.expectedUri})
    : _client = HttpClient() {
    _client.findProxy = (uri) => 'DIRECT';
  }

  final bool Function() _canSend;
  final Uri expectedUri;
  final HttpClient _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_canSend()) throw StateError('Diagnostics transport is disabled.');
    if (request.url != expectedUri) {
      throw StateError('Diagnostics destination is not allowlisted.');
    }
    TransportPrivacy.requireAllowed(request.url.origin);

    final outgoing = await _client.openUrl(request.method, request.url);
    outgoing.followRedirects = false;
    request.headers.forEach((name, value) {
      outgoing.headers.set(name, value);
    });
    await outgoing.addStream(request.finalize());
    if (!_canSend()) {
      _client.close(force: true);
      throw StateError('Diagnostics transport was disabled during send.');
    }

    final incoming = await outgoing.close();
    final headers = <String, String>{};
    incoming.headers.forEach(
      (name, values) => headers[name] = values.join(','),
    );
    if (incoming.isRedirect) {
      await incoming.drain<void>();
      throw StateError('Diagnostics redirects are blocked.');
    }
    return http.StreamedResponse(
      incoming,
      incoming.statusCode,
      contentLength: incoming.contentLength < 0 ? null : incoming.contentLength,
      request: request,
      headers: headers,
      reasonPhrase: incoming.reasonPhrase,
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// Fail-closed, allowlisted reliability reporting for the opt-in collector.
///
/// Events contain only a fixed source label and a one-way hash of the stack
/// shape. No exception text, breadcrumbs, request data, user data, attachments,
/// or message content is ever submitted.
final class ReliabilityDiagnostics {
  ReliabilityDiagnostics({ReliabilityDiagnosticsConfig? config})
    : _config = config ?? ReliabilityDiagnosticsConfig.fromEnvironment;

  static ReliabilityDiagnostics? _instance;

  static bool get isAvailable =>
      (_instance?.configured ??
      ReliabilityDiagnosticsConfig.fromEnvironment.isConfigured);

  static void configure(ReliabilityDiagnostics diagnostics) {
    _instance = diagnostics;
  }

  static Future<void> updateConsent(bool enabled) async {
    await _instance?.setEnabled(enabled);
  }

  final ReliabilityDiagnosticsConfig _config;
  bool _active = false;
  bool _handlersInstalled = false;
  ReliabilityDiagnosticsHttpClient? _httpClient;

  bool get configured => _config.isConfigured;

  Future<void> startIfConsented(bool consented) => setEnabled(consented);

  Future<void> setEnabled(bool enabled) async {
    if (!enabled) {
      _active = false;
      _httpClient?.close();
      _httpClient = null;
      if (Sentry.isEnabled) await Sentry.close();
      return;
    }
    if (!configured) {
      throw StateError('Remote diagnostics are unavailable in this build.');
    }
    if (!Sentry.isEnabled) {
      final httpClient = ReliabilityDiagnosticsHttpClient(
        () => _active,
        expectedUri: _config.envelopeUri!,
      );
      _httpClient = httpClient;
      try {
        await Sentry.init((options) {
          // Remove default integrations before they can observe arbitrary app
          // errors or enrich events with platform/device context.
          for (final integration in options.integrations.toList()) {
            options.removeIntegration(integration);
          }
          options.dsn = _config.dsn;
          options.httpClient = httpClient;
          options.attachStacktrace = false;
          options.maxBreadcrumbs = 0;
          options.sendDefaultPii = false;
          options.sendClientReports = false;
          options.beforeSend = _allowlistedEvent;
        });
      } catch (_) {
        _httpClient = null;
        httpClient.close();
        rethrow;
      }
    }
    _active = true;
    _installErrorHandlers();
  }

  void _installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutterHandler?.call(details);
      unawaited(_record('flutter', details.stack));
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousPlatformHandler = dispatcher.onError;
    dispatcher.onError = (error, stackTrace) {
      unawaited(_record('platform', stackTrace));
      return previousPlatformHandler?.call(error, stackTrace) ?? false;
    };
  }

  Future<void> _record(String source, StackTrace? stackTrace) async {
    if (!_active || !Sentry.isEnabled) return;
    final stackHash = sha256
        .convert(utf8.encode(stackTrace?.toString() ?? 'no-stack'))
        .toString()
        .substring(0, 24);
    await Sentry.captureEvent(
      SentryEvent(
        message: SentryMessage('unhandled_$source'),
        fingerprint: ['reliability-v1', source, stackHash],
        tags: {
          'diagnostics_contract': 'reliability-v1',
          'source': source,
          'stack_hash': stackHash,
        },
        level: SentryLevel.fatal,
      ),
    );
  }

  static SentryEvent? _allowlistedEvent(SentryEvent event, Hint hint) {
    final tags = event.tags;
    final source = tags?['source'];
    final stackHash = tags?['stack_hash'];
    if (tags?['diagnostics_contract'] != 'reliability-v1' ||
        (source != 'flutter' && source != 'platform') ||
        stackHash == null ||
        !RegExp(r'^[a-f0-9]{24}$').hasMatch(stackHash)) {
      return null;
    }
    final safeSource = source!;
    final safeStackHash = stackHash;

    // Rebuild rather than mutate: this is the last boundary before network I/O.
    return SentryEvent(
      message: SentryMessage('unhandled_$safeSource'),
      fingerprint: ['reliability-v1', safeSource, safeStackHash],
      tags: {
        'diagnostics_contract': 'reliability-v1',
        'source': safeSource,
        'stack_hash': safeStackHash,
      },
      level: SentryLevel.fatal,
    );
  }
}
