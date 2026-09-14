import 'dart:convert';

import '../constants.dart';
import 'native_bridge.dart';

/// Resolves runtime gateway settings from the file OpenClaw actually reads,
/// `/root/.openclaw/openclaw.json`.
///
/// The gateway port is NOT fixed at 18789. Upstream precedence is
/// `--port` > `OPENCLAW_GATEWAY_PORT` > `gateway.port` > 18789, so the app must
/// read `gateway.port` instead of assuming the default - otherwise health
/// checks, the dashboard URL and the node WebSocket all target the wrong port
/// when a user changes it (#124).
class GatewayConfig {
  GatewayConfig._();

  static const String configPath = 'root/.openclaw/openclaw.json';

  static int _port = AppConstants.defaultGatewayPort;

  /// Last resolved port. Defaults to 18789 until [resolvePort] runs.
  static int get port => _port;

  /// Base HTTP URL of the local gateway on the resolved port.
  static String get baseUrl => 'http://${AppConstants.gatewayHost}:$_port';

  /// Dashboard URL for a token, on the resolved port.
  static String dashboardUrl(String token) =>
      'http://localhost:$_port/#token=$token';

  /// Matches a tokenised dashboard URL on the resolved port, e.g.
  /// `http://localhost:19000/#token=abc123`.
  static RegExp get tokenUrlRegex => RegExp(
        r'https?://(?:localhost|127\.0\.0\.1):' +
            _port.toString() +
            r'/#token=[0-9a-f]+',
      );

  /// Matches a tokenised dashboard URL on *any* port, so a token is still
  /// captured from gateway stdout when the port is unknown or has just changed.
  static final RegExp anyPortTokenUrlRegex = RegExp(
    r'https?://(?:localhost|127\.0\.0\.1):(\d{2,5})/#token=[0-9a-f]+',
  );

  /// Read `gateway.port` from openclaw.json and cache it. Falls back to the
  /// previously resolved value when the config is missing or unreadable.
  static Future<int> resolvePort() async {
    try {
      final raw = await NativeBridge.readRootfsFile(configPath);
      if (raw == null || raw.isEmpty) return _port;
      final config = jsonDecode(raw);
      if (config is! Map) return _port;
      final gateway = config['gateway'];
      if (gateway is! Map) return _port;
      final parsed = parsePort(gateway['port']);
      if (parsed != null) _port = parsed;
    } catch (_) {
      // Keep the last known port - never throw from a config read.
    }
    return _port;
  }

  /// Validate a port value coming from config or user input.
  /// Accepts int or numeric String; returns null when out of range.
  static int? parsePort(Object? value) {
    int? candidate;
    if (value is int) {
      candidate = value;
    } else if (value is num) {
      candidate = value.toInt();
    } else if (value is String) {
      candidate = int.tryParse(value.trim());
    }
    if (candidate == null) return null;
    if (candidate < 1 || candidate > 65535) return null;
    return candidate;
  }

  /// Override the cached port (used after the user edits it in Settings).
  static void setCachedPort(int value) {
    final parsed = parsePort(value);
    if (parsed != null) _port = parsed;
  }
}
