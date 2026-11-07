import '../models/connection.dart';
import 'package:flutter/foundation.dart';

/// Enlace de emparejado de una instancia remota: codifica host + puerto + token
/// (y opcionalmente etiqueta, HTTPS, Dashboard y credenciales del Bridge) en
/// una URI `hermes://pair?...`
/// que el servidor imprime como QR. La app la escanea (o se pega) y precarga la
/// instancia, evitando teclear IP y un token largo en el móvil.
///
/// Núcleo PURO (sin Flutter) para poder testearlo sin dispositivo.
class PairingLink {
  static const scheme = 'hermes';
  static const authority = 'pair';

  final String host;
  final int port;
  final String token;
  final String? label;
  final bool useHttps;
  final String? dashboardUrl;
  final String? bridgeUrl;
  final String? bridgeToken;

  const PairingLink({
    required this.host,
    required this.port,
    required this.token,
    this.label,
    this.useHttps = false,
    this.dashboardUrl,
    this.bridgeUrl,
    this.bridgeToken,
  });

  /// Construye la URI canónica `hermes://pair?host=...&port=...&token=...`.
  String build() {
    final q = <String, String>{
      'host': host,
      'port': port.toString(),
      'token': token,
      if (label != null && label!.trim().isNotEmpty) 'label': label!.trim(),
      if (useHttps) 'https': '1',
      if (dashboardUrl != null && dashboardUrl!.trim().isNotEmpty)
        'dashboard': dashboardUrl!.trim(),
      if (bridgeUrl != null && bridgeUrl!.trim().isNotEmpty)
        'bridge': bridgeUrl!.trim(),
      if (bridgeToken != null && bridgeToken!.trim().isNotEmpty)
        'bridge_token': bridgeToken!.trim(),
    };
    return Uri(
      scheme: scheme,
      host: authority,
      queryParameters: q,
    ).toString();
  }

  /// Intenta parsear una URI de emparejado. Devuelve null si no es válida
  /// (esquema/authority incorrectos o faltan host/token).
  static PairingLink? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    Uri uri;
    Map<String, String> q;
    try {
      uri = Uri.parse(text);
      if (uri.scheme.toLowerCase() != scheme) return null;
      if (uri.host.toLowerCase() != authority) return null;
      // queryParameters decodes lazily and can throw on malformed UTF-8.
      q = uri.queryParameters;
    } catch (_) {
      // Parser errors can embed the raw URI, including pairing credentials.
      debugPrint('[pairing] malformed URI (redacted)');
      return null;
    }
    final host = (q['host'] ?? '').trim();
    final token = (q['token'] ?? '').trim();
    if (host.isEmpty || token.isEmpty) return null;
    final port = int.tryParse((q['port'] ?? '').trim());
    if (port == null || port <= 0 || port > 65535) return null;
    final https = (q['https'] ?? '').trim();
    final dash = (q['dashboard'] ?? '').trim();
    final bridge = (q['bridge'] ?? '').trim();
    final bridgeToken = (q['bridge_token'] ?? '').trim();
    final label = (q['label'] ?? '').trim();
    return PairingLink(
      host: host,
      port: port,
      token: token,
      label: label.isEmpty ? null : label,
      useHttps: https == '1' || https.toLowerCase() == 'true',
      dashboardUrl: dash.isEmpty ? null : dash,
      bridgeUrl: bridge.isEmpty ? null : bridge,
      bridgeToken: bridgeToken.isEmpty ? null : bridgeToken,
    );
  }

  /// Borrador de instancia a precargar en el editor (el usuario revisa y guarda).
  SavedConnection toDraftConnection() {
    final lbl = (label != null && label!.trim().isNotEmpty)
        ? label!.trim()
        : host;
    return SavedConnection(
      id: 'pair_${DateTime.now().microsecondsSinceEpoch}',
      label: lbl,
      host: host,
      port: port,
      apiKey: token,
      useHttps: useHttps,
      dashboardUrl: (dashboardUrl != null && dashboardUrl!.trim().isNotEmpty)
          ? dashboardUrl!.trim()
          : null,
    );
  }
}
