import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/voice/voice_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceSettings', () {
    test('sin preferencias guardadas usa los motores públicos', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final settings = VoiceSettings.load(prefs);

      expect(settings.sttEngine, SttEngineKind.sherpaLive);
      expect(settings.ttsEngine, TtsEngineKind.onnx);
      expect(settings.autoSpeak, isFalse);
      expect(settings.bargeInEnabled, isFalse);
      expect(settings.serverSttUrl, isEmpty);
      expect(settings.allowLegacyQueryTokenFallback, isFalse);
      expect(settings.kokoroTtsUrl, isEmpty);
      expect(settings.openAiTtsUrl, isEmpty);
      expect(settings.customTtsUrl, isEmpty);
      expect(
        settings.readAloudStopBehavior,
        ReadAloudStopBehavior.pauseAndResume,
      );
    });

    test('las preferencias de los experimentos retirados se ignoran', () async {
      SharedPreferences.setMockInitialValues({
        'voice_filler_enabled': true,
        'voice_model': 'gemma4:e4b',
        'voice_fast_mode': true,
        'voice_reasoning': 'medium',
        'voice_talker_first': true,
        'voice_hands_free_auto': true,
        'voice_full_duplex': true,
        'voice_engine_v2': true,
        'voice_barge_in_enabled': true,
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = VoiceSettings.load(prefs);

      expect(settings.sttEngine, SttEngineKind.sherpaLive);
      expect(settings.ttsEngine, TtsEngineKind.onnx);
      expect(settings.autoSpeak, isFalse);
      expect(
        settings.bargeInEnabled,
        isFalse,
        reason: 'una preferencia experimental antigua no debe reactivarlo',
      );
    });

    test('los ajustes públicos hacen round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const original = VoiceSettings(
        sttEngine: SttEngineKind.whisper,
        ttsEngine: TtsEngineKind.elevenlabs,
        autoSpeak: true,
        bargeInEnabled: true,
        readAloudStopBehavior: ReadAloudStopBehavior.stopAndRestart,
        elevenVoiceId: 'voiceX',
      );

      await original.save(prefs);
      final loaded = VoiceSettings.load(prefs);

      expect(loaded.sttEngine, SttEngineKind.whisper);
      expect(loaded.ttsEngine, TtsEngineKind.elevenlabs);
      expect(loaded.autoSpeak, isTrue);
      expect(loaded.bargeInEnabled, isTrue);
      expect(prefs.getBool('voice_barge_in_enabled_v2'), isTrue);
      expect(
        loaded.readAloudStopBehavior,
        ReadAloudStopBehavior.stopAndRestart,
      );
      expect(loaded.elevenVoiceId, 'voiceX');
    });

    test(
      'el fallback query-token legacy requiere consentimiento explícito',
      () async {
        SharedPreferences.setMockInitialValues({
          'voice_server_stt_url': 'ws://192.168.1.20:9123',
        });
        final prefs = await SharedPreferences.getInstance();
        expect(
          VoiceSettings.load(prefs).allowLegacyQueryTokenFallback,
          isFalse,
        );

        await const VoiceSettings(
          allowLegacyQueryTokenFallback: true,
        ).save(prefs);
        expect(VoiceSettings.load(prefs).allowLegacyQueryTokenFallback, isTrue);
      },
    );

    test(
      'una URL STT con token heredado se borra antes de volver a guardarse',
      () async {
        const unsafe = 'ws://192.168.1.20:9123?token=old-token';
        SharedPreferences.setMockInitialValues({'voice_server_stt_url': unsafe});
        final prefs = await SharedPreferences.getInstance();

        final loaded = VoiceSettings.load(prefs);
        expect(loaded.serverSttUrl, isEmpty);

        await loaded
            .copyWith(allowLegacyQueryTokenFallback: true)
            .save(prefs);
        expect(prefs.getString('voice_server_stt_url'), isEmpty);
      },
    );

    test(
      'dictado Hermes y servidor STT personalizado no se confunden',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        await const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ).save(prefs);
        expect(VoiceSettings.load(prefs).sttEngine, SttEngineKind.hermesServer);

        await const VoiceSettings(
          sttEngine: SttEngineKind.server,
          serverSttUrl: 'ws://192.168.1.20:9123',
        ).save(prefs);
        final custom = VoiceSettings.load(prefs);
        expect(custom.sttEngine, SttEngineKind.server);
        expect(custom.serverSttUrl, 'ws://192.168.1.20:9123');
      },
    );
  });
}
