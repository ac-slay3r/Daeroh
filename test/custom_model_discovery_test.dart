import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/custom_model_discovery.dart';

IOClient _directClient() => IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = null;
  });

  test(
    'rejects public cleartext before model discovery sends a request',
    () async {
      var requests = 0;
      final inner = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      addTearDown(inner.close);

      await expectLater(
        discoverCustomProviderModels(
          'http://models.example.test:11434',
          httpClient: inner,
        ),
        throwsArgumentError,
      );
      expect(requests, 0);
    },
  );

  test('discovers OpenAI-compatible models over private transport', () async {
    final inner = MockClient((request) async {
      expect(request.url.toString(), 'http://192.168.1.8:11434/v1/models');
      return http.Response('{"data":[{"id":"alpha"},{"id":"beta"}]}', 200);
    });
    addTearDown(inner.close);

    expect(
      await discoverCustomProviderModels(
        'http://192.168.1.8:11434/',
        httpClient: inner,
      ),
      ['alpha', 'beta'],
    );
  });

  test('falls back to Ollama tags over the same private transport', () async {
    final requestedPaths = <String>[];
    final inner = MockClient((request) async {
      requestedPaths.add(request.url.path);
      if (request.url.path == '/v1/models') {
        return http.Response('{"data":[]}', 200);
      }
      return http.Response('{"models":[{"name":"qwen"}]}', 200);
    });
    addTearDown(inner.close);

    expect(
      await discoverCustomProviderModels(
        'http://100.100.20.30:11434',
        httpClient: inner,
      ),
      ['qwen'],
    );
    expect(requestedPaths, ['/v1/models', '/api/tags']);
  });

  test(
    'blocks a custom-model redirect before it reaches a public destination',
    () async {
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
          'http://localhost:${target.port}/models',
        );
        await request.response.close();
      });
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      final inner = _directClient();
      addTearDown(inner.close);

      await expectLater(
        discoverCustomProviderModels(
          'http://127.0.0.1:${source.port}',
          httpClient: inner,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(targetRequests, 0);
    },
  );
}
