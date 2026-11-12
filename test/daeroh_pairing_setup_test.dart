import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

void main() {
  test('runtime lib sources contain no XPeta setup URL', () {
    final urls = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      urls.addAll(
        RegExp(
          r'''https?://[^\s'")]+''',
        ).allMatches(entity.readAsStringSync()).map((m) => m.group(0)!),
      );
    }
    expect(
      urls.where(
        (url) => RegExp(r'xP3ta|xpetalab', caseSensitive: false).hasMatch(url),
      ),
      isEmpty,
    );
  });

  test('Linux command verifies a downloaded script before execution', () {
    final command = ServerSetupGenerator.curlCommand;
    expect(command, contains('curl --fail'));
    expect(command, contains('sha256sum -c -'));
    expect(command, contains('sh "\$file"'));
    expect(command, isNot(contains('| sh "')));
    expect(command, isNot(contains('http://')));
    expect(
      ServerSetupGenerator.setupCommandFor(ServerHostPlatform.windows),
      contains('Linux'),
    );
  });

  test(
    'real Python parses admitted environment syntax without changing keys',
    () async {
      final fixture = await _PairingFixture.start();
      addTearDown(fixture.close);
      const cases = <({String name, List<int> env, String token})>[
        (
          name: 'LF',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            108,
            102,
            10,
          ],
          token: 'lf',
        ),
        (
          name: 'CRLF',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            99,
            114,
            108,
            102,
            13,
            10,
          ],
          token: 'crlf',
        ),
        (
          name: 'no final newline',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            110,
            111,
            45,
            102,
            105,
            110,
            97,
            108,
            45,
            110,
            101,
            119,
            108,
            105,
            110,
            101,
          ],
          token: 'no-final-newline',
        ),
        (
          name: 'export',
          env: [
            101,
            120,
            112,
            111,
            114,
            116,
            32,
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            101,
            120,
            112,
            111,
            114,
            116,
            101,
            100,
            10,
          ],
          token: 'exported',
        ),
        (
          name: 'single quote',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            39,
            115,
            105,
            110,
            103,
            108,
            101,
            39,
            10,
          ],
          token: 'single',
        ),
        (
          name: 'double quote',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            34,
            100,
            111,
            117,
            98,
            108,
            101,
            34,
            10,
          ],
          token: 'double',
        ),
        (
          name: 'leading whitespace',
          env: [
            32,
            9,
            101,
            120,
            112,
            111,
            114,
            116,
            9,
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            32,
            61,
            32,
            115,
            112,
            97,
            99,
            101,
            100,
            32,
            9,
            13,
            10,
          ],
          token: 'spaced',
        ),
        (
          name: 'ends in r',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            115,
            117,
            102,
            102,
            105,
            120,
            45,
            114,
          ],
          token: 'suffix-r',
        ),
        (
          name: 'ends in n',
          env: [
            65,
            80,
            73,
            95,
            83,
            69,
            82,
            86,
            69,
            82,
            95,
            75,
            69,
            89,
            61,
            115,
            117,
            102,
            102,
            105,
            120,
            45,
            110,
          ],
          token: 'suffix-n',
        ),
      ];
      for (final value in cases) {
        await fixture.writeEnv(value.env);
        fixture.expectedToken = value.token;
        fixture.requests.clear();
        final result = await fixture.run(showLink: true);
        expect(result.exitCode, 0, reason: '${value.name}: ${result.stderr}');
        final link = _pairingLink(result.stdout);
        expect(link.token, value.token, reason: value.name);
        expect(fixture.requests, [
          'Bearer daeroh-pairing-wrong-bearer',
          'Bearer ${value.token}',
        ]);
      }
    },
  );

  test('real Python rejects invalid environment files before HTTP', () async {
    final fixture = await _PairingFixture.start();
    addTearDown(fixture.close);
    for (final text in [
      'OTHER=value\n',
      'API_SERVER_KEY=one\nAPI_SERVER_KEY=two\n',
      'API_SERVER_KEY="unmatched\n',
      "API_SERVER_KEY='unmatched\n",
    ]) {
      await fixture.writeEnv(text.codeUnits);
      fixture.requests.clear();
      final result = await fixture.run();
      expect(result.exitCode, isNonZero, reason: text);
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('hermes://pair?')),
      );
      expect(fixture.requests, isEmpty, reason: text);
    }
  });

  test(
    'dashboard uses api health, rejects redirects, and reports state',
    () async {
      final fixture = await _PairingFixture.start(startDashboard: true);
      addTearDown(fixture.close);
      await fixture.writeEnv('API_SERVER_KEY=dashboard-token\n'.codeUnits);
      fixture.expectedToken = 'dashboard-token';
      final confirmed = await fixture.run(
        showLink: true,
        dashboardPort: fixture.dashboard!.port,
      );
      expect(confirmed.exitCode, 0, reason: confirmed.stderr.toString());
      expect(
        _pairingLink(confirmed.stdout).dashboardUrl,
        'http://${fixture.host.address}:${fixture.dashboard!.port}',
      );
      expect(fixture.dashboardPaths, ['/api/health']);

      fixture.dashboardMode = _DashboardMode.redirect;
      fixture.dashboardPaths.clear();
      final redirected = await fixture.run(
        showLink: true,
        dashboardPort: fixture.dashboard!.port,
      );
      expect(redirected.exitCode, 0, reason: redirected.stderr.toString());
      expect(_pairingLink(redirected.stdout).dashboardUrl, isNull);
      expect(fixture.dashboardPaths, ['/api/health']);
      final closed = await fixture.run(dashboardPort: fixture.dashboard!.port);
      expect(closed.exitCode, 0, reason: closed.stderr.toString());
      expect(
        closed.stderr,
        contains(
          'Gateway authentication was checked; dashboard was not confirmed.',
        ),
      );

      final notRequested = await fixture.run(showLink: true);
      expect(notRequested.exitCode, 0);
      expect(_pairingLink(notRequested.stdout).dashboardUrl, isNull);
      final noDashboard = await fixture.run();
      expect(noDashboard.exitCode, 0, reason: noDashboard.stderr.toString());
      expect(
        noDashboard.stderr,
        contains(
          'Gateway authentication was checked; dashboard was not requested.',
        ),
      );
    },
  );

  test(
    'whole probe deadline rejects a trickle and accepts timely responses',
    () async {
      final fixture = await _PairingFixture.start();
      addTearDown(fixture.close);
      await fixture.writeEnv('API_SERVER_KEY=deadline-token\n'.codeUnits);
      fixture.expectedToken = 'deadline-token';
      fixture.trickle = true;
      final watch = Stopwatch()..start();
      final slow = await fixture.run().timeout(const Duration(seconds: 8));
      watch.stop();
      expect(slow.exitCode, isNonZero);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      fixture.trickle = false;
      final timely = await fixture.run(showLink: true);
      expect(timely.exitCode, 0, reason: timely.stderr.toString());
      expect(_pairingLink(timely.stdout).token, 'deadline-token');
    },
  );

  test(
    'failed precondition performs no writes and non-TTY stdout has no secret',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'daeroh-pair-negative-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final home = Directory('${root.path}/home')..createSync();
      File(
        '${home.path}/.env',
      ).writeAsStringSync('API_SERVER_KEY=synthetic-no-leak\n');
      final foreign = File('${home.path}/hermes-gateway.service')
        ..writeAsStringSync('foreign bytes\n');
      final before = await foreign.readAsBytes();
      final systemctl = File('${bin.path}/systemctl')
        ..writeAsStringSync('#!/bin/sh\nexit 3\n');
      await _makeExecutable(systemctl);
      final result = await Process.run(
        'sh',
        ['scripts/hermes-mobile-setup.sh'],
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'HERMES_HOME': home.path,
        },
      );
      expect(result.exitCode, isNonZero);
      expect(await foreign.readAsBytes(), before);
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('synthetic-no-leak')),
      );
    },
  );
}

class _PairingFixture {
  _PairingFixture._(this.root, this.host, this.gateway);
  final Directory root;
  final InternetAddress host;
  final HttpServer gateway;
  HttpServer? dashboard;
  final requests = <String>[];
  final dashboardPaths = <String>[];
  String expectedToken = '';
  bool trickle = false;
  _DashboardMode dashboardMode = _DashboardMode.ok;

  static Future<_PairingFixture> start({bool startDashboard = false}) async {
    final root = await Directory.systemTemp.createTemp('daeroh-pair-real-');
    final host = await _privateAddress();
    final gateway = await HttpServer.bind(host, 0);
    final fixture = _PairingFixture._(root, host, gateway);
    await Directory('${root.path}/home').create();
    final bin = Directory('${root.path}/bin')..createSync();
    final systemctl = File('${bin.path}/systemctl')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    await _makeExecutable(systemctl);
    gateway.listen(fixture._gateway);
    if (startDashboard) {
      fixture.dashboard = await HttpServer.bind(host, 0);
      fixture.dashboard!.listen(fixture._dashboard);
    }
    return fixture;
  }

  Future<void> writeEnv(List<int> bytes) =>
      File('${root.path}/home/.env').writeAsBytes(bytes);

  Future<ProcessResult> run({
    bool showLink = false,
    int? dashboardPort,
  }) => Process.run(
    showLink ? 'script' : 'sh',
    showLink
        ? [
            '-q',
            '-c',
            '${File('scripts/hermes-mobile-setup.sh').absolute.path} --show-link',
            '/dev/null',
          ]
        : ['scripts/hermes-mobile-setup.sh'],
    environment: {
      'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
      'HERMES_HOME': '${root.path}/home',
      'HERMES_PAIR_HOST': host.address,
      'HERMES_PAIR_PORT': '${gateway.port}',
      if (dashboardPort != null) 'HERMES_DASHBOARD_PORT': '$dashboardPort',
    },
  );

  Future<void> _gateway(HttpRequest request) async {
    requests.add(request.headers.value(HttpHeaders.authorizationHeader) ?? '');
    if (trickle) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      for (final byte
          in 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n'.codeUnits) {
        socket.add([byte]);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await socket.close();
      return;
    }
    request.response.statusCode =
        requests.last == 'Bearer daeroh-pairing-wrong-bearer'
        ? 401
        : requests.last == 'Bearer $expectedToken'
        ? 200
        : 403;
    await request.response.close();
  }

  Future<void> _dashboard(HttpRequest request) async {
    dashboardPaths.add(request.uri.path);
    if (dashboardMode == _DashboardMode.redirect) {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/api/health');
    } else if (request.uri.path != '/api/health') {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.statusCode = HttpStatus.ok;
    }
    await request.response.close();
  }

  Future<void> close() async {
    await gateway.close(force: true);
    await dashboard?.close(force: true);
    await root.delete(recursive: true);
  }
}

enum _DashboardMode { ok, redirect }

Future<InternetAddress> _privateAddress() async {
  for (final interface in await NetworkInterface.list()) {
    for (final address in interface.addresses) {
      if (address.type == InternetAddressType.IPv4 && _allowed(address.address))
        return address;
    }
  }
  throw StateError('a private IPv4 test interface is required');
}

bool _allowed(String host) {
  final parts = host.split('.').map(int.parse).toList();
  return parts[0] == 10 ||
      (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] == 192 && parts[1] == 168) ||
      (parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127);
}

PairingLink _pairingLink(Object value) {
  final match = RegExp(r'hermes://pair\?[^\s\r]+').firstMatch(value.toString());
  expect(match, isNotNull, reason: value.toString());
  return PairingLink.tryParse(match!.group(0)!)!;
}

Future<void> _makeExecutable(File file) async {
  final result = await Process.run('chmod', ['700', file.path]);
  if (result.exitCode != 0) throw StateError('chmod failed');
}
