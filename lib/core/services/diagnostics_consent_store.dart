import 'package:shared_preferences/shared_preferences.dart';

import 'reliability_diagnostics.dart';

/// Explicit, device-local consent for sending sanitized reliability telemetry.
///
/// The default is fail-closed: no telemetry transport may send data until the
/// person using this installation opts in. The preference contains no account,
/// endpoint, or diagnostic data and is intentionally global to this app.
final class DiagnosticsConsentStore {
  static const String preferenceKey = 'diagnostics.remote_opt_in';

  const DiagnosticsConsentStore(this._prefs);

  final SharedPreferences _prefs;

  bool get enabled => _prefs.getBool(preferenceKey) ?? false;

  /// Restores diagnostics only when this build has a collector configured.
  ///
  /// Full and Play builds share app preferences. A prior opt-in must not make
  /// a build with no diagnostics DSN fail during startup or retain a dormant
  /// consent that could be reactivated by a later build.
  Future<void> startReliabilityDiagnostics() async {
    if (!ReliabilityDiagnostics.isAvailable && enabled) {
      await setEnabled(false);
      return;
    }
    await ReliabilityDiagnostics.updateConsent(enabled);
  }

  /// Persists the user's choice before a transport can observe the new state.
  Future<void> setEnabled(bool value) async {
    final written = await _prefs.setBool(preferenceKey, value);
    if (!written) {
      throw StateError('Could not persist diagnostics consent');
    }
    try {
      await ReliabilityDiagnostics.updateConsent(value);
    } catch (_) {
      // A build without a collector must remain fail-closed rather than leave
      // an opt-in visible that cannot send to the promised destination.
      await _prefs.setBool(preferenceKey, false);
      rethrow;
    }
  }
}
