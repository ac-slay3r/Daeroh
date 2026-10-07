import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/private_http_client.dart';
import 'package:hermes_android/core/utils/private_websocket_client.dart';

IOClient directClient() => IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

void main() {
  test('WebSocket handshake does not follow cross-host redirect', () async {
    var targetRequests = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests++;
      await request.response.close();
    });
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        'http://localhost:${target.port}/stolen',
      );
      await request.response.close();
    });
    addTearDown(() async {
      await source.close(force: true);
      await target.close(force: true);
    });
    try {
      await WebSocket.connect(
        'ws://127.0.0.1:${source.port}/socket',
        customClient: privateWebSocketHttpClient,
      );
    } catch (_) {}
    expect(targetRequests, 0);
  });

  test('same-origin redirect works and retains auth', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/end');
      } else {
        request.response.write(request.headers.value('authorization'));
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final client = PrivateHttpClient(directClient());
    addTearDown(client.close);
    final res = await client.get(
      Uri.parse('http://127.0.0.1:${server.port}/start'),
      headers: {'Authorization': 'Bearer private'},
    );
    expect(res.body, 'Bearer private');
    expect(requests, 2);
  });

  test('cross-scheme redirect is blocked before destination request', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      request.response.statusCode = 307;
      request.response.headers.set(
        'location',
        'https://127.0.0.1:${source.port}/tls',
      );
      await request.response.close();
    });
    addTearDown(() => source.close(force: true));
    final client = PrivateHttpClient(directClient());
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('http://127.0.0.1:${source.port}/start')),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('caller-disabled redirects remain disabled', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('location', '/next');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final client = PrivateHttpClient(directClient());
    addTearDown(client.close);
    final request = http.Request(
      'GET',
      Uri.parse('http://127.0.0.1:${server.port}/start'),
    )..followRedirects = false;
    final response = await client.send(request);
    await response.stream.drain<void>();
    expect(response.statusCode, 302);
    expect(requests, 1);
  });

  test('credential-bearing POST is not replayed through a redirect', () async {
    var targetRequests = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests++;
      await request.response.close();
    });
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      request.response.statusCode = 307;
      request.response.headers.set(
        'location',
        'http://localhost:${target.port}/stolen',
      );
      await request.response.close();
    });
    addTearDown(() async {
      await source.close(force: true);
      await target.close(force: true);
    });
    final client = PrivateHttpClient(directClient());
    addTearDown(client.close);
    final response = await client.post(
      Uri.parse('http://127.0.0.1:${source.port}/send'),
      headers: {'Authorization': 'Bearer private'},
      body: 'private payload',
    );
    expect(response.statusCode, 307);
    expect(targetRequests, 0);
  });

  test(
    'BridgeClient refuses redirect to DNS cleartext before target request',
    () async {
      var targetRequests = 0;
      var sourceRequests = 0;
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) {
        targetRequests++;
        request.response.statusCode = 200;
        request.response.write('{"ok":true}');
        request.response.close();
      });
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      source.listen((request) {
        sourceRequests++;
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://localhost:${target.port}/stolen',
        );
        request.response.close();
      });
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      final client = BridgeClient(
        baseUrl: 'http://127.0.0.1:${source.port}',
        token: 'private',
        httpClient: directClient(),
      );
      addTearDown(client.close);
      await expectLater(
        client.read('soul'),
        throwsA(isA<http.ClientException>()),
      );
      expect(sourceRequests, 1);
      expect(targetRequests, 0);
    },
  );

  test(
    'DashboardClient refuses redirect to DNS cleartext before target request',
    () async {
      var targetRequests = 0;
      var sourceRequests = 0;
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) {
        targetRequests++;
        request.response.statusCode = 200;
        request.response.write('{"ok":true}');
        request.response.close();
      });
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      source.listen((request) {
        sourceRequests++;
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://localhost:${target.port}/stolen',
        );
        request.response.close();
      });
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      final client = DashboardClient(
        host: '127.0.0.1',
        port: source.port,
        manualToken: 'private',
        httpClientOverride: directClient(),
      );
      addTearDown(client.close);
      await expectLater(
        client.apiGet('status'),
        throwsA(isA<http.ClientException>()),
      );
      expect(sourceRequests, 1);
      expect(targetRequests, 0);
    },
  );
}
