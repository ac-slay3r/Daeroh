import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_attempt_store.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/secure_storage_policy.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Biometrics extends LocalAuthentication {
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async => true;
}

/// Host channel model, NOT Android runtime or disk durability evidence. Exercises
/// the production Dart adapter, including real secure-storage option encoding.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SharedPreferences prefs;
  late Map<String, String> legacy;
  Map<String, String>? disk;
  String? corruptLegacy;
  String? failedOperation;
  bool corruptNative = false;
  bool? commitReply = true;
  Completer<void>? commitGate;
  Completer<void>? commitStarted;
  var loseReplyAfterCommit = false;
  late List<MethodCall> calls;
  late List<MethodCall> secureCalls;
  // 10.3.1 caches config by preferences name; initialize does not replace it.
  bool? cachedResetOnError;

  AppLockService restart() => AppLockService(prefs, localAuth: _Biometrics());
  String window(int count) => jsonEncode({'attempts': count, 'until': null});

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    prefs = await SharedPreferences.getInstance();
    legacy = {
      'app_lock_pin_salt': 'legacy-salt',
      'app_lock_pin_hash': sha256
          .convert(utf8.encode('legacy-salt1234'))
          .toString(),
    };
    disk = null;
    corruptLegacy = null;
    failedOperation = null;
    corruptNative = false;
    commitReply = true;
    commitGate = null;
    commitStarted = null;
    loseReplyAfterCommit = false;
    calls = [];
    secureCalls = [];
    cachedResetOnError = null;
    messenger.setMockMethodCallHandler(secure, (call) async {
      secureCalls.add(call);
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final options = Map<String, dynamic>.from(arguments['options'] as Map);
      cachedResetOnError ??= options['resetOnError'] == 'true';
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          if (key == corruptLegacy) {
            if (!cachedResetOnError!) {
              throw PlatformException(code: 'decrypt_failed');
            }
            legacy.remove(key);
          }
          return legacy[key];
        case 'write':
          legacy[key] = arguments['value'] as String;
          return null;
        case 'delete':
          legacy.remove(key);
          return null;
        default:
          throw StateError('Unexpected secure-storage call: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(AppLockAttemptStore.channel, (
      call,
    ) async {
      calls.add(call);
      if (corruptNative || call.method == failedOperation) {
        throw PlatformException(code: 'app_lock_storage');
      }
      final args = call.arguments == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(call.arguments as Map);
      if (call.method == 'isInitialized') return disk != null;
      if (call.method == 'read') return disk![args['key']];
      commitStarted?.complete();
      commitStarted = null;
      await commitGate?.future;
      if (commitReply != true) return commitReply;
      switch (call.method) {
        case 'initialize':
          disk ??= Map<String, String>.from(args['values'] as Map);
        case 'write':
          disk![args['key'] as String] = args['value'] as String;
        case 'delete':
          disk!.remove(args['key']);
        default:
          throw StateError('Unexpected native call: ${call.method}');
      }
      if (loseReplyAfterCommit) {
        loseReplyAfterCommit = false;
        throw PlatformException(code: 'process_death_after_commit');
      }
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(AppLockAttemptStore.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('all app-owned constructors share one native initialization policy', () {
    final constructors = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (RegExp(
        r'\bFlutterSecureStorage\s*\(',
      ).hasMatch(file.readAsStringSync())) {
        constructors.add(file.path);
      }
    }
    expect(constructors, ['lib/core/services/secure_storage_policy.dart']);
    final defaults = const AndroidOptions().toMap();
    final actual = sharedSecureStorage.aOptions.toMap();
    expect(
      actual,
      {...defaults, 'resetOnError': 'false'},
      reason: 'Do not change namespace, prefix, ciphers or migration settings',
    );
    expect(appLockSecureStorage, same(sharedSecureStorage));
  });

  test(
    'API credentials first preserve corrupt budget and unrelated keys',
    () async {
      legacy['api_key_fixture'] = 'synthetic-credential';
      legacy[AppLockAttemptStore.windowKey] = 'unreadable ciphertext';
      corruptLegacy = AppLockAttemptStore.windowKey;
      final before = Map<String, String>.from(legacy);
      expect(
        await SecureStorage().readApiKey('fixture'),
        'synthetic-credential',
      );
      expect(await restart().verifyPin('1234'), isFalse);
      expect(legacy, before);
      expect(disk, isNull);
    },
  );

  test(
    'app-lock first does not reset an unreadable unrelated credential',
    () async {
      expect(await restart().verifyPin('0000'), isFalse);
      legacy['api_key_fixture'] = 'unreadable ciphertext';
      corruptLegacy = 'api_key_fixture';
      await expectLater(
        SecureStorage().readApiKey('fixture'),
        throwsA(isA<PlatformException>()),
      );
      expect(legacy['api_key_fixture'], 'unreadable ciphertext');
      expect(jsonDecode(disk![AppLockAttemptStore.windowKey]!)['attempts'], 1);
    },
  );

  test('configured adapter propagates unreadable legacy ciphertext', () async {
    legacy[AppLockAttemptStore.windowKey] = 'unreadable ciphertext';
    corruptLegacy = AppLockAttemptStore.windowKey;
    expect(await restart().verifyPin('1234'), isFalse);
    expect(disk, isNull);
    expect(legacy[AppLockAttemptStore.windowKey], 'unreadable ciphertext');
    expect(calls.map((c) => c.method), ['isInitialized']);
    expect(secureCalls, isNotEmpty);
  });

  for (final key in [
    AppLockAttemptStore.windowKey,
    AppLockAttemptStore.cooldownKey,
  ]) {
    test(
      'default startup read first retains corrupt $key across restart',
      () async {
        legacy[key] = 'unreadable ciphertext';
        corruptLegacy = key;
        // Actual main.dart startup factory, with no injected/configured storage.
        await CancelledTurnTombstoneStore.secure().initialize();
        expect(await restart().verifyPin('1234'), isFalse);
        expect(await restart().verifyPin('1234'), isFalse);
        expect(cachedResetOnError, isFalse);
        expect(disk, isNull);
        expect(legacy[key], 'unreadable ciphertext');
        expect(secureCalls.where((call) => call.method == 'write'), isEmpty);
      },
    );
  }

  test(
    'four legacy misses migrate once and fifth miss survives restart',
    () async {
      legacy[AppLockAttemptStore.windowKey] = window(4);
      final service = restart();
      expect(await service.verifyPin('0000'), isFalse);
      expect(service.cooldownRemaining, greaterThan(0));
      expect(await restart().verifyPin('1234'), isFalse);
      expect(calls.where((c) => c.method == 'initialize').length, 1);
      expect(legacy[AppLockAttemptStore.windowKey], window(4));
    },
  );

  test('native budget survives a fresh service after every miss', () async {
    for (var miss = 1; miss <= 5; miss++) {
      expect(await restart().verifyPin('0000'), isFalse);
      final saved = jsonDecode(disk![AppLockAttemptStore.windowKey]!);
      expect(saved['attempts'], miss == 5 ? 0 : miss);
      expect(saved['until'] != null, miss == 5);
    }
    expect(await restart().verifyPin('1234'), isFalse);
  });

  test('lost migration reply cannot cause stale reimport', () async {
    legacy[AppLockAttemptStore.windowKey] = window(4);
    loseReplyAfterCommit = true;
    expect(await restart().verifyPin('1234'), isFalse);
    final service = restart();
    expect(await service.verifyPin('0000'), isFalse);
    expect(service.cooldownRemaining, greaterThan(0));
    expect(calls.where((c) => c.method == 'initialize').length, 1);
  });

  test(
    'native reservation exception refuses comparison across restart',
    () async {
      disk = {AppLockAttemptStore.windowKey: window(4)};
      failedOperation = 'write';
      expect(await restart().verifyPin('1234'), isFalse);
      expect(await restart().verifyPin('1234'), isFalse);
      expect(disk![AppLockAttemptStore.windowKey], window(4));
      expect(secureCalls.where((c) => c.method == 'write'), isEmpty);
    },
  );

  test('legacy cooldown is imported without shortening it', () async {
    legacy[AppLockAttemptStore.cooldownKey] = DateTime.now()
        .add(const Duration(seconds: 30))
        .toIso8601String();
    final service = restart();
    expect(await service.verifyPin('1234'), isFalse);
    expect(service.cooldownRemaining, greaterThan(0));
    expect(disk![AppLockAttemptStore.cooldownKey], isNull);
    expect(disk![AppLockAttemptStore.windowKey], isNotNull);
  });

  for (final reply in [false, null]) {
    test('unacknowledged migration ($reply) never grants guesses', () async {
      commitReply = reply;
      expect(await restart().verifyPin('1234'), isFalse);
      expect(await restart().verifyPin('1234'), isFalse);
      expect(disk, isNull);
    });
    test(
      'unacknowledged reservation ($reply) prevents PIN comparison',
      () async {
        disk = {AppLockAttemptStore.windowKey: window(4)};
        commitReply = reply;
        expect(await restart().verifyPin('1234'), isFalse);
        expect(disk![AppLockAttemptStore.windowKey], window(4));
        // A correct legacy PIN would write its upgraded salt/hash if compared.
        expect(secureCalls.where((c) => c.method == 'write'), isEmpty);
      },
    );
  }

  test('no comparison or success before disk acknowledgement', () async {
    disk = {AppLockAttemptStore.windowKey: window(4)};
    commitGate = Completer<void>();
    commitStarted = Completer<void>();
    final started = commitStarted!.future;
    var finished = false;
    final verification = restart().verifyPin('1234').then((value) {
      finished = true;
      return value;
    });
    await started;
    expect(finished, isFalse);
    expect(secureCalls.where((c) => c.method == 'write'), isEmpty);
    expect(disk![AppLockAttemptStore.windowKey], window(4));
    commitGate!.complete();
    expect(await verification, isTrue);
  });

  test(
    'process loss after reservation commit cannot give a sixth guess',
    () async {
      disk = {AppLockAttemptStore.windowKey: window(4)};
      loseReplyAfterCommit = true;
      expect(await restart().verifyPin('1234'), isFalse);
      expect(await restart().verifyPin('1234'), isFalse);
      expect(secureCalls.where((c) => c.method == 'write'), isEmpty);
    },
  );

  test(
    'native read/ciphertext failure never falls back to stale legacy',
    () async {
      disk = {AppLockAttemptStore.windowKey: window(4)};
      corruptNative = true;
      expect(await restart().verifyPin('1234'), isFalse);
      expect(secureCalls, isEmpty);
    },
  );

  test(
    'success leaves initialized empty record and never reimports old misses',
    () async {
      legacy[AppLockAttemptStore.windowKey] = window(4);
      expect(await restart().verifyPin('1234'), isTrue);
      expect(disk, isEmpty);
      expect(await restart().verifyPin('0000'), isFalse);
      expect(jsonDecode(disk![AppLockAttemptStore.windowKey]!)['attempts'], 1);
      expect(calls.where((c) => c.method == 'initialize').length, 1);
    },
  );

  test('expired native cooldown resets durably without reimport', () async {
    legacy[AppLockAttemptStore.windowKey] = window(4);
    disk = {
      AppLockAttemptStore.windowKey: jsonEncode({
        'attempts': 0,
        'until': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      }),
    };
    expect(await restart().verifyPin('0000'), isFalse);
    expect(jsonDecode(disk![AppLockAttemptStore.windowKey]!)['attempts'], 1);
    expect(calls.where((c) => c.method == 'initialize'), isEmpty);
  });

  test(
    'failed native cleanup refuses successful PIN and biometric unlock',
    () async {
      disk = {AppLockAttemptStore.windowKey: window(3)};
      failedOperation = 'delete';
      final service = restart();
      expect(await service.verifyPin('1234'), isFalse);
      expect(await service.authenticateBiometric(reason: 'test'), isFalse);
      expect(service.locked.value, isTrue);
    },
  );

  test('biometric success resets native cooldown across restart', () async {
    legacy[AppLockAttemptStore.windowKey] = window(4);
    final service = restart();
    expect(await service.verifyPin('0000'), isFalse);
    expect(await service.authenticateBiometric(reason: 'test'), isTrue);
    expect(disk, isEmpty);
    expect(await restart().verifyPin('0000'), isFalse);
    expect(jsonDecode(disk![AppLockAttemptStore.windowKey]!)['attempts'], 1);
  });

  test(
    'native source contract uses checked commit, encryption and registered channel',
    () {
      const root = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';
      final adapter = File('$root/AppLockAttempts.kt').readAsStringSync();
      final boundary = File(
        '$root/CommittedAppLockRecord.kt',
      ).readAsStringSync();
      final activity = File('$root/MainActivity.kt').readAsStringSync();
      expect(
        adapter,
        contains('prefs.edit().putString(RECORD, encrypted).commit()'),
      );
      expect(adapter, contains('Cipher.getInstance("AES/GCM/NoPadding")'));
      expect(adapter, contains('KeyStore.getInstance("AndroidKeyStore")'));
      expect(adapter, contains('check(!keyStore.containsAlias(ALIAS))'));
      expect(adapter, isNot(contains('prefs.edit().clear()')));
      expect(boundary, contains('check(commitEncrypted(encrypt(value)))'));
      expect(boundary, contains('failed = true'));
      expect(activity, contains('AppLockAttempts.attach(applicationContext,'));
    },
  );
}
