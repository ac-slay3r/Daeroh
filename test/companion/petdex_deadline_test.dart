import 'dart:async';

// Provided by flutter_test, matching the existing network resilience tests.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final image = Uri.parse('https://assets.petdex.dev/sprite.webp');

  test(
    'chunks cannot extend deadline; cancellation does not delay failure',
    () {
      fakeAsync((clock) {
        var cancelled = false;
        final cancelPending = Completer<void>();
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
            return cancelPending.future;
          },
        );
        final service = PetdexRemoteService(
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(body.stream, 200),
          ),
        );
        Object? failure;
        service
            .loadImage(image)
            .then<void>(
              (_) => fail('must time out'),
              onError: (Object error) {
                failure = error;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 15));
        body.add([1]);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 4));
        body.add([2]);
        clock.flushMicrotasks();
        expect(failure, isNull);
        expect(cancelled, isFalse);
        clock.elapse(const Duration(seconds: 1));
        expect(failure, isA<PetdexRemoteException>());
        expect(cancelled, isTrue);
        expect(service.imageCacheEntriesForTesting, 0);
        cancelPending.complete();
        unawaited(body.close());
        clock.flushMicrotasks();
        service.dispose();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  for (final status in [200, 302, 500]) {
    test('late send response $status is cancelled and never cached', () {
      fakeAsync((clock) {
        final response = Completer<http.StreamedResponse>();
        var cancelled = false;
        var requests = 0;
        final body = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        final service = PetdexRemoteService(
          client: MockClient.streaming((_, _) {
            requests++;
            return response.future;
          }),
        );
        Object? failure;
        service
            .loadImage(image)
            .then<void>(
              (_) => fail('must time out'),
              onError: (Object error) {
                failure = error;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 20));
        expect(failure, isA<PetdexRemoteException>());
        expect(cancelled, isFalse);
        response.complete(
          http.StreamedResponse(
            body.stream,
            status,
            headers: {'location': '/next.webp'},
          ),
        );
        clock.flushMicrotasks();
        expect(cancelled, isTrue);
        expect(requests, 1);
        expect(service.imageCacheEntriesForTesting, 0);
        unawaited(body.close());
        clock.flushMicrotasks();
        service.dispose();
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }

  test('redirect and send time consume the same body deadline', () {
    fakeAsync((clock) {
      final first = Completer<http.StreamedResponse>();
      final redirectBody = StreamController<List<int>>(
        onCancel: () => (Completer<void>()..complete()).future,
      );
      var requests = 0;
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final service = PetdexRemoteService(
        client: MockClient.streaming(
          (_, _) async => ++requests == 1
              ? first.future
              : http.StreamedResponse(body.stream, 200),
        ),
      );
      Object? failure;
      service
          .loadImage(image)
          .then<void>(
            (_) => fail('must time out'),
            onError: (Object error) {
              failure = error;
            },
          );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 15));
      first.complete(
        http.StreamedResponse(
          redirectBody.stream,
          302,
          headers: {'location': '/next.webp'},
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(Duration.zero);
      expect(failure, isNull);
      expect(requests, 2);
      body.add([1]);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
      expect(failure, isA<PetdexRemoteException>());
      expect(cancelled, isTrue);
      expect(service.imageCacheEntriesForTesting, 0);
      unawaited(redirectBody.close());
      unawaited(body.close());
      clock.flushMicrotasks();
      service.dispose();
      expect(clock.pendingTimers, isEmpty);
    });
  });
}
