import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/private_http_client.dart';
import '../utils/transport_privacy.dart';

/// Fetches the live model catalog from a custom provider without weakening the
/// app's private-transport boundary.
///
/// Custom providers may expose either OpenAI-compatible `/v1/models` or native
/// Ollama `/api/tags`. Redirect handling stays inside [PrivateHttpClient], so a
/// catalog lookup can never pivot to another origin or public cleartext URL.
Future<List<String>> discoverCustomProviderModels(
  String baseUrl, {
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final normalized = TransportPrivacy.requireAllowed(baseUrl.trim());
  final rawClient = httpClient ?? http.Client();
  final client = PrivateHttpClient(rawClient);
  final base = normalized.replaceFirst(RegExp(r'/+$'), '');

  try {
    final openAi = await client
        .get(Uri.parse('$base/v1/models'))
        .timeout(timeout);
    if (openAi.statusCode == 200) {
      final models = _openAiModelIds(openAi.body);
      if (models.isNotEmpty) return models;
    }

    final ollama = await client
        .get(Uri.parse('$base/api/tags'))
        .timeout(timeout);
    if (ollama.statusCode == 200) return _ollamaModelNames(ollama.body);
    return const [];
  } finally {
    if (httpClient == null) client.close();
  }
}

List<String> _openAiModelIds(String body) {
  final data = jsonDecode(body);
  if (data is! Map) return const [];
  final rows = data['data'];
  if (rows is! List) return const [];
  return rows
      .whereType<Map>()
      .map((row) => (row['id'] ?? '').toString().trim())
      .where((id) => id.isNotEmpty)
      .toList();
}

List<String> _ollamaModelNames(String body) {
  final data = jsonDecode(body);
  if (data is! Map) return const [];
  final rows = data['models'];
  if (rows is! List) return const [];
  return rows
      .whereType<Map>()
      .map((row) => (row['name'] ?? '').toString().trim())
      .where((name) => name.isNotEmpty)
      .toList();
}
