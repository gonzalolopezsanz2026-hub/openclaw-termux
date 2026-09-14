import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw/constants.dart';
import 'package:openclaw/services/gateway_config.dart';
import 'package:openclaw/services/gateway_service.dart';

/// The gateway auth token is captured by regex from gateway/onboarding stdout.
/// It has broken repeatedly (#74, #82, #94), so the parsing contract is pinned
/// here.
void main() {
  tearDown(() => GatewayConfig.setCachedPort(AppConstants.defaultGatewayPort));

  group('token capture from gateway output', () {
    test('captures a token on the default port', () {
      const line = 'Dashboard: http://localhost:18789/#token=a1b2c3d4e5f6';
      final m = GatewayConfig.anyPortTokenUrlRegex.firstMatch(line);
      expect(m, isNotNull);
      expect(m!.group(0), 'http://localhost:18789/#token=a1b2c3d4e5f6');
      expect(m.group(1), '18789');
    });

    test('captures a token on a custom port', () {
      const line = 'Dashboard: http://127.0.0.1:19000/#token=deadbeef00';
      final m = GatewayConfig.anyPortTokenUrlRegex.firstMatch(line);
      expect(m, isNotNull);
      expect(m!.group(1), '19000');
    });

    test('captures a token from a URL rebuilt out of a wrapped TUI box', () {
      // Reproduces the real failure mode: the gateway prints the URL inside a
      // box-drawing frame, wrapped across lines. gateway_service strips ANSI,
      // box characters and whitespace before matching.
      const raw = '│ http://localhost:18789/#token=abc1 │\n│ 23def │';
      final cleaned = raw
          .replaceAll(RegExp(r'[│┤├┬┴┼╮╯╰╭─╌╴╶┌┐└┘◇◆]+'), '')
          .replaceAll(RegExp(r'\s+'), '');
      final m = GatewayConfig.anyPortTokenUrlRegex.firstMatch(cleaned);
      expect(m, isNotNull);
      expect(m!.group(0), 'http://localhost:18789/#token=abc123def');
    });

    test('the token value can be re-extracted for the node handshake', () {
      // node_service reads the token back out of the stored dashboard URL.
      const url = 'http://localhost:19000/#token=abc123def456';
      final token =
          RegExp(r'[#?&]token=([0-9a-fA-F]+)').firstMatch(url)?.group(1);
      expect(token, 'abc123def456');
    });

    test('does not match a non-token URL', () {
      expect(
        GatewayConfig.anyPortTokenUrlRegex.hasMatch('http://localhost:18789/'),
        isFalse,
      );
      expect(
        GatewayConfig.anyPortTokenUrlRegex
            .hasMatch('http://example.com:18789/#token=abcdef'),
        isFalse,
      );
    });
  });

  group('generated gateway token', () {
    test('is 64 lower-case hex chars and survives a URL round-trip', () {
      final token = GatewayService.generateGatewayToken();
      expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));

      // The generated token must satisfy the same [0-9a-f]+ shape the capture
      // regex and the node handshake extraction rely on.
      GatewayConfig.setCachedPort(18789);
      final url = GatewayConfig.dashboardUrl(token);
      expect(GatewayConfig.anyPortTokenUrlRegex.hasMatch(url), isTrue);
      expect(
        RegExp(r'[#?&]token=([0-9a-fA-F]+)').firstMatch(url)?.group(1),
        token,
      );
    });

    test('is different every time', () {
      final a = GatewayService.generateGatewayToken();
      final b = GatewayService.generateGatewayToken();
      expect(a, isNot(equals(b)));
    });
  });

  group('dashboard URL construction', () {
    test('round-trips a token through the configured port', () {
      GatewayConfig.setCachedPort(19000);
      final url = GatewayConfig.dashboardUrl('feed1234');
      expect(url, 'http://localhost:19000/#token=feed1234');
      // What we build must be what we can parse back.
      final m = GatewayConfig.anyPortTokenUrlRegex.firstMatch(url);
      expect(m, isNotNull);
      expect(m!.group(1), '19000');
      expect(
        RegExp(r'[#?&]token=([0-9a-fA-F]+)').firstMatch(url)?.group(1),
        'feed1234',
      );
    });
  });
}
