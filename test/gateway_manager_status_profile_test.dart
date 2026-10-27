import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/widgets/status_pill.dart';

SavedConnection _connection(int port, {String apiKey = 'test-key'}) =>
    SavedConnection(
      id: 'android-connection',
      label: 'Android profile',
      host: '127.0.0.1',
      port: port,
      apiKey: apiKey,
      kind: InstanceKind.homelab,
    );

Future<HttpServer> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

Future<void> _respond(HttpRequest request, int statusCode) async {
  request.response.statusCode = statusCode;
  await request.response.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HttpOverrides.global = null);

  test(
    'named profile status authenticates through its scoped session route',
    () async {
      final paths = <String>[];
      final server = await _serve((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/health') {
          await _respond(request, HttpStatus.ok);
        } else if (request.uri.path == '/p/android/api/sessions') {
          expect(request.uri.queryParameters, const {'limit': '0'});
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer test-key',
          );
          await _respond(request, HttpStatus.ok);
        } else {
          await _respond(request, HttpStatus.unauthorized);
        }
      });
      addTearDown(() => server.close(force: true));

      final status = await fetchGatewayInstanceStatus(
        _connection(server.port),
        profile: 'android',
      );

      expect(status, InstanceStatus.online);
      expect(paths, ['/health', '/p/android/api/sessions']);
    },
  );

  test(
    'invalid named-profile key maps session auth rejection to error',
    () async {
      final server = await _serve((request) async {
        if (request.uri.path == '/health') {
          await _respond(request, HttpStatus.ok);
        } else {
          expect(request.uri.path, '/p/android/api/sessions');
          await _respond(request, HttpStatus.unauthorized);
        }
      });
      addTearDown(() => server.close(force: true));

      final status = await fetchGatewayInstanceStatus(
        _connection(server.port, apiKey: 'invalid-key'),
        profile: 'android',
      );

      expect(status, InstanceStatus.error);
    },
  );

  test('default profile preserves the unprefixed session route', () async {
    final paths = <String>[];
    final server = await _serve((request) async {
      paths.add(request.uri.path);
      await _respond(request, HttpStatus.ok);
    });
    addTearDown(() => server.close(force: true));

    final status = await fetchGatewayInstanceStatus(_connection(server.port));

    expect(status, InstanceStatus.online);
    expect(paths, ['/health', '/api/sessions']);
  });

  test('non-200 session response maps to offline', () async {
    final server = await _serve((request) async {
      await _respond(
        request,
        request.uri.path == '/health'
            ? HttpStatus.ok
            : HttpStatus.internalServerError,
      );
    });
    addTearDown(() => server.close(force: true));

    final status = await fetchGatewayInstanceStatus(
      _connection(server.port),
      profile: 'android',
    );

    expect(status, InstanceStatus.offline);
  });
}
