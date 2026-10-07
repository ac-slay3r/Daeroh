// Runtime local CONTROLABLE: el agente Hermes completo corriendo en Termux.
//
// Expone Gateway :8642 + Dashboard :9119 en localhost (las mismas APIs que la
// Consola ya habla), así que es el único camino para "controlar un agente
// local desde la Consola". El provider: detecta Termux, lo instala vía F-Droid
// si falta, lanza el instalador documentado (RUN_COMMAND best-effort), y
// autodetecta el agente sondeando http://127.0.0.1:8642/health.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../bridge_client.dart';
import '../connection_manager.dart';
import '../../utils/private_http_client.dart';
import '../platform/android_apps.dart';
import 'agent_runtime.dart';

class LocalTermuxAgentProvider implements AgentRuntimeProvider {
  final AppBridge apps;
  final http.Client _http;

  LocalTermuxAgentProvider({required this.apps, http.Client? client})
    : _http = PrivateHttpClient(client ?? http.Client());

  @override
  String get id => 'local-termux';

  @override
  String get displayName => 'Agente local (Termux)';

  String get package => AgentRuntimeConsts.termuxPackage;

  /// Base URL del daemon de Ollama. En dispositivo real con Termux es el
  /// loopback del propio Android; en el emulador se reescribe a 10.0.2.2 para
  /// alcanzar el Ollama del host de desarrollo (de lo contrario `127.0.0.1`
  /// apunta a la VM del emulador y da "Connection refused").
  String get _ollamaBase =>
      'http://${resolveEmulatorLoopback(AgentRuntimeConsts.localHost)}:11434';

  @override
  Future<AgentRuntimeStatus> status() async {
    // 1) ¿Vivo en :9119? ⇒ listo. Y, de paso, queda EVIDENCIA de que existe:
    //    persistimos la marca de instalado para futuros arranques en frío.
    if (await isAgentRunning()) {
      await AgentRuntimeConsts.setAgentInstalled(true);
      return AgentRuntimeStatus.ready;
    }
    // 2) Sin el runtime Termux no puede haber agente: ofrecer instalar runtime.
    final termux = await apps.isInstalled(package);
    if (!termux) return AgentRuntimeStatus.notInstalled;
    // 3) Termux presente y el agente NO responde. Detección binaria:
    //    • con marca de instalado ⇒ está instalado pero parado → SÓLO arrancar.
    //    • sin marca ⇒ no hay agente → SÓLO instalar.
    if (await AgentRuntimeConsts.isAgentInstalledMarked()) {
      return AgentRuntimeStatus.installed;
    }
    return AgentRuntimeStatus.needsSetup;
  }

  Future<bool> isTermuxInstalled() => apps.isInstalled(package);

  /// Sonda REAL del sistema de archivos de Termux: ¿está instalado el agente
  /// Hermes (aunque esté parado)? Devuelve true/false según la sonda, o null si
  /// es inconcluso (Termux no respondió / sin allow-external-apps / timeout).
  /// Permite la detección binaria honesta cuando no hay marca persistida ni el
  /// agente está corriendo.
  Future<bool?> probeAgentInstalled() async {
    final out = await apps.probeTermux(AgentRuntimeConsts.detectInstalledCommand);
    if (out == null) return null;
    if (out.contains('@@HERMES_INSTALLED')) return true;
    if (out.contains('@@HERMES_ABSENT')) return false;
    return null; // salida inesperada → no concluir
  }

  /// Abre la ficha de F-Droid para instalar Termux.
  Future<bool> installTermux() => apps.installFromFDroid(package);

  /// Intenta lanzar el instalador del agente dentro de Termux (RUN_COMMAND).
  /// Best-effort: devuelve false si Termux no lo permite (la UI cae a "copiar
  /// comando y abrir Termux").
  Future<bool> runInstaller() =>
      apps.runInTermux(AgentRuntimeConsts.installCommand);

  /// El comando de instalación (para copiar al portapapeles).
  String get installCommand => AgentRuntimeConsts.installCommand;

  /// Lanza el instalador con el **wrapper de progreso** (sirve su log por
  /// localhost para la barra en vivo). Premium: RUN_COMMAND silencioso, sin
  /// abrir terminal — el usuario ve el progreso dentro de la Consola.
  Future<bool> runInstallerWithProgress() => apps.runInTermux(
    AgentRuntimeConsts.installWrapperCommand,
    background: true,
  );

  /// Comando del wrapper (fallback: copiar y pegar en Termux).
  String get installWrapperCommand => AgentRuntimeConsts.installWrapperCommand;

  /// Lanza la REPARACIÓN del agente (reconstruye el venv de Python roto
  /// conservando datos). Mismo mecanismo que el instalador: progreso por :8643,
  /// así la pantalla de instalación lo muestra en vivo. Ver
  /// [AgentRuntimeConsts.repairWrapperCommand].
  Future<bool> runRepairWithProgress() => apps.runInTermux(
    AgentRuntimeConsts.repairWrapperCommand,
    background: true,
  );

  /// Comando de reparación (fallback: copiar y pegar en Termux).
  String get repairWrapperCommand => AgentRuntimeConsts.repairWrapperCommand;

  /// Escribe `~/.hermes/config.yaml` en Termux (background) con el proveedor,
  /// modelo y API key dados. Reemplaza el setup interactivo sin
  /// que el usuario tenga que abrir Termux.
  Future<void> configureAgent({
    required String provider,
    required String model,
    required String apiKey,
    String? baseUrl,
    bool isOAuth = false,
  }) async {
    final cmd = AgentRuntimeConsts.writeConfigCommand(
      provider: provider,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
      isOAuth: isOAuth,
    );
    await apps.runInTermux(cmd, background: true);
  }

  /// Lanza el flujo OAuth de un provider (`hermes auth` / `hermes model set
  /// codex`) en Termux EN SEGUNDO PLANO (background: true): no abre la terminal.
  /// El comando sirve su salida por localhost (:8644); la UI sondea
  /// [fetchOAuthLog], extrae la URL `https://…` y la abre en el navegador.
  Future<void> runOAuthFlow({required String provider}) async {
    final cmd = AgentRuntimeConsts.oauthCommand(provider: provider);
    await apps.runInTermux(cmd, background: true);
  }

  /// Lee el log del flujo OAuth servido por localhost (:8644). Devuelve el texto
  /// acumulado (incluye la URL de login y los marcadores @@OAUTH_*), o null si
  /// el servidor aún no responde. Mismo mecanismo que [fetchInstallProgress].
  Future<String?> fetchOAuthLog({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse(AgentRuntimeConsts.oauthProgressUrl))
          .timeout(timeout);
      return res.statusCode == 200 ? res.body : null;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// Lee las últimas líneas del log del gateway vía el servidor de diagnóstico
  /// temporal (:8645) que [startAgent] levanta ~60 s. Devuelve null si el
  /// servidor no responde (p.ej. ya pasaron los 60 s o python3 no está).
  Future<String?> fetchGatewayLog({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse(AgentRuntimeConsts.gatewayLogUrl))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final lines = res.body.trimRight().split('\n');
      return lines.length > 30
          ? lines.sublist(lines.length - 30).join('\n')
          : res.body;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// Arranca el agente Hermes ya instalado (Dashboard :9119) en segundo plano
  /// dentro de Termux. Antes despliega el Mobile Bridge (asset → ~/.hermes) para
  /// que el arranque lo levante y la Consola pueda escribir SOUL/memoria e
  /// instalar/activar skills. Best-effort: si el asset no carga, arranca igual.
  /// Devuelve true si Termux ACEPTÓ ejecutar el comando (no garantiza que el
  /// agente arranque, pero false significa que el intent ni siquiera se pudo
  /// despachar: Termux no instalado o sin permiso RUN_COMMAND / allow-external-
  /// apps). Los llamadores deben avisar al usuario en ese caso en vez de esperar
  /// en vano a que el gateway suba.
  Future<bool> startAgent() async {
    final token = await AgentRuntimeConsts.getOrGenerateLocalToken();
    var cmd = AgentRuntimeConsts.startAgentCommandWith(token);
    final deploy = await _bridgeDeployPrefix();
    if (deploy != null) cmd = '$deploy\n$cmd';
    return apps.runInTermux(cmd, background: true);
  }

  /// Reinicia SOLO el Mobile Bridge (sin tocar dashboard/gateway/ollama):
  /// re-despliega el script desde el asset y lo arranca con el token actual,
  /// reemplazando cualquier bridge viejo (con token distinto → 401). Es un
  /// RUN_COMMAND pequeño, más fiable que un reinicio completo del agente.
  /// Devuelve true si Termux ACEPTÓ el comando; false significa que el intent ni
  /// se pudo despachar (Termux no instalado / sin permiso RUN_COMMAND), y el
  /// llamador debe avisar en vez de fingir que el bridge se está instalando.
  Future<bool> restartBridge() async {
    final token = await AgentRuntimeConsts.getOrGenerateLocalToken();
    var cmd = AgentRuntimeConsts.restartBridgeCommandWith(token);
    final deploy = await _bridgeDeployPrefix();
    if (deploy != null) cmd = '$deploy\n$cmd';
    return apps.runInTermux(cmd, background: true);
  }

  /// Lee el log de arranque del bridge (`~/.hermes/bridge.out`) DESDE Termux
  /// vía la sonda con resultado, para mostrar en la app el error real cuando el
  /// bridge no levanta (sin que el usuario tenga que abrir Termux). Devuelve las
  /// últimas líneas, o null si Termux no devolvió nada.
  Future<String?> readBridgeLog() async {
    final out = await apps.probeTermux(
      'cat \$HOME/.hermes/bridge.out 2>/dev/null | tail -n 80',
    );
    final t = out?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Construye el prefijo que despliega el script del bridge desde el asset.
  /// Devuelve null si el asset no está disponible (no debería en producción).
  ///
  /// El script se **comprime con gzip antes de base64**: incrustarlo crudo
  /// (91 KB → 121 KB en base64) dejaba el comando de arranque a ~1,5 KB del
  /// límite de `MAX_ARG_STRLEN` (128 KB por argumento de `execve`); en el
  /// dispositivo real, con el token UUID y el overhead de RUN_COMMAND, lo
  /// superaba y el intent fallaba en silencio → "el agente no arranca aunque
  /// reinicie Termux". gzip lo reduce ~69 % (a ~37 KB), dejando >80 KB de margen.
  Future<String?> _bridgeDeployPrefix() async {
    try {
      final script =
          await rootBundle.loadString('assets/bridge/hermes_bridge.py');
      if (script.trim().isEmpty) return null;
      final b64 = base64.encode(gzip.encode(utf8.encode(script)));
      return AgentRuntimeConsts.deployBridgeCommand(b64);
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// Garantiza que el bridge EN EJECUCIÓN es la versión que ESTE APK espera
  /// ([AgentRuntimeConsts.expectedBridgeVersion]). Si ya coincide, no hace nada.
  /// Si está desactualizado (o no responde — bridge viejo de una instalación
  /// anterior), lo redespliega y reinicia, y espera a que levante la versión
  /// correcta. Esto es lo que evita que, tras actualizar el APK, el bridge viejo
  /// siga sirviendo código antiguo: el app llamaría endpoints nuevos → 404 →
  /// "sin modelos / skills / info del servidor". Idempotente y barato cuando ya
  /// está fresco (solo una sonda de versión). Devuelve true si al terminar corre
  /// la versión esperada.
  Future<bool> ensureFreshBridge(String bridgeUrl) async {
    if (bridgeUrl.trim().isEmpty) return false;
    final running = await BridgeClient.probeVersion(bridgeUrl);
    if (running == AgentRuntimeConsts.expectedBridgeVersion) return true;
    final dispatched = await restartBridge();
    if (!dispatched) return false;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await BridgeClient.probeVersion(bridgeUrl) ==
          AgentRuntimeConsts.expectedBridgeVersion) {
        return true;
      }
    }
    return false;
  }

  /// Para el agente Hermes en ejecución (TERM → espera 2 s → KILL). Best-effort
  /// vía RUN_COMMAND en segundo plano.
  Future<void> stopAgent() async {
    await apps.runInTermux(
      AgentRuntimeConsts.stopAgentCommand,
      background: true,
    );
  }

  /// Para el proceso ollama serve en Termux (TERM → 2 s → KILL). Best-effort.
  Future<void> stopOllama() async {
    await apps.runInTermux(
      AgentRuntimeConsts.stopOllamaCommand,
      background: true,
    );
  }

  /// Intenta leer los últimos logs del gateway por RUN_COMMAND background.
  /// Android no devuelve stdout en este canal, así que la UI conserva un
  /// mensaje informativo hasta que haya un puente de lectura dedicado.
  Future<String> readAgentLogs() async {
    await apps.runInTermux(
      AgentRuntimeConsts.readLogsCommand,
      background: true,
    );
    return '(system logs are not directly available from the app)';
  }

  /// Comando de arranque resuelto con el token de sesión real (UUID persistido
  /// en SecureStorage), para mostrarlo como fallback "copiar y pegar en Termux".
  /// Preferir este sobre [startAgentCommand]: el síncrono lleva el token literal
  /// de fallback y se conserva solo por compatibilidad con callers existentes.
  Future<String> get startAgentCommandResolved async {
    final token = await AgentRuntimeConsts.getOrGenerateLocalToken();
    return AgentRuntimeConsts.startAgentCommandWith(token);
  }

  /// Comando de arranque (fallback: copiar y pegar en Termux). Lleva el token
  /// literal de fallback; usar [startAgentCommandResolved] para el token real.
  String get startAgentCommand => AgentRuntimeConsts.startAgentCommand;

  /// Cancela la instalación en curso: mata el proceso y su servidor de log en
  /// Termux para dejar el estado limpio. Best-effort vía RUN_COMMAND.
  Future<bool> cancelInstall() => apps.runInTermux(
    AgentRuntimeConsts.cancelInstallCommand,
    background: true,
  );

  /// Lanza el script de desinstalación en Termux (RUN_COMMAND background).
  Future<bool> runUninstall() =>
      apps.runInTermux(AgentRuntimeConsts.uninstallCommand, background: true);

  /// Borra los modelos de Ollama (`~/.ollama`) y desinstala el paquete ollama.
  /// Opcional: por defecto la desinstalación los CONSERVA para no re-descargar
  /// GB al reinstalar. Se llama tras la desinstalación (ollama ya parado).
  Future<bool> removeOllamaModels() => apps.runInTermux(
        AgentRuntimeConsts.removeOllamaModelsCommand,
        background: true,
      );

  /// Cancela la desinstalación en curso. Best-effort.
  Future<bool> cancelUninstall() => apps.runInTermux(
    AgentRuntimeConsts.cancelUninstallCommand,
    background: true,
  );

  /// Lee el log de progreso de la desinstalación (mismo servidor que el instalador).
  Future<String?> fetchUninstallProgress({
    Duration timeout = const Duration(seconds: 3),
  }) => fetchInstallProgress(timeout: timeout);

  /// Elimina la conexión local de la Consola, si existe. Empareja por host +
  /// kind para capturar tanto las nuevas (:9119) como las antiguas (:8642).
  Future<void> removeLocalConnection(ConnectionManager cm) async {
    final toRemove = cm
        .getConnections()
        .where(
          (c) =>
              c.host == AgentRuntimeConsts.localHost &&
              c.kind == InstanceKind.localhost,
        )
        .toList();
    for (final c in toRemove) {
      await cm.deleteConnection(c.id);
    }
  }

  /// Comando para activar `allow-external-apps` en Termux (una vez), para que
  /// la instalación automática (RUN_COMMAND) funcione.
  String get allowExternalAppsCommand =>
      AgentRuntimeConsts.allowExternalAppsCommand;

  /// Bootstrap automático sin intervención: abre Termux en PRIMER PLANO
  /// (TermuxActivity, que no exige `allow-external-apps`) con un comando que
  /// activa la propiedad y devuelve el foco a la Consola. Tras volver, la
  /// pantalla reintenta el RUN_COMMAND real. Best-effort.
  Future<bool> bootstrapExternalApps() => apps.launchTermuxForeground(
    AgentRuntimeConsts.bootstrapExternalAppsCommand,
  );

  /// Pre-flight de red: ¿se alcanza el instalador oficial? Evita empezar para
  /// morir a medias sin conexión.
  Future<bool> installerReachable() async {
    final uri = Uri.parse(AgentRuntimeConsts.installerUrl);
    try {
      final res = await _http.head(uri).timeout(const Duration(seconds: 6));
      return res.statusCode < 500;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se continúa sin propagar): $e');
      try {
        final res = await _http.get(uri).timeout(const Duration(seconds: 8));
        return res.statusCode == 200;
      } catch (e) {
        debugPrint('[termux-agent] excepción silenciada (GET de respaldo también falló, se asume false): $e');
        return false;
      }
    }
  }

  /// Lee el log de progreso que sirve el wrapper por localhost. Devuelve el
  /// texto acumulado, o null si el servidor aún no responde.
  Future<String?> fetchInstallProgress({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse(AgentRuntimeConsts.installProgressUrl))
          .timeout(timeout);
      return res.statusCode == 200 ? res.body : null;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// ¿Hay una instalación REALMENTE en curso ahora mismo? Fuente de verdad para
  /// el banner «Retomar» y el estado del setup: el wrapper de instalación sirve
  /// su log por localhost (:8643) SÓLO mientras corre; cuando termina, falla, lo
  /// matan o se desinstala, el servidor cae. Así, un flag `local_install_in_progress`
  /// que quedó obsoleto (p. ej. tras desinstalar) NO produce un «Retomar»
  /// fantasma. Devuelve true únicamente si el servidor responde y el log aún no
  /// tiene marcador terminal (@@done/@@exit).
  Future<bool> isInstallRunning({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final log = await fetchInstallProgress(timeout: timeout);
    if (log == null) return false;
    final lower = log.toLowerCase();
    if (lower.contains('@@done') || lower.contains('@@exit')) return false;
    return true;
  }

  /// Sondea si el agente Hermes local está vivo. La API REST que usa la Consola
  /// (chat `/v1/runs`, sesiones, estado) la sirve el **dashboard en :9119**, no
  /// el subcomando `hermes gateway` (que es el gateway de MENSAJERÍA — Telegram/
  /// WhatsApp/… — y no expone HTTP en :8642). Verificado en vivo: :8642 no
  /// responde; :9119 sirve `/health`, `/api/sessions`, `/v1/runs`. Por eso se
  /// sondea el dashboard.
  Future<bool> isAgentRunning({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // El agente local corre como dashboard en :9119, cuyo endpoint de salud
    // público es `/api/status` (igual que usa ConnectionDiagnostics para las
    // conexiones dashboard). `/health` sólo lo sirve el gateway (:8642), que no
    // expone HTTP, así que sondearlo daba 404 y el agente —aun estando vivo—
    // se detectaba como ausente, forzando el flujo de instalación.
    final uri = Uri.parse(
      'http://${AgentRuntimeConsts.localHost}:${AgentRuntimeConsts.localDashboardPort}/api/status',
    );
    try {
      final res = await _http.get(uri).timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
    } catch (_) {
      // cae al sondeo del bridge
    }
    // Fallback: el Dashboard a veces NO arranca on-device (OOM o permisos del
    // venv) aunque el agente esté funcional —el chat va por el Mobile Bridge
    // (:9131), no por el dashboard—. Si el bridge responde a `/bridge/health`
    // (público, sin token), el agente está EN MARCHA. Sin este fallback, parar
    // y arrancar mostraba "el gateway no arrancó" pese a que el chat funcionaba.
    try {
      final bridgeUri = Uri.parse(
        'http://${AgentRuntimeConsts.localHost}:${AgentRuntimeConsts.localBridgePort}/bridge/health',
      );
      final res = await _http.get(bridgeUri).timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Crea (si no existe) y guarda la conexión al agente local, devolviéndola.
  ///
  /// El agente local expone toda su API (chat `/v1/runs`, sesiones, estado) en
  /// el **dashboard :9119**; el `hermes gateway` (:8642) es de mensajería y no
  /// sirve HTTP. Por eso la conexión usa `port = localDashboardPort` (9119) para
  /// que `baseUrl`/`gatewayUrl` (que el chat usa) apunten al dashboard.
  Future<SavedConnection> ensureLocalConnection(ConnectionManager cm) async {
    // Conectar es evidencia de que el agente existe: persistimos la marca para
    // que un futuro arranque en frío lo detecte como «instalado, parado».
    await AgentRuntimeConsts.setAgentInstalled(true);
    const localPort = AgentRuntimeConsts.localDashboardPort; // 9119
    final dash =
        'http://${AgentRuntimeConsts.localHost}:${AgentRuntimeConsts.localDashboardPort}';
    final existing = cm
        .getConnections()
        .where((c) =>
            c.host == AgentRuntimeConsts.localHost &&
            c.kind == InstanceKind.localhost)
        .toList();
    // Token canónico con el que la app arranca el agente (UUID persistido).
    // El dashboard local lo exige; una conexión con un apiKey distinto recibe
    // 401 y la instancia parece "offline" aunque el agente responda.
    final token = await AgentRuntimeConsts.getOrGenerateLocalToken();
    if (existing.isNotEmpty) {
      final c = existing.first;
      // Migra conexiones locales antiguas: puerto del gateway (:8642), flag
      // on-device (sus servicios viven en este mismo Android, no en el host del
      // emulador — no reescribir 127.0.0.1→10.0.2.2) y token desincronizado.
      if (c.port != localPort || !c.onDeviceLoopback || c.apiKey != token) {
        final fixed = c.copyWith(
          port: localPort,
          dashboardUrl: dash,
          onDeviceLoopback: true,
          apiKey: token,
        );
        await cm.upsertConnection(fixed);
        return fixed;
      }
      return c;
    }

    final conn = SavedConnection(
      id: const Uuid().v4(),
      label: 'Hermes local',
      host: AgentRuntimeConsts.localHost,
      port: localPort,
      // El dashboard local arranca con HERMES_DASHBOARD_SESSION_TOKEN = el token
      // dinámico (UUID persistido en SecureStorage). El servidor acepta este
      // valor tanto en X-Hermes-Session-Token como en Authorization: Bearer, lo
      // que permite que ApiClient funcione sin cambios.
      apiKey: token,
      dashboardUrl: dash,
      kind: InstanceKind.localhost,
      onDeviceLoopback: true,
      notes: 'Agente Hermes local (Termux) en este dispositivo.',
    );
    await cm.upsertConnection(conn);
    return conn;
  }

  /// Instala ollama en Termux (descarga binario de GitHub). Best-effort.
  Future<bool> installOllama() => apps.runInTermux(
    AgentRuntimeConsts.installOllamaCommand,
    background: true,
  );

  /// ¿Está el binario `ollama` instalado en Termux? Sonda con resultado: evita
  /// el cuelgue de intentar arrancarlo y esperar 45 s en :11434 cuando no está.
  /// Devuelve true/false; null si Termux no respondió (no se pudo determinar).
  Future<bool?> isOllamaInstalled() async {
    final out = await apps.probeTermux(
      'command -v ollama >/dev/null 2>&1 && echo OLLAMA_OK || echo OLLAMA_NO',
    );
    if (out == null) return null;
    if (out.contains('OLLAMA_OK')) return true;
    if (out.contains('OLLAMA_NO')) return false;
    return null;
  }

  /// Log de la instalación de ollama (`~/.hermes/ollama-install.out`), para ver
  /// el progreso/errores reales del `pkg install` sin abrir Termux.
  Future<String?> readOllamaInstallLog() async {
    final out = await apps.probeTermux(
      'cat \$HOME/.hermes/ollama-install.out 2>/dev/null | tail -n 80',
    );
    final t = out?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Log del DAEMON ollama (`~/.ollama/serve.log`), para ver por qué `ollama
  /// serve` no levanta en :11434 (instalado pero parado). Distinto del log de
  /// instalación: este es del arranque del servidor.
  Future<String?> readOllamaServeLog() async {
    final out = await apps.probeTermux(
      'cat \$HOME/.ollama/serve.log 2>/dev/null | tail -n 80',
    );
    final t = out?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Inicia ollama serve en background (:11434). Idempotente.
  Future<bool> startOllama() =>
      apps.runInTermux(AgentRuntimeConsts.startOllamaCommand, background: true);

  /// Descarga un modelo de ollama. Best-effort (RUN_COMMAND no retorna stdout).
  Future<void> pullOllamaModel(String model) async {
    if (!AgentRuntimeConsts.isValidModelName(model)) {
      throw ArgumentError('Invalid model name: $model');
    }
    await apps.runInTermux(
      AgentRuntimeConsts.ollamaPullCommand(model),
      background: true,
    );
  }

  /// Descarga un modelo a través de la API HTTP de ollama (`POST /api/pull`),
  /// que emite progreso en streaming NDJSON. Devuelve un stream con la fracción
  /// descargada (0.0–1.0); emite null cuando aún no hay tamaño conocido
  /// (p.ej. "pulling manifest"). El daemon debe estar corriendo (:11434).
  Stream<OllamaPullProgress> pullOllamaModelStream(String model) async* {
    if (!AgentRuntimeConsts.isValidModelName(model)) {
      throw ArgumentError('Invalid model name: $model');
    }
    final req = http.Request(
      'POST',
      Uri.parse('$_ollamaBase/api/pull'),
    )..body = jsonEncode({'model': model, 'stream': true});
    req.headers['content-type'] = 'application/json';

    final res = await _http.send(req);
    if (res.statusCode != 200) {
      throw Exception('ollama /api/pull → HTTP ${res.statusCode}');
    }
    // El cuerpo es NDJSON: una línea JSON por evento. Se acumula por si una
    // línea llega partida entre chunks.
    var buffer = '';
    await for (final chunk in res.stream.transform(utf8.decoder)) {
      buffer += chunk;
      var idx = buffer.indexOf('\n');
      while (idx >= 0) {
        final line = buffer.substring(0, idx).trim();
        buffer = buffer.substring(idx + 1);
        idx = buffer.indexOf('\n');
        if (line.isEmpty) continue;
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final status = (obj['status'] ?? '').toString();
          final total = (obj['total'] as num?)?.toDouble();
          final completed = (obj['completed'] as num?)?.toDouble();
          final fraction = (total != null && total > 0 && completed != null)
              ? (completed / total).clamp(0.0, 1.0)
              : null;
          yield OllamaPullProgress(
            status: status,
            fraction: fraction,
            done: status.toLowerCase() == 'success',
          );
        } catch (_) {
          // Línea no-JSON o parcial: se ignora.
        }
      }
    }
  }

  /// Comprueba si ollama serve está activo en :11434.
  Future<bool> isOllamaRunning({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse('$_ollamaBase/'))
          .timeout(timeout);
      return res.statusCode < 500;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Espera polling hasta que ollama responda o se agote [timeout].
  /// Devuelve true si arrancó a tiempo, false si expiró.
  /// Útil tras [startOllama]: el intent RUN_COMMAND es fire-and-forget,
  /// así que no basta con un delay fijo.
  Future<bool> waitUntilOllamaReady({
    Duration timeout = const Duration(seconds: 40),
    Duration interval = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isOllamaRunning()) return true;
      await Future.delayed(interval);
    }
    return false;
  }

  /// Comprueba si un modelo de ollama está disponible en el dispositivo.
  /// Consulta :11434/api/tags y busca el prefijo del tag (antes de `:version`).
  Future<bool> isOllamaModelAvailable(
    String modelTag, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse('$_ollamaBase/api/tags'))
          .timeout(timeout);
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      if (body == null) return false;
      final models = (body['models'] as List?) ?? [];
      final prefix = modelTag.split(':').first.toLowerCase();
      return models.any(
        (m) => (m['name'] as String? ?? '').toLowerCase().startsWith(prefix),
      );
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Lista los modelos de ollama ya descargados en el dispositivo (nombres
  /// completos con tag). Consulta :11434/api/tags. Devuelve [] si el servidor
  /// no responde o no hay modelos.
  Future<List<String>> listOllamaModels({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final res = await _http
          .get(Uri.parse('$_ollamaBase/api/tags'))
          .timeout(timeout);
      if (res.statusCode != 200) return [];
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      final models = (body?['models'] as List?) ?? [];
      return models
          .map((m) => (m['name'] as String? ?? '').trim())
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se devuelve lista vacía): $e');
      return [];
    }
  }

  /// Borra UN modelo concreto vía la API HTTP de ollama (`DELETE /api/delete`).
  /// Es la vía limpia (igual que /api/pull y /api/tags): no usa RUN_COMMAND ni
  /// desinstala el paquete. Devuelve true si ollama confirmó el borrado (200).
  Future<bool> deleteOllamaModel(
    String model, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!AgentRuntimeConsts.isValidModelName(model)) {
      throw ArgumentError('Invalid model name: $model');
    }
    try {
      final req = http.Request(
        'DELETE',
        Uri.parse('$_ollamaBase/api/delete'),
      )..body = jsonEncode({'model': model});
      req.headers['content-type'] = 'application/json';
      final res = await _http.send(req).timeout(timeout);
      // Drena el cuerpo para liberar la conexión.
      await res.stream.drain<void>();
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[termux-agent] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  /// Configura hermes para usar ollama como provider local (:11434).
  Future<void> configureWithOllama(String model) async {
    await configureAgent(
      provider: 'ollama',
      model: model,
      apiKey: '',
      baseUrl: 'http://127.0.0.1:11434',
    );
  }

  void dispose() => _http.close();
}

/// Progreso de una descarga de modelo de ollama (`/api/pull`).
class OllamaPullProgress {
  /// Texto de estado del daemon ("pulling manifest", "downloading…", "success").
  final String status;

  /// Fracción descargada (0.0–1.0) o null si aún no se conoce el tamaño.
  final double? fraction;

  /// La descarga terminó correctamente.
  final bool done;

  const OllamaPullProgress({
    required this.status,
    required this.fraction,
    required this.done,
  });
}
