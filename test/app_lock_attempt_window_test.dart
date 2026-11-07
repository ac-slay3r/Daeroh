import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';

class _FaultStorage extends FlutterSecureStorage {
  String? failRead;
  String? failWrite;
  String? failDelete;
  Completer<void>? writeGate;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failRead) throw StateError('read unavailable');
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failWrite) throw StateError('write unavailable');
    if (key == 'app_lock_attempt_window') await writeGate?.future;
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failDelete) throw StateError('delete unavailable');
    await super.delete(key: key);
  }
}

class _Biometrics extends LocalAuthentication {
  bool result = true;
  bool throws = false;
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    if (throws) throw StateError('biometrics unavailable');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FlutterSecureStorage storage;

  Future<AppLockService> restart() async =>
      AppLockService(prefs, storage: storage);

  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = const FlutterSecureStorage();
  });

  test(
    'four failed PINs survive restart; the next miss starts cooldown',
    () async {
      final first = await restart();
      await first.setPin('1234');
      for (var i = 0; i < 4; i++) {
        expect(await first.verifyPin('0000'), isFalse);
        expect(first.cooldownRemaining, 0);
      }
      final saved = jsonDecode(
        (await storage.read(key: 'app_lock_attempt_window'))!,
      );
      expect(saved['attempts'], 4);

      final second = await restart();
      expect(await second.verifyPin('0000'), isFalse);
      expect(second.cooldownRemaining, greaterThan(0));
      expect(await second.verifyPin('1234'), isFalse);

      final third = await restart();
      expect(await third.verifyPin('1234'), isFalse);
      expect(third.cooldownRemaining, greaterThan(0));
    },
  );

  test('successful PIN clears partial failures even after restart', () async {
    final first = await restart();
    await first.setPin('1234');
    for (var i = 0; i < 4; i++) {
      expect(await first.verifyPin('0000'), isFalse);
    }
    final second = await restart();
    expect(await second.verifyPin('1234'), isTrue);
    expect(await storage.read(key: 'app_lock_attempt_window'), isNull);
    final third = await restart();
    expect(await third.verifyPin('0000'), isFalse);
    expect(third.cooldownRemaining, 0);
  });

  test(
    'expired cooldown clears the window and grants a fresh budget',
    () async {
      final first = await restart();
      await first.setPin('1234');
      await storage.write(
        key: 'app_lock_attempt_window',
        value: jsonEncode({
          'attempts': 0,
          'until': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toIso8601String(),
        }),
      );
      final second = await restart();
      expect(await second.verifyPin('0000'), isFalse);
      expect(second.cooldownRemaining, 0);
      expect(
        jsonDecode(
          (await storage.read(key: 'app_lock_attempt_window'))!,
        )['attempts'],
        1,
      );
    },
  );

  test('old persisted cooldown is honored on restart', () async {
    final first = await restart();
    await first.setPin('1234');
    await storage.write(
      key: 'app_lock_cooldown_until',
      value: DateTime.now().add(const Duration(seconds: 30)).toIso8601String(),
    );
    final second = await restart();
    expect(await second.verifyPin('1234'), isFalse);
    expect(second.cooldownRemaining, greaterThan(0));
  });

  test('unreadable attempt window does not grant a new PIN budget', () async {
    final first = await restart();
    await first.setPin('1234');
    await storage.write(key: 'app_lock_attempt_window', value: 'corrupt');
    final second = await restart();
    expect(await second.verifyPin('1234'), isFalse);
  });

  test('restart after every miss cannot replenish the budget', () async {
    await (await restart()).setPin('1234');
    for (var i = 1; i <= 5; i++) {
      final service = await restart();
      expect(await service.verifyPin('0000'), isFalse);
      final saved = jsonDecode(
        (await storage.read(key: 'app_lock_attempt_window'))!,
      );
      expect(saved['attempts'], i == 5 ? 0 : i);
      expect(saved['until'] != null, i == 5);
    }
    expect(await (await restart()).verifyPin('1234'), isFalse);
  });

  for (final key in [
    'app_lock_attempt_window',
    'app_lock_cooldown_until',
    'app_lock_pin_salt',
    'app_lock_pin_hash',
  ]) {
    test('read failure for $key refuses PIN and remains closed', () async {
      await (await restart()).setPin('1234');
      final faults = _FaultStorage()..failRead = key;
      final service = AppLockService(prefs, storage: faults);
      expect(await service.verifyPin('1234'), isFalse);
      faults.failRead = null;
      expect(await service.verifyPin('1234'), isFalse);
      expect(service.locked.value, isTrue);
    });
  }

  test(
    'reservation write failure refuses even correct PIN across restart',
    () async {
      await (await restart()).setPin('1234');
      final faults = _FaultStorage()..failWrite = 'app_lock_attempt_window';
      for (var i = 0; i < 2; i++) {
        final service = AppLockService(prefs, storage: faults);
        expect(await service.verifyPin('1234'), isFalse);
        expect(service.locked.value, isTrue);
      }
      faults.failWrite = null;
      final service = AppLockService(prefs, storage: faults);
      expect(await service.verifyPin('0000'), isFalse);
      expect(
        jsonDecode(
          (await storage.read(key: 'app_lock_attempt_window'))!,
        )['attempts'],
        1,
      );
    },
  );

  for (final key in ['app_lock_attempt_window', 'app_lock_cooldown_until']) {
    test('PIN cleanup failure for $key cannot unlock', () async {
      await (await restart()).setPin('1234');
      final faults = _FaultStorage()..failDelete = key;
      final service = AppLockService(prefs, storage: faults);
      expect(await service.verifyPin('1234'), isFalse);
      faults.failDelete = null;
      expect(await service.verifyPin('1234'), isFalse);
      expect(service.locked.value, isTrue);
    });
  }

  test('expiry cleanup failure does not grant fresh attempts', () async {
    await (await restart()).setPin('1234');
    await storage.write(
      key: 'app_lock_attempt_window',
      value: jsonEncode({
        'attempts': 0,
        'until': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      }),
    );
    final faults = _FaultStorage()..failDelete = 'app_lock_attempt_window';
    expect(
      await AppLockService(prefs, storage: faults).verifyPin('1234'),
      isFalse,
    );
  });

  test(
    'overlapping PIN and biometric calls cannot overwrite reservations',
    () async {
      final faults = _FaultStorage();
      final service = AppLockService(
        prefs,
        storage: faults,
        localAuth: _Biometrics(),
      );
      await service.setPin('1234');
      faults.writeGate = Completer<void>();
      final first = service.verifyPin('0000');
      expect(await service.verifyPin('1234'), isFalse);
      expect(await service.authenticateBiometric(reason: 'test'), isFalse);
      faults.writeGate!.complete();
      expect(await first, isFalse);
      expect(
        jsonDecode(
          (await storage.read(key: 'app_lock_attempt_window'))!,
        )['attempts'],
        1,
      );
    },
  );

  test(
    'biometric success clears persisted cooldown; cancellation does not',
    () async {
      final auth = _Biometrics()..result = false;
      final service = AppLockService(prefs, storage: storage, localAuth: auth);
      await service.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await service.verifyPin('0000');
      }
      expect(await service.authenticateBiometric(reason: 'test'), isFalse);
      expect(await (await restart()).verifyPin('1234'), isFalse);
      auth.result = true;
      expect(await service.authenticateBiometric(reason: 'test'), isTrue);
      expect(service.authInProgress, isFalse);
      expect(await storage.read(key: 'app_lock_attempt_window'), isNull);
      expect(await (await restart()).verifyPin('1234'), isTrue);
    },
  );

  test(
    'biometric cleanup failure refuses unlock and keeps PIN closed',
    () async {
      final faults = _FaultStorage();
      final service = AppLockService(
        prefs,
        storage: faults,
        localAuth: _Biometrics(),
      );
      await service.setPin('1234');
      await service.verifyPin('0000');
      faults.failDelete = 'app_lock_attempt_window';
      expect(await service.authenticateBiometric(reason: 'test'), isFalse);
      expect(service.authInProgress, isFalse);
      expect(service.locked.value, isTrue);
      faults.failDelete = null;
      expect(await service.verifyPin('1234'), isFalse);
    },
  );

  test('biometric plugin error leaves PIN fallback available', () async {
    final service = AppLockService(
      prefs,
      storage: storage,
      localAuth: _Biometrics()..throws = true,
    );
    await service.setPin('1234');
    expect(await service.authenticateBiometric(reason: 'test'), isFalse);
    expect(await service.verifyPin('1234'), isTrue);
  });

  test('legacy migration never shortens a newer cooldown', () async {
    await (await restart()).setPin('1234');
    final later = DateTime.now().add(const Duration(seconds: 30));
    await storage.write(
      key: 'app_lock_attempt_window',
      value: jsonEncode({'attempts': 0, 'until': later.toIso8601String()}),
    );
    await storage.write(
      key: 'app_lock_cooldown_until',
      value: DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
    );
    expect(await (await restart()).verifyPin('1234'), isFalse);
    expect(
      jsonDecode(
        (await storage.read(key: 'app_lock_attempt_window'))!,
      )['until'],
      later.toIso8601String(),
    );
    expect(await storage.read(key: 'app_lock_cooldown_until'), isNull);
  });

  test('failed legacy migration retains cooldown across restart', () async {
    await (await restart()).setPin('1234');
    await storage.write(
      key: 'app_lock_cooldown_until',
      value: DateTime.now().add(const Duration(seconds: 30)).toIso8601String(),
    );
    final faults = _FaultStorage()..failWrite = 'app_lock_attempt_window';
    expect(
      await AppLockService(prefs, storage: faults).verifyPin('1234'),
      isFalse,
    );
    expect(await storage.read(key: 'app_lock_cooldown_until'), isNotNull);
    expect(await (await restart()).verifyPin('1234'), isFalse);
  });

  test('valid fifth PIN is accepted and clears its reservation', () async {
    final service = await restart();
    await service.setPin('1234');
    for (var i = 0; i < 4; i++) {
      await service.verifyPin('0000');
    }
    expect(await (await restart()).verifyPin('1234'), isTrue);
    expect(await storage.read(key: 'app_lock_attempt_window'), isNull);
  });
}
