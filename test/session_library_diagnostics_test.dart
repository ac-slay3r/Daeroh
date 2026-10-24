import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/session_library_diagnostics.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SessionLibraryDiagnostic', () {
    test('keeps only allowlisted HTTP status categories', () {
      expect(
        SessionLibraryDiagnostic.fromError(
          const CoreReadException(CoreReadErrorKind.auth, statusCode: 401),
        ).label,
        'HTTP 401',
      );
      expect(
        SessionLibraryDiagnostic.fromError(
          const CoreReadException(CoreReadErrorKind.forbidden, statusCode: 403),
        ).label,
        'HTTP 403',
      );
      expect(
        SessionLibraryDiagnostic.fromError(
          const CoreReadException(
            CoreReadErrorKind.profileUnavailable,
            statusCode: 404,
          ),
        ).label,
        'HTTP 404',
      );
      expect(
        SessionLibraryDiagnostic.fromError(
          const CoreReadException(
            CoreReadErrorKind.temporarilyUnavailable,
            statusCode: 503,
          ),
        ).label,
        'HTTP 503',
      );
    });

    test('classifies transport, timeout, and malformed responses', () {
      expect(
        SessionLibraryDiagnostic.fromError(TimeoutException('timed out')).label,
        'timeout',
      );
      expect(
        SessionLibraryDiagnostic.fromError(
          http.ClientException('network'),
        ).label,
        'transport',
      );
      expect(
        SessionLibraryDiagnostic.fromError(
          const FormatException('bad body'),
        ).label,
        'invalid-response',
      );
    });

    test(
      'never retains a secret, header, URL, profile, or session payload',
      () {
        final diagnostic = SessionLibraryDiagnostic.fromError(
          StateError(
            'Bearer super-secret Authorization: cookie=abc '
            'https://user:pass@example.test/p/android/api/sessions/session-42',
          ),
        );

        expect(diagnostic.label, 'unknown');
        expect(diagnostic.label, isNot(contains('secret')));
        expect(diagnostic.label, isNot(contains('Authorization')));
        expect(diagnostic.label, isNot(contains('android')));
        expect(diagnostic.label, isNot(contains('session-42')));
      },
    );
  });
}
