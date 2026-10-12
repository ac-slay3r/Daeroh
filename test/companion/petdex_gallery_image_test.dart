import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/screens/companion/petdex_gallery_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _alpha = Uri.parse('https://assets.petdex.dev/alpha.png');
final _beta = Uri.parse('https://assets.petdex.dev/beta.png');

Object _manifest() => {
  'pets': [
    for (final name in ['Alpha', 'Beta'])
      {
        'slug': name.toLowerCase(),
        'displayName': name,
        'kind': 'creature',
        'spritesheetUrl': 'https://assets.petdex.dev/${name.toLowerCase()}.png',
        'petJsonUrl': 'https://assets.petdex.dev/${name.toLowerCase()}.json',
        'zipUrl': 'https://assets.petdex.dev/${name.toLowerCase()}.zip',
      },
  ],
};

http.StreamedResponse _body(List<int> bytes) =>
    http.StreamedResponse(Stream.value(bytes), 200);

Future<Uint8List> _png(WidgetTester tester, int width, int height) async {
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.amber, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }))!;
}

Future<PetdexRemoteService> _pumpGallery(
  WidgetTester tester,
  List<Uri> requested,
  Future<http.StreamedResponse> Function(http.BaseRequest) respond,
) async {
  SharedPreferences.setMockInitialValues({});
  final controller = CompanionController(
    CompanionRepository(),
    await CompanionPreferences.load(),
  );
  final service = PetdexRemoteService(
    client: MockClient.streaming((request, _) async {
      requested.add(request.url);
      expect(request.url.origin, 'https://assets.petdex.dev');
      expect(request.followRedirects, isFalse);
      if (request.url == PetdexRemoteService.manifestUrl) {
        return _body(utf8.encode(jsonEncode(_manifest())));
      }
      return respond(request);
    }),
  );
  addTearDown(service.dispose);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: PetdexGalleryScreen(controller: controller, service: service),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

Future<void> _open(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _close(WidgetTester tester) {
  Navigator.of(
    tester.element(find.byKey(const ValueKey('petdex-detail-surface'))),
  ).pop();
}

// Engine decoding is real asynchronous work, not a fake-time timer. Wait only
// for the rendered image (or error) with a bounded real-async readiness loop.
Future<void> _waitForDecode(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    if (images.any((image) => image.image != null) ||
        find.byIcon(Icons.image_not_supported_outlined).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Image decoding did not reach a rendered image/error within 1 second');
}

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('manifest, search and sort never fetch row artwork', (
    tester,
  ) async {
    final requested = <Uri>[];
    await _pumpGallery(
      tester,
      requested,
      (_) async => fail('Implicit image GET'),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.pets), findsNWidgets(2));
    await tester.enterText(find.byType(TextField), 'Beta');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.auto_awesome));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(requested, [PetdexRemoteService.manifestUrl]);
  });

  for (final size in [const Size(1200, 2400), const Size(2400, 1200)]) {
    testWidgets(
      'valid ${size.width}x${size.height} image decodes within both bounds',
      (tester) async {
        final png = await _png(tester, size.width.toInt(), size.height.toInt());
        final requested = <Uri>[];
        await _pumpGallery(tester, requested, (request) async {
          if (request.url.path.endsWith('.zip')) {
            return http.StreamedResponse(const Stream.empty(), 404);
          }
          return _body(png);
        });
        await _open(tester, 'Alpha');
        await _waitForDecode(tester);
        expect(requested, [PetdexRemoteService.manifestUrl, _alpha]);
        final provider =
            tester.widget<Image>(find.byType(Image)).image as ResizeImage;
        expect(provider.width, 660);
        expect(provider.height, 540);
        expect(provider.policy, ResizeImagePolicy.fit);
        final memory = provider.imageProvider as MemoryImage;
        expect(memory.bytes, png);
        final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!;
        expect(decoded.width, lessThanOrEqualTo(660));
        expect(decoded.height, lessThanOrEqualTo(540));
        expect(
          decoded.width / decoded.height,
          closeTo(size.width / size.height, 0.01),
        );
        expect(
          PaintingBinding.instance.imageCache.containsKey(memory),
          isFalse,
        );
        // Installation notifier rebuilds must not refetch the preview.
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(requested.where((uri) => uri == _alpha), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final failure in [
    'oversized-stream',
    'oversized-header',
    'redirect',
    'invalid-image',
  ]) {
    testWidgets('$failure produces placeholder through bounded loader', (
      tester,
    ) async {
      final requested = <Uri>[];
      final service = await _pumpGallery(tester, requested, (_) async {
        switch (failure) {
          case 'oversized-stream':
            return _body(Uint8List(PetdexRemoteService.maxImageBytes + 1));
          case 'oversized-header':
            return http.StreamedResponse(
              const Stream.empty(),
              200,
              contentLength: PetdexRemoteService.maxImageBytes + 1,
            );
          case 'redirect':
            return http.StreamedResponse(
              const Stream.empty(),
              302,
              headers: {'location': 'https://attacker.example/image.png'},
            );
          default:
            return _body([1, 2, 3]);
        }
      });
      await _open(tester, 'Alpha');
      await _waitForDecode(tester);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(requested, [PetdexRemoteService.manifestUrl, _alpha]);
      if (failure != 'invalid-image') {
        expect(service.imageCacheEntriesForTesting, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final lateError in [false, true]) {
    testWidgets('dismissed detail lateError=$lateError cannot paint next pet', (
      tester,
    ) async {
      final pending = Completer<http.StreamedResponse>();
      final png = await _png(tester, 40, 80);
      final requested = <Uri>[];
      await _pumpGallery(tester, requested, (request) async {
        if (request.url == _alpha) return pending.future;
        return _body(png);
      });
      await _open(tester, 'Alpha');
      _close(tester);
      await tester.pumpAndSettle();
      await _open(tester, 'Beta');
      await _waitForDecode(tester);
      if (lateError) {
        pending.completeError(Exception('late failure'));
      } else {
        pending.complete(_body([1, 2, 3]));
      }
      await tester.pumpAndSettle();
      final provider =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect((provider.imageProvider as MemoryImage).bytes, png);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
      expect(requested, [PetdexRemoteService.manifestUrl, _alpha, _beta]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('completion after gallery disposal has no widget effects', (
    tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    await _pumpGallery(tester, [], (_) => pending.future);
    await _open(tester, 'Alpha');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(Exception('disposed request'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
  });
}
