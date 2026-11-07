import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/diagnostics_consent_store.dart';
import 'package:hermes_android/core/services/reliability_diagnostics.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('remote diagnostics are off by default and persist an explicit opt-in', () async {
    final prefs = await SharedPreferences.getInstance();
    final consent = DiagnosticsConsentStore(prefs);

    expect(consent.enabled, isFalse);

    await consent.setEnabled(true);
    expect(consent.enabled, isTrue);
    expect(
      prefs.getBool(DiagnosticsConsentStore.preferenceKey),
      isTrue,
    );

    await consent.setEnabled(false);
    expect(consent.enabled, isFalse);
    expect(
      prefs.getBool(DiagnosticsConsentStore.preferenceKey),
      isFalse,
    );
  });

  test('startup clears stale consent when diagnostics are unavailable', () async {
    SharedPreferences.setMockInitialValues({
      DiagnosticsConsentStore.preferenceKey: true,
    });
    final prefs = await SharedPreferences.getInstance();
    ReliabilityDiagnostics.configure(
      ReliabilityDiagnostics(config: const ReliabilityDiagnosticsConfig('')),
    );
    final consent = DiagnosticsConsentStore(prefs);

    await consent.startReliabilityDiagnostics();

    expect(consent.enabled, isFalse);
    expect(prefs.getBool(DiagnosticsConsentStore.preferenceKey), isFalse);
  });
}
