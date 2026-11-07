import 'dart:io';

import 'transport_privacy.dart';

/// Dedicated WebSocket handshake client. dart:io WebSocket.connect otherwise
/// follows HTTP redirects before checking the 101 response (including to a
/// different cleartext host). Keep one HttpClient for connection reuse.
final HttpClient privateWebSocketHttpClient = _NoRedirectWebSocketClient();

class _NoRedirectWebSocketClient implements HttpClient {
  final HttpClient _inner = HttpClient();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    TransportPrivacy.requireAllowed(url.toString());
    final request = await _inner.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  // WebSocket.connect calls openUrl only; this intentionally cannot be used as
  // a general-purpose HttpClient with unguarded operations (get, post, etc.).
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('WebSocket handshake client: openUrl only');
}
