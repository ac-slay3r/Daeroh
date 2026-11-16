// SPDX-FileCopyrightText: 2026 Daeroh contributors
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _Gateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionHistoryGateway,
        HermesDesktopSessionActivityGateway {
  final controller = StreamController<TuiGatewayEvent>.broadcast();
  final submissions = <String>[];
  final durable = <Map<String, dynamic>>[];
  @override
  Stream<TuiGatewayEvent> get events => controller.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;
  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime',
    storedSessionId: 'stored',
    created: true,
  );
  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime',
    storedSessionId: storedSessionId,
    created: false,
    running: false,
    status: 'idle',
  );
  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList();
  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) => resumeExisting(storedSessionId);
  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async => SessionMessagesPage.fromRaw(
    // Real session.history projects SQLite identity as row_id, REST as id.
    // Native history is unpaginated and cannot prove the REST end boundary.
    rawMessages: [
      for (final m in durable) {...m, 'row_id': m['id']}..remove('id'),
    ],
    pagination: null,
    paginationProvided: false,
  );
  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
  }

  void emit(String type, [Map<String, dynamic> payload = const {}]) =>
      controller.add(
        TuiGatewayEvent(type: type, sessionId: 'runtime', payload: payload),
      );
  @override
  Future<void> close() => controller.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Harness {
  final gateway = _Gateway();
  int restVisibleCount = 0;
  late final chat = createChat();
  ActiveChat createChat({bool cold = false}) {
    final result = ActiveChat(
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'unused',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'session_id': 'stored',
              'messages': gateway.durable.take(restVisibleCount).toList(),
            }),
            200,
          ),
        ),
      ),
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'projection-test',
        label: 'Synthetic',
        host: 'example.invalid',
        port: 443,
        apiKey: 'unused',
        useHttps: true,
        kind: InstanceKind.vps,
      ),
      sessionId: cold ? 'stored' : 'mob-projection-test',
      initialStoredSessionId: cold ? 'stored' : null,
      sessionTitle: 'Synthetic',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
      attachDesktopRuntimeOnLoad: true,
    )..smoothStreaming = false;
    if (!cold) result.markStoredSessionMissing();
    addTearDown(result.dispose);
    return result;
  }

  Future<void> start(String prompt) async {
    expect(
      await chat.send(
        fullText: prompt,
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    await stream(prompt);
  }

  Future<void> stream(String prompt) async {
    gateway.emit('message.start');
    gateway.emit('message.delta', {'text': '$prompt reply'});
    await _flush();
  }

  Future<void> complete(String prompt, {bool restReady = true}) async {
    gateway.durable.addAll([
      {'id': gateway.durable.length + 1, 'role': 'user', 'content': prompt},
      {
        'id': gateway.durable.length + 2,
        'role': 'assistant',
        'content': '$prompt reply',
      },
    ]);
    if (restReady) restVisibleCount = gateway.durable.length;
    gateway.emit('message.complete', {'text': '$prompt reply'});
    await _flush();
  }

  Future<void> refresh() async {
    restVisibleCount = gateway.durable.length;
    await chat.loadMessages(passiveOnly: true);
  }

  Future<void> twoTurns({String second = 'second'}) async {
    await start('first');
    await complete('first');
    await refresh();
    await start(second);
    // Terminal precedes REST persistence; the following session.history
    // refresh carries the new durable rows. This is the observed race.
    await complete(second, restReady: false);
    await refresh();
  }

  void expectPairs(int count, {ActiveChat? subject}) {
    final rows = (subject ?? chat).messages;
    expect(rows.where(isRealUserTurn), hasLength(count), reason: '$rows');
    expect(
      rows.where((m) => m['role'] == 'assistant'),
      hasLength(count),
      reason: '$rows',
    );
    expect(rows.where((m) => m['_optimistic'] == true), isEmpty);
    expect(
      rows.map((m) => m['row_id'] ?? m['id']),
      orderedEquals(gateway.durable.reversed.map((m) => m['id'])),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  _Harness harness() {
    final h = _Harness();
    addTearDown(h.gateway.close);
    return h;
  }

  test('ordinary second send retires adopted first-turn fence', () async {
    final h = harness();
    await h.twoTurns();
    h.expectPairs(2);
    expect(h.gateway.submissions, ['first', 'second']);
  });
  test('queued second turn during streaming has one durable pair', () async {
    final h = harness();
    await h.start('first');
    expect(h.chat.enqueue('second'), isTrue);
    expect(h.chat.queuedMessages, ['second']);
    await h.complete('first');
    await _flush();
    expect(h.gateway.submissions, ['first', 'second']);
    await h.stream('second');
    await h.complete('second', restReady: false);
    await h.refresh();
    h.expectPairs(2);
    expect(h.chat.queuedMessages, isEmpty);
    expect(h.gateway.submissions, ['first', 'second']);
  });
  test(
    'reopening retained Chat cannot restore an adopted projection',
    () async {
      final h = harness();
      await h.twoTurns();
      // Route reopen reuses the retained ActiveChat and reloads its transcript.
      // Real route/pixel coverage is also exercised on both emulator targets.
      await h.chat.loadMessages();
      await h.refresh();
      h.expectPairs(2);
      expect(h.gateway.submissions, ['first', 'second']);
    },
  );
  test(
    'warm resume reconciles one durable pair per turn without resend',
    () async {
      final h = harness();
      await h.twoTurns();
      await h.chat.reconcileAfterResume();
      await h.refresh();
      h.expectPairs(2);
      expect(h.gateway.submissions, ['first', 'second']);
    },
  );
  test(
    'cold start loads server identities without local projection state',
    () async {
      final h = harness();
      await h.twoTurns();
      h.expectPairs(2);
      h.chat.dispose();
      final cold = h.createChat(cold: true);
      await cold.loadMessages();
      h.expectPairs(2, subject: cold);
      expect(h.gateway.submissions, ['first', 'second']);
    },
  );
  test(
    'genuine identical repeated prompts retain both durable identities',
    () async {
      final h = harness();
      await h.twoTurns(second: 'first');
      h.expectPairs(2);
      expect(
        h.chat.messages
            .where((m) => m['role'] == 'user')
            .map((m) => m['content']),
        ['first', 'first'],
      );
      expect(h.gateway.submissions, ['first', 'first']);
    },
  );
  test('undelivered queued entry survives projection reconciliation', () async {
    final h = harness();
    await h.twoTurns();
    expect(h.chat.enqueue('never delivered'), isTrue);
    final entry = h.chat.queuedEntries.single;
    h.chat.markQueuedRetryExhaustedForTesting(entry.id);
    await h.refresh();
    h.expectPairs(2);
    expect(h.chat.queuedEntries.single.id, entry.id);
    expect(h.chat.queuedMessages, ['never delivered']);
    expect(h.chat.queuedRetriesExhausted, {entry.id});
    expect(h.gateway.submissions, ['first', 'second']);
  });
}
