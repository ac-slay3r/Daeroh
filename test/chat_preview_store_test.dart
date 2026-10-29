import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_preview_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secure = <String, String>{};
  String? delayedWriteKey;
  Completer<void>? heldWrite;
  Completer<void>? writeStarted;
  Completer<void>? heldDelete;
  Completer<void>? deleteStarted;
  Completer<void>? heldRead;
  Completer<void>? readStarted;
  var failWrites = false;

  setUp(() {
    ChatPreviewStore.resetForTesting();
    secure.clear();
    delayedWriteKey = null;
    heldWrite = null;
    writeStarted = null;
    heldDelete = null;
    deleteStarted = null;
    heldRead = null;
    readStarted = null;
    failWrites = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
            final key = args['key'] as String?;
            switch (call.method) {
              case 'write':
                if (failWrites) throw PlatformException(code: 'write-failed');
                final writeGate = heldWrite;
                heldWrite = null;
                if (writeGate != null) {
                  writeStarted?.complete();
                  await writeGate.future;
                }
                if (key == delayedWriteKey) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                }
                secure[key!] = args['value'] as String;
                return null;
              case 'read':
                final value = secure[key];
                final gate = heldRead;
                heldRead = null;
                if (gate != null) {
                  readStarted?.complete();
                  await gate.future;
                }
                return value;
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'delete':
                final deleteGate = heldDelete;
                heldDelete = null;
                if (deleteGate != null) {
                  deleteStarted?.complete();
                  await deleteGate.future;
                }
                secure.remove(key);
                return null;
            }
            return null;
          },
        );
  });

  const scope = ChatPreviewScope(
    connectionId: 'conn-a',
    profile: 'profile-a',
    sessionId: 'session-a',
  );

  Map<String, dynamic> row(int id, {String text = 'message'}) => {
    'role': id.isEven ? 'assistant' : 'user',
    'content': '$text $id',
    'message_id': 'm-$id',
    'timestamp': id,
    'tool_calls': const ['must-not-persist'],
    'attachment': {'url': 'https://token@example.invalid'},
  };

  test(
    'writes bounded encrypted render previews and reads them back',
    () async {
      await ChatPreviewStore.save(
        scope,
        List.generate(101, (index) => row(index)),
      );

      expect(secure.keys, hasLength(1));
      final raw = secure.values.single;
      expect(raw, isNot(contains('must-not-persist')));
      expect(raw, isNot(contains('token@example.invalid')));

      final saved = await ChatPreviewStore.load(scope);
      expect(saved.messages, hasLength(100));
      expect(saved.messages.first['message_id'], 'm-1');
      expect(saved.messages.last['message_id'], 'm-100');
    },
  );

  test(
    'dedupes canonical identity and accepts newer render metadata',
    () async {
      await ChatPreviewStore.save(scope, [
        row(1, text: 'old'),
        {...row(1, text: 'new'), 'display_kind': 'process_complete'},
      ]);

      final saved = await ChatPreviewStore.load(scope);
      expect(saved.messages, hasLength(1));
      expect(saved.messages.single['content'], 'new 1');
      expect(saved.messages.single['display_kind'], 'process_complete');
    },
  );

  test(
    'oversized text is clipped and a storage failure stays non-fatal',
    () async {
      await ChatPreviewStore.save(scope, [
        {...row(1), 'content': List.filled(200000, 'x').join()},
      ]);
      final saved = await ChatPreviewStore.load(scope);
      expect(saved.messages.single['content'].length, lessThan(200000));

      failWrites = true;
      await expectLater(ChatPreviewStore.save(scope, [row(2)]), completes);
    },
  );

  test(
    'delete fences a late save so a removed scope cannot resurrect',
    () async {
      delayedWriteKey = ChatPreviewStore.debugKeyFor(scope);
      final lateSave = ChatPreviewStore.save(scope, [row(1)]);
      await Future<void>.delayed(Duration.zero);
      await ChatPreviewStore.clear(scope);
      await lateSave;

      expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
    },
  );

  test(
    'rejects rows without canonical identity or private render state',
    () async {
      await ChatPreviewStore.save(scope, [
        {'role': 'assistant', 'content': 'anonymous'},
        {...row(1), '_pipeline': true},
        row(2),
      ]);

      final saved = await ChatPreviewStore.load(scope);
      expect(saved.messages.map((message) => message['message_id']), ['m-2']);
    },
  );

  test('empty accepted projection retires the prior encrypted preview', () async {
    await ChatPreviewStore.save(scope, [row(1)]);
    await ChatPreviewStore.save(scope, const []);

    expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
  });

  test('profile cleanup fences a first write not yet visible to readAll', () async {
    delayedWriteKey = ChatPreviewStore.debugKeyFor(scope);
    final pending = ChatPreviewStore.save(scope, [row(1)]);
    await Future<void>.delayed(Duration.zero);

    await ChatPreviewStore.deleteForProfile('conn-a', 'profile-a');
    await pending;

    expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
  });

  test('scope clear fences a held secure read before it can publish', () async {
    await ChatPreviewStore.save(scope, [row(1)]);
    heldRead = Completer<void>();
    readStarted = Completer<void>();
    final release = heldRead!;
    final pending = ChatPreviewStore.load(scope);
    await readStarted!.future;

    var clearFinished = false;
    final clear = ChatPreviewStore.clear(scope).whenComplete(() => clearFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(clearFinished, isFalse);
    release.complete();

    await clear;

    expect((await pending).isEmpty, isTrue);
  });

  test('newer publication wins when an older secure write finishes last', () async {
    delayedWriteKey = ChatPreviewStore.debugKeyFor(scope);
    final older = ChatPreviewStore.save(scope, [row(1, text: 'old')]);
    await Future<void>.delayed(Duration.zero);
    await ChatPreviewStore.save(scope, [row(1, text: 'new')]);
    await older;

    expect((await ChatPreviewStore.load(scope)).messages.single['content'], 'new 1');
  });

  test('keeps integer canonical row identities through a safe round trip', () async {
    await ChatPreviewStore.save(scope, [
      {'row_id': 1, 'role': 'user', 'content': 'one'},
      {'row_id': 2, 'role': 'assistant', 'content': 'two'},
    ]);

    final saved = await ChatPreviewStore.load(scope);
    expect(saved.messages.map((row) => row['row_id']), [1, 2]);
  });

  test('keeps desktop canonical aliases through a safe round trip', () async {
    await ChatPreviewStore.save(scope, [
      {
        '_desktopMessageId': 'desktop-message-1',
        '_desktopRowId': 7,
        'role': 'assistant',
        'content': 'alias-only',
      },
    ]);

    final saved = await ChatPreviewStore.load(scope);
    expect(saved.messages, hasLength(1));
    expect(saved.messages.single['_desktopMessageId'], 'desktop-message-1');
    expect(saved.messages.single['_desktopRowId'], 7);
  });

  test('confirmed profile deletion removes matching preview owners', () async {
    await ChatPreviewStore.save(scope, [row(1)]);
    final dashboard = DashboardClient(
      host: 'fixture.invalid',
      useHttps: true,
      manualToken: 'fixture',
      connectionId: scope.connectionId,
      httpClientOverride: MockClient((_) async => http.Response('', 204)),
    );

    await dashboard.deleteProfile('profile-a');

    expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
  });

  test(
    'remote session deletion clears preview after draft cleanup fails',
    () async {
      await ChatPreviewStore.save(scope, [row(1)]);
      SharedPreferences.setMockInitialValues({});
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args =
                  (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
              final key = args['key'] as String?;
              if (call.method == 'read' && key?.startsWith('chat_draft_v3.') == true) {
                throw PlatformException(code: 'draft-read-failed');
              }
              switch (call.method) {
                case 'read':
                  return secure[key];
                case 'readAll':
                  return Map<String, String>.from(secure);
                case 'write':
                  secure[key!] = args['value'] as String;
                  return null;
                case 'delete':
                  secure.remove(key);
                  return null;
              }
              return null;
            },
          );
      final api = ApiClient(
        baseUrl: 'https://fixture.invalid',
        apiKey: 'fixture',
        connectionId: scope.connectionId,
        httpClient: MockClient(
          (_) async => http.Response('{"deleted":true}', 200),
        ),
      );

      expect(await api.deleteSession('session-a', profile: 'profile-a'), isTrue);
      expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
    },
  );

  test('completed cleanup never exposes a stale held write', () async {
    heldWrite = Completer<void>();
    writeStarted = Completer<void>();
    final releaseWrite = heldWrite!;
    final staleSave = ChatPreviewStore.save(scope, [row(1, text: 'private')]);
    await writeStarted!.future;

    final cleanup = ChatPreviewStore.deleteForProfile(scope.connectionId, scope.profile);
    await Future<void>.delayed(Duration.zero);
    releaseWrite.complete();
    await Future.wait([staleSave, cleanup]);

    final snapshot = await ChatPreviewStore.load(scope);
    expect(snapshot.messages, isEmpty);
  });

  test('a queued empty delete cannot erase a later accepted preview', () async {
    await ChatPreviewStore.save(scope, [row(1, text: 'seed')]);
    heldDelete = Completer<void>();
    deleteStarted = Completer<void>();
    final releaseDelete = heldDelete!;
    final staleEmpty = ChatPreviewStore.save(scope, const []);
    await deleteStarted!.future;

    final validLater = ChatPreviewStore.save(scope, [row(1, text: 'valid-later')]);
    releaseDelete.complete();
    await Future.wait([staleEmpty, validLater]);

    expect(
      (await ChatPreviewStore.load(scope)).messages.single['content'],
      'valid-later 1',
    );
  });

  test('profile cleanup waits for a held native write then deletes raw storage', () async {
    heldWrite = Completer<void>();
    writeStarted = Completer<void>();
    final releaseWrite = heldWrite!;
    final pendingSave = ChatPreviewStore.save(scope, [row(1, text: 'private')]);
    await writeStarted!.future;

    var cleanupFinished = false;
    final cleanup = ChatPreviewStore.deleteForProfile(scope.connectionId, scope.profile)
        .whenComplete(() => cleanupFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(cleanupFinished, isFalse);

    releaseWrite.complete();
    await Future.wait([pendingSave, cleanup]);
    expect(secure.containsKey(ChatPreviewStore.debugKeyFor(scope)), isFalse);
    expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
  });

  test('profile cleanup keeps the same profile on a neighboring connection', () async {
    const neighboring = ChatPreviewScope(
      connectionId: 'conn-b',
      profile: 'profile-a',
      sessionId: 'session-b',
    );
    await ChatPreviewStore.save(scope, [row(1, text: 'remove')]);
    await ChatPreviewStore.save(neighboring, [row(2, text: 'keep')]);

    await ChatPreviewStore.deleteForProfile(scope.connectionId, scope.profile);
    ChatPreviewStore.resetForTesting(); // Simulated process recreation.

    expect((await ChatPreviewStore.load(scope)).isEmpty, isTrue);
    expect(
      (await ChatPreviewStore.load(neighboring)).messages.single['content'],
      'keep 2',
    );
  });
}
