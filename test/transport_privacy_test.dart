import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/transport_privacy.dart';

void main() {
  group('TransportPrivacy.classify · secure', () {
    test('https:// es seguro', () {
      expect(
        TransportPrivacy.classify('https://ejemplo.com:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('wss:// es seguro', () {
      expect(
        TransportPrivacy.classify('wss://ejemplo.com:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('https:// hacia IPv6 con puerto sigue siendo seguro', () {
      expect(
        TransportPrivacy.classify('https://[::1]:8642'),
        TransportPrivacyClass.secure,
      );
    });

    test('URL vacía no obtiene permiso de red', () {
      expect(
        TransportPrivacy.classify(''),
        TransportPrivacyClass.publicCleartext,
      );
      expect(() => TransportPrivacy.requireAllowed('   '), throwsArgumentError);
    });
  });

  group('TransportPrivacy.classify · privateCleartext', () {
    test('localhost DNS no concede permiso cleartext', () {
      expect(
        TransportPrivacy.classify('http://localhost:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a loopback 127.0.0.1', () {
      expect(
        TransportPrivacy.classify('http://127.0.0.1:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('IPv6 loopback ::1 sin esquema ni corchetes ni puerto', () {
      expect(
        TransportPrivacy.classify('::1'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('ws:// a IPv6 loopback entre corchetes', () {
      expect(
        TransportPrivacy.classify('ws://[::1]:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a LAN 10.0.0.0/8', () {
      expect(
        TransportPrivacy.classify('http://10.1.2.3:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a LAN 172.16-31.x.x (dentro de rango)', () {
      expect(
        TransportPrivacy.classify('http://172.20.0.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('172.15.x.x y 172.32.x.x quedan fuera del rango 172.16-31', () {
      expect(
        TransportPrivacy.classify('http://172.15.0.5:8642'),
        TransportPrivacyClass.publicCleartext,
      );
      expect(
        TransportPrivacy.classify('http://172.32.0.5:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a LAN 192.168.0.0/16', () {
      expect(
        TransportPrivacy.classify('http://192.168.1.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('http:// a CGNAT de Tailscale 100.64.0.0/10', () {
      expect(
        TransportPrivacy.classify('http://100.64.0.1:8642'),
        TransportPrivacyClass.privateCleartext,
      );
      expect(
        TransportPrivacy.classify('http://100.100.50.7:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });

    test('100.63.x.x y 100.128.x.x quedan fuera del rango CGNAT', () {
      expect(
        TransportPrivacy.classify('http://100.63.0.1:8642'),
        TransportPrivacyClass.publicCleartext,
      );
      expect(
        TransportPrivacy.classify('http://100.128.0.1:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('MagicDNS de Tailscale requiere TLS', () {
      expect(
        TransportPrivacy.classify('http://mi-servidor.ts.net:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('sin esquema explícito se asume http:// (cleartext)', () {
      expect(
        TransportPrivacy.classify('192.168.1.5:8642'),
        TransportPrivacyClass.privateCleartext,
      );
    });
  });

  group('TransportPrivacy.classify · publicCleartext', () {
    test('http:// a dominio público', () {
      expect(
        TransportPrivacy.classify('http://ejemplo.com:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('http:// a IP pública', () {
      expect(
        TransportPrivacy.classify('http://8.8.8.8:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('ws:// a host público', () {
      expect(
        TransportPrivacy.classify('ws://chat.ejemplo.com'),
        TransportPrivacyClass.publicCleartext,
      );
    });

    test('sin esquema hacia host público también avisa', () {
      expect(
        TransportPrivacy.classify('ejemplo.com:8642'),
        TransportPrivacyClass.publicCleartext,
      );
    });
  });

  group('TransportPrivacy.requireAllowed', () {
    test('rechaza nombres DNS que parecen privados en HTTP y WS', () {
      for (final host in [
        'localhost',
        'printer',
        'printer.local',
        'node.test',
        'node.example',
        'node.ts.net',
        'private.example.com',
      ]) {
        for (final scheme in ['http', 'ws']) {
          expect(
            () => TransportPrivacy.requireAllowed('$scheme://$host:8642'),
            throwsArgumentError,
            reason: '$scheme://$host',
          );
        }
      }
    });

    test('permite solo literales IPv4 privados y loopback en HTTP y WS', () {
      for (final host in [
        '127.0.0.2',
        '10.1.2.3',
        '172.31.255.255',
        '192.168.0.1',
        '100.127.255.254',
      ]) {
        for (final scheme in ['http', 'ws']) {
          final url = '$scheme://$host:8642';
          expect(TransportPrivacy.requireAllowed(url), url);
        }
      }
    });

    test('IPv6 ULA literal is private, link-local without scope is denied', () {
      expect(
        TransportPrivacy.requireAllowed('ws://[fd00::1]:8642'),
        'ws://[fd00::1]:8642',
      );
      expect(
        TransportPrivacy.requireAllowed('http://[fc00::2]'),
        'http://[fc00::2]',
      );
      for (final host in [
        'fe80::1',
        'febf::1',
        '2001:db8::1',
        '::ffff:10.1.2.3',
      ]) {
        expect(
          () => TransportPrivacy.requireAllowed('http://[$host]:8642'),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test(
      'unknown schemes and malformed URLs never gain network permission',
      () {
        for (final url in [
          'ftp://10.0.0.1',
          'file://127.0.0.1',
          'http://',
          'https://',
          '://10.0.0.1',
          'http://[::1',
          'http://10.0.0.1:bad',
          'http://10.0.0.1:99999',
        ]) {
          expect(
            () => TransportPrivacy.requireAllowed(url),
            throwsArgumentError,
            reason: url,
          );
        }
      },
    );

    test('bloquea HTTP público', () {
      expect(
        () => TransportPrivacy.requireAllowed('http://8.8.8.8:8642'),
        throwsArgumentError,
      );
    });

    test('permite HTTPS y HTTP privado/Tailscale', () {
      expect(
        TransportPrivacy.requireAllowed('https://hermes.example.com'),
        'https://hermes.example.com',
      );
      expect(
        TransportPrivacy.requireAllowed('http://100.100.50.7:8642'),
        'http://100.100.50.7:8642',
      );
    });
  });
}
