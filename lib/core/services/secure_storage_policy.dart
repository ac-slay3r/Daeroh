import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One policy for every app-owned consumer of the shared encrypted store.
///
/// Android flutter_secure_storage 10.3.1 caches the FIRST configuration by
/// preferences name. Setting this only on app-lock is too late when startup,
/// a background engine, or another service has already touched the store.
/// Never silently delete unreadable security state or other consumers' keys.
/// Keep the default namespace, key prefix, ciphers and migration options so
/// existing encrypted credentials remain accessible; only recovery changes.
const sharedSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false),
);
