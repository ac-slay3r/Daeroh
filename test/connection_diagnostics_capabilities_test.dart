import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

final _connection = SavedConnection(
  id: 'diagnostics-test',
  label: 'Diagnostics test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  onDeviceLoopback: true,
);

String _caps({bool? toggle, bool? plugins, Object? endpoint}) {
  final features = <String, Object?>{};
  if (toggle != null) features['skills_toggle'] = toggle;
  if (plugins != null) features['plugins_api'] = plugins;
  return jsonEncode({
    'object': 'hermes.api_server.capabilities',
    'features': features,
    'endpoints': {'plugins': ?endpoint},
  });
}

Future<({CapabilityMatrix matrix, List<http.Request> requests})> _run(
  int status,
  String body, {
  List<(int, String)>? responses,
}) async {
  final requests = <http.Request>[];
  final diagnostics = ConnectionDiagnostics(
    httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/health') {
        return http.Response('{"version":"0.20.4"}', 200);
      }
      if (request.url.path == '/v1/capabilities') {
        final response = (responses ?? [(status, body)]).removeAt(0);
        return http.Response(response.$2, response.$1);
      }
      return http.Response('{}', 200);
    }),
  );
  final (gateway, version, serverCaps) = await diagnostics.probeGateway(
    _connection,
  );
  final matrix = diagnostics.buildMatrix(
    gateway,
    const [],
    version,
    serverCaps: serverCaps,
  );
  diagnostics.close();
  return (matrix: matrix, requests: requests);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'profile-scoped gateway diagnostics never probe unscoped routes',
    () async {
      for (final (profile, prefix) in const [
        ('android', '/p/android'),
        ('', ''),
        ('default', ''),
      ]) {
        final requests = <http.Request>[];
        final diagnostics = ConnectionDiagnostics(
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/health') {
              return http.Response('{"version":"0.20.4"}', 200);
            }
            return http.Response('{}', 200);
          }),
        );

        await diagnostics.probeGateway(_connection, profile: profile);
        diagnostics.close();

        final paths = requests.map((request) => request.url.path).toSet();
        expect(paths, contains('/health'), reason: 'health stays public');
        for (final route in const [
          '/api/sessions',
          '/v1/models',
          '/v1/capabilities',
          '/v1/skills',
          '/v1/toolsets',
          '/v1/plugins',
        ]) {
          expect(paths, contains('$prefix$route'), reason: 'profile=$profile');
        }
        if (prefix.isNotEmpty) {
          expect(
            paths.where((p) => p != '/health'),
            everyElement(startsWith(prefix)),
          );
        }
      }
    },
  );

  test('declared capabilities are authoritative', () async {
    for (final declared in [true, false]) {
      final result = await _run(
        200,
        _caps(toggle: declared, plugins: declared),
      );
      final expected = declared ? CapState.yes : CapState.no;
      expect(
        [result.matrix.skillsToggle, result.matrix.pluginsSupported],
        [expected, expected],
      );
      expect(
        [
          result.matrix.isServerSourced('skillsToggle'),
          result.matrix.skillsInstall,
          result.requests.map((r) => r.method).toSet(),
        ],
        [
          true,
          CapState.unknown,
          {'GET'},
        ],
      );
    }
  });

  test('invalid capabilities fall back safely', () async {
    for (final response in [
      (200, _caps()),
      (404, '{}'),
      (200, '{not-json'),
      (200, '{"object":"other","features":{"skills_toggle":true}}'),
    ]) {
      final result = await _run(response.$1, response.$2);
      expect(
        [result.matrix.skillsToggle, result.matrix.pluginsSupported],
        [CapState.unknown, CapState.yes],
      );
      expect(
        result.requests.where((r) => r.url.path == '/v1/plugins'),
        hasLength(1),
      );
    }
  });

  test(
    'malformed capabilities never expose response content in logs',
    () async {
      const marker = 'CAPABILITY_SECRET_MARKER_7f31';
      final output = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) output.add(message);
      };

      try {
        await _run(200, '{"token":"$marker",oops');
      } finally {
        debugPrint = previousDebugPrint;
      }

      expect(output.join('\n'), isNot(contains(marker)));
    },
  );

  test(
    'an endpoint inventory without plugins is authoritative: no probe, no failure',
    () async {
      // Shape of a real hermes-agent 0.22 document: endpoints are enumerated,
      // plugins is absent, and plugins_api is not declared either way.
      final body = jsonEncode({
        'object': 'hermes.api_server.capabilities',
        'features': {'skills_api': true},
        'endpoints': {
          'skills': {'method': 'GET', 'path': '/v1/skills'},
          'toolsets': {'method': 'GET', 'path': '/v1/toolsets'},
        },
      });
      for (final (profile, prefix) in const [
        ('', ''),
        ('android', '/p/android'),
      ]) {
        final requests = <http.Request>[];
        final diagnostics = ConnectionDiagnostics(
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/health') {
              return http.Response('{"version":"0.22.5"}', 200);
            }
            if (request.url.path == '$prefix/v1/capabilities') {
              return http.Response(body, 200);
            }
            if (request.url.path.endsWith('/plugins')) {
              return http.Response('{}', 404);
            }
            return http.Response('{}', 200);
          }),
        );
        final (gateway, version, serverCaps) = await diagnostics.probeGateway(
          _connection,
          profile: profile,
        );
        final matrix = diagnostics.buildMatrix(
          gateway,
          const [],
          version,
          serverCaps: serverCaps,
        );
        diagnostics.close();

        expect(
          requests.map((r) => r.url.path).where((p) => p.contains('plugins')),
          isEmpty,
          reason: 'profile=$profile: undeclared plugins must not be probed',
        );
        expect(gateway.map((r) => r.name), isNot(contains('plugins')));
        expect(
          gateway.where((r) => r.name != 'health').map((r) => r.status),
          everyElement(ProbeStatus.ok),
          reason: 'a healthy server must not show a failing check',
        );
        expect(matrix.pluginsSupported, CapState.no);
        expect(matrix.isServerSourced('pluginsSupported'), isTrue);
      }
    },
  );

  test('plugin metadata is restricted to safe GET', () async {
    const valid = '/v9/server-declared/plugins';
    final accepted = await _run(
      200,
      _caps(plugins: true, endpoint: {'method': 'GET', 'path': valid}),
    );
    final request = accepted.requests.singleWhere((r) => r.url.path == valid);
    expect(request.followRedirects, isFalse);
    expect(
      accepted.requests.map((r) => r.url.path),
      isNot(contains('/v1/plugins')),
    );

    for (final endpoint in [
      {'method': 'PUT', 'path': '/v1/plugins'},
      {'method': 'GET', 'path': 'https://evil.example/v1/plugins'},
      {'method': 'GET', 'path': '/v1/plugins/install'},
    ]) {
      final rejected = await _run(
        200,
        _caps(plugins: true, endpoint: endpoint),
      );
      expect(
        rejected.requests.map((r) => r.url.host),
        everyElement('127.0.0.1'),
      );
      expect(
        rejected.requests.map((r) => r.url.path),
        isNot(contains(endpoint['path'])),
      );
    }
  });

  test('capabilities status and body come from one response', () async {
    for (final laterStatus in [401, 500, 302]) {
      final body = _caps(toggle: false, plugins: false);
      final result = await _run(
        200,
        body,
        responses: [(200, body), (laterStatus, '{not-json')],
      );
      expect(
        [result.matrix.skillsToggle, result.matrix.pluginsSupported],
        [CapState.no, CapState.no],
      );
      expect(
        result.requests.where((r) => r.url.path == '/v1/capabilities'),
        hasLength(1),
      );
    }
    final result = await _run(302, _caps(toggle: true, plugins: true));
    final request = result.requests.singleWhere(
      (r) => r.url.path == '/v1/capabilities',
    );
    expect(request.followRedirects, isFalse);
    expect(result.matrix.skillsToggle, CapState.unknown);
    expect(result.matrix.isServerSourced('skillsToggle'), isFalse);
  });
}
