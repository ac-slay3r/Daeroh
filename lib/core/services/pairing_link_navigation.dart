import 'package:flutter/material.dart';

import 'app_lock.dart';
import 'pairing_link.dart';
import 'pairing_link_delivery_gate.dart';

/// Routes valid pairing links only when the root navigator is available and
/// App Lock is released. Both initial-link and stream deliveries use [handle].
final class PairingLinkNavigation {
  PairingLinkNavigation({
    required this.lock,
    required this.navigatorKey,
    required this.routeForLink,
  }) {
    lock.locked.addListener(_onLockChanged);
  }

  final AppLockService lock;
  final GlobalKey<NavigatorState> navigatorKey;
  final Route<void> Function(PairingLink) routeForLink;
  final PairingLinkDeliveryGate _delivery = PairingLinkDeliveryGate();
  bool _retryScheduled = false;
  bool _disposed = false;

  void handle(Uri uri) {
    if (_disposed || PairingLink.tryParse(uri.toString()) == null) return;
    // Never accept (or mark as handled) a URI while locked or before the
    // navigator exists. The queued URI survives both conditions.
    if (lock.locked.value ||
        navigatorKey.currentState == null ||
        _delivery.hasDeferred) {
      _delivery.defer(uri);
      if (!lock.locked.value) _scheduleDrain();
      return;
    }
    _open(uri);
  }

  void _open(Uri uri) {
    final nav = navigatorKey.currentState;
    if (_disposed || lock.locked.value || nav == null) {
      _delivery.defer(uri);
      if (!_disposed && !lock.locked.value) _scheduleDrain();
      return;
    }
    if (!_delivery.shouldHandle(uri)) return;
    final link = PairingLink.tryParse(uri.toString());
    if (link != null) nav.push(routeForLink(link));
  }

  void _onLockChanged() {
    if (!lock.locked.value) _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_disposed || _retryScheduled || !_delivery.hasDeferred) return;
    _retryScheduled = true;
    // The lock gate removes its route synchronously on unlock; waiting a frame
    // also handles listeners firing before that gate's listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryScheduled = false;
      if (_disposed || lock.locked.value) return;
      final pending = _delivery.takeDeferredIf(
        navigatorKey.currentState != null,
      );
      if (pending != null) _open(pending);
      if (_delivery.hasDeferred) _scheduleDrain();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void dispose() {
    _disposed = true;
    lock.locked.removeListener(_onLockChanged);
  }
}
