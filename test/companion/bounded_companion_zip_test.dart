import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/bounded_companion_zip.dart';

// Deliberately independent of archive's ZIP encoder. This permits duplicate
// names and signed/unsigned data descriptors without library normalization.
Uint8List zipFixture(
  List<(String, List<int>)> files, {
  int method = 8,
  bool descriptor = false,
  bool descriptorSignature = true,
}) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  void number(BytesBuilder out, int value, int width) {
    final bytes = ByteData(width);
    if (width == 2) {
      bytes.setUint16(0, value, Endian.little);
    } else {
      bytes.setUint32(0, value, Endian.little);
    }
    out.add(bytes.buffer.asUint8List());
  }

  for (final (filename, content) in files) {
    final name = utf8.encode(filename);
    final compressed = method == 0
        ? content
        : ZLibEncoder(raw: true).convert(content);
    final crc = getCrc32(content);
    final offset = local.length;
    number(local, 0x04034b50, 4);
    for (final v in [20, descriptor ? 8 : 0, method, 0, 0]) {
      number(local, v, 2);
    }
    for (final v in [crc, compressed.length, content.length]) {
      number(local, descriptor ? 0 : v, 4);
    }
    number(local, name.length, 2);
    number(local, 0, 2);
    local.add(name);
    local.add(compressed);
    if (descriptor) {
      if (descriptorSignature) number(local, 0x08074b50, 4);
      for (final v in [crc, compressed.length, content.length]) {
        number(local, v, 4);
      }
    }
    number(central, 0x02014b50, 4);
    for (final v in [20, 20, descriptor ? 8 : 0, method, 0, 0]) {
      number(central, v, 2);
    }
    for (final v in [crc, compressed.length, content.length]) {
      number(central, v, 4);
    }
    for (final v in [name.length, 0, 0, 0, 0]) {
      number(central, v, 2);
    }
    number(central, 0, 4);
    number(central, offset, 4);
    central.add(name);
  }
  final offset = local.length;
  final size = central.length;
  local.add(central.takeBytes());
  number(local, 0x06054b50, 4);
  for (final v in [0, 0, files.length, files.length]) {
    number(local, v, 2);
  }
  number(local, size, 4);
  number(local, offset, 4);
  number(local, 0, 2);
  return local.takeBytes();
}

BoundedCompanionZip parse(
  Uint8List bytes, {
  int limit = 4096,
  int entries = 256,
}) => BoundedCompanionZip(bytes, maxEntries: entries, maxExpandedBytes: limit);

int centralOffset(Uint8List zip) =>
    ByteData.sublistView(zip).getUint32(zip.length - 6, Endian.little);

void main() {
  for (final method in [0, 8]) {
    for (final descriptor in [false, true]) {
      for (final signature in [false, true]) {
        test(
          'round trip method=$method descriptor=$descriptor signature=$signature',
          () {
            final zip = zipFixture(
              [
                ('nested/pet.json', utf8.encode('{"valid":true}')),
                ('empty/', <int>[]),
              ],
              method: method,
              descriptor: descriptor,
              descriptorSignature: signature,
            );
            final archive = parse(zip);
            expect(archive.entries.length, 2);
            expect(archive.entries.first.filename, 'nested/pet.json');
            expect(
              utf8.decode(archive.entries.first.read(14)),
              '{"valid":true}',
            );
            expect(archive.entries.last.read(0), isEmpty);
          },
        );
      }
    }
  }

  test('small bomb fixture rejects declared expansion before decode', () {
    final zip = File(
      'test/companion/fixtures/manifest_bomb.zip',
    ).readAsBytesSync();
    expect(zip.length, 1148);
    expect(() => parse(zip), throwsFormatException);
  });

  test('forged small sizes stop actual output at the sink, not at EOF', () {
    final zip = File(
      'test/companion/fixtures/manifest_bomb.zip',
    ).readAsBytesSync();
    final data = ByteData.sublistView(zip);
    data.setUint32(22, 32, Endian.little);
    data.setUint32(centralOffset(zip) + 24, 32, Endian.little);
    final entry = parse(zip).entries.single;
    expect(
      () => entry.read(64),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'immediate output guard',
          'ZIP output exceeds limit',
        ),
      ),
    );
  });

  test('per-entry cap checked before allocating output', () {
    final entry = parse(
      zipFixture([('pet.json', List.filled(64, 32))]),
    ).entries.single;
    expect(() => entry.read(63), throwsFormatException);
    expect(entry.read(64).length, 64);
  });

  test('aggregate includes directories, unused files and duplicate names', () {
    for (final names in [
      ['pet.json', 'unused.txt'],
      ['pet.json', 'unused/'],
      ['pet.json', 'pet.json'],
    ]) {
      final zip = zipFixture([
        for (final name in names) (name, List.filled(32, 32)),
      ]);
      expect(() => parse(zip, limit: 63), throwsFormatException);
      expect(parse(zip, limit: 64).entries.length, 2);
    }
  });

  test('entry count and actual central-directory records must agree', () {
    final zip = zipFixture([for (var i = 0; i < 257; i++) ('$i/', <int>[])]);
    expect(() => parse(zip), throwsFormatException);
    expect(parse(zip, entries: 257).entries.length, 257);
    final data = ByteData.sublistView(zip);
    data.setUint16(zip.length - 14, 1, Endian.little);
    data.setUint16(zip.length - 12, 1, Endian.little);
    expect(() => parse(zip), throwsFormatException);
  });

  test('reject every truncated prefix of an otherwise valid ZIP', () {
    final zip = zipFixture([('pet.json', utf8.encode('{}'))]);
    for (var length = 0; length < zip.length; length++) {
      expect(
        () => parse(Uint8List.sublistView(zip, 0, length)),
        throwsFormatException,
        reason: 'length=$length',
      );
    }
  });

  test('reject mismatched local metadata, encryption, codecs and ZIP64', () {
    for (final (where, width, value) in <(String, int, int)>[
      ('localMethod', 2, 12),
      ('centralMethod', 2, 12),
      ('localFlags', 2, 1),
      ('centralFlags', 2, 1),
      ('localSize', 4, 1),
      ('centralSize', 4, 0xffffffff),
      ('centralCompressed', 4, 0xffffffff),
      ('localOffset', 4, 0xffffffff),
      ('disk', 2, 1),
      ('nameLength', 2, 65535),
    ]) {
      final zip = zipFixture([('pet.json', utf8.encode('{}'))]);
      final c = centralOffset(zip);
      final offset = <String, int>{
        'localMethod': 8,
        'centralMethod': c + 10,
        'localFlags': 6,
        'centralFlags': c + 8,
        'localSize': 22,
        'centralSize': c + 24,
        'centralCompressed': c + 20,
        'localOffset': c + 42,
        'disk': zip.length - 18,
        'nameLength': c + 28,
      }[where]!;
      final data = ByteData.sublistView(zip);
      if (width == 2) {
        data.setUint16(offset, value, Endian.little);
      } else {
        data.setUint32(offset, value, Endian.little);
      }
      expect(() => parse(zip), throwsFormatException, reason: where);
    }
  });

  test('directory parsing never inflates symlink or unused payloads', () {
    final zip = zipFixture([
      ('unused-link', [1, 2, 3]),
    ]);
    final c = centralOffset(zip);
    final data = ByteData.sublistView(zip);
    data.setUint16(c + 4, 0x0314, Endian.little); // UNIX creator
    data.setUint32(c + 38, 0xa000 << 16, Endian.little); // symlink mode
    zip[30 + 'unused-link'.length] = 7; // invalid DEFLATE block
    final archive = parse(zip);
    expect(archive.entries.single.filename, 'unused-link');
    expect(() => archive.entries.single.read(3), throwsFormatException);
  });

  test('reject aliased/overlapping local records', () {
    final zip = zipFixture([
      ('same', [1]),
      ('same', [1]),
    ]);
    final c = centralOffset(zip);
    ByteData.sublistView(zip).setUint32(c + 46 + 4 + 42, 0, Endian.little);
    expect(() => parse(zip), throwsFormatException);
  });

  test('reject mismatched descriptor and checksums', () {
    final zip = zipFixture([
      ('pet.json', [1, 2, 3]),
    ], descriptor: true);
    zip[centralOffset(zip) - 1] ^= 1;
    expect(() => parse(zip), throwsFormatException);
    final corrupt = zipFixture([
      ('pet.json', [1, 2, 3]),
    ], method: 0);
    corrupt[38] ^= 1;
    expect(() => parse(corrupt).entries.single.read(3), throwsFormatException);
  });

  test('truncated DEFLATE cannot bypass output length and checksum checks', () {
    final zip = zipFixture([('pet.json', List.filled(1024, 32))]);
    final c = centralOffset(zip);
    final compressed = c - 38;
    for (var missing = 1; missing <= compressed; missing++) {
      final out = BytesBuilder()
        ..add(Uint8List.sublistView(zip, 0, c - missing))
        ..add(Uint8List.sublistView(zip, c));
      final truncated = out.takeBytes();
      final data = ByteData.sublistView(truncated);
      data.setUint32(18, compressed - missing, Endian.little);
      data.setUint32(c - missing + 20, compressed - missing, Endian.little);
      data.setUint32(truncated.length - 6, c - missing, Endian.little);
      // dart:io can accept a missing terminal byte if all output was already
      // emitted. This importer guarantees bounded, length/CRC-checked content,
      // not canonical DEFLATE encoding. Every incomplete output must fail.
      try {
        expect(
          parse(truncated).entries.single.read(1024),
          List.filled(1024, 32),
        );
      } on FormatException {
        // Rejection is also acceptable; no partial content reaches the caller.
      }
      data.setUint32(14, 0, Endian.little);
      data.setUint32(c - missing + 16, 0, Endian.little);
      expect(
        () => parse(truncated).entries.single.read(1024),
        throwsFormatException,
        reason: 'missing=$missing with invalid CRC',
      );
    }
  });

  test('unsupported DEFLATE block is rejected', () {
    final zip = zipFixture([
      ('pet.json', [1, 2, 3]),
    ]);
    zip[38] = 7; // BFINAL=1, reserved BTYPE=3.
    expect(() => parse(zip).entries.single.read(3), throwsFormatException);
  });

  group('unsupported dialect is distinguished from malformed', () {
    Uint8List base() => zipFixture([
      ('pet.json', [1, 2, 3]),
    ]);
    void u16(Uint8List z, int p, int v) =>
        ByteData.sublistView(z).setUint16(p, v, Endian.little);
    void expectUnsupported(Uint8List z) => expect(
      () => parse(z),
      throwsA(isA<UnsupportedCompanionZipException>()),
    );

    test('encrypted entry (flag bit 0)', () {
      final z = base();
      u16(z, centralOffset(z) + 8, 1);
      expectUnsupported(z);
    });
    test('strong encryption (flag bit 6)', () {
      final z = base();
      u16(z, centralOffset(z) + 8, 0x40);
      expectUnsupported(z);
    });
    test('unsupported codec (bzip2)', () {
      final z = base();
      u16(z, centralOffset(z) + 10, 12);
      expectUnsupported(z);
    });
    test('multi-disk EOCD', () {
      final z = base();
      u16(z, z.length - 22 + 4, 1);
      expectUnsupported(z);
    });
    test('ZIP64 sentinel in EOCD', () {
      final z = base();
      ByteData.sublistView(z).setUint32(z.length - 6, 0xffffffff, Endian.little);
      expectUnsupported(z);
    });
    test('malformed archives stay generic FormatException', () {
      final z = base();
      z[z.length - 22] = 0; // destroy EOCD signature
      expect(
        () => parse(z),
        throwsA(
          isA<FormatException>().having(
            (e) => e is UnsupportedCompanionZipException,
            'unsupported',
            isFalse,
          ),
        ),
      );
    });
    test('supported STORE/DEFLATE still parse', () {
      for (final m in [0, 8]) {
        expect(parse(zipFixture([('a', [1])], method: m)).entries, hasLength(1));
      }
    });
  });
}
