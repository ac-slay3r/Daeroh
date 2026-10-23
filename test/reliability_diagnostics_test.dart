import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/reliability_diagnostics.dart';

void main() {
  group('ReliabilityDiagnosticsConfig', () {
    test('is disabled without a build-time DSN', () {
      expect(const ReliabilityDiagnosticsConfig('').isConfigured, isFalse);
    });

    test('allows a secure self-hosted DSN', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'https://public-key@errors.example.test/42',
        ).isConfigured,
        isTrue,
      );
    });

    test('allows a Tailnet IP only when it is private cleartext', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'http://public-key@100.64.0.4:8060/42',
        ).isConfigured,
        isTrue,
      );
    });

    test('fails closed for a public cleartext DSN', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'http://public-key@analytics.example.test/42',
        ).isConfigured,
        isFalse,
      );
    });

    test('fails closed for a DSN without a public project key', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'https://errors.example.test/42',
        ).isConfigured,
        isFalse,
      );
    });

    test('fails closed for a DSN containing a secret key', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'https://public-key:secret-key@errors.example.test/42',
        ).isConfigured,
        isFalse,
      );
    });

    test('fails closed for a non-numeric project ID', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'https://public-key@errors.example.test/project',
        ).isConfigured,
        isFalse,
      );
    });

    test('derives the exact GlitchTip envelope route', () {
      expect(
        const ReliabilityDiagnosticsConfig(
          'https://public-key@errors.example.test/base/42',
        ).envelopeUri,
        Uri.parse('https://errors.example.test/base/api/42/envelope/'),
      );
    });
  });

  test('transport rejects redirects instead of following them', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://example.com',
      );
      await request.response.close();
    });
    final endpoint = Uri.parse(
      'http://${server.address.address}:${server.port}/api/42/envelope/',
    );
    final client = ReliabilityDiagnosticsHttpClient(
      () => true,
      expectedUri: endpoint,
    );
    addTearDown(client.close);

    await expectLater(client.get(endpoint), throwsA(isA<StateError>()));
  });

  test('transport rejects a different secure destination', () async {
    final client = ReliabilityDiagnosticsHttpClient(
      () => true,
      expectedUri: Uri.parse('https://collector.example.test/api/42/envelope/'),
    );
    addTearDown(client.close);

    await expectLater(
      client.get(Uri.parse('https://other.example.test/api/42/envelope/')),
      throwsA(isA<StateError>()),
    );
  });
}
