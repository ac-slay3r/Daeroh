// Client for the skills.sh public registry (https://skills.sh).
//
// API status (verified 2026-06-10):
//   GET /api/v1/skills/search?q=<query>&limit=<n>  — requires Bearer auth (HTTP 401 anon)
//   GET /api/v1/skills?view=trending|all-time|hot   — requires Bearer auth (HTTP 401 anon)
//
// Both endpoints require a Vercel OIDC token — no public anonymous access.
// This client degrades gracefully: all public methods return empty results and
// expose [isAvailable] = false so the UI can show an honest empty state.
//
// Install command (from https://skills.sh/docs/cli):
//   npx skills add <owner>/<repo>
// e.g.  npx skills add vercel-labs/agent-skills
//
// Only called from SkillsScreen tabs. No background calls, no telemetry.

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/private_http_client.dart';

/// A single skill entry from the skills.sh registry.
class StoreSkill {
  final String id;
  final String slug;
  final String name;
  final String source;
  final int installs;
  final String sourceType;
  final String installUrl;
  final String url;
  final String description;

  const StoreSkill({
    required this.id,
    required this.slug,
    required this.name,
    required this.source,
    required this.installs,
    required this.sourceType,
    required this.installUrl,
    required this.url,
    this.description = '',
  });

  factory StoreSkill.fromJson(Map<String, dynamic> json) {
    return StoreSkill(
      id: json['id'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String? ?? '',
      source: json['source'] as String? ?? '',
      installs: (json['installs'] as num?)?.toInt() ?? 0,
      sourceType: json['sourceType'] as String? ?? 'github',
      installUrl: json['installUrl'] as String? ?? '',
      url: json['url'] as String? ?? '',
      description: (json['description'] ?? json['summary'] ?? '').toString(),
    );
  }

  /// Identificador instalable vía bridge (registro de Hermes) si lo es. Acepta
  /// 2–5 segmentos (p.ej. `owner/repo`, `official/email/agentmail`,
  /// `skills-sh/owner/repo/skill`), opcionalmente con `@skill`. Debe coincidir
  /// con el `SKILL_RE` REAL del servidor y con `BridgeClient.isValidSkillSource`
  /// (el catálogo oficial de skills.sh usa rutas multi-segmento).
  String? get bridgeSource {
    final s = installUrl.trim();
    return RegExp(r'^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+){1,4}(@[A-Za-z0-9_.-]+)?$')
            .hasMatch(s)
        ? s
        : null;
  }

  /// The command a user runs on the Hermes server to install this skill.
  /// Format: `npx skills add <installUrl>`
  String get installCommand => 'npx skills add $installUrl';
}

/// Result of a search or list operation against skills.sh.
class StoreResult {
  final List<StoreSkill> skills;
  final String? error;

  const StoreResult({required this.skills, this.error});

  bool get hasError => error != null;
  bool get isEmpty => skills.isEmpty;
}

/// Unauthenticated HTTP client for skills.sh.
///
/// Since the skills.sh API requires Vercel OIDC tokens (no public key), all
/// live requests return [StoreResult] with an empty list and an explanatory
/// [StoreResult.error] so the UI can surface an honest empty state. The
/// architecture is in place so the client can be upgraded if a public token
/// becomes available.
class SkillStoreClient {
  static const String _baseUrl = 'https://skills.sh';
  static const Duration _timeout = Duration(seconds: 10);
  static const String _userAgent = 'hermes-android/1.0';

  // Set to non-empty to enable live API calls when a token is available.
  final String? _bearerToken;
  final http.Client _http;

  SkillStoreClient({String? bearerToken, http.Client? httpClient})
    : _bearerToken = bearerToken, // ignore: prefer_initializing_formals
      _http = PrivateHttpClient(httpClient ?? http.Client());

  /// Whether this client has authentication credentials and can make live
  /// requests to skills.sh. Always false in the current build.
  bool get isAvailable {
    final t = _bearerToken;
    return t != null && t.isNotEmpty;
  }

  Map<String, String> get _headers => {
    'User-Agent': _userAgent,
    'Accept': 'application/json',
    if (isAvailable) 'Authorization': 'Bearer $_bearerToken',
  };

  /// Search skills.sh by query string.
  ///
  /// Returns [StoreResult.error] with an explanation when the API is
  /// unavailable (no auth token) or the request fails.
  Future<StoreResult> search(String query, {int limit = 30}) async {
    if (!isAvailable) {
      return const StoreResult(
        skills: [],
        error: 'skills.sh API requires authentication — not available',
      );
    }
    if (query.trim().length < 2) {
      return const StoreResult(skills: [], error: null);
    }
    try {
      final uri = Uri.parse(
        '$_baseUrl/api/v1/skills/search'
        '?q=${Uri.encodeQueryComponent(query.trim())}&limit=$limit',
      );
      final res = await _http.get(uri, headers: _headers).timeout(_timeout);
      if (res.statusCode == 401 || res.statusCode == 403) {
        return const StoreResult(
          skills: [],
          error: 'skills.sh API requires authentication',
        );
      }
      if (res.statusCode != 200) {
        return StoreResult(skills: [], error: 'HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List? ?? [];
      final skills = data
          .whereType<Map<String, dynamic>>()
          .map(StoreSkill.fromJson)
          .toList();
      return StoreResult(skills: skills);
    } catch (e) {
      return StoreResult(skills: [], error: e.toString());
    }
  }

  /// Fetch the leaderboard from skills.sh, optionally filtered by [view].
  ///
  /// [view] accepts 'all-time', 'trending', or 'hot'.
  Future<StoreResult> listByView(
    String view, {
    int page = 0,
    int perPage = 50,
  }) async {
    if (!isAvailable) {
      return const StoreResult(
        skills: [],
        error: 'skills.sh API requires authentication — not available',
      );
    }
    try {
      final uri = Uri.parse(
        '$_baseUrl/api/v1/skills'
        '?view=$view&page=$page&per_page=$perPage',
      );
      final res = await _http.get(uri, headers: _headers).timeout(_timeout);
      if (res.statusCode == 401 || res.statusCode == 403) {
        return const StoreResult(
          skills: [],
          error: 'skills.sh API requires authentication',
        );
      }
      if (res.statusCode != 200) {
        return StoreResult(skills: [], error: 'HTTP ${res.statusCode}');
      }
      final body = jsonDecode(res.body);
      final List<dynamic> data = body is List
          ? body
          : ((body as Map)['data'] as List? ?? []);
      final skills = data
          .whereType<Map<String, dynamic>>()
          .map(StoreSkill.fromJson)
          .toList();
      return StoreResult(skills: skills);
    } catch (e) {
      return StoreResult(skills: [], error: e.toString());
    }
  }

  void close() => _http.close();
}
