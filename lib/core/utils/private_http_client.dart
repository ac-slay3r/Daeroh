import 'package:http/http.dart' as http;

import 'transport_privacy.dart';

/// Enforces the transport boundary on every HTTP request, including redirects.
/// Only same-origin GET/HEAD redirects are replayed; request bodies are never
/// replayed and credentials never cross an origin boundary.
class PrivateHttpClient extends http.BaseClient {
  PrivateHttpClient(this._inner);

  final http.Client _inner;
  static const int _maxRedirects = 5;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    TransportPrivacy.requireAllowed(request.url.toString());
    final original = request.url;
    final followRedirects = request.followRedirects;
    var current = request;
    for (var redirects = 0; ; redirects++) {
      current.followRedirects = false;
      final response = await _inner.send(current);
      if (response.statusCode < 300 || response.statusCode > 399) {
        return response;
      }
      final location = response.headers['location'];
      if (!followRedirects ||
          location == null ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        return response;
      }
      final next = current.url.resolve(location);
      // Drain before throwing so the connection can be reused. Never include
      // Location in diagnostics: it may contain bearer material in its query.
      await response.stream.drain<void>();
      if (redirects >= _maxRedirects ||
          next.scheme != original.scheme ||
          next.host != original.host ||
          next.port != original.port ||
          next.userInfo.isNotEmpty ||
          TransportPrivacy.classify(next.toString()) ==
              TransportPrivacyClass.publicCleartext) {
        throw http.ClientException('HTTP redirect blocked by transport policy');
      }
      current = http.Request(request.method, next)
        ..headers.addAll(request.headers);
    }
  }

  @override
  void close() => _inner.close();
}
