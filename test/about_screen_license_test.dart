import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('Acerca de registra GPLv3 y conserva la atribucion upstream', (
    tester,
  ) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Daeroh',
      packageName: 'cool.n0thing.daeroh',
      version: '1.2.7-qa',
      buildNumber: '914',
      buildSignature: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const AboutScreen(),
      ),
    );
    await tester.pump();

    final entries = await LicenseRegistry.licenses.toList();
    final project = entries.singleWhere(
      (entry) => entry.packages.contains('Daeroh'),
    );
    final projectNotice = project.paragraphs
        .map((paragraph) => paragraph.text)
        .join('\n');
    expect(projectNotice, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(projectNotice, contains('Version 3, 29 June 2007'));

    final upstream = entries.singleWhere(
      (entry) => entry.packages.contains('hermes-android (upstream)'),
    );
    final notice = upstream.paragraphs
        .map((paragraph) => paragraph.text)
        .join('\n');

    expect(notice, contains('rusty4444'));
    expect(notice, contains('MIT License'));
    expect(
      entries.any((entry) => entry.packages.contains('Thinking Orbs 0.3.1')),
      isFalse,
    );
  });

  testWidgets('Privacy note opens bundled document on Hermes surface', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Daeroh',
      packageName: 'cool.n0thing.daeroh',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const AboutScreen(),
      ),
    );
    final noteRow = find.text('Privacy note');
    await tester.ensureVisible(noteRow);
    await tester.pumpAndSettle();
    await tester.tap(noteRow);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('daeroh-privacy-note')), findsOneWidget);
    expect(find.textContaining('Daeroh privacy'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
