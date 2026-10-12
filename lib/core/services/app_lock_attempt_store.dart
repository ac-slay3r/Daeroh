import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_policy.dart';

/// Must share the first-initialization policy with every other consumer.
const appLockSecureStorage = sharedSecureStorage;

/// Android reserves guesses in a separate Keystore-encrypted, commit-checked
/// record. Other platforms and explicitly injected test storage keep the secure
/// storage adapter. No plaintext attempt state is written to preferences.
class AppLockAttemptStore {
  AppLockAttemptStore(this._legacy, {this.durableAndroid = false});

  static const windowKey = 'app_lock_attempt_window';
  static const cooldownKey = 'app_lock_cooldown_until';
  static const channel = MethodChannel('hermes/app_lock_attempts');

  final FlutterSecureStorage _legacy;
  final bool durableAndroid;
  Future<void>? _ready;

  Future<void> _initialize() async {
    final initialized = await channel.invokeMethod<bool>('isInitialized');
    if (initialized != false) {
      // Null is a broken native contract, not evidence of a fresh install.
      if (initialized != true) {
        throw StateError('App-lock storage initialization unavailable');
      }
      return;
    }
    final values = <String, String>{};
    for (final key in [windowKey, cooldownKey]) {
      final value = await _legacy.read(key: key);
      if (value != null) values[key] = value;
    }
    await _commit('initialize', {'values': values});
    // Retain the old encrypted values: an interrupted migration is repeatable.
    // Once initialized, native storage is authoritative even when empty. Never
    // reimport these stale keys after success, expiry or biometric reset.
  }

  Future<void> _commit(String method, Map<String, Object?> arguments) async {
    if (await channel.invokeMethod<bool>(method, arguments) != true) {
      throw StateError('App-lock disk commit was not acknowledged');
    }
  }

  Future<String?> read({required String key}) async {
    if (!durableAndroid) return _legacy.read(key: key);
    await (_ready ??= _initialize());
    return channel.invokeMethod<String>('read', {'key': key});
  }

  Future<void> write({required String key, required String value}) async {
    if (!durableAndroid) return _legacy.write(key: key, value: value);
    await (_ready ??= _initialize());
    await _commit('write', {'key': key, 'value': value});
  }

  Future<void> delete({required String key}) async {
    if (!durableAndroid) return _legacy.delete(key: key);
    await (_ready ??= _initialize());
    await _commit('delete', {'key': key});
  }
}
