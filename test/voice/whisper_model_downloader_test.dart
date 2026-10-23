import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/whisper_model_downloader.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('whisper-downloader-');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  WhisperModelDownloader downloader(_TrackingClient client) =>
      WhisperModelDownloader(
        clientFactory: () => client,
        maxDownloadBytes: 8,
        connectTimeout: const Duration(milliseconds: 20),
        readTimeout: const Duration(milliseconds: 20),
        totalTimeout: const Duration(milliseconds: 50),
      );

  test('publica solo después de un stream válido y cierra el cliente', () async {
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.fromIterable(const [
          [1, 2],
          [3, 4],
        ]),
        HttpStatus.ok,
        contentLength: 4,
      ),
    );
    final target = File('${temp.path}/tiny.bin');
    final progress = <double>[];

    await downloader(client).download(
      source: Uri.parse('https://models.example/tiny.bin'),
      target: target,
      onProgress: progress.add,
    );

    expect(await target.readAsBytes(), [1, 2, 3, 4]);
    expect(File('${target.path}.part').existsSync(), isFalse);
    expect(progress.last, 1);
    expect(client.closed, isTrue);
    expect(client.requests.single.followRedirects, isFalse);
  });

  test('rechaza tamaño declarado antes de consumir el body y limpia staging',
      () async {
    var streamRead = false;
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.fromFuture(Future<List<int>>(() {
          streamRead = true;
          return <int>[1];
        })),
        HttpStatus.ok,
        contentLength: 9,
      ),
    );
    final target = File('${temp.path}/oversize.bin');

    await expectLater(
      downloader(client).download(
        source: Uri.parse('https://models.example/oversize.bin'),
        target: target,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(streamRead, isFalse);
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
    expect(client.closed, isTrue);
  });

  test('rechaza un stream sin longitud que excede el límite y limpia staging',
      () async {
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.fromIterable(const [
          [1, 2, 3, 4],
          [5, 6, 7, 8, 9],
        ]),
        HttpStatus.ok,
      ),
    );
    final target = File('${temp.path}/overflow.bin');

    await expectLater(
      downloader(client).download(
        source: Uri.parse('https://models.example/overflow.bin'),
        target: target,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('rechaza respuesta vacía y longitud truncada sin publicar un modelo',
      () async {
    for (final response in <http.StreamedResponse>[
      http.StreamedResponse(Stream<List<int>>.empty(), HttpStatus.ok),
      http.StreamedResponse(
        Stream<List<int>>.value(const [1, 2]),
        HttpStatus.ok,
        contentLength: 3,
      ),
    ]) {
      final client = _TrackingClient((_) async => response);
      final target = File('${temp.path}/${response.hashCode}.bin');
      await expectLater(
        downloader(client).download(
          source: Uri.parse('https://models.example/${response.hashCode}.bin'),
          target: target,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    }
  });

  test('limpia staging y cierra el cliente si el stream se estanca', () async {
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.periodic(const Duration(seconds: 1), (_) => [1]),
        HttpStatus.ok,
      ),
    );
    final target = File('${temp.path}/stalled.bin');

    await expectLater(
      downloader(client).download(
        source: Uri.parse('https://models.example/stalled.bin'),
        target: target,
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
    expect(client.closed, isTrue);
  });

  test('sigue redirects HTTPS relativos y rechaza destinos inseguros', () async {
    final redirects = _TrackingClient((request) async {
      if (request.url.path == '/start') {
        return http.StreamedResponse(
          Stream<List<int>>.empty(),
          HttpStatus.found,
          headers: const {'location': '/final'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(const [1]),
        HttpStatus.ok,
        contentLength: 1,
      );
    });
    final target = File('${temp.path}/redirect.bin');
    await downloader(redirects).download(
      source: Uri.parse('https://models.example/start'),
      target: target,
    );
    expect(redirects.requests.map((r) => r.url.path), ['/start', '/final']);

    final insecure = _TrackingClient(
      (_) async => http.StreamedResponse(
        Stream<List<int>>.empty(),
        HttpStatus.found,
        headers: const {'location': 'http://models.example/final'},
      ),
    );
    await expectLater(
      downloader(insecure).download(
        source: Uri.parse('https://models.example/start'),
        target: File('${temp.path}/insecure.bin'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('aplica el límite total también al drenar redirects y errores',
      () async {
    for (final status in [HttpStatus.found, HttpStatus.notFound]) {
      final controller = StreamController<List<int>>();
      final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (!controller.isClosed) controller.add(const [1]);
      });
      final client = _TrackingClient(
        (_) async => http.StreamedResponse(
          controller.stream,
          status,
          headers: status == HttpStatus.found
              ? const {'location': 'https://models.example/final'}
              : const <String, String>{},
        ),
      );
      final pending = downloader(client).download(
        source: Uri.parse('https://models.example/start'),
        target: File('${temp.path}/$status.bin'),
      );

      final stopwatch = Stopwatch()..start();
      await expectLater(
        pending.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      ticker.cancel();
      await controller.close();
      try {
        await pending;
      } catch (_) {
        // The current implementation only settles after the stream closes.
      }
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 150)));
      expect(client.closed, isTrue);
    }
  });

  test('cancela el stream al expirar el límite total aunque close sea no-op',
      () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(controller.stream, HttpStatus.ok),
      closeDelegate: () {},
    );
    final pending = downloader(client).download(
      source: Uri.parse('https://models.example/stalled.bin'),
      target: File('${temp.path}/cancelled.bin'),
    );

    await expectLater(pending, throwsA(isA<TimeoutException>()));
    expect(cancelled, isTrue);
    await controller.close();
  });

  test('preserva un final creado durante la descarga', () async {
    final controller = StreamController<List<int>>();
    final client = _TrackingClient(
      (_) async => http.StreamedResponse(controller.stream, HttpStatus.ok),
    );
    final target = File('${temp.path}/raced.bin');
    final pending = downloader(client).download(
      source: Uri.parse('https://models.example/raced.bin'),
      target: target,
    );
    await Future<void>.delayed(Duration.zero);
    await target.writeAsBytes(const [9]);
    controller
      ..add(const [1, 2])
      ..close();

    await expectLater(pending, throwsA(isA<StateError>()));
    expect(await target.readAsBytes(), [9]);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('un único transfer posee el staging de un destino', () async {
    final firstBody = StreamController<List<int>>();
    final first = _TrackingClient(
      (_) async => http.StreamedResponse(firstBody.stream, HttpStatus.ok),
    );
    final second = _TrackingClient(
      (_) async => throw StateError('a second transfer must not start'),
    );
    final target = File('${temp.path}/owned.bin');
    final firstDownload = downloader(first).download(
      source: Uri.parse('https://models.example/owned.bin'),
      target: target,
    );
    await Future<void>.delayed(Duration.zero);
    final secondDownload = downloader(second).download(
      source: Uri.parse('https://models.example/owned.bin'),
      target: target,
    );
    firstBody
      ..add(const [1])
      ..close();

    await Future.wait([firstDownload, secondDownload]);
    expect(second.requests, isEmpty);
    expect(await target.readAsBytes(), [1]);
  });

  test('un destino ya presente es idempotente y no abre un cliente', () async {
    final target = File('${temp.path}/present.bin')..writeAsBytesSync([9]);
    var factoryCalls = 0;
    final client = _TrackingClient((_) async => throw StateError('unused'));
    final safeDownloader = WhisperModelDownloader(
      clientFactory: () {
        factoryCalls++;
        return client;
      },
    );

    await safeDownloader.download(
      source: Uri.parse('https://models.example/present.bin'),
      target: target,
    );

    expect(factoryCalls, 0);
    expect(await target.readAsBytes(), [9]);
  });
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._handler, {this.closeDelegate});

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;
  final void Function()? closeDelegate;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _handler(request);
  }

  @override
  void close() {
    closed = true;
    closeDelegate?.call();
  }
}
