import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/byte_bounded_lru_cache.dart';

/// Una mascota listada en el manifest remoto de Petdex (feature 006 / Petdex
/// remoto). Solo datos de catálogo; el arte se descarga bajo demanda.
class PetdexRemotePet {
  final String slug;
  final String displayName;
  final String submittedBy;

  /// Categoría del manifest: `character`, `creature` u `object` (u otra futura).
  final String kind;
  final Uri spritesheetUrl;
  final Uri petJsonUrl;
  final Uri zipUrl;

  const PetdexRemotePet({
    required this.slug,
    required this.displayName,
    required this.submittedBy,
    required this.kind,
    required this.spritesheetUrl,
    required this.petJsonUrl,
    required this.zipUrl,
  });

  /// Autor mostrable (cae a "Petdex" si el manifest no lo trae).
  String get author =>
      submittedBy.trim().isEmpty ? 'Petdex' : submittedBy.trim();
}

/// Error de catálogo/descarga remota de Petdex. La UI lo captura y muestra un
/// aviso claro; **nunca** debe propagar un crash.
class PetdexRemoteException implements Exception {
  final String message;
  PetdexRemoteException(this.message);
  @override
  String toString() => 'PetdexRemoteException: $message';
}

/// Acceso **read-only** y seguro al catálogo remoto de Petdex.
///
/// Contrato verificado (2026-06-26): `GET https://petdex.dev/api/manifest`
/// redirige (307) a `https://assets.petdex.dev/manifests/petdex-v1.json`, un
/// manifest **estable y versionado** con `{generatedAt, total, pets:[{slug,
/// displayName, submittedBy, spritesheetUrl, petJsonUrl, zipUrl}]}`. El
/// `zip.zip` de cada mascota contiene `pet.json` + `spritesheet.webp` y se
/// instala con el **mismo pipeline validado** que la importación local
/// (`CompanionImportService.importFromZipBytes`), que infiere la geometría
/// 192×208 y escribe de forma atómica.
///
/// Seguridad: solo HTTPS, solo host [_allowedHost] (allowlist), con límites de
/// tamaño y timeouts; sin ejecutar nada, sin scraping de HTML, sin CLI/npx.
class PetdexRemoteService {
  PetdexRemoteService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Único host permitido para catálogo y assets (Cloudflare R2 de Petdex).
  static const String _allowedHost = 'assets.petdex.dev';

  /// URL canónica del manifest versionado (destino del 307 de /api/manifest).
  static final Uri manifestUrl = Uri.parse(
    'https://$_allowedHost/manifests/petdex-v1.json',
  );

  static const Duration _manifestTimeout = Duration(seconds: 20);
  static const Duration _zipTimeout = Duration(seconds: 45);
  static const int _maxRedirects = 5;

  /// Cap del manifest (es ~1 MB; margen amplio pero acotado).
  static const int _maxManifestBytes = 24 * 1024 * 1024;

  /// Cap de un ZIP de mascota (el import service vuelve a validar el tamaño).
  static const int _maxZipBytes = 32 * 1024 * 1024;

  /// Compressed spritesheets only; decoded pixel memory is bounded by the UI.
  static const int maxImageBytes = 4 * 1024 * 1024;
  static const int maxImageCacheBytes = 8 * 1024 * 1024;
  static const int maxImageCacheEntries = 32;
  static const Duration _imageTimeout = Duration(seconds: 20);

  final ByteBoundedLruCache<Uri, Uint8List> _imageCache =
      ByteBoundedLruCache<Uri, Uint8List>(
        maxEntries: maxImageCacheEntries,
        maxBytes: maxImageCacheBytes,
        sizeOf: (uri, bytes) => uri.toString().length * 2 + bytes.lengthInBytes,
      );

  @visibleForTesting
  int get imageCacheEntriesForTesting => _imageCache.length;

  @visibleForTesting
  int get imageCacheBytesForTesting => _imageCache.bytes;

  bool _isAllowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == _allowedHost &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  /// Descarga y parsea el manifest. Entradas malformadas o con URLs fuera de la
  /// allowlist se **descartan** (no rompen la lista). Lanza
  /// [PetdexRemoteException] si la red/JSON global falla.
  Future<List<PetdexRemotePet>> fetchManifest() async {
    final bytes = await _getCapped(
      manifestUrl,
      _maxManifestBytes,
      _manifestTimeout,
    );
    final Object? root;
    try {
      root = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      debugPrint(
        '[petdex] excepción silenciada (se relanza como error propio): $e',
      );
      throw PetdexRemoteException('el manifest no es JSON válido');
    }
    if (root is! Map || root['pets'] is! List) {
      throw PetdexRemoteException('el manifest no tiene el formato esperado');
    }
    final out = <PetdexRemotePet>[];
    for (final raw in (root['pets'] as List)) {
      final pet = _parsePet(raw);
      if (pet != null) out.add(pet);
    }
    if (out.isEmpty) {
      throw PetdexRemoteException('el manifest no contiene mascotas válidas');
    }
    return out;
  }

  PetdexRemotePet? _parsePet(Object? raw) {
    if (raw is! Map) return null;
    final slug = (raw['slug'] ?? '').toString().trim();
    final displayName = (raw['displayName'] ?? '').toString().trim();
    final spritesheet = Uri.tryParse((raw['spritesheetUrl'] ?? '').toString());
    final petJson = Uri.tryParse((raw['petJsonUrl'] ?? '').toString());
    final zip = Uri.tryParse((raw['zipUrl'] ?? '').toString());
    if (slug.isEmpty ||
        spritesheet == null ||
        petJson == null ||
        zip == null ||
        !_isAllowed(spritesheet) ||
        !_isAllowed(petJson) ||
        !_isAllowed(zip)) {
      return null;
    }
    return PetdexRemotePet(
      slug: slug,
      displayName: displayName.isEmpty ? slug : displayName,
      submittedBy: (raw['submittedBy'] ?? '').toString(),
      kind: (raw['kind'] ?? '').toString().trim().toLowerCase(),
      spritesheetUrl: spritesheet,
      petJsonUrl: petJson,
      zipUrl: zip,
    );
  }

  /// Descarga el `zip.zip` de [pet] (validado por allowlist). Devuelve los bytes
  /// para entregárselos a `CompanionImportService.importFromZipBytes`.
  Future<Uint8List> downloadPetZip(PetdexRemotePet pet) async {
    if (!_isAllowed(pet.zipUrl)) {
      throw PetdexRemoteException('origen del ZIP no permitido');
    }
    return _getCapped(pet.zipUrl, _maxZipBytes, _zipTimeout);
  }

  /// Fetch a manifest spritesheet only when requested by the caller. No
  /// unverified response (including a redirect target) enters the image cache.
  /// The cache belongs to this service instance and is discarded on dispose.
  Future<Uint8List> loadImage(Uri url) async {
    if (!_isAllowed(url)) {
      throw PetdexRemoteException('origen de la imagen no permitido');
    }
    final cached = _imageCache.lookup(url);
    if (cached != null) return Uint8List.fromList(cached.value);
    final bytes = await _getCapped(url, maxImageBytes, _imageTimeout);
    _imageCache.put(url, bytes);
    return Uint8List.fromList(bytes);
  }

  /// GET con allowlist en cada salto, timeout total y **tope de tamaño durante
  /// la descarga** (lee el stream y aborta si supera [maxBytes]).
  Future<Uint8List> _getCapped(Uri uri, int maxBytes, Duration timeout) async {
    final expired = Completer<Never>();
    StreamSubscription<List<int>>? subscription;
    void cancelBody() {
      final active = subscription;
      subscription = null;
      if (active != null) unawaited(active.cancel().catchError((Object _) {}));
    }

    // One timer for send, every redirect and the entire body. Neither chunks
    // nor redirects reset the deadline. Cancellation must not delay timeout.
    final deadline = Timer(timeout, () {
      expired.completeError(TimeoutException('Petdex GET timeout'));
      cancelBody();
    });
    Future<T> withinDeadline<T>(Future<T> work) =>
        Future.any([work, expired.future]);

    try {
      for (var redirects = 0; ; redirects++) {
        if (!_isAllowed(uri)) {
          throw PetdexRemoteException('URL no permitida: $uri');
        }
        final req = http.Request('GET', uri)
          ..followRedirects = false
          ..maxRedirects = 0;
        final response = _client.send(req).then((res) {
          if (expired.isCompleted) {
            // Some Clients cannot cancel send. Release any late response body.
            unawaited(
              res.stream.listen(null).cancel().catchError((Object _) {}),
            );
            throw TimeoutException('Petdex GET timeout');
          }
          return res;
        });
        final res = await withinDeadline(response);
        if (res.statusCode == 301 ||
            res.statusCode == 302 ||
            res.statusCode == 303 ||
            res.statusCode == 307 ||
            res.statusCode == 308) {
          // Do not consume a redirect body; cancel it before sending another GET.
          await withinDeadline(res.stream.listen(null).cancel());
          if (redirects >= _maxRedirects) {
            throw PetdexRemoteException('demasiadas redirecciones');
          }
          final location = res.headers['location']?.trim();
          if (location == null || location.isEmpty) {
            throw PetdexRemoteException('redirección sin Location válido');
          }
          final target = Uri.tryParse(location);
          if (target == null) {
            throw PetdexRemoteException('redirección sin Location válido');
          }
          uri = uri.resolveUri(target);
          continue;
        }
        if (res.statusCode != 200) {
          await withinDeadline(res.stream.listen(null).cancel());
          throw PetdexRemoteException('respuesta HTTP ${res.statusCode}');
        }
        final declared = res.contentLength;
        if (declared != null && declared > maxBytes) {
          await withinDeadline(res.stream.listen(null).cancel());
          throw PetdexRemoteException('el recurso supera el tamaño máximo');
        }
        final builder = BytesBuilder(copy: false);
        final body = Completer<void>();
        subscription = res.stream.listen(
          (chunk) {
            if (body.isCompleted || expired.isCompleted) return;
            if (chunk.length > maxBytes - builder.length) {
              body.completeError(
                PetdexRemoteException('el recurso supera el tamaño máximo'),
              );
              cancelBody();
              return;
            }
            builder.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (!body.isCompleted) body.completeError(error, stack);
          },
          onDone: () {
            if (!body.isCompleted) body.complete();
          },
          cancelOnError: true,
        );
        await withinDeadline(body.future);
        return builder.takeBytes();
      }
    } on PetdexRemoteException {
      rethrow;
    } on TimeoutException {
      throw PetdexRemoteException('tiempo de espera agotado');
    } catch (e) {
      throw PetdexRemoteException('fallo de red: $e');
    } finally {
      deadline.cancel();
      cancelBody();
    }
  }

  void dispose() {
    _imageCache.clear();
    _client.close();
  }
}
