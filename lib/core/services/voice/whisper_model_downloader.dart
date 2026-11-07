import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Descarga un modelo Whisper a almacenamiento privado sin confiar en la
/// longitud o redirecciones del host de distribución. Los límites son defensas
/// de disponibilidad; no afirman autenticidad criptográfica del modelo.
class WhisperModelDownloader {
  static const int defaultMaxDownloadBytes = 512 * 1024 * 1024;
  static const Duration defaultConnectTimeout = Duration(seconds: 30);
  static const Duration defaultReadTimeout = Duration(seconds: 30);
  static const Duration defaultTotalTimeout = Duration(minutes: 10);
  static const int defaultMaxRedirects = 5;

  static final Map<String, Future<void>> _activeDownloads = {};

  WhisperModelDownloader({
    http.Client Function()? clientFactory,
    this.maxDownloadBytes = defaultMaxDownloadBytes,
    this.connectTimeout = defaultConnectTimeout,
    this.readTimeout = defaultReadTimeout,
    this.totalTimeout = defaultTotalTimeout,
    this.maxRedirects = defaultMaxRedirects,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    if (maxDownloadBytes <= 0) {
      throw ArgumentError.value(maxDownloadBytes, 'maxDownloadBytes');
    }
    if (connectTimeout <= Duration.zero ||
        readTimeout <= Duration.zero ||
        totalTimeout <= Duration.zero) {
      throw ArgumentError('Download timeouts must be positive.');
    }
    if (maxRedirects < 0) throw ArgumentError.value(maxRedirects, 'maxRedirects');
  }

  final http.Client Function() _clientFactory;
  final int maxDownloadBytes;
  final Duration connectTimeout;
  final Duration readTimeout;
  final Duration totalTimeout;
  final int maxRedirects;

  Future<void> download({
    required Uri source,
    required File target,
    void Function(double progress)? onProgress,
  }) {
    final key = target.absolute.path;
    final active = _activeDownloads[key];
    if (active != null) return active;

    final started = _download(
      source: source,
      target: target,
      onProgress: onProgress,
    );
    _activeDownloads[key] = started;
    return started.whenComplete(() {
      if (identical(_activeDownloads[key], started)) {
        _activeDownloads.remove(key);
      }
    });
  }

  Future<void> _download({
    required Uri source,
    required File target,
    void Function(double progress)? onProgress,
  }) async {
    if (target.existsSync()) {
      onProgress?.call(1);
      return;
    }
    _requireSafeSource(source);
    final deadline = DateTime.now().add(totalTimeout);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.part');
    if (temporary.existsSync()) await temporary.delete();

    final client = _clientFactory();
    try {
      final response = await _requestFollowingRedirects(
        client,
        source,
        deadline: deadline,
      );
      if (response.statusCode != HttpStatus.ok) {
        await _drain(response.stream, deadline: deadline);
        throw FormatException('Whisper model download failed (${response.statusCode}).');
      }
      await _writeResponse(
        response,
        temporary: temporary,
        target: target,
        deadline: deadline,
        onProgress: onProgress,
      );
    } finally {
      client.close();
      if (temporary.existsSync()) {
        try {
          await temporary.delete();
        } catch (_) {
          // A failed cleanup must not conceal the download error.
        }
      }
    }
  }

  Future<http.StreamedResponse> _requestFollowingRedirects(
    http.Client client,
    Uri initial, {
    required DateTime deadline,
  }) async {
    var current = initial;
    for (var redirects = 0;; redirects++) {
      _requireSafeSource(current);
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..maxRedirects = 0;
      final response = await client
          .send(request)
          .timeout(_boundedTimeout(connectTimeout, deadline));
      if (!_isRedirect(response.statusCode)) return response;
      try {
        if (redirects >= maxRedirects) {
          throw FormatException('Whisper model redirect limit exceeded.');
        }
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          throw const FormatException('Whisper model redirect is missing Location.');
        }
        current = current.resolve(location.trim());
        _requireSafeSource(current);
      } finally {
        await _drain(response.stream, deadline: deadline);
      }
    }
  }

  Future<void> _writeResponse(
    http.StreamedResponse response, {
    required File temporary,
    required File target,
    required DateTime deadline,
    void Function(double progress)? onProgress,
  }) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxDownloadBytes) {
      throw FormatException('Whisper model exceeds the download limit.');
    }

    var received = 0;
    var sinkClosed = false;
    final sink = temporary.openWrite();
    try {
      await _consume(
        response.stream,
        deadline: deadline,
        onChunk: (chunk) {
          received += chunk.length;
          if (received > maxDownloadBytes) {
            throw FormatException('Whisper model exceeds the download limit.');
          }
          sink.add(chunk);
          if (declared != null && declared > 0) {
            onProgress?.call(received / declared);
          }
        },
      );
      await sink.close();
      sinkClosed = true;
      if (received == 0) {
        throw const FormatException('Whisper model download was empty.');
      }
      if (declared != null && received != declared) {
        throw const FormatException('Whisper model download was truncated.');
      }
      if (target.existsSync()) {
        throw StateError('Whisper model target was created during download.');
      }
      await temporary.rename(target.path);
      onProgress?.call(1);
    } finally {
      if (!sinkClosed) {
        try {
          await sink.close();
        } catch (_) {
          // The transfer error remains the useful error.
        }
      }
    }
  }

  Future<void> _drain(
    Stream<List<int>> stream, {
    required DateTime deadline,
  }) =>
      _consume(stream, deadline: deadline, onChunk: (_) {});

  Future<void> _consume(
    Stream<List<int>> stream, {
    required DateTime deadline,
    required void Function(List<int> chunk) onChunk,
  }) async {
    final completion = Completer<void>();
    Timer? idleTimer;
    Timer? totalTimer;
    late final StreamSubscription<List<int>> subscription;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
    }

    void armIdleTimer() {
      idleTimer?.cancel();
      final timeout = _boundedTimeout(readTimeout, deadline);
      idleTimer = Timer(timeout, () {
        fail(TimeoutException('Whisper model download stalled.', timeout));
      });
    }

    final total = _remaining(deadline);
    totalTimer = Timer(total, () {
      fail(TimeoutException('Whisper model download exceeded its deadline.', total));
    });
    subscription = stream.listen(
      (chunk) {
        if (completion.isCompleted) return;
        try {
          onChunk(chunk);
          armIdleTimer();
        } catch (error, stackTrace) {
          fail(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) => fail(error, stackTrace),
      onDone: () {
        if (!completion.isCompleted) completion.complete();
      },
      cancelOnError: false,
    );
    armIdleTimer();
    try {
      await completion.future;
    } finally {
      idleTimer?.cancel();
      totalTimer.cancel();
      await subscription.cancel();
    }
  }

  Duration _boundedTimeout(Duration requested, DateTime deadline) {
    final remaining = _remaining(deadline);
    return requested < remaining ? requested : remaining;
  }

  Duration _remaining(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Whisper model download exceeded its deadline.');
    }
    return remaining;
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;

  static void _requireSafeSource(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw FormatException('Whisper model URL must be credential-free HTTPS.');
    }
  }
}
