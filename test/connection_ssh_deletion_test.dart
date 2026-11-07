import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const sshFields = [
    'user',
    'host',
    'port',
    'method',
    'password',
    'privkey',
    'passphrase',
    'hostkey',
  ];
  final values = <String, String>{};
  String? failingDeleteKey;
  String? failingReadKey;
  late SharedPreferences prefs;
  late ConnectionManager manager;
  late String id;
  var cancelledTurnCleanups = 0;
  final secure = SecureStorage();

  Future<void> seedSsh(String connectionId) async {
    for (final field in sshFields) {
      await secure.writeSsh(connectionId, field, 'fixture-$field');
    }
  }

  setUp(() async {
    values.clear();
    failingDeleteKey = null;
    failingReadKey = null;
    cancelledTurnCleanups = 0;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              if (key == failingReadKey) {
                throw PlatformException(code: 'test-read-failure');
              }
              return values[key];
            case 'readAll':
              return Map<String, String>.of(values);
            case 'write':
              values[key!] = args['value'] as String;
            case 'delete':
              if (key == failingDeleteKey) {
                throw PlatformException(code: 'test-delete-failure');
              }
              values.remove(key);
          }
          return null;
        });
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    manager = await ConnectionManager.create(
      prefs,
      clearCancelledTurns: (_) async {
        cancelledTurnCleanups++;
        return 0;
      },
    );
    await manager.saveConnection('fixture', '127.0.0.1', 9119, 'fixture-api');
    id = manager.getConnections().single.id;
    await manager.setDefaultConnection(id);
    await seedSsh(id);
    await seedSsh('$id-other');
    for (final field in ['token', 'user', 'pass']) {
      await secure.writeDashboardSecret(id, field, 'fixture-dashboard');
      await secure.writeDashboardSecret('$id-other', field, 'other-dashboard');
    }
    for (final field in ['url', 'token']) {
      await secure.writeBridge(id, field, 'fixture-bridge');
      await secure.writeBridge('$id-other', field, 'other-bridge');
    }
    for (final field in sshFields) {
      expect(values['ssh_${field}_$id'], 'fixture-$field');
    }
  });

  tearDown(() {
    manager.dispose();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void expectSshPurged({String? except}) {
    for (final field in sshFields) {
      final key = 'ssh_${field}_$id';
      expect(values.containsKey(key), key == except, reason: key);
      expect(values['ssh_${field}_$id-other'], 'fixture-$field');
    }
  }

  test(
    'deleting a connection purges its SSH secrets and host trust only',
    () async {
      await manager.deleteConnection(id);

      expectSshPurged();
      expect(values.containsKey('api_key_$id'), isFalse);
      expect(values.containsKey('dash_token_$id'), isFalse);
      expect(values.containsKey('bridge_token_$id'), isFalse);
      expect(manager.getConnections(), isEmpty);
      expect(prefs.getStringList('saved_connections'), isEmpty);
      expect(prefs.containsKey(ConnectionManager.defaultConnKey), isFalse);
      expect(cancelledTurnCleanups, 1);
    },
  );

  test('recovery store failure does not skip SSH cleanup', () async {
    failingReadKey = 'chat_turn_outbox_v1';

    await manager.deleteConnection(id);

    expectSshPurged();
    expect(manager.getConnections(), isEmpty);
  });

  for (final field in ['password', 'privkey', 'hostkey']) {
    test(
      'SSH $field deletion failure is surfaced and can be retried',
      () async {
        failingDeleteKey = 'ssh_${field}_$id';
        final savedConnections = prefs.getStringList('saved_connections');

        await expectLater(
          manager.deleteConnection(id),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'test-delete-failure',
            ),
          ),
        );

        expectSshPurged(except: failingDeleteKey);
        expect(prefs.getStringList('saved_connections'), savedConnections);
        expect(manager.getConnections().single.id, id);
        expect(prefs.getString(ConnectionManager.defaultConnKey), id);
        expect(cancelledTurnCleanups, 0);
        expect(values.containsKey('api_key_$id'), isFalse);
        expect(values.containsKey('dash_token_$id'), isFalse);
        expect(values.containsKey('bridge_token_$id'), isFalse);

        failingDeleteKey = null;
        await manager.deleteConnection(id);
        expectSshPurged();
        expect(manager.getConnections(), isEmpty);
        expect(cancelledTurnCleanups, 1);
      },
    );
  }

  for (final prefix in [
    'api_key',
    'dash_token',
    'dash_user',
    'dash_pass',
    'bridge_url',
    'bridge_token',
  ]) {
    test(
      '$prefix deletion failure still purges SSH and retains connection',
      () async {
        failingDeleteKey = '${prefix}_$id';

        await expectLater(
          manager.deleteConnection(id),
          throwsA(isA<PlatformException>()),
        );

        expectSshPurged();
        expect(values.containsKey(failingDeleteKey), isTrue);
        for (final keyPrefix in [
          'api_key',
          'dash_token',
          'dash_user',
          'dash_pass',
          'bridge_url',
          'bridge_token',
        ]) {
          expect(values.containsKey('${keyPrefix}_$id'), keyPrefix == prefix);
        }
        for (final field in ['token', 'user', 'pass']) {
          expect(values['dash_${field}_$id-other'], 'other-dashboard');
        }
        for (final field in ['url', 'token']) {
          expect(values['bridge_${field}_$id-other'], 'other-bridge');
        }
        expect(manager.getConnections().single.id, id);
        expect(prefs.getString(ConnectionManager.defaultConnKey), id);
        expect(cancelledTurnCleanups, 0);
        failingDeleteKey = null;
        await manager.deleteConnection(id);
        expect(manager.getConnections(), isEmpty);
        expectSshPurged();
      },
    );
  }
}
