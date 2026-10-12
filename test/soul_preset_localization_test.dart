import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/screens/soul_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key']);
            }
            return null;
          },
        );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });

  for (final language in ['en', 'es']) {
    testWidgets('profile wizard inserts $language SOUL for all presets', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ProfileBuilderScreen(
            connection: SavedConnection(
              id: 'preset-test',
              label: 'Test',
              host: '127.0.0.1',
              port: 8642,
              apiKey: '',
            ),
            existing: const {},
          ),
        ),
      );
      final s = Strings.of(tester.element(find.byType(ProfileBuilderScreen)));
      final presets = [
        (s.prfPresetTechnical, s.prfPresetTechnicalContent),
        (s.prfPresetHomelab, s.prfPresetHomelabContent),
        (s.prfPresetMinimal, s.prfPresetMinimalContent),
      ];
      for (final (label, content) in presets) {
        await tester.tap(find.text(label));
        await tester.pump();
        final soulField = tester.widget<HermesField>(
          find.widgetWithText(HermesField, s.prfSoulLabel),
        );
        expect(soulField.controller.text, content);
        expect(
          content,
          startsWith(language == 'en' ? '# Identity' : '# Identidad'),
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'SOUL editor shows localized templates and inserts $language content',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'onboarding_done': true,
          AppLocales.prefKey: language,
        });
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        final secure = SecureStorage();
        final chats = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        addTearDown(chats.dispose);
        final ssh = SshManager(secure, manager);
        await tester.pumpWidget(
          HermesApp(
            connManager: manager,
            appLock: AppLockService(prefs),
            approvalPolicy: ApprovalPolicyService(prefs),
            fontSize: FontSizeService(prefs),
            bridgeManager: BridgeManager(secure, manager),
            sshManager: ssh,
            sftpTransfers: SftpTransferService(ssh, NotificationService(prefs)),
            sshSessions: SshSessionService(ssh),
            notifications: NotificationService(prefs),
            activeChats: chats,
          ),
        );
        await tester.pump(const Duration(seconds: 4));
        Navigator.of(
          tester.element(find.byType(Navigator).first),
        ).push(MaterialPageRoute<void>(builder: (_) => const SoulScreen()));
        await tester.pumpAndSettle();
        final s = Strings.of(tester.element(find.byType(SoulScreen)));
        final presets = [
          (s.soulTplTechName, s.soulTplTechDesc, s.soulTplTechContent),
          (s.soulTplHomelabName, s.soulTplHomelabDesc, s.soulTplHomelabContent),
          (s.soulTplMinimalName, s.soulTplMinimalDesc, s.soulTplMinimalContent),
        ];
        for (final (label, description, content) in presets) {
          await tester.tap(find.byTooltip(s.soulTemplatesTitle));
          await tester.pumpAndSettle();
          expect(find.text(label), findsOneWidget);
          expect(find.text(description), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          if (tester.any(find.text(s.soulReplace))) {
            await tester.tap(find.text(s.soulReplace));
            await tester.pumpAndSettle();
          }
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            content,
          );
          expect(
            content,
            startsWith(language == 'en' ? '# Identity' : '# Identidad'),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
