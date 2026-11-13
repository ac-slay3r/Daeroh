// Spec 080 step A: install-source notice (Settings → About) and the About
// page on the design primitives. Screenshots: DESIGN_SHOTS_DIR.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/services/install_source.dart';
import 'package:hermes_android/core/widgets/install_source_section.dart';

import '../support/design_shots.dart';
import 'detail_single_scroll_contract_test.dart' show nestedVerticalScrollables;

const _updateUrl = String.fromEnvironment('DAEROH_UPDATE_PAGE_URL');
const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  final configuredUrl = InstallSourceInfo.updateUrl(InstallSource.manual);

  test('installer package → channel and configured update page', () {
    expect(
      InstallSourceInfo.classify('com.android.vending'),
      InstallSource.googlePlay,
    );
    expect(
      InstallSourceInfo.classify('dev.imranr.obtainium.fdroid'),
      InstallSource.githubObtainium,
    );
    expect(
      InstallSourceInfo.classify('dev.imranr.obtainium'),
      InstallSource.githubObtainium,
    );
    expect(InstallSourceInfo.classify(null), InstallSource.manual);
    expect(
      InstallSourceInfo.classify('com.google.android.packageinstaller'),
      InstallSource.manual,
    );

    for (final source in InstallSource.values) {
      expect(InstallSourceInfo.updateUrl(source), configuredUrl);
    }
    if (configuredUrl == null) {
      expect(
        _updateUrl,
        anyOf(isEmpty, startsWith('ftp:'), startsWith('mailto:')),
      );
    } else {
      final uri = Uri.parse(configuredUrl);
      expect(uri.scheme, anyOf('http', 'https'));
      expect(uri.hasAuthority, isTrue);
      expect(uri.host, isNotEmpty);
      expect(uri.host, isNot(contains('github.com')));
      expect(uri.host.toLowerCase(), isNot(contains('xp3ta')));
      expect(uri.host.toLowerCase(), isNot(contains('xpetalab')));
      expect(uri.path, isNot(contains('/releases')));
    }
  });

  test('update URL guard keeps private endpoint details out of source', () {
    final forbidden = [
      String.fromCharCodes([49, 48, 48, 46, 54, 52, 46, 48, 46, 55]),
      String.fromCharCodes([58, 56, 55, 57, 50]),
    ];
    for (final directory in ['lib', 'test', 'docs']) {
      for (final entity in Directory(directory).listSync(recursive: true)) {
        if (entity is! File) continue;
        final contents = utf8.decode(
          entity.readAsBytesSync(),
          allowMalformed: true,
        );
        for (final value in forbidden) {
          expect(contents, isNot(contains(value)), reason: entity.path);
        }
      }
    }
  });

  for (final (source, label) in const [
    (InstallSource.googlePlay, 'Google Play'),
    (InstallSource.githubObtainium, 'Página de actualizaciones'),
    (InstallSource.manual, 'Instalación manual'),
  ]) {
    testWidgets('install source $source', (tester) async {
      await pumpDesignScreen(
        tester,
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [InstallSourceSection(initialSource: source)],
          ),
        ),
      );
      expect(find.text('Actualizaciones'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      if (configuredUrl == null) {
        expect(find.byKey(const ValueKey('install-source-open')), findsNothing);
        expect(
          find.text(
            'La página de actualizaciones no está configurada en esta compilación.',
          ),
          findsOneWidget,
        );
      } else {
        expect(
          find.byKey(const ValueKey('install-source-open')),
          findsOneWidget,
        );
        expect(find.text('Abrir página de actualizaciones'), findsOneWidget);
      }
    });
  }

  testWidgets('configured update page launches externally', (tester) async {
    if (configuredUrl == null) return;
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _launcherChannel,
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _launcherChannel,
        null,
      ),
    );

    await pumpDesignScreen(
      tester,
      Scaffold(body: InstallSourceSection(initialSource: InstallSource.manual)),
    );
    await tester.tap(find.byKey(const ValueKey('install-source-open')));
    await tester.pump();

    expect(
      calls.where(
        (call) =>
            call.arguments is Map &&
            (call.arguments as Map)['url'] == configuredUrl,
      ),
      isNotEmpty,
    );
  });

  testWidgets('install source detected through the platform channel', (
    tester,
  ) async {
    InstallSourceInfo.installerOverride = () async => 'com.android.vending';
    addTearDown(() => InstallSourceInfo.installerOverride = null);
    await pumpDesignScreen(
      tester,
      const Scaffold(body: InstallSourceSection()),
    );
    await tester.pump();
    expect(find.text('Google Play'), findsOneWidget);
  });

  testWidgets('About page: groups, one scroll', (tester) async {
    InstallSourceInfo.installerOverride = () async => null;
    addTearDown(() => InstallSourceInfo.installerOverride = null);
    await pumpDesignScreen(tester, const AboutScreen());
    expect(nestedVerticalScrollables(tester), isEmpty);
    expect(tester.takeException(), isNull);
    await saveDesignShot(tester, 'about');
  });
}
