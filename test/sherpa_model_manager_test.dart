import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/services/voice/model_download.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';

final class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);

  @override
  void close() => closed = true;
}

void _seedModel(Directory support, SherpaSttModel model) {
  final dir = Directory('${support.path}/stt_sherpa_models/${model.dirName}')
    ..createSync(recursive: true);
  File('${dir.path}/${model.tokens}').writeAsStringSync('tokens');
  File('${dir.path}/${model.encoder}').writeAsStringSync('encoder');
  File('${dir.path}/${model.decoder}').writeAsStringSync('decoder');
  if (model.isTransducer) {
    File('${dir.path}/${model.joiner}').writeAsStringSync('joiner');
  }
}

List<int> _validArchive(SherpaSttModel model) {
  final archive = Archive()
    ..add(ArchiveFile.string('${model.dirName}/${model.tokens}', 'tokens'))
    ..add(
      ArchiveFile.bytes(
        '${model.dirName}/${model.encoder}',
        List.filled(32, 1),
      ),
    )
    ..add(
      ArchiveFile.bytes(
        '${model.dirName}/${model.decoder}',
        List.filled(32, 2),
      ),
    );
  if (model.isTransducer) {
    archive.add(
      ArchiveFile.bytes('${model.dirName}/${model.joiner}', List.filled(32, 3)),
    );
  }
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rechaza un archivo STT declarado por encima del límite antes de leerlo',
    () async {
      final support = Directory.systemTemp.createTempSync('sherpa-download-');
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return support.path;
        }
        return null;
      });

      var archiveSubscribed = false;
      final archive = StreamController<List<int>>(
        onListen: () => archiveSubscribed = true,
      )..close();
      final client = _ScriptedClient((request) async {
        if (request.url.path.endsWith('silero_vad.onnx')) {
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            200,
            contentLength: 3,
          );
        }
        return http.StreamedResponse(archive.stream, 200, contentLength: 1025);
      });

      try {
        final manager = SherpaSttModelManager(
          clientFactory: () => client,
          maxArchiveBytes: 1024,
        );

        await expectLater(
          manager.download(kSherpaSttModels.first),
          throwsA(isA<FormatException>()),
        );

        expect(archiveSubscribed, isFalse);
        expect(client.closed, isTrue);
        expect(
          File(
            '${support.path}/stt_sherpa_models/'
            '${kSherpaSttModels.first.dirName}.tar.bz2.part',
          ).existsSync(),
          isFalse,
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        archive.close();
        support.deleteSync(recursive: true);
      }
    },
  );

  test('cancela un stream STT detenido y limpia su descarga parcial', () async {
    final support = Directory.systemTemp.createTempSync('sherpa-timeout-');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      return null;
    });

    var archiveCancelled = false;
    final archive = StreamController<List<int>>(
      onCancel: () => archiveCancelled = true,
    );
    final client = _ScriptedClient((request) async {
      if (request.url.path.endsWith('silero_vad.onnx')) {
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          200,
          contentLength: 3,
        );
      }
      return http.StreamedResponse(archive.stream, 200);
    });

    try {
      final manager = SherpaSttModelManager(
        clientFactory: () => client,
        readTimeout: const Duration(milliseconds: 10),
        totalTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        manager.download(kSherpaSttModels.first),
        throwsA(isA<TimeoutException>()),
      );

      expect(archiveCancelled, isTrue);
      expect(client.closed, isTrue);
      expect(
        File(
          '${support.path}/stt_sherpa_models/'
          '${kSherpaSttModels.first.dirName}.tar.bz2.part',
        ).existsSync(),
        isFalse,
      );
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      archive.close();
      support.deleteSync(recursive: true);
    }
  });

  test(
    'cancelar Silero detenido cancela el último stream compartido',
    () async {
      final support = Directory.systemTemp.createTempSync('sherpa-vad-cancel-');
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return support.path;
        }
        return null;
      });
      final model = kSherpaSttModels.first;
      _seedModel(support, model);
      var sileroCancelled = false;
      final silero = StreamController<List<int>>(
        onCancel: () => sileroCancelled = true,
      );
      final client = _ScriptedClient((request) async {
        expect(request.url.path, endsWith('silero_vad.onnx'));
        return http.StreamedResponse(silero.stream, 200, contentLength: 3);
      });

      try {
        final manager = SherpaSttModelManager(clientFactory: () => client);
        final download = manager.download(model);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        manager.cancelDownload(model);
        await expectLater(download, throwsA(isA<ModelDownloadCancelled>()));
        expect(sileroCancelled, isTrue);
        expect(File(await manager.sileroPath()).existsSync(), isFalse);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        await silero.close();
        support.deleteSync(recursive: true);
      }
    },
  );

  test('un nuevo lease no se une al job Silero que ya fue cancelado', () async {
    final support = Directory.systemTemp.createTempSync('sherpa-vad-retry-');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return support.path;
      }
      return null;
    });
    final first = kSherpaSttModels[0];
    final second = kSherpaSttModels[1];
    _seedModel(support, first);
    _seedModel(support, second);
    final cancelStarted = Completer<void>();
    final releaseCancel = Completer<void>();
    final firstSilero = StreamController<List<int>>(
      onCancel: () {
        if (!cancelStarted.isCompleted) cancelStarted.complete();
        return releaseCancel.future;
      },
    );
    var requests = 0;
    final manager = SherpaSttModelManager(
      clientFactory: () {
        final client = _ScriptedClient((request) async {
          requests++;
          if (requests == 1) {
            return http.StreamedResponse(
              firstSilero.stream,
              200,
              contentLength: 3,
            );
          }
          return http.StreamedResponse(
            Stream.value(const [1, 2, 3]),
            200,
            contentLength: 3,
          );
        });
        return client;
      },
    );

    try {
      final canceled = manager.download(first);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      manager.cancelDownload(first);
      await cancelStarted.future;

      final replacement = manager.download(second);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, 2);

      releaseCancel.complete();
      await expectLater(canceled, throwsA(isA<ModelDownloadCancelled>()));
      await expectLater(replacement, completes);
      expect(await manager.sileroReady(), isTrue);
    } finally {
      if (!releaseCancel.isCompleted) releaseCancel.complete();
      await firstSilero.close();
      messenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    }
  });

  test('comparte una sola descarga Silero entre modelos simultáneos', () async {
    final support = Directory.systemTemp.createTempSync('sherpa-shared-vad-');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      return null;
    });
    final first = kSherpaSttModels[0];
    final second = kSherpaSttModels[1];
    _seedModel(support, first);
    _seedModel(support, second);
    final streams = <StreamController<List<int>>>[];
    var sileroRequests = 0;
    final client = _ScriptedClient((request) async {
      if (!request.url.path.endsWith('silero_vad.onnx')) {
        throw StateError('No archive request was expected.');
      }
      sileroRequests += 1;
      final stream = StreamController<List<int>>();
      streams.add(stream);
      return http.StreamedResponse(stream.stream, 200, contentLength: 3);
    });

    try {
      final manager = SherpaSttModelManager(clientFactory: () => client);
      final downloads = [manager.download(first), manager.download(second)];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final stream in streams) {
        stream.add(const [1, 2, 3]);
        await stream.close();
      }

      await expectLater(Future.wait(downloads), completes);
      expect(sileroRequests, 1);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      for (final stream in streams) {
        await stream.close();
      }
      support.deleteSync(recursive: true);
    }
  });

  test('cancelar al iniciar extracción no publica un modelo nuevo', () async {
    final support = Directory.systemTemp.createTempSync(
      'sherpa-extract-cancel-',
    );
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      return null;
    });
    final model = kSherpaSttModels.first;
    final archive = _validArchive(model);
    final client = _ScriptedClient((request) async {
      if (request.url.path.endsWith('silero_vad.onnx')) {
        return http.StreamedResponse(
          Stream.value(const [1, 2, 3]),
          200,
          contentLength: 3,
        );
      }
      return http.StreamedResponse(
        Stream.value(archive),
        200,
        contentLength: archive.length,
      );
    });

    try {
      final manager = SherpaSttModelManager(clientFactory: () => client);
      await expectLater(
        manager.download(
          model,
          onProgress: (progress) {
            if (progress.phase == SherpaPrepPhase.extracting) {
              manager.cancelDownload(model);
            }
          },
        ),
        throwsA(isA<ModelDownloadCancelled>()),
      );
      expect(
        Directory(
          '${support.path}/stt_sherpa_models/${model.dirName}',
        ).existsSync(),
        isFalse,
      );
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    }
  });
}
