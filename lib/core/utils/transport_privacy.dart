import 'dart:io';

// Android permite cleartext globalmente porque network_security_config.xml no
// puede acotar el permiso por CIDR. Los nombres DNS pueden resolver a destinos
// públicos y por eso siempre requieren TLS.
enum TransportPrivacyClass {
  /// https:// o wss://: el transporte está cifrado, sin más que avisar.
  secure,

  /// http:// o ws:// hacia una IP literal loopback, LAN o Tailscale.
  privateCleartext,

  /// Cleartext hacia otro destino, o URL inválida/esquema desconocido; no se
  /// permite construir un cliente con esta clasificación.
  publicCleartext,
}

/// Helper puro (sin estado, sin I/O) para clasificar la privacidad de
/// transporte de una URL de servidor tal como la escribe el usuario.
class TransportPrivacy {
  const TransportPrivacy._();

  /// Clasifica [url] según su esquema y, si es cleartext, según si el host
  /// es de red privada o público.
  ///
  /// Acepta URLs sin esquema (p.ej. `192.168.1.5:8642`): se asume `http://`
  /// como la app hace al normalizar (ver `SavedConnection.normalizeHostAndPort`).
  /// URLs vacías o irreconocibles no obtienen permiso de red.
  static TransportPrivacyClass classify(String url) {
    var raw = url.trim();
    if (raw.isEmpty) return TransportPrivacyClass.publicCleartext;

    if (!raw.contains('://')) {
      // Host IPv6 sin corchetes (p.ej. "::1" o "::1:8642" no es ambiguo,
      // pero para simplificar detectamos "más de un ':'" como IPv6 literal
      // y lo entrecomillamos para que Uri.parse lo acepte).
      if (!raw.startsWith('[') && ':'.allMatches(raw).length > 1) {
        raw = '[$raw]';
      }
      raw = 'http://$raw';
    }

    try {
      final uri = Uri.parse(raw);
      if (!uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.port < 0 ||
          uri.port > 65535) {
        return TransportPrivacyClass.publicCleartext;
      }
      final scheme = uri.scheme.toLowerCase();
      if (scheme == 'https' || scheme == 'wss') {
        return TransportPrivacyClass.secure;
      }
      if (scheme != 'http' && scheme != 'ws') {
        return TransportPrivacyClass.publicCleartext;
      }
      return _isPrivateHost(uri.host)
          ? TransportPrivacyClass.privateCleartext
          : TransportPrivacyClass.publicCleartext;
    } on FormatException {
      return TransportPrivacyClass.publicCleartext;
    }
  }

  /// Límite efectivo de release: HTTP/WS solo se acepta para loopback, LAN o
  /// Tailscale. La network security config de Android no entiende CIDR, así que
  /// esta comprobación debe ejecutarse antes de construir cualquier cliente.
  static String requireAllowed(String url) {
    if (classify(url) == TransportPrivacyClass.publicCleartext) {
      throw ArgumentError(
        'HTTP/WS público bloqueado: configura HTTPS/WSS o usa una dirección privada/Tailscale.',
      );
    }
    return url;
  }

  /// Solo IPs literales: loopback, RFC 1918, Tailscale 100.64.0.0/10 y
  /// IPv6 ULA. IPv6 link-local queda excluida: requiere ámbito de interfaz y
  /// un literal sin zona no identifica un destino inequívoco.
  static bool _isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return false;
    if (h == '::1') return true;
    if (h.contains(':')) {
      final address = InternetAddress.tryParse(h);
      if (address == null ||
          address.type != InternetAddressType.IPv6 ||
          h.contains('%')) {
        return false;
      }
      return address.rawAddress[0] & 0xfe == 0xfc; // fc00::/7 ULA
    }

    final octets = _ipv4Octets(h);
    if (octets == null) return false;
    final a = octets[0];
    final b = octets[1];
    if (a == 127) return true; // loopback 127.0.0.0/8
    if (a == 10) return true; // LAN 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // LAN 172.16.0.0/12
    if (a == 192 && b == 168) return true; // LAN 192.168.0.0/16
    if (a == 100 && b >= 64 && b <= 127) {
      return true; // CGNAT/Tailscale 100.64.0.0/10
    }
    return false;
  }

  /// Devuelve los 4 octetos de [host] si es una IPv4 literal, o null.
  static List<int>? _ipv4Octets(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final p in parts) {
      if (p.isEmpty ||
          (p.length > 1 && p.startsWith('0')) ||
          !RegExp(r'^\d+$').hasMatch(p)) {
        return null;
      }
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
      octets.add(n);
    }
    return octets;
  }
}
