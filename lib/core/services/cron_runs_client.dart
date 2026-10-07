// Service wrapper for the optional cron job run-history endpoint.
//
// Hermes Dashboard may expose GET /api/cron/jobs/:id/runs returning a list of
// execution records. This client probes that endpoint and gracefully degrades
// to an empty list with a human-readable reason when the gateway does not
// support it (HTTP 404 / 405 / parse error).
//
// Auth pattern replicates DashboardClient._authHeaders() — reads the SPA
// session token from the dashboard homepage and sends it as
// X-Hermes-Session-Token, which is how all dashboard-only endpoints work.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';
import '../utils/private_http_client.dart';

/// Result of a cron run-history fetch. Either a list of runs or a
/// human-readable reason why history is unavailable.
sealed class CronRunsResult {
  const CronRunsResult();
}

class CronRunsData extends CronRunsResult {
  final List<Map<String, dynamic>> runs;
  const CronRunsData(this.runs);
}

class CronRunsUnavailable extends CronRunsResult {
  final String reason;
  const CronRunsUnavailable(this.reason);
}

class CronRunsClient {
  final String baseUrl;
  final http.Client _http;
  String? _token;

  static const _kTimeout = Duration(seconds: 10);

  CronRunsClient({
    required String host,
    int port = 9119,
    bool useHttps = false,
    http.Client? httpClientOverride,
  }) : baseUrl = TransportPrivacy.requireAllowed(
         '${useHttps ? 'https' : 'http'}://$host:$port',
       ),
       _http = PrivateHttpClient(httpClientOverride ?? http.Client());

  Future<String?> _getToken() async {
    if (_token != null) return _token;
    try {
      final res = await _http.get(Uri.parse('$baseUrl/')).timeout(_kTimeout);
      if (res.statusCode != 200) return null;
      final match = RegExp(
        r'window\.__HERMES_SESSION_TOKEN__="([^"]+)";',
      ).firstMatch(res.body);
      _token = match?.group(1);
      return _token;
    } catch (e) {
      debugPrint('[cron-runs] excepción silenciada (se devuelve null): $e');
      return null;
    }
  }

  /// Fetches run history for [jobId].
  ///
  /// Returns [CronRunsData] with the list (possibly empty) if the endpoint
  /// is available and responds with a parseable list.
  /// Returns [CronRunsUnavailable] with a reason if the gateway does not
  /// support the endpoint or an error occurs.
  Future<CronRunsResult> fetchRuns(String jobId) async {
    final token = await _getToken();
    if (token == null) {
      return const CronRunsUnavailable(
        'History unavailable: could not get the dashboard token.',
      );
    }

    try {
      final headers = {
        'X-Hermes-Session-Token': token,
        'Content-Type': 'application/json',
      };
      final res = await _http
          .get(
            Uri.parse('$baseUrl/api/cron/jobs/$jobId/runs'),
            headers: headers,
          )
          .timeout(_kTimeout);

      if (res.statusCode == 404 || res.statusCode == 405) {
        return const CronRunsUnavailable(
          'History not available in this gateway version.',
        );
      }
      if (res.statusCode == 401) {
        _token = null;
        return const CronRunsUnavailable(
          'No access to history: invalid session token.',
        );
      }
      if (res.statusCode != 200) {
        return CronRunsUnavailable(
          'History unavailable (HTTP ${res.statusCode}).',
        );
      }

      final decoded = jsonDecode(res.body);
      List<dynamic> rawList;
      if (decoded is List<dynamic>) {
        rawList = decoded;
      } else if (decoded is Map<String, dynamic> &&
          decoded['data'] is List<dynamic>) {
        rawList = decoded['data'] as List<dynamic>;
      } else if (decoded is Map<String, dynamic> &&
          decoded['runs'] is List<dynamic>) {
        rawList = decoded['runs'] as List<dynamic>;
      } else {
        return const CronRunsUnavailable(
          'History not available in this gateway version.',
        );
      }

      final runs = rawList.whereType<Map<String, dynamic>>().toList();
      return CronRunsData(runs);
    } on Exception catch (e) {
      return CronRunsUnavailable('Error loading history: $e');
    }
  }

  void close() => _http.close();
}
