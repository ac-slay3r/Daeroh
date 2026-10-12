import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// The local companion format accepts single-disk, non-encrypted ZIP32 files
/// using STORE or DEFLATE. ZIP64 and other codecs are deliberately rejected:
/// they are unnecessary for packs capped at 12 MiB and widen the decoder path.
/// No payload is inflated while reading the directory, including symlinks,
/// duplicates, directories, and unused files. Metadata is only a rejection
/// gate; actual output is checked synchronously before each copy.
class BoundedCompanionZip {
  BoundedCompanionZip(
    Uint8List bytes, {
    required int maxEntries,
    required int maxExpandedBytes,
  }) {
    final data = ByteData.sublistView(bytes);
    Never invalid() => throw const FormatException('invalid companion ZIP');
    // Well-formed but outside the supported dialect (encrypted, ZIP64,
    // multi-disk, other codecs). Still a rejection; only the type differs so
    // the UI can explain how to re-create the archive.
    Never unsupported() => throw const UnsupportedCompanionZipException();
    void range(int start, int length, int end) {
      if (start < 0 || length < 0 || start > end || length > end - start) {
        invalid();
      }
    }

    int u16(int p) => data.getUint16(p, Endian.little);
    int u32(int p) => data.getUint32(p, Endian.little);
    void extras(int start, int length) {
      final end = start + length;
      while (start < end) {
        range(start, 4, end);
        // Reject ZIP64 rather than interpreting attacker-controlled uint64s.
        if (u16(start) == 1) unsupported();
        final size = u16(start + 2);
        start += 4;
        range(start, size, end);
        start += size;
      }
    }

    // EOCD must terminate the input, including its bounded optional comment.
    var eocd = -1;
    for (
      var p = bytes.length - 22;
      p >= 0 && p >= bytes.length - 22 - 65535;
      p--
    ) {
      if (u32(p) == 0x06054b50 && u16(p + 20) == bytes.length - p - 22) {
        eocd = p;
        break;
      }
    }
    if (eocd < 0) invalid();
    final count = u16(eocd + 10);
    final directorySize = u32(eocd + 12);
    final directoryStart = u32(eocd + 16);
    if (u16(eocd + 4) != 0 ||
        u16(eocd + 6) != 0 ||
        count == 0xffff ||
        directorySize == 0xffffffff ||
        directoryStart == 0xffffffff) {
      unsupported();
    }
    if (u16(eocd + 8) != count || count > maxEntries) invalid();
    range(directoryStart, directorySize, eocd);
    if (directorySize != eocd - directoryStart) invalid();

    var p = directoryStart;
    var declaredTotal = 0;
    final ranges = <(int, int)>[];
    for (var i = 0; i < count; i++) {
      range(p, 46, eocd);
      if (u32(p) != 0x02014b50) invalid();
      final flags = u16(p + 8);
      final method = u16(p + 10);
      final crc = u32(p + 16);
      final compressed = u32(p + 20);
      final expanded = u32(p + 24);
      final nameLength = u16(p + 28);
      final extraLength = u16(p + 30);
      final commentLength = u16(p + 32);
      final local = u32(p + 42);
      // Encryption (traditional 0x1, strong 0x40, header-masked 0x2000),
      // other codecs, ZIP64 sentinels and multi-disk entries are unsupported.
      if ((flags & 0x2041) != 0 ||
          (method != 0 && method != 8) ||
          u16(p + 34) != 0 ||
          compressed == 0xffffffff ||
          expanded == 0xffffffff ||
          local == 0xffffffff) {
        unsupported();
      }
      // Only deflate options, data descriptors, and UTF-8 are supported.
      if ((flags & ~0x080e) != 0 ||
          expanded > maxExpandedBytes - declaredTotal) {
        invalid();
      }
      declaredTotal += expanded;
      range(p + 46, nameLength + extraLength + commentLength, eocd);
      extras(p + 46 + nameLength, extraLength);
      final nameBytes = Uint8List.sublistView(
        bytes,
        p + 46,
        p + 46 + nameLength,
      );
      final name = utf8.decode(nameBytes);
      if (name.isEmpty || name.contains('\u0000')) invalid();

      range(local, 30, directoryStart);
      if (u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method ||
          u16(local + 26) != nameLength) {
        invalid();
      }
      final localExtra = u16(local + 28);
      final payload = local + 30 + nameLength + localExtra;
      range(local + 30, nameLength + localExtra, directoryStart);
      for (var n = 0; n < nameLength; n++) {
        if (bytes[local + 30 + n] != nameBytes[n]) invalid();
      }
      extras(local + 30 + nameLength, localExtra);
      range(payload, compressed, directoryStart);
      var end = payload + compressed;
      if ((flags & 8) == 0) {
        if (u32(local + 14) != crc ||
            u32(local + 18) != compressed ||
            u32(local + 22) != expanded) {
          invalid();
        }
      } else {
        // Streaming ZIP writers may leave zeros in the local header.
        if ((u32(local + 14) != 0 && u32(local + 14) != crc) ||
            (u32(local + 18) != 0 && u32(local + 18) != compressed) ||
            (u32(local + 22) != 0 && u32(local + 22) != expanded)) {
          invalid();
        }
        range(end, 12, directoryStart);
        if (u32(end) == 0x08074b50) {
          end += 4;
          range(end, 12, directoryStart);
        }
        if (u32(end) != crc ||
            u32(end + 4) != compressed ||
            u32(end + 8) != expanded) {
          invalid();
        }
        end += 12;
      }
      if (method == 0 && compressed != expanded) invalid();
      ranges.add((local, end));
      entries.add(
        BoundedCompanionZipEntry._(
          name,
          expanded,
          crc,
          method,
          Uint8List.sublistView(bytes, payload, payload + compressed),
        ),
      );
      p += 46 + nameLength + extraLength + commentLength;
    }
    // Count is checked against actual records, not trusted as an allocation hint.
    if (p != eocd) invalid();
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) invalid();
    }
  }

  final entries = <BoundedCompanionZipEntry>[];
}

class BoundedCompanionZipEntry {
  BoundedCompanionZipEntry._(
    this.filename,
    this.uncompressedSize,
    this._crc,
    this._method,
    this._compressed,
  );

  final String filename;
  final int uncompressedSize;
  final int _crc;
  final int _method;
  final Uint8List _compressed;

  Uint8List read(int limit) {
    if (uncompressedSize > limit || uncompressedSize < 0) {
      throw const FormatException('ZIP entry exceeds limit');
    }
    // Exact bounded allocation; never allocate from an unchecked ZIP size.
    final output = _BoundedZipSink(uncompressedSize);
    if (_method == 0) {
      output.add(_compressed);
    } else {
      // Do NOT use archive's ZipFile.decompress / ZLibDecoder.decodeStream:
      // archive 4.0.9's IO adapter collects every output chunk until close.
      // The native Dart converter calls this sink synchronously per chunk,
      // and stops immediately if the sink throws. Input slices are bounded too.
      final input = ZLibDecoder(raw: true).startChunkedConversion(output);
      for (var p = 0; p < _compressed.length; p += 1024) {
        final end = p + 1024 < _compressed.length
            ? p + 1024
            : _compressed.length;
        input.addSlice(_compressed, p, end, false);
      }
      input.close();
    }
    // dart:io tolerates some missing terminal DEFLATE bits after complete
    // output. We require exact bounded content and CRC, not canonical encoding.
    if (output.length != uncompressedSize || getCrc32(output.bytes) != _crc) {
      throw const FormatException('ZIP size or checksum mismatch');
    }
    return output.bytes;
  }
}

class _BoundedZipSink extends ByteConversionSink {
  _BoundedZipSink(int limit) : bytes = Uint8List(limit);

  final Uint8List bytes;
  int length = 0;

  @override
  void add(List<int> chunk) {
    if (chunk.length > bytes.length - length) {
      throw const FormatException('ZIP output exceeds limit');
    }
    bytes.setRange(length, length + chunk.length, chunk);
    length += chunk.length;
  }

  @override
  void close() {}
}

/// The archive is structurally readable but uses a ZIP feature the bounded
/// importer deliberately does not support (encryption, ZIP64, multi-disk,
/// or a codec other than STORE/DEFLATE).
class UnsupportedCompanionZipException extends FormatException {
  const UnsupportedCompanionZipException()
    : super('unsupported companion ZIP dialect');
}
