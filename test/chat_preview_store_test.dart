import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_preview_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secure = <String, String>{};
  String? delayedWriteKey;
  Completer<void>? heldRead;
  Completer<void>? readStarted;
  var failWrites = false;

  setUp(() {
    secure.clear();
    delayedWriteKey = null;
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

    await ChatPreviewStore.clear(scope);
    release.complete();

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
}
