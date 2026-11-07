import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/core_read.dart';

/// A deliberately body-free, allowlisted status for the server session library.
///
/// Do not retain [Object.toString] here: HTTP bodies and transport exceptions
/// can include credentials, URLs, profiles, session IDs, or transcript content.
final class SessionLibraryDiagnostic {
  final String label;

  const SessionLibraryDiagnostic._(this.label);

  static const _unknown = SessionLibraryDiagnostic._('unknown');

  factory SessionLibraryDiagnostic.fromError(Object error) {
    if (error is CoreReadException) {
      return switch (error.statusCode) {
        401 => const SessionLibraryDiagnostic._('HTTP 401'),
        403 => const SessionLibraryDiagnostic._('HTTP 403'),
        404 => const SessionLibraryDiagnostic._('HTTP 404'),
        503 => const SessionLibraryDiagnostic._('HTTP 503'),
        _
            when error.kind == CoreReadErrorKind.malformed ||
                error.kind == CoreReadErrorKind.paginationStalled =>
          const SessionLibraryDiagnostic._('invalid-response'),
        _ when error.kind == CoreReadErrorKind.temporarilyUnavailable =>
          const SessionLibraryDiagnostic._('transport'),
        _ => _unknown,
      };
    }
    if (error is TimeoutException) {
      return const SessionLibraryDiagnostic._('timeout');
    }
    if (error is http.ClientException) {
      return const SessionLibraryDiagnostic._('transport');
    }
    if (error is FormatException || error is TypeError) {
      return const SessionLibraryDiagnostic._('invalid-response');
    }
    return _unknown;
  }
}
