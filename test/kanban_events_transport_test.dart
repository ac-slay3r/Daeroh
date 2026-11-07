import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Kanban event socket rejects cleartext DNS before connecting', () async {
    final conn = SavedConnection(
      id: 'kanban-dns',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: 'http://server.example:9119',
    );
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'session-token',
      httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
    );
    final client = KanbanClient(conn, dashboardClient: dashboard);
    addTearDown(client.close);
    await expectLater(client.events().first, throwsArgumentError);
  });

  test(
    'Kanban event socket never follows a cross-host handshake redirect',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var targetRequests = 0;
      final targetSubscription = target.listen((request) async {
        targetRequests++;
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      });
      final sourceSubscription = source.listen((request) async {
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'ws://localhost:${target.port}/api/plugins/kanban/events?ticket=secret',
        );
        await request.response.close();
      });
      addTearDown(() async {
        await sourceSubscription.cancel();
        await targetSubscription.cancel();
        await source.close(force: true);
        await target.close(force: true);
      });

      final conn = SavedConnection(
        id: 'kanban-redirect',
        label: 'Test',
        host: '127.0.0.1',
        port: source.port,
        apiKey: 'test-key',
        dashboardUrl: 'http://127.0.0.1:${source.port}',
      );
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: source.port,
        manualToken: 'session-token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
      );
      final client = KanbanClient(conn, dashboardClient: dashboard);
      addTearDown(client.close);

      await expectLater(
        client.events().first,
        throwsA(isA<WebSocketException>()),
      );
      expect(targetRequests, 0);
    },
  );
}
