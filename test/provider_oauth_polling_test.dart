import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;

class Fixture {
  final nav = GlobalKey<NavigatorState>();
  int calls = 0, launches = 0, completions = 0;
  bool? result;
  late String expired;
  Future<void> open(
    WidgetTester t, {
    int expiry = 0,
    List<Duration>? delays,
    Future<Map<String, dynamic>> Function()? poll,
  }) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [hermesRouteObserver],
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(body: Text('base')),
      ),
    );
    nav.currentState!
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => ProviderOAuthLoginScreen(
              providerName: 'Fixture',
              providerSlug: 'fixture',
              url: 'https://idp.example/authorize',
              expiresIn: expiry,
              pollDelays: delays,
              launchBrowser: (_) async {
                launches++;
                return true;
              },
              poll: () {
                calls++;
                return poll?.call() ?? Future.value({'status': 'pending'});
              },
            ),
          ),
        )
        .then((value) {
          completions++;
          result = value;
        });
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expired = Strings.of(
      t.element(find.byType(ProviderOAuthLoginScreen)),
    ).mdlCodeExpired;
    addTearDown(() async {
      await t.pumpWidget(const SizedBox.shrink());
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
    });
  }

  Future<void> seconds(WidgetTester t, int n) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(seconds: 1));
      await t.pump();
    }
  }

  Future<void> cover(WidgetTester t) async {
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('cover')),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('R1 pending flow must still detect success after 51 seconds', (
    t,
  ) async {
    final f = Fixture();
    bool approved = false;
    await f.open(
      t,
      poll: () async => {'status': approved ? 'approved' : 'pending'},
    );
    await f.seconds(t, 60);
    expect(
      f.calls,
      6,
      reason: 'six pending results consumed default delay list',
    );
    approved = true;
    await f.seconds(t, 25);
    expect(
      f.result,
      isTrue,
      reason: 'approval at 60s must be detected before 300s expiry',
    );
  });
  for (final expiry in [0, 5]) {
    testWidgets('R2 elapsed expiry survives pause expiresIn=$expiry', (
      t,
    ) async {
      final f = Fixture();
      await f.open(t, expiry: expiry);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await f.seconds(t, expiry == 0 ? 301 : 6);
      expect(f.calls, 0);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 1));
      expect(
        f.calls,
        0,
        reason: 'expired session must not be polled on resume',
      );
      expect(find.text(f.expired), findsOneWidget);
    });
  }
  testWidgets('R3 app resume must not uncover covered OAuth route', (t) async {
    final f = Fixture();
    await f.open(t);
    await f.cover(t);
    await f.seconds(t, 4);
    expect(f.calls, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 1));
    expect(f.calls, 0, reason: 'route remains covered after app resume');
  });
  testWidgets('R3 popping cover while app paused must not poll', (t) async {
    final f = Fixture();
    await f.open(t);
    await f.cover(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    f.nav.currentState!.pop();
    await t.pump(const Duration(milliseconds: 1));
    expect(f.calls, 0, reason: 'foreground remains paused after didPopNext');
  });
  testWidgets('control slow poll is single flight through many ticks', (
    t,
  ) async {
    final f = Fixture();
    final pending = Completer<Map<String, dynamic>>();
    await f.open(t, poll: () => pending.future);
    await f.seconds(t, 15);
    expect(f.calls, 1);
    pending.complete({'status': 'pending'});
    await t.pump();
    await f.seconds(t, 2);
    expect(f.calls, 1);
    await f.seconds(t, 1);
    expect(f.calls, 2);
  });
  testWidgets(
    'control late paused success ignored then one foreground recheck and pop',
    (t) async {
      final f = Fixture();
      final first = Completer<Map<String, dynamic>>();
      var n = 0;
      await f.open(
        t,
        poll: () {
          n++;
          return n == 1 ? first.future : Future.value({'status': 'approved'});
        },
      );
      await f.seconds(t, 3);
      expect(f.calls, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      first.complete({'status': 'approved'});
      await t.pump();
      expect(f.completions, 0);
      expect(f.calls, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 1));
      await t.pump(const Duration(milliseconds: 400));
      expect(f.calls, 2);
      expect(f.completions, 1);
      expect(f.result, isTrue);
      expect(f.launches, 1);
      await f.seconds(t, 20);
      expect(f.completions, 1);
      expect(f.calls, 2);
    },
  );
  testWidgets(
    'control resume before in-flight completion defers exactly one recheck',
    (t) async {
      final f = Fixture();
      final first = Completer<Map<String, dynamic>>();
      var n = 0;
      await f.open(
        t,
        poll: () {
          n++;
          return n == 1 ? first.future : Future.value({'status': 'pending'});
        },
      );
      await f.seconds(t, 3);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 1));
      expect(f.calls, 1);
      first.complete({'status': 'pending'});
      await t.pump();
      await t.pump(const Duration(milliseconds: 1));
      expect(f.calls, 2);
      expect(f.launches, 1);
    },
  );
  testWidgets('control dispose with poll in flight ignores late success', (
    t,
  ) async {
    final f = Fixture();
    final first = Completer<Map<String, dynamic>>();
    await f.open(t, poll: () => first.future);
    await f.seconds(t, 3);
    f.nav.currentState!.pop(false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    first.complete({'status': 'approved'});
    await t.pump();
    await f.seconds(t, 10);
    expect(f.calls, 1);
    expect(f.completions, 1);
    expect(f.result, isFalse);
    expect(t.takeException(), isNull);
  });
  testWidgets('control foreground expiry fences late success', (t) async {
    final f = Fixture();
    final first = Completer<Map<String, dynamic>>();
    await f.open(t, expiry: 5, poll: () => first.future);
    await f.seconds(t, 6);
    expect(find.text(f.expired), findsOneWidget);
    first.complete({'status': 'approved'});
    await t.pump();
    expect(f.completions, 0);
    expect(f.calls, 1);
  });
  for (final error in [false, true]) {
    testWidgets(
      'control slow_down or transient error delays next call error=$error',
      (t) async {
        final f = Fixture();
        await f.open(
          t,
          delays: List.filled(10, const Duration(seconds: 1)),
          poll: () async {
            if (error) throw StateError('synthetic');
            return {'status': 'slow_down'};
          },
        );
        await f.seconds(t, 1);
        expect(f.calls, 1);
        await f.seconds(t, 4);
        expect(f.calls, 1);
        await f.seconds(t, 1);
        expect(f.calls, 2);
      },
    );
  }
  testWidgets('positive expiry fences a hung poll across pause and resume', (
    t,
  ) async {
    final f = Fixture();
    final pending = Completer<Map<String, dynamic>>();
    await f.open(t, expiry: 5, poll: () => pending.future);
    await f.seconds(t, 3);
    expect(f.calls, 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await f.seconds(t, 3);
    pending.complete({'status': 'approved'});
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 1));
    expect(find.text(f.expired), findsOneWidget);
    expect(f.calls, 1);
    expect(f.completions, 0);
  });
  testWidgets(
    'route pop retires an in-flight callback before reverse disposal',
    (t) async {
      final f = Fixture();
      final first = Completer<Map<String, dynamic>>();
      await f.open(t, poll: () => first.future);
      await f.seconds(t, 3);
      expect(f.calls, 1);
      f.nav.currentState!.pop(false);
      await t.pump(const Duration(milliseconds: 1));
      final sentinel = f.nav.currentState!.push<bool>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('sentinel')),
        ),
      );
      var sentinelPopped = false;
      sentinel.then((_) => sentinelPopped = true);
      await t.pump(const Duration(milliseconds: 1));
      first.complete({'status': 'approved'});
      await t.pump();
      expect(sentinelPopped, isFalse);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('sentinel'), findsOneWidget);
    },
  );
  testWidgets('latest resume consumes obsolete in-flight recheck intent', (
    t,
  ) async {
    final f = Fixture();
    final first = Completer<Map<String, dynamic>>();
    var n = 0;
    await f.open(
      t,
      poll: () {
        n++;
        return n == 1 ? first.future : Future.value({'status': 'pending'});
      },
    );
    await f.seconds(t, 3);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 1));
    expect(f.calls, 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    first.complete({'status': 'pending'});
    await t.pump();
    expect(f.calls, 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 1));
    await t.pump(const Duration(milliseconds: 1));
    expect(f.calls, 2);
  });
  testWidgets('dismissed popup resumes a timer consumed while hidden', (
    t,
  ) async {
    final f = Fixture();
    await f.open(t);
    showDialog<void>(
      context: f.nav.currentContext!,
      builder: (_) => const AlertDialog(title: Text('popup')),
    );
    await t.pump();
    await f.seconds(t, 10);
    expect(f.calls, 0, reason: 'no poll may run behind a popup route');
    f.nav.currentState!.pop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(
      ModalRoute.of(
        t.element(find.byType(ProviderOAuthLoginScreen)),
      )!.isCurrent,
      isTrue,
    );
    await f.seconds(t, 25);
    expect(f.calls, greaterThan(0));
    expect(f.launches, 1);
  });
  testWidgets('dismissed popup rechecks after an in-flight result was hidden', (
    t,
  ) async {
    final f = Fixture();
    final first = Completer<Map<String, dynamic>>();
    var n = 0;
    await f.open(
      t,
      poll: () =>
          ++n == 1 ? first.future : Future.value({'status': 'approved'}),
    );
    await f.seconds(t, 3);
    showDialog<void>(
      context: f.nav.currentContext!,
      builder: (_) => const AlertDialog(title: Text('popup')),
    );
    await t.pump();
    first.complete({'status': 'approved'});
    await t.pump();
    expect(f.completions, 0);
    f.nav.currentState!.pop();
    await t.pump();
    await f.seconds(t, 25);
    expect(f.calls, 2);
    expect(f.result, isTrue);
    expect(f.completions, 1);
  });
}
