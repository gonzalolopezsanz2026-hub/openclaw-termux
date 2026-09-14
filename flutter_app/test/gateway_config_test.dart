import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw/constants.dart';
import 'package:openclaw/services/gateway_config.dart';

void main() {
  group('GatewayConfig.parsePort', () {
    test('accepts valid ints and numeric strings', () {
      expect(GatewayConfig.parsePort(19000), 19000);
      expect(GatewayConfig.parsePort('19000'), 19000);
      expect(GatewayConfig.parsePort(' 19000 '), 19000);
      expect(GatewayConfig.parsePort(18789.0), 18789);
      expect(GatewayConfig.parsePort(1), 1);
      expect(GatewayConfig.parsePort(65535), 65535);
    });

    test('rejects out-of-range and non-numeric values', () {
      expect(GatewayConfig.parsePort(0), isNull);
      expect(GatewayConfig.parsePort(-1), isNull);
      expect(GatewayConfig.parsePort(65536), isNull);
      expect(GatewayConfig.parsePort('not-a-port'), isNull);
      expect(GatewayConfig.parsePort(''), isNull);
      expect(GatewayConfig.parsePort(null), isNull);
      expect(GatewayConfig.parsePort(<String, String>{}), isNull);
    });
  });

  group('resolved port plumbing (#124)', () {
    tearDown(() => GatewayConfig.setCachedPort(AppConstants.defaultGatewayPort));

    test('defaults to 18789', () {
      expect(GatewayConfig.port, AppConstants.defaultGatewayPort);
      expect(GatewayConfig.baseUrl, 'http://127.0.0.1:18789');
    });

    test('base URL and dashboard URL follow the configured port', () {
      GatewayConfig.setCachedPort(19000);
      expect(GatewayConfig.port, 19000);
      expect(GatewayConfig.baseUrl, 'http://127.0.0.1:19000');
      expect(
        GatewayConfig.dashboardUrl('deadbeef'),
        'http://localhost:19000/#token=deadbeef',
      );
    });

    test('an invalid port never overwrites the cached value', () {
      GatewayConfig.setCachedPort(19000);
      GatewayConfig.setCachedPort(70000);
      expect(GatewayConfig.port, 19000);
    });

    test('tokenUrlRegex tracks the configured port', () {
      GatewayConfig.setCachedPort(19000);
      expect(
        GatewayConfig.tokenUrlRegex
            .hasMatch('http://localhost:19000/#token=abc123'),
        isTrue,
      );
      expect(
        GatewayConfig.tokenUrlRegex
            .hasMatch('http://localhost:18789/#token=abc123'),
        isFalse,
      );
    });
  });

  group('anyPortTokenUrlRegex', () {
    test('captures the port from a custom-port dashboard URL', () {
      final match = GatewayConfig.anyPortTokenUrlRegex
          .firstMatch('Dashboard: http://localhost:19000/#token=abc123def');
      expect(match, isNotNull);
      expect(match!.group(1), '19000');
      expect(match.group(0), 'http://localhost:19000/#token=abc123def');
    });

    test('still matches the default port and 127.0.0.1', () {
      expect(
        GatewayConfig.anyPortTokenUrlRegex
            .firstMatch('http://127.0.0.1:18789/#token=ff00')
            ?.group(1),
        '18789',
      );
    });

    test('ignores URLs without a token fragment', () {
      expect(
        GatewayConfig.anyPortTokenUrlRegex.hasMatch('http://localhost:19000/'),
        isFalse,
      );
    });
  });
}
