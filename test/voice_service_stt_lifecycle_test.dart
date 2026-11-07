// Tests del ciclo de vida del motor STT en VoiceService (FIX-1, TASK-022).
//
// El bug de estabilidad del modo voz era que checkStt() —llamado en CADA turno—
// destruía y reconstruía el motor STT (y con él un AudioRecord nativo + contexto
// whisper.cpp) en cada escucha, lo que provocaba fugas y cuelgues tras varias
// interacciones. Estos tests verifican el comportamiento corregido sin tocar
// hardware, inyectando un motor falso vía `debugSttFactory`.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_remote.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';

/// Motor STT falso: cuenta paradas y liberaciones, y puede simular un fallo al
/// liberar para comprobar que no tumba el servicio.
class _BlockingServerSttEngine extends ServerSttEngine {
  _BlockingServerSttEngine(this.availableGate)
    : super(
        baseUrl: 'ws://127.0.0.1:9123',
        allowLegacyQueryTokenFallback: true,
      );

  final Completer<bool> availableGate;
  final Completer<void> availableStarted = Completer<void>();
  int revokeCount = 0;
  int disposeCount = 0;

  @override
  Future<bool> available() {
    if (!availableStarted.isCompleted) availableStarted.complete();
    return availableGate.future;
  }

  @override
  void revokeLegacyQueryTokenFallback() {
    revokeCount++;
    super.revokeLegacyQueryTokenFallback();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _PingBlockingServerSttEngine extends ServerSttEngine {
  _PingBlockingServerSttEngine(this.pingGate)
    : super(
        baseUrl: 'ws://127.0.0.1:9123',
        allowLegacyQueryTokenFallback: true,
      );

  final Completer<bool> pingGate;
  final Completer<void> pingStarted = Completer<void>();
  int revokeCount = 0;
  int disposeCount = 0;

  @override
  Future<bool> available() async => false;

  @override
  Future<bool> ping({Duration timeout = const Duration(seconds: 4)}) {
    if (!pingStarted.isCompleted) pingStarted.complete();
    return pingGate.future;
  }

  @override
  void revokeLegacyQueryTokenFallback() {
    revokeCount++;
    super.revokeLegacyQueryTokenFallback();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _FakeStt implements SttEngine {
  _FakeStt({this.throwOnDispose = false, this.disposeGate});

  final bool throwOnDispose;
  final Completer<void>? disposeGate;
  final Completer<void> disposeStarted = Completer<void>();
  int stopCount = 0;
  int disposeCount = 0;

  @override
  Future<bool> available() async => true;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    onCaptureReady?.call();
    return const Stream<SttResult>.empty();
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await disposeGate?.future;
    if (throwOnDispose) throw Exception('boom');
  }

  @override
  bool get supportsPartials => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VoiceService voice;
  late List<_FakeStt> created;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    voice = VoiceService(prefs, SecureStorage());
    created = [];
    voice.debugSttFactory = () {
      final e = _FakeStt();
      created.add(e);
      return e;
    };
  });

  test(
    'un ajuste inicial efímero no modifica la preferencia persistida',
    () async {
      SharedPreferences.setMockInitialValues({
        'voice_stt_engine': SttEngineKind.server.id,
      });
      final prefs = await SharedPreferences.getInstance();
      final stored = VoiceSettings.load(prefs);
      final ephemeral = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: stored.copyWith(sttEngine: SttEngineKind.sherpaLive),
      );

      expect(ephemeral.settings.sttEngine, SttEngineKind.sherpaLive);
      expect(prefs.getString('voice_stt_engine'), SttEngineKind.server.id);
    },
  );

  test(
    'checkStt reutiliza el motor entre turnos (no recrea por turno)',
    () async {
      for (var i = 0; i < 5; i++) {
        final check = await voice.checkStt();
        expect(check.ready, isTrue);
      }
      // Cinco turnos, UN solo motor: antes del fix eran cinco AudioRecord nativos.
      expect(created, hasLength(1));
      expect(created.single.disposeCount, 0);
    },
  );

  test('checkStt recrea el motor si cambia la configuración STT', () async {
    await voice.checkStt();
    expect(created, hasLength(1));

    // Cambiar de motor invalida el cacheado (saveSettings lo libera).
    await voice.saveSettings(
      voice.settings.copyWith(sttEngine: SttEngineKind.system),
    );

    await voice.checkStt();
    expect(created, hasLength(2));
    // El motor viejo se liberó al cambiar de configuración.
    expect(created.first.disposeCount, 1);
    expect(created.last.disposeCount, 0);
  });

  test('revocar fallback legacy no interrumpe un motor STT no servidor',
      () async {
    await voice.saveSettings(
      voice.settings.copyWith(allowLegacyQueryTokenFallback: true),
    );
    await voice.checkStt();
    expect(created, hasLength(1));

    await voice.saveSettings(
      voice.settings.copyWith(allowLegacyQueryTokenFallback: false),
    );

    expect(created.single.disposeCount, 0);
    await voice.checkStt();
    expect(created, hasLength(1));
  });

  test('dispose cancela un check STT server antes de crear su motor', () async {
    await voice.saveSettings(
      voice.settings.copyWith(
        sttEngine: SttEngineKind.server,
        serverSttUrl: 'ws://127.0.0.1:9123',
        allowLegacyQueryTokenFallback: true,
      ),
    );
    final tokenGate = Completer<String?>();
    var enginesCreated = 0;
    voice.debugSttFactory = null;
    voice.debugServerSttTokenLoader = () => tokenGate.future;
    voice.debugServerSttFactory = () {
      enginesCreated++;
      return _BlockingServerSttEngine(Completer<bool>()..complete(true));
    };

    final check = voice.checkStt();
    await Future<void>.delayed(Duration.zero);
    await voice.dispose();
    tokenGate.complete('token');

    expect((await check).status, SttStatus.needsServerConfig);
    expect(enginesCreated, 0);
  });

  test('revocar fallback legacy libera el STT servidor con voz activa',
      () async {
    await voice.saveSettings(
      voice.settings.copyWith(
        sttEngine: SttEngineKind.server,
        serverSttUrl: 'ws://127.0.0.1:9123',
        allowLegacyQueryTokenFallback: true,
      ),
    );
    final serverEngine =
        _BlockingServerSttEngine(Completer<bool>()..complete(true));
    voice.debugSttFactory = null;
    voice.debugServerSttTokenLoader = () async => '';
    voice.debugServerSttFactory = () => serverEngine;
    await voice.checkStt();
    voice.setVoiceConversationActive(true);

    await voice.saveSettings(
      voice.settings.copyWith(allowLegacyQueryTokenFallback: false),
    );

    expect(serverEngine.revokeCount, 1);
    expect(serverEngine.disposeCount, 1);
  });

  test('cambiar el fallback legacy recrea el motor STT cacheado', () async {
    await voice.checkStt();
    expect(created, hasLength(1));

    await voice.saveSettings(
      voice.settings.copyWith(allowLegacyQueryTokenFallback: true),
    );

    await voice.checkStt();
    expect(created, hasLength(2));
    expect(created.first.disposeCount, 1);
  });

  test(
    'los checks STT server simultáneos comparten un único probe revocable',
    () async {
      await voice.saveSettings(
        voice.settings.copyWith(
          sttEngine: SttEngineKind.server,
          serverSttUrl: 'ws://127.0.0.1:9123',
          allowLegacyQueryTokenFallback: true,
        ),
      );
      final firstGate = Completer<bool>();
      final engines = [_BlockingServerSttEngine(firstGate)];
      var next = 0;
      voice.debugSttFactory = null;
      voice.debugServerSttTokenLoader = () async => '';
      voice.debugServerSttFactory = () => engines[next++];

      final firstCheck = voice.checkStt();
      await engines.single.availableStarted.future;
      final secondCheck = voice.checkStt();
      await Future<void>.delayed(Duration.zero);
      expect(next, 1);

      await voice.saveSettings(
        voice.settings.copyWith(allowLegacyQueryTokenFallback: false),
      );
      expect(engines.single.revokeCount, 1);

      firstGate.complete(true);
      expect((await firstCheck).status, SttStatus.needsServerConfig);
      expect((await secondCheck).status, SttStatus.needsServerConfig);
      expect(engines.single.disposeCount, 1);
    },
  );

  test(
    'revocar fallback legacy mantiene el probe ping revocable',
    () async {
      await voice.saveSettings(
        voice.settings.copyWith(
          sttEngine: SttEngineKind.server,
          serverSttUrl: 'ws://127.0.0.1:9123',
          allowLegacyQueryTokenFallback: true,
        ),
      );
      final pingGate = Completer<bool>();
      final engine = _PingBlockingServerSttEngine(pingGate);
      voice.debugSttFactory = null;
      voice.debugServerSttTokenLoader = () async => '';
      voice.debugServerSttFactory = () => engine;

      final check = voice.checkStt();
      await engine.pingStarted.future;
      await voice.saveSettings(
        voice.settings.copyWith(allowLegacyQueryTokenFallback: false),
      );
      expect(engine.revokeCount, 1);

      pingGate.complete(true);
      expect((await check).status, SttStatus.needsServerConfig);
      expect(engine.disposeCount, 1);
    },
  );

  test(
    'stopDictation para el motor pero NO lo libera (se reutiliza)',
    () async {
      await voice.checkStt();
      await voice.stopDictation();

      expect(created.single.stopCount, 1);
      expect(created.single.disposeCount, 0);

      // El siguiente turno reutiliza el MISMO motor (no se creó otro).
      await voice.checkStt();
      expect(created, hasLength(1));
    },
  );

  test(
    'stopDictation es un no-op si no hay motor (no crea ni crashea)',
    () async {
      await voice.stopDictation();
      expect(created, isEmpty);
    },
  );

  test('cancelDictation aborta sin transcribir y recrea el motor', () async {
    await voice.checkStt();
    final engine = created.single;

    await voice.cancelDictation();
    expect(engine.stopCount, 0);
    expect(engine.disposeCount, 1);

    await voice.checkStt();
    expect(created, hasLength(2));
  });

  test(
    'disposeSttForVoiceExit libera el motor y obliga a recrear al reentrar',
    () async {
      await voice.checkStt();
      final engine = created.single;

      await voice.disposeSttForVoiceExit();
      expect(engine.disposeCount, 1);

      // Reentrar al modo voz construye un motor nuevo y limpio.
      await voice.checkStt();
      expect(created, hasLength(2));
      expect(created.last.disposeCount, 0);
    },
  );

  test('disposeSttForVoiceExit es idempotente', () async {
    await voice.checkStt();
    await voice.disposeSttForVoiceExit();
    await voice.disposeSttForVoiceExit();

    // El segundo cierre no re-libera ni revienta.
    expect(created.single.disposeCount, 1);
  });

  test(
    'salir espera un cancel STT pendiente antes de liberar el runtime',
    () async {
      final gate = Completer<void>();
      final engine = _FakeStt(disposeGate: gate);
      voice.debugSttFactory = () {
        created.add(engine);
        return engine;
      };
      await voice.checkStt();

      final cancel = voice.cancelDictation();
      await engine.disposeStarted.future;
      var exitCompleted = false;
      final exit = voice.disposeSttForVoiceExit().then((_) {
        exitCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);

      expect(exitCompleted, isFalse);
      expect(engine.disposeCount, 1);
      gate.complete();
      await Future.wait([cancel, exit]);
      expect(exitCompleted, isTrue);
      expect(engine.disposeCount, 1);
    },
  );

  test(
    'un dispose del motor que lanza excepción no tumba el servicio',
    () async {
      voice.debugSttFactory = () {
        final e = _FakeStt(throwOnDispose: true);
        created.add(e);
        return e;
      };
      await voice.checkStt();

      // No debe propagar la excepción del motor muerto.
      await expectLater(voice.disposeSttForVoiceExit(), completes);

      // Y el servicio sigue usable: el siguiente turno crea un motor nuevo.
      await voice.checkStt();
      expect(created, hasLength(2));
    },
  );

  test(
    'dictado del composer no reutiliza la ruta de conversación nativa',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final hermesVoice = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ),
      );
      final engines = <_FakeStt>[];
      hermesVoice.debugSttFactory = () {
        final engine = _FakeStt();
        engines.add(engine);
        return engine;
      };
      expect(
        hermesVoice.enableNativeVoice(
          speak: (text) async => {'ok': true},
          transcribe: (dataUrl, mimeType) async => {
            'ok': true,
            'transcript': 'ruta conversación',
          },
        ),
        isTrue,
      );
      final owner = Object();
      final preparation = hermesVoice.beginHermesServerDictationPreparation(
        owner: owner,
      );
      expect(
        hermesVoice.enableHermesServerDictation(
          owner: owner,
          preparation: preparation,
          transcribe: (dataUrl, mimeType) async => {
            'ok': true,
            'transcript': 'ruta composer',
          },
        ),
        isTrue,
      );

      final check = await hermesVoice.checkStt(forComposerDictation: true);
      expect(check.engine, SttEngineKind.hermesServer);
      await hermesVoice
          .startDictation(continuous: true, forComposerDictation: true)
          .drain<void>();
      expect(engines, hasLength(1));

      await hermesVoice.dispose();
    },
  );

  test(
    'checkStt tras la ruta nativa no deja el flag nativo colgado (#39)',
    () async {
      // #39: la voz funciona la primera vez y luego se vuelve poco fiable.
      // `checkStt` recicla el motor server/hermesServer en cada llamada, pero
      // dejaba `_sttNativeVoice` en true: la siguiente resolución creía que el
      // motor vivo seguía siendo el nativo y devolvía un engine ya dispuesto.
      final prefs = await SharedPreferences.getInstance();
      final hermesVoice = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ),
      );
      final engines = <_FakeStt>[];
      hermesVoice.debugSttFactory = () {
        final engine = _FakeStt();
        engines.add(engine);
        return engine;
      };
      expect(
        hermesVoice.enableNativeVoice(
          speak: (text) async => {'ok': true},
          transcribe: (dataUrl, mimeType) async => {
            'ok': true,
            'transcript': 'primera',
          },
        ),
        isTrue,
      );

      // Primera grabación: crea el motor de la ruta nativa.
      await hermesVoice.startDictation(continuous: false).drain<void>();
      expect(engines, hasLength(1));

      // Un checkStt intermedio recicla el motor server.
      await hermesVoice.checkStt();

      // Segunda grabación: debe trabajar sobre un motor VIVO, nunca sobre uno
      // ya dispuesto.
      await hermesVoice.startDictation(continuous: false).drain<void>();
      final live = engines.where((e) => e.disposeCount == 0).toList();
      expect(
        live,
        isNotEmpty,
        reason: 'la segunda grabación no puede usar un motor dispuesto',
      );

      await hermesVoice.dispose();
    },
  );

  test('rebind Hermes libera A solo después de disponer su motor', () async {
    final gate = Completer<void>();
    final engine = _FakeStt(disposeGate: gate);
    final prefs = await SharedPreferences.getInstance();
    final hermesVoice = VoiceService(
      prefs,
      SecureStorage(),
      initialSettings: const VoiceSettings(
        sttEngine: SttEngineKind.hermesServer,
      ),
    );
    hermesVoice.debugSttFactory = () => engine;
    final ownerA = Object();
    final ownerB = Object();
    var releasesA = 0;
    var releasesB = 0;
    final preparationA = hermesVoice.beginHermesServerDictationPreparation(
      owner: ownerA,
    );
    expect(
      hermesVoice.enableHermesServerDictation(
        owner: ownerA,
        preparation: preparationA,
        transcribe: (dataUrl, mimeType) async => {'ok': true},
        onDispose: () => releasesA++,
      ),
      isTrue,
    );
    await hermesVoice.checkStt();

    final preparationB = hermesVoice.beginHermesServerDictationPreparation(
      owner: ownerB,
    );
    await engine.disposeStarted.future;
    expect(releasesA, 0);
    expect(
      hermesVoice.enableHermesServerDictation(
        owner: ownerB,
        preparation: preparationB,
        transcribe: (dataUrl, mimeType) async => {'ok': true},
        onDispose: () => releasesB++,
      ),
      isTrue,
    );
    expect(hermesVoice.hermesServerDictationReady, isTrue);

    gate.complete();
    await hermesVoice.disposeSttForVoiceExit();
    expect(releasesA, 1);
    expect(releasesB, 0);
    expect(hermesVoice.disableHermesServerDictation(owner: ownerB), isTrue);
    expect(releasesB, 1);
    expect(hermesVoice.disableHermesServerDictation(owner: ownerB), isFalse);
    expect(releasesB, 1);
    await hermesVoice.dispose();
  });
}
