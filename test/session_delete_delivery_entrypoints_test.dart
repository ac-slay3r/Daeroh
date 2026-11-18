// SPDX-FileCopyrightText: 2026 Daeroh contributors
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/session_detail_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Keep the real deleteSession implementation; only discovery/health are fixtures.
class _SessionsClient extends ApiClient {
  _SessionsClient(
    SavedConnection connection,
    this.session,
    http.Client transport,
  ) : super(
        baseUrl: connection.baseUrl,
        apiKey: 'test-only',
        connectionId: connection.id,
        httpClient: transport,
      );
  final Session session;
  @override
  Future<bool> healthCheck({
    String? profile,
    bool verifySessionAccess = true,
  }) async => true;
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async => [session];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    secure.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'readAll':
                return Map<String, String>.of(secure);
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'delete':
                secure.remove(args['key']);
            }
            return null;
          },
        );
  });

  for (final surface in [
    'Home',
    'session list',
    'session detail',
    'Settings',
  ]) {
    testWidgets('$surface confirmed deletion revokes queued producer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-only',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      await manager.setActiveConnection(connection.id);
      final session = Session.fromJson({
        'id': 'delete-session',
        'title': 'Delete queued conversation',
        'source': surface == 'Settings' ? 'cron' : 'mobile',
        'started_at': DateTime.now().millisecondsSinceEpoch / 1000,
      });
      final route = LocalConversationCleanupFence.beginLifecycle(
        connectionId: connection.id,
        profile: 'default',
        sessionId: session.id,
      );
      final producer = LocalConversationCleanupFence.beginServiceLifecycle(
        route,
      );
      final outbox = TurnOutboxStore(lifecycle: producer);
      final now = DateTime.now().millisecondsSinceEpoch;
      final turn = PreparedTurn(
        connectionId: connection.id,
        sessionId: session.id,
        clientTurnId: 'queued',
        profile: 'default',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'do not send after deletion',
        attachments: const [],
        model: 'model',
        queued: true,
      );
      await outbox.save(turn);
      var deletes = 0;
      final transport = MockClient((request) async {
        if (request.method == 'DELETE') {
          deletes++;
          return http.Response('{"deleted":true}', 200);
        }
        if (request.url.path.endsWith('/api/sessions')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': session.id, 'title': session.title, 'source': 'mobile'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final client = _SessionsClient(connection, session, transport);
      Widget screen = switch (surface) {
        'Home' => HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => client,
        ),
        'session list' => SessionListScreen(
          connection: connection,
          connManager: manager,
          clientOverride: client,
        ),
        'session detail' => SessionDetailScreen(
          connection: connection,
          session: session,
          client: client,
          skipInitialSessionRefresh: true,
        ),
        _ => Scaffold(
          body: HistoryCleanupSection(
            connection: connection,
            connManager: manager,
            verifyHistoryCleanupForTesting: () async => true,
            remoteClientOverride: client,
          ),
        ),
      };
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('es'),
            theme: AppTheme.fromId('dark'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: screen,
          ),
        );
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (surface == 'Home') {
          await tester.drag(
            find.text('Delete queued conversation'),
            const Offset(-500, 0),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('home-recent-action-delete')),
          );
        } else if (surface == 'session list') {
          await tester.longPress(find.text('Delete queued conversation'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Borrar sesión'));
          await tester.tap(find.text('Borrar sesión'));
        } else if (surface == 'session detail') {
          final action = find.byKey(const ValueKey('session-detail-delete'));
          await tester.ensureVisible(action);
          await tester.tap(action);
        } else {
          await tester.tap(
            find.byKey(const ValueKey('history-cleanup-normal')),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        if (surface == 'Settings') {
          // Cron-only cleanup deliberately does not advance a profile epoch;
          // this must exercise the exact-session fence, not a broader cleanup.
          await tester.tap(
            find.byKey(const ValueKey('history-cleanup-scope-chats')),
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('history-cleanup-scope-automations')),
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('history-cleanup-scope-confirm')),
          );
        } else if (surface == 'session detail') {
          await tester.tap(
            find.byKey(const ValueKey('session-detail-delete-confirm')),
          );
        } else {
          await tester.tap(find.text('Borrar').last);
        }
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }, () => transport);
      expect(
        deletes,
        1,
        reason: 'The actual surface must confirm a remote DELETE',
      );
      await expectLater(
        outbox.save(turn),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      LocalConversationCleanupFence.resetForTesting();
      TurnOutboxStore.resetSerializationForTesting();
      expect(
        await TurnOutboxStore().loadAllForChat(
          connection.id,
          session.id,
          profile: 'default',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
