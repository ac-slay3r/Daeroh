import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_sherpa.dart';

const _dirName = 'sherpa-test-model';
const _required = ['tokens.txt', 'encoder.int8.onnx', 'decoder.int8.onnx'];

File _writeArchive(Directory root, Archive archive) {
  final tar = TarEncoder().encodeBytes(archive);
  final compressed = BZip2Encoder().encodeBytes(tar);
  return File('${root.path}/model.tar.bz2')..writeAsBytesSync(compressed);
}

File _writeGnuLongLinkArchive(Directory root, Archive archive) {
  final tar = TarEncoder().encodeBytes(archive);
  final marker = ascii.encode('././@LongLink');
  var longLinkHeader = -1;
  for (var offset = 0; offset + 512 <= tar.length; offset += 512) {
    var matches = true;
    for (var index = 0; index < marker.length; index++) {
      if (tar[offset + index] != marker[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      longLinkHeader = offset;
      break;
    }
  }
  if (longLinkHeader < 0) {
    throw StateError('El fixture no generó un nombre GNU largo.');
  }

  tar[longLinkHeader + 156] = 0x4c;
  tar.fillRange(longLinkHeader + 148, longLinkHeader + 156, 0x20);
  var checksum = 0;
  for (var index = longLinkHeader; index < longLinkHeader + 512; index++) {
    checksum += tar[index];
  }
  final encodedChecksum = ascii.encode(
    checksum.toRadixString(8).padLeft(6, '0'),
  );
  tar.setRange(longLinkHeader + 148, longLinkHeader + 154, encodedChecksum);
  tar[longLinkHeader + 154] = 0;
  tar[longLinkHeader + 155] = 0x20;

  final compressed = BZip2Encoder().encodeBytes(tar);
  return File('${root.path}/model-gnu-longlink.tar.bz2')
    ..writeAsBytesSync(compressed);
}

Archive _completeArchive() {
  final archive = Archive();
  archive.add(ArchiveFile.directory('$_dirName/'));
  archive.add(ArchiveFile.string('$_dirName/tokens.txt', 'tokens'));
  archive.add(
    ArchiveFile.bytes('$_dirName/encoder.int8.onnx', List.filled(70000, 1)),
  );
  archive.add(
    ArchiveFile.bytes('$_dirName/decoder.int8.onnx', List.filled(70000, 2)),
  );
  archive.add(
    ArchiveFile.bytes('$_dirName/encoder.onnx', List.filled(70000, 3)),
  );
  return archive;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extrae en streaming solo los artefactos int8 requeridos', () {
    final root = Directory.systemTemp.createTempSync('stt-model-archive-');
    try {
      final target = Directory('${root.path}/$_dirName')..createSync();
      File('${target.path}/resto-parcial').writeAsStringSync('stale');
      final input = _writeArchive(root, _completeArchive());

      extractSherpaModelArchive(
        input.path,
        root.path,
        dirName: _dirName,
        requiredFiles: _required,
      );

      expect(File('${target.path}/tokens.txt').readAsStringSync(), 'tokens');
      expect(File('${target.path}/encoder.int8.onnx').lengthSync(), 70000);
      expect(File('${target.path}/decoder.int8.onnx').lengthSync(), 70000);
      expect(File('${target.path}/encoder.onnx').existsSync(), isFalse);
      expect(File('${target.path}/resto-parcial').existsSync(), isFalse);
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('resuelve nombres GNU LongLink usados por modelos locales', () {
    final root = Directory.systemTemp.createTempSync('stt-model-longlink-');
    const longFile =
        'encoder-epoch-12-avg-2-chunk-16-left-64-with-a-name-that-forces-'
        'gnu-longlink.int8.onnx';
    try {
      final archive = Archive()
        ..add(ArchiveFile.string('$_dirName/tokens.txt', 'tokens'))
        ..add(
          ArchiveFile.bytes('$_dirName/$longFile', List<int>.filled(2048, 7)),
        );
      final input = _writeGnuLongLinkArchive(root, archive);

      extractSherpaModelArchive(
        input.path,
        root.path,
        dirName: _dirName,
        requiredFiles: const ['tokens.txt', longFile],
      );

      expect(File('${root.path}/$_dirName/$longFile').lengthSync(), 2048);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza traversal transportado mediante GNU LongLink', () {
    final root = Directory.systemTemp.createTempSync(
      'stt-model-longlink-path-',
    );
    final escapeName = '${List.filled(16, 'escape-').join()}outside.txt';
    try {
      final malicious = _completeArchive()
        ..add(ArchiveFile.string('../$escapeName', 'no'));
      final input = _writeGnuLongLinkArchive(root, malicious);

      expect(
        () => extractSherpaModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          requiredFiles: _required,
        ),
        throwsFormatException,
      );

      expect(File('${root.parent.path}/$escapeName').existsSync(), isFalse);
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('un tar incompleto conserva el modelo anterior y limpia el staging', () {
    final root = Directory.systemTemp.createTempSync('stt-model-missing-');
    try {
      final target = Directory('${root.path}/$_dirName')..createSync();
      final sentinel = File('${target.path}/anterior')..writeAsStringSync('ok');
      final incomplete = Archive()
        ..add(ArchiveFile.string('$_dirName/tokens.txt', 'tokens'));
      final input = _writeArchive(root, incomplete);

      expect(
        () => extractSherpaModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          requiredFiles: _required,
        ),
        throwsFormatException,
      );

      expect(sentinel.readAsStringSync(), 'ok');
      expect(
        Directory('${root.path}/$_dirName.extracting').existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rechaza rutas que intentan salir del directorio del modelo', () {
    final root = Directory.systemTemp.createTempSync('stt-model-path-');
    try {
      final malicious = _completeArchive()
        ..add(ArchiveFile.string('../escape.txt', 'no'));
      final input = _writeArchive(root, malicious);

      expect(
        () => extractSherpaModelArchive(
          input.path,
          root.path,
          dirName: _dirName,
          requiredFiles: _required,
        ),
        throwsFormatException,
      );

      expect(File('${root.parent.path}/escape.txt').existsSync(), isFalse);
      expect(Directory('${root.path}/$_dirName').existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('delete limpia modelo, staging, backup y descarga parcial', () async {
    final support = Directory.systemTemp.createTempSync('stt-model-delete-');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      return null;
    });
    try {
      final model = kSherpaSttModels.first;
      final base = Directory('${support.path}/stt_sherpa_models')
        ..createSync(recursive: true);
      final target = Directory('${base.path}/${model.dirName}')..createSync();
      final stage = Directory('${target.path}.extracting')..createSync();
      final previous = Directory('${target.path}.previous')..createSync();
      final partial = File('${base.path}/${model.dirName}.tar.bz2.part')
        ..writeAsStringSync('partial');

      await SherpaSttModelManager().delete(model);

      expect(target.existsSync(), isFalse);
      expect(stage.existsSync(), isFalse);
      expect(previous.existsSync(), isFalse);
      expect(partial.existsSync(), isFalse);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    }
  });
}
