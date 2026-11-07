import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Client _json(Object body) => MockClient((req) async {
  return http.Response(jsonEncode(body), 200);
});

/// The mock fails closed: even an accidental send to another origin never
/// reaches a socket, and redirect tests can inspect every attempted hop.
MockClient _redirectClient(
  List<Uri> requested,
  Future<http.StreamedResponse> Function(http.BaseRequest) respond,
) => MockClient.streaming((request, _) async {
  requested.add(request.url);
  expect(request.url.scheme, 'https');
  expect(request.url.host, 'assets.petdex.dev');
  expect(request.followRedirects, isFalse);
  expect(request.maxRedirects, 0);
  return respond(request);
});

http.StreamedResponse _redirect(String location) => http.StreamedResponse(
  const Stream<List<int>>.empty(),
  302,
  headers: {'location': location},
);

http.StreamedResponse _zip(List<int> bytes) =>
    http.StreamedResponse(Stream.value(bytes), 200);

void main() {
  group('PetdexRemoteService.fetchManifest', () {
    test(
      'parsea entradas válidas y descarta las de host no permitido',
      () async {
        final client = _json({
          'generatedAt': 'now',
          'total': 2,
          'pets': [
            {
              'slug': 'boba',
              'displayName': 'Boba',
              'submittedBy': 'Ada',
              'spritesheetUrl':
                  'https://assets.petdex.dev/pets/boba/sprite.webp',
              'petJsonUrl': 'https://assets.petdex.dev/pets/boba/petjson.json',
              'zipUrl': 'https://assets.petdex.dev/pets/boba/zip.zip',
            },
            {
              // host no permitido → descartada
              'slug': 'evil',
              'displayName': 'Evil',
              'spritesheetUrl': 'https://evil.example.com/x/sprite.webp',
              'petJsonUrl': 'https://evil.example.com/x/petjson.json',
              'zipUrl': 'https://evil.example.com/x/zip.zip',
            },
          ],
        });
        final svc = PetdexRemoteService(client: client);
        final pets = await svc.fetchManifest();
        expect(pets, hasLength(1));
        expect(pets.first.slug, 'boba');
        expect(pets.first.author, 'Ada');
        expect(pets.first.zipUrl.host, 'assets.petdex.dev');
      },
    );

    test('parsea kind (categoría) en minúsculas', () async {
      final client = _json({
        'pets': [
          {
            'slug': 'c',
            'displayName': 'C',
            'kind': 'Creature',
            'spritesheetUrl': 'https://assets.petdex.dev/pets/c/sprite.webp',
            'petJsonUrl': 'https://assets.petdex.dev/pets/c/petjson.json',
            'zipUrl': 'https://assets.petdex.dev/pets/c/zip.zip',
          },
        ],
      });
      final pets = await PetdexRemoteService(client: client).fetchManifest();
      expect(pets.first.kind, 'creature');
    });

    test('displayName/author caen a defaults', () async {
      final client = _json({
        'pets': [
          {
            'slug': 'nodisplay',
            'spritesheetUrl': 'https://assets.petdex.dev/pets/n/sprite.webp',
            'petJsonUrl': 'https://assets.petdex.dev/pets/n/petjson.json',
            'zipUrl': 'https://assets.petdex.dev/pets/n/zip.zip',
          },
        ],
      });
      final pets = await PetdexRemoteService(client: client).fetchManifest();
      expect(pets.first.displayName, 'nodisplay'); // cae al slug
      expect(pets.first.author, 'Petdex'); // sin submittedBy
    });

    test('JSON inválido → PetdexRemoteException (sin crash)', () async {
      final client = MockClient((req) async => http.Response('no-json{', 200));
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('formato inesperado (sin pets) → excepción', () async {
      final client = _json({'foo': 'bar'});
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('HTTP != 200 → excepción', () async {
      final client = MockClient((req) async => http.Response('nope', 404));
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('todas las entradas inválidas → excepción (lista vacía)', () async {
      final client = _json({
        'pets': [
          {'slug': '', 'zipUrl': 'https://assets.petdex.dev/x/zip.zip'},
        ],
      });
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });
  });

  group('PetdexRemoteService.downloadPetZip', () {
    final pet = PetdexRemotePet(
      slug: 'boba',
      displayName: 'Boba',
      submittedBy: 'Ada',
      kind: 'character',
      spritesheetUrl: Uri.parse(
        'https://assets.petdex.dev/pets/boba/sprite.webp',
      ),
      petJsonUrl: Uri.parse('https://assets.petdex.dev/pets/boba/petjson.json'),
      zipUrl: Uri.parse('https://assets.petdex.dev/pets/boba/zip.zip'),
    );

    test('devuelve los bytes del ZIP', () async {
      final payload = Uint8List.fromList([80, 75, 3, 4, 1, 2, 3]);
      final client = MockClient.streaming((req, body) async {
        return http.StreamedResponse(Stream.value(payload), 200);
      });
      final bytes = await PetdexRemoteService(
        client: client,
      ).downloadPetZip(pet);
      expect(bytes, payload);
    });

    test('rechaza un zipUrl fuera de la allowlist', () async {
      final evil = PetdexRemotePet(
        slug: 'x',
        displayName: 'x',
        submittedBy: '',
        kind: 'object',
        spritesheetUrl: Uri.parse('https://evil.com/s.webp'),
        petJsonUrl: Uri.parse('https://evil.com/p.json'),
        zipUrl: Uri.parse('https://evil.com/z.zip'),
      );
      final client = MockClient((req) async => http.Response('x', 200));
      expect(
        PetdexRemoteService(client: client).downloadPetZip(evil),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('rechaza redirect externo antes de solicitar el destino', () async {
      final requested = <Uri>[];
      final client = _redirectClient(
        requested,
        (_) async => _redirect('https://attacker.example/zip.zip'),
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.downloadPetZip(pet),
        throwsA(isA<PetdexRemoteException>()),
      );
      expect(requested, [pet.zipUrl]);
    });

    for (final target in [
      'https://assets.petdex.dev:8443/zip.zip',
      'https://fixture@assets.petdex.dev/zip.zip',
      'http://assets.petdex.dev/zip.zip',
      '//attacker.example/zip.zip',
    ]) {
      test('rejects unsafe redirect $target before sending it', () async {
        final requested = <Uri>[];
        final service = PetdexRemoteService(
          client: _redirectClient(
            requested,
            (request) async =>
                request.url == pet.zipUrl ? _redirect(target) : _zip([80, 75]),
          ),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.downloadPetZip(pet),
          throwsA(isA<PetdexRemoteException>()),
        );
        expect(requested, [pet.zipUrl]);
      });
    }

    for (final status in [403, 200]) {
      test('cancels rejected HTTP $status response body', () async {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        addTearDown(() {
          unawaited(body.close());
        });
        final service = PetdexRemoteService(
          client: _redirectClient(
            [],
            (_) async => http.StreamedResponse(
              body.stream,
              status,
              contentLength: status == 200 ? 32 * 1024 * 1024 + 1 : null,
            ),
          ),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.downloadPetZip(pet),
          throwsA(isA<PetdexRemoteException>()),
        );
        expect(cancelled, isTrue);
      });
    }

    test('sigue una cadena de redirects permitidos', () async {
      final requested = <Uri>[];
      final first = Uri.parse('https://assets.petdex.dev/pets/boba/one.zip');
      final last = Uri.parse('https://assets.petdex.dev/pets/boba/two.zip');
      final payload = [80, 75, 3, 4];
      final client = _redirectClient(requested, (request) async {
        if (request.url == pet.zipUrl) return _redirect(first.toString());
        if (request.url == first) return _redirect(last.toString());
        if (request.url == last) return _zip(payload);
        fail('Unexpected request: ${request.url}');
      });
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      expect(await service.downloadPetZip(pet), payload);
      expect(requested, [pet.zipUrl, first, last]);
    });

    test('resuelve Location relativo contra la URI actual', () async {
      final requested = <Uri>[];
      final next = pet.zipUrl.resolve('../next.zip');
      final client = _redirectClient(
        requested,
        (request) async => request.url == pet.zipUrl
            ? _redirect('../next.zip')
            : _zip([80, 75]),
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      expect(await service.downloadPetZip(pet), [80, 75]);
      expect(requested, [pet.zipUrl, next]);
    });

    test(
      'corta un ciclo de redirects sin enviar solicitudes ilimitadas',
      () async {
        final requested = <Uri>[];
        final client = _redirectClient(
          requested,
          (_) async => _redirect(pet.zipUrl.toString()),
        );
        final service = PetdexRemoteService(client: client);
        addTearDown(service.dispose);

        await expectLater(
          service.downloadPetZip(pet),
          throwsA(isA<PetdexRemoteException>()),
        );
        expect(requested, isNotEmpty);
        expect(requested.length, lessThan(20));
        expect(requested, everyElement(pet.zipUrl));
      },
    );

    test('mantiene el límite de bytes después de un redirect', () async {
      final requested = <Uri>[];
      final next = pet.zipUrl.resolve('oversize.zip');
      final client = _redirectClient(
        requested,
        (request) async => request.url == pet.zipUrl
            ? _redirect('oversize.zip')
            : http.StreamedResponse(
                Stream.value([80, 75]),
                200,
                contentLength: 32 * 1024 * 1024 + 1,
              ),
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.downloadPetZip(pet),
        throwsA(isA<PetdexRemoteException>()),
      );
      expect(requested, [pet.zipUrl, next]);
    });

    test('mantiene el timeout durante la cadena de redirects', () async {
      final requested = <Uri>[];
      final next = pet.zipUrl.resolve('stalled.zip');
      final pending = Completer<http.StreamedResponse>();
      final client = _redirectClient(
        requested,
        (request) => request.url == pet.zipUrl
            ? Future.value(_redirect('stalled.zip'))
            : pending.future,
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      // Shorten only the service's long timeout; no network or 45s wait.
      await runZoned(
        () => expectLater(
          service.downloadPetZip(pet),
          throwsA(isA<PetdexRemoteException>()),
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(
                zone,
                duration >= const Duration(seconds: 20)
                    ? const Duration(milliseconds: 20)
                    : duration,
                callback,
              ),
        ),
      );
      expect(requested, [pet.zipUrl, next]);
    });

    test('corta un stream que supera el límite tras un redirect', () async {
      final requested = <Uri>[];
      final next = pet.zipUrl.resolve('stream.zip');
      final client = _redirectClient(
        requested,
        (request) async => request.url == pet.zipUrl
            ? _redirect('stream.zip')
            : http.StreamedResponse(
                Stream.value(Uint8List(32 * 1024 * 1024 + 1)),
                200,
              ),
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.downloadPetZip(pet),
        throwsA(isA<PetdexRemoteException>()),
      );
      expect(requested, [pet.zipUrl, next]);
    });

    test('rechaza redirect sin Location', () async {
      final requested = <Uri>[];
      final client = _redirectClient(
        requested,
        (_) async =>
            http.StreamedResponse(const Stream<List<int>>.empty(), 302),
      );
      final service = PetdexRemoteService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.downloadPetZip(pet),
        throwsA(isA<PetdexRemoteException>()),
      );
      expect(requested, [pet.zipUrl]);
    });
  });

  group('PetdexRemoteService.loadImage', () {
    final image = Uri.parse('https://assets.petdex.dev/pets/boba/sprite.webp');

    test(
      'rejects an oversized stream and never caches partial images',
      () async {
        var requests = 0;
        final client = _redirectClient([], (_) async {
          requests++;
          return http.StreamedResponse(
            Stream.value(Uint8List(PetdexRemoteService.maxImageBytes + 1)),
            200,
          );
        });
        final service = PetdexRemoteService(client: client);
        addTearDown(service.dispose);

        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            service.loadImage(image),
            throwsA(isA<PetdexRemoteException>()),
          );
          expect(service.imageCacheEntriesForTesting, 0);
          expect(service.imageCacheBytesForTesting, 0);
        }
        expect(requests, 2); // A failed load cannot become a cache hit.
      },
    );

    test(
      'rejects external redirect before requesting or caching target',
      () async {
        final requested = <Uri>[];
        final client = _redirectClient(
          requested,
          (_) async => _redirect('https://attacker.example/sprite.webp'),
        );
        final service = PetdexRemoteService(client: client);
        addTearDown(service.dispose);

        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            service.loadImage(image),
            throwsA(isA<PetdexRemoteException>()),
          );
          expect(service.imageCacheEntriesForTesting, 0);
        }
        expect(requested, [image, image]);
      },
    );

    test(
      'caches only verified bytes and evicts within the byte budget',
      () async {
        var requests = 0;
        final client = _redirectClient([], (_) async {
          requests++;
          return _zip(Uint8List(3 * 1024 * 1024));
        });
        final service = PetdexRemoteService(client: client);
        addTearDown(service.dispose);

        final first = await service.loadImage(image);
        first[0] = 42;
        expect((await service.loadImage(image))[0], 0);
        expect(requests, 1);
        for (var i = 0; i < 3; i++) {
          await service.loadImage(image.resolve('sprite$i.webp'));
        }
        expect(
          service.imageCacheBytesForTesting,
          lessThanOrEqualTo(PetdexRemoteService.maxImageCacheBytes),
        );
        expect(service.imageCacheEntriesForTesting, 2);
        await service.loadImage(image);
        expect(requests, 5); // Oldest entry was evicted.
      },
    );
  });
}
