import 'package:shared_preferences/shared_preferences.dart';

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

  /// Persists the user's choice before a transport can observe the new state.
  Future<void> setEnabled(bool value) async {
    final written = await _prefs.setBool(preferenceKey, value);
    if (!written) {
      throw StateError('Could not persist diagnostics consent');
    }
  }
}
