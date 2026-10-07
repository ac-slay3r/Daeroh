import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/pairing_link_navigation.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final first = Uri.parse('hermes://pair?host=first&port=8642&token=one');
  final second = Uri.parse('hermes://pair?host=second&port=8642&token=two');

  Future<(AppLockService, PairingLinkNavigation)> mount(
    WidgetTester tester, {
    required bool locked,
  }) async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': locked});
    final prefs = await SharedPreferences.getInstance();
    final lock = AppLockService(prefs);
    final navKey = GlobalKey<NavigatorState>();
    final navigation = PairingLinkNavigation(
      lock: lock,
      navigatorKey: navKey,
      routeForLink: (link) => MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: Text('pair: ${link.host}')),
      ),
    );
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        theme: AppTheme.fromMode(AppThemeMode.dark),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) =>
            AppLockGate(lock: lock, navigatorKey: navKey, child: child!),
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpAndSettle();
    return (lock, navigation);
  }

  testWidgets(
    'initial and stream links stay behind lock until unlock, once each',
    (tester) async {
      final (lock, navigation) = await mount(tester, locked: true);
      navigation.handle(first); // getInitialLink
      navigation.handle(first); // duplicate stream delivery
      navigation.handle(second); // distinct stream delivery
      await tester.pumpAndSettle();
      expect(find.text('HERMES'), findsOneWidget);
      expect(find.text('pair: first', skipOffstage: false), findsNothing);
      expect(find.text('pair: second', skipOffstage: false), findsNothing);

      lock.unlock();
      await tester.pumpAndSettle();
      expect(find.text('pair: second'), findsOneWidget);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.text('pair: first'), findsOneWidget);
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unlocked stream link opens immediately and duplicate is suppressed',
    (tester) async {
      final (_, navigation) = await mount(tester, locked: false);
      navigation.handle(first);
      navigation.handle(first);
      await tester.pumpAndSettle();
      expect(find.text('pair: first'), findsOneWidget);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background lock prevents delivery until foreground unlock', (
    tester,
  ) async {
    final (lock, navigation) = await mount(tester, locked: true);
    lock.unlock();
    await tester.pumpAndSettle();
    lock.lockNow(); // background timeout / resume lock
    await tester.pumpAndSettle();
    navigation.handle(first);
    await tester.pumpAndSettle();
    expect(find.text('HERMES'), findsOneWidget);
    expect(find.text('pair: first', skipOffstage: false), findsNothing);
    lock.unlock();
    await tester.pumpAndSettle();
    expect(find.text('pair: first'), findsOneWidget);
  });

  testWidgets('relock before deferred delivery keeps URI queued', (tester) async {
    final (lock, navigation) = await mount(tester, locked: true);
    navigation.handle(first);
    lock.unlock();
    lock.lockNow();
    await tester.pumpAndSettle();
    expect(find.text('pair: first', skipOffstage: false), findsNothing);
    lock.unlock();
    await tester.pumpAndSettle();
    expect(find.text('pair: first'), findsOneWidget);
  });

  testWidgets('invalid URI is ignored while unlocked', (tester) async {
    final (_, navigation) = await mount(tester, locked: false);
    navigation.handle(Uri.parse('https://example.com/?token=secret'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
