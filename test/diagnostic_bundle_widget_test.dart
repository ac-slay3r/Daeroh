import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/diagnostic_bundle_service.dart';
import 'package:hermes_android/core/services/diagnostics_consent_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/diagnostic_bundle_tile.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _FakeController extends DiagnosticBundleController {
  _FakeController(ConnectionManager manager) : super(manager: manager) {
    bundle = DiagnosticBundleService(now: () => DateTime.utc(2026, 7, 14, 20))
        .build(
          const DiagnosticBundleInput(
            appVersion: '1.1.3',
            buildNumber: 900,
            flavor: DiagnosticFlavor.qa,
            androidApi: 36,
            formFactor: DiagnosticFormFactor.phone,
          ),
        );
  }

  late final DiagnosticBundle bundle;
  int prepareCalls = 0;
  int shareCalls = 0;

  @override
  Future<DiagnosticBundle> prepare(DiagnosticFormFactor formFactor) async {
    prepareCalls++;
    return bundle;
  }

  @override
  Future<void> share(DiagnosticBundle bundle) async {
    shareCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  Future<ConnectionManager> manager() async {
    final prefs = await SharedPreferences.getInstance();
    return ConnectionManager.create(prefs);
  }

  Future<void> pumpTile(
    WidgetTester tester,
    DiagnosticBundleController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(body: DiagnosticBundleTile(controller: controller)),
      ),
    );
  }

  testWidgets('muestra preview y cancelar no comparte', (tester) async {
    final controller = _FakeController(await manager());
    await pumpTile(tester, controller);

    await tester.tap(find.text('Generar diagnóstico local'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.prepareCalls, 1);
    expect(controller.shareCalls, 0);
    expect(find.text('Revisar diagnóstico'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('diagnostic-bundle-preview')),
      findsOneWidget,
    );
    expect(find.textContaining('"schemaVersion":1'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Revisar diagnóstico'), findsNothing);
    expect(controller.shareCalls, 0);
  });

  testWidgets('compartir requiere confirmación explícita', (tester) async {
    final controller = _FakeController(await manager());
    await pumpTile(tester, controller);

    await tester.tap(find.text('Generar diagnóstico local'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.shareCalls, 0);

    await tester.tap(find.text('Compartir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.shareCalls, 1);
    expect(find.text('Revisar diagnóstico'), findsNothing);
  });

  test('archivo existe solo durante share y se elimina después', () async {
    final cache = await Directory.systemTemp.createTemp('hermes-share-test-');
    addTearDown(() async {
      if (await cache.exists()) await cache.delete(recursive: true);
    });
    final service = DiagnosticBundleService(
      cacheDirectory: () async => cache,
      now: () => DateTime.utc(2026, 7, 14, 20),
      randomToken: () => 'share-test',
    );
    File? shared;
    var existedDuringShare = false;
    final controller = DiagnosticBundleController(
      manager: await manager(),
      service: service,
      shareFile: (file) async {
        shared = file;
        existedDuringShare = await file.exists();
      },
    );
    final bundle = service.build(
      const DiagnosticBundleInput(
        appVersion: '1.1.3',
        buildNumber: 900,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
        formFactor: DiagnosticFormFactor.phone,
      ),
    );

    expect(await cache.list().toList(), isEmpty);
    await controller.share(bundle);

    expect(existedDuringShare, isTrue);
    expect(shared?.parent.path, cache.path);
    expect(await shared!.exists(), isFalse);
  });

  testWidgets('el consentimiento remoto empieza apagado y persiste el cambio', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final consent = DiagnosticsConsentStore(prefs);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: DiagnosticsConsentTile(consent: consent, isAvailable: true),
        ),
      ),
    );

    final toggle = find.byKey(const ValueKey('diagnostics-remote-opt-in'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(consent.enabled, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(consent.enabled, isFalse);
  });
}
