import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/gateway_state.dart';
import 'gateway_config.dart';
import 'native_bridge.dart';
import 'preferences_service.dart';

class GatewayService {
  static const int _maxLogLines = 500;
  static const Duration _logFlushInterval = Duration(milliseconds: 100);

  Timer? _healthTimer;
  Timer? _initialDelayTimer;
  Timer? _logFlushTimer;
  StreamSubscription? _logSubscription;
  /// Bounded ring buffer of log lines. A deque gives O(1) append and O(1)
  /// eviction; the previous list-copy approach was O(n) per line.
  final ListQueue<String> _logRing = ListQueue<String>(_maxLogLines);
  final _stateController = StreamController<GatewayState>.broadcast();
  GatewayState _state = const GatewayState();
  DateTime? _startingAt;
  bool _startInProgress = false;
  static final _boxDrawing = RegExp(r'[│┤├┬┴┼╮╯╰╭─╌╴╶┌┐└┘◇◆]+');

  /// Strip ANSI, box-drawing chars, and whitespace to reconstruct URLs
  /// split by terminal line wrapping or TUI borders.
  static String _cleanForUrl(String text) {
    return text
        .replaceAll(AppConstants.ansiEscape, '')
        .replaceAll(_boxDrawing, '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  static String _ts(String msg) => '${DateTime.now().toUtc().toIso8601String()} $msg';

  Stream<GatewayState> get stateStream => _stateController.stream;
  GatewayState get state => _state;

  void _updateState(GatewayState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  /// Check if the gateway is already running (e.g. after app restart)
  /// and sync the UI state accordingly.  If not running but auto-start
  /// is enabled, start it automatically.
  Future<void> init() async {
    final prefs = PreferencesService();
    await prefs.init();
    final savedUrl = prefs.dashboardUrl;

    // Always ensure directories and resolv.conf exist on app open.
    // Android may clear the files directory during an app update (#40).
    try { await NativeBridge.setupDirs(); } catch (_) {}
    try { await NativeBridge.writeResolv(); } catch (_) {}
    // Dart dart:io fallback if native calls failed (#40).
    try {
      final filesDir = await NativeBridge.getFilesDir();
      const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';
      final resolvFile = File('$filesDir/config/resolv.conf');
      if (!resolvFile.existsSync()) {
        Directory('$filesDir/config').createSync(recursive: true);
        resolvFile.writeAsStringSync(resolvContent);
      }
      // Also write into rootfs /etc/ so DNS works even if bind-mount fails
      final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
      if (!rootfsResolv.existsSync()) {
        rootfsResolv.parent.createSync(recursive: true);
        rootfsResolv.writeAsStringSync(resolvContent);
      }
    } catch (_) {}

    // Repair corrupted config before gateway start (#88).
    // This fixes the "Invalid input: expected object, received string" crash loop.
    await _repairConfigFile();

    // Resolve the configured gateway port before any health check or URL
    // construction - it is not necessarily 18789 (#124).
    await GatewayConfig.resolvePort();

    final alreadyRunning = await NativeBridge.isGatewayRunning();
    if (alreadyRunning) {
      // Write allowCommands config so the next gateway restart picks it up,
      // and in case the running gateway supports config hot-reload.
      await _writeNodeAllowConfig();
      // Prefer token from config file over stale SharedPreferences value (#74, #82).
      final configToken = await _readTokenFromConfig();
      final effectiveUrl = configToken != null
          ? GatewayConfig.dashboardUrl(configToken)
          : savedUrl;
      if (configToken != null) prefs.dashboardUrl = effectiveUrl;
      _startingAt = DateTime.now();
      _updateState(_state.copyWith(
        status: GatewayStatus.starting,
        dashboardUrl: effectiveUrl,
        logs: _appendAndSnapshot('[INFO] Gateway process detected, reconnecting...'),
      ));

      _subscribeLogs();
      _startHealthCheck();
    } else if (prefs.autoStartGateway) {
      _updateState(_state.copyWith(
        logs: _appendAndSnapshot('[INFO] Auto-starting gateway...'),
      ));
      await start();
    }
  }

  void _subscribeLogs() {
    _logSubscription?.cancel();
    _logSubscription = NativeBridge.gatewayLogStream.listen((log) {
      // Append in O(1) amortised. The previous implementation rebuilt the
      // whole list per line (`[..._state.logs, log]`), i.e. O(n) copies per
      // line and O(n²) over a session, and pushed a new state - rebuilding
      // the log UI - for every single line. `openclaw gateway --verbose` emits
      // thousands of lines, so both costs were real.
      _logRing.addLast(log);
      while (_logRing.length > _maxLogLines) {
        _logRing.removeFirst();
      }

      // Token detection stays synchronous: the dashboard URL must not wait
      // for the next flush tick.
      String? dashboardUrl;
      final cleanLog = _cleanForUrl(log);
      // Match a token URL on any port - the gateway may be bound to a custom
      // port via gateway.port / --port (#124).
      final urlMatch = GatewayConfig.anyPortTokenUrlRegex.firstMatch(cleanLog);
      if (urlMatch != null) {
        dashboardUrl = urlMatch.group(0);
        // Keep the resolved port in sync with what the gateway actually printed.
        final loggedPort = GatewayConfig.parsePort(urlMatch.group(1));
        if (loggedPort != null) GatewayConfig.setCachedPort(loggedPort);
        final prefs = PreferencesService();
        prefs.init().then((_) => prefs.dashboardUrl = dashboardUrl);
        NativeBridge.showUrlNotification(dashboardUrl!, title: 'Dashboard Ready');
        _flushLogs(dashboardUrl: dashboardUrl);
        return;
      }

      _scheduleLogFlush();
    });
  }

  /// Coalesce log bursts into at most one state update per
  /// [_logFlushInterval], bounding UI rebuilds by elapsed time rather than by
  /// line count.
  void _scheduleLogFlush() {
    if (_logFlushTimer != null) return;
    _logFlushTimer = Timer(_logFlushInterval, () {
      _logFlushTimer = null;
      _flushLogs();
    });
  }

  void _flushLogs({String? dashboardUrl}) {
    _logFlushTimer?.cancel();
    _logFlushTimer = null;
    _updateState(_state.copyWith(
      logs: _logRing.toList(growable: false),
      dashboardUrl: dashboardUrl,
    ));
  }

  /// Append a service-generated log line through the same ring buffer.
  void _appendLog(String message) {
    _logRing.addLast(_ts(message));
    while (_logRing.length > _maxLogLines) {
      _logRing.removeFirst();
    }
  }

  /// Append a line and return the current buffer as an immutable snapshot,
  /// for use directly in `copyWith(logs: ...)`.
  List<String> _appendAndSnapshot(String message) {
    _appendLog(message);
    return _logRing.toList(growable: false);
  }

  /// Patch /root/.openclaw/openclaw.json so the gateway authorises the node
  /// commands this app declares.
  ///
  /// The canonical upstream keys are `gateway.nodes.commands.allow` and
  /// `gateway.nodes.commands.deny` (see OpenClaw "Configuration - gateway").
  /// Earlier versions of this app wrote `gateway.nodes.allowCommands` /
  /// `denyCommands`, which OpenClaw ignores - so classified commands such as
  /// `camera.snap` and `screen.record` were never actually allowed (#81, #95).
  /// The legacy keys are removed here so they cannot fail config validation.
  Future<void> _writeNodeAllowConfig() async {
    const allowCommands = [
      'camera.snap', 'camera.clip', 'camera.list',
      'canvas.navigate', 'canvas.eval', 'canvas.snapshot',
      'flash.on', 'flash.off', 'flash.toggle', 'flash.status',
      'location.get',
      'battery.status',
      'screen.record',
      'sensor.read', 'sensor.list',
      'haptic.vibrate',
      'serial.list', 'serial.connect', 'serial.disconnect', 'serial.write', 'serial.read',
    ];
    // Use a Node.js one-liner to safely merge into existing openclaw.json
    // without clobbering other settings (API keys, onboarding config, etc.)
    final allowJson = jsonEncode(allowCommands);
    final script = '''
const fs = require("fs");
const p = "/root/.openclaw/openclaw.json";
let c = {};
try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
if (!c.gateway) c.gateway = {};
if (!c.gateway.mode) c.gateway.mode = "local";
// Ensure a persistent auth token so the app can always hand the dashboard a
// tokenised URL (http://localhost:PORT/#token=...). Without one the Control UI
// opens on a manual "Gateway Token" prompt instead of connecting.
// Never overwrite an existing token, and never touch password-auth setups:
// upstream fails startup when both token and password are set without an
// explicit gateway.auth.mode.
if (!c.gateway.auth) c.gateway.auth = {};
{
  const a = c.gateway.auth;
  const hasToken = typeof a.token === "string" && a.token.length > 0;
  const hasPassword = typeof a.password === "string" && a.password.length > 0;
  if (!hasToken && !hasPassword && a.mode !== "none" && a.mode !== "password"
      && a.mode !== "trusted-proxy") {
    a.token = require("crypto").randomBytes(32).toString("hex");
    if (!a.mode) a.mode = "token";
  }
}
if (!c.gateway.nodes) c.gateway.nodes = {};
// Canonical command policy keys.
if (!c.gateway.nodes.commands) c.gateway.nodes.commands = {};
c.gateway.nodes.commands.allow = $allowJson;
c.gateway.nodes.commands.deny = [];
// Drop the legacy keys this app used to write; OpenClaw never read them.
delete c.gateway.nodes.allowCommands;
delete c.gateway.nodes.denyCommands;
// Silent same-host pairing so the in-app node does not need manual approval.
if (!c.gateway.nodes.pairing) c.gateway.nodes.pairing = {};
if (c.gateway.nodes.pairing.autoApproveLocal === undefined) {
  c.gateway.nodes.pairing.autoApproveLocal = true;
}
// Fix config corruption: models entries must be objects, not strings (#83, #88)
if (c.models && c.models.providers) {
  for (const [pid, prov] of Object.entries(c.models.providers)) {
    if (prov && Array.isArray(prov.models)) {
      prov.models = prov.models.map(m => typeof m === "string" ? { id: m } : m);
    }
  }
}
fs.writeFileSync(p, JSON.stringify(c, null, 2));
''';
    var prootOk = false;
    try {
      await NativeBridge.runInProot(
        'node -e ${_shellEscape(script)}',
        timeout: 15,
      );
      prootOk = true;
    } catch (_) {}

    // Direct file I/O fallback (#56): if proot/node isn't ready, write the
    // config directly on the Android filesystem so the gateway still picks
    // up the command policy on next start.
    if (!prootOk) {
      try {
        final filesDir = await NativeBridge.getFilesDir();
        final configFile = File('$filesDir/rootfs/ubuntu/root/.openclaw/openclaw.json');
        Map<String, dynamic> config = {};
        if (configFile.existsSync()) {
          try {
            config = Map<String, dynamic>.from(
                jsonDecode(configFile.readAsStringSync()) as Map);
          } catch (_) {}
        }
        config.putIfAbsent('gateway', () => <String, dynamic>{});
        final gw = config['gateway'] as Map<String, dynamic>;
        // Ensure gateway.mode=local so the gateway starts without --allow-unconfigured (#93, #90)
        gw.putIfAbsent('mode', () => 'local');
        _ensureAuthToken(gw);
        gw.putIfAbsent('nodes', () => <String, dynamic>{});
        final nodes = gw['nodes'] as Map<String, dynamic>;
        nodes.putIfAbsent('commands', () => <String, dynamic>{});
        final commands = nodes['commands'] as Map<String, dynamic>;
        commands['allow'] = allowCommands;
        commands['deny'] = <String>[];
        nodes.remove('allowCommands');
        nodes.remove('denyCommands');
        nodes.putIfAbsent('pairing', () => <String, dynamic>{});
        final pairing = nodes['pairing'] as Map<String, dynamic>;
        pairing.putIfAbsent('autoApproveLocal', () => true);
        // Fix config corruption: models entries must be objects, not strings (#83, #88)
        _repairModelEntries(config);
        configFile.parent.createSync(recursive: true);
        configFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(config),
        );
      } catch (_) {}
    }
  }

  /// Ensure `gateway.auth.token` exists so a tokenised dashboard URL can be
  /// built. Mirrors the Node.js path in [_writeNodeAllowConfig]: never
  /// overwrites an existing credential and leaves password / trusted-proxy /
  /// no-auth setups alone.
  static void _ensureAuthToken(Map<String, dynamic> gateway) {
    gateway.putIfAbsent('auth', () => <String, dynamic>{});
    final auth = gateway['auth'];
    if (auth is! Map<String, dynamic>) return;
    final token = auth['token'];
    final password = auth['password'];
    final mode = auth['mode'];
    final hasToken = token is String && token.isNotEmpty;
    final hasPassword = password is String && password.isNotEmpty;
    if (hasToken ||
        hasPassword ||
        mode == 'none' ||
        mode == 'password' ||
        mode == 'trusted-proxy') {
      return;
    }
    auth['token'] = generateGatewayToken();
    auth.putIfAbsent('mode', () => 'token');
  }

  /// 32 random bytes as lower-case hex - matches the `[0-9a-f]+` shape the
  /// token URL regex expects.
  static String generateGatewayToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Repair openclaw.json on disk - fixes corrupted model entries and ensures
  /// gateway.mode=local is set. Called on init() before any gateway start (#88).
  Future<void> _repairConfigFile() async {
    try {
      final filesDir = await NativeBridge.getFilesDir();
      final configFile = File('$filesDir/rootfs/ubuntu/root/.openclaw/openclaw.json');
      if (!configFile.existsSync()) return;
      final content = configFile.readAsStringSync();
      if (content.isEmpty) return;

      Map<String, dynamic> config;
      try {
        config = Map<String, dynamic>.from(jsonDecode(content) as Map);
      } catch (_) {
        return; // Unparseable - _writeNodeAllowConfig will recreate it
      }

      bool modified = false;

      // Ensure gateway.mode=local (#93, #90)
      config.putIfAbsent('gateway', () => <String, dynamic>{});
      final gw = config['gateway'] as Map<String, dynamic>;
      if (!gw.containsKey('mode')) {
        gw['mode'] = 'local';
        modified = true;
      }

      // Fix model entries: strings → objects (#83, #88)
      final models = config['models'] as Map<String, dynamic>?;
      if (models != null) {
        final providers = models['providers'] as Map<String, dynamic>?;
        if (providers != null) {
          for (final entry in providers.values) {
            if (entry is Map<String, dynamic>) {
              final modelsList = entry['models'];
              if (modelsList is List) {
                for (int i = 0; i < modelsList.length; i++) {
                  if (modelsList[i] is String) {
                    modelsList[i] = {'id': modelsList[i]};
                    modified = true;
                  }
                }
              }
            }
          }
        }
      }

      if (modified) {
        configFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(config),
        );
      }
    } catch (_) {}
  }

  /// Fix corrupted model entries: convert bare strings to {id: string} objects (#83, #88).
  static void _repairModelEntries(Map<String, dynamic> config) {
    final models = config['models'] as Map<String, dynamic>?;
    if (models == null) return;
    final providers = models['providers'] as Map<String, dynamic>?;
    if (providers == null) return;
    for (final entry in providers.values) {
      if (entry is Map<String, dynamic>) {
        final modelsList = entry['models'];
        if (modelsList is List) {
          entry['models'] = modelsList.map((m) {
            if (m is String) return {'id': m};
            return m;
          }).toList();
        }
      }
    }
  }

  /// Read the actual gateway auth token from openclaw.json config file (#74, #82).
  /// This is the source of truth - more reliable than regex-scraping stdout.
  Future<String?> _readTokenFromConfig() async {
    try {
      final raw = await NativeBridge.readRootfsFile('root/.openclaw/openclaw.json');
      if (raw == null) return null;
      final config = jsonDecode(raw) as Map<String, dynamic>;
      final token = config['gateway']?['auth']?['token'];
      if (token is String && token.isNotEmpty) return token;
    } catch (_) {}
    return null;
  }

  /// Escape a string for use as a single-quoted shell argument.
  static String _shellEscape(String s) {
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  Future<void> start() async {
    // Prevent concurrent start() calls from racing
    if (_startInProgress) return;
    _startInProgress = true;

    // Clear any stale token from a previous session (#74, #82).
    // The fresh token will be captured from gateway stdout once it starts.
    final prefs = PreferencesService();
    await prefs.init();
    prefs.dashboardUrl = null;

    _updateState(_state.copyWith(
      status: GatewayStatus.starting,
      clearError: true,
      clearDashboardUrl: true,
      logs: _appendAndSnapshot('[INFO] Starting gateway...'),
    ));

    try {
      // Ensure directories exist - Android may have cleared them (#40).
      // Non-fatal: the GatewayService foreground service also creates them.
      try { await NativeBridge.setupDirs(); } catch (_) {}
      try { await NativeBridge.writeResolv(); } catch (_) {}
      // Dart dart:io fallback if native calls failed (#40).
      try {
        final filesDir = await NativeBridge.getFilesDir();
        const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';
        final resolvFile = File('$filesDir/config/resolv.conf');
        if (!resolvFile.existsSync()) {
          Directory('$filesDir/config').createSync(recursive: true);
          resolvFile.writeAsStringSync(resolvContent);
        }
        // Also write into rootfs /etc/ so DNS works even if bind-mount fails
        final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
        if (!rootfsResolv.existsSync()) {
          rootfsResolv.parent.createSync(recursive: true);
          rootfsResolv.writeAsStringSync(resolvContent);
        }
      } catch (_) {}
      await _writeNodeAllowConfig();
      // Re-read gateway.port - the user may have changed it since init() (#124).
      await GatewayConfig.resolvePort();
      _startingAt = DateTime.now();
      await NativeBridge.startGateway();
      _subscribeLogs();
      _startHealthCheck();
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to start: $e',
        logs: _appendAndSnapshot('[ERROR] Failed to start: $e'),
      ));
    } finally {
      _startInProgress = false;
    }
  }

  Future<void> stop() async {
    _cancelAllTimers();
    _logSubscription?.cancel();
    _startingAt = null;

    try {
      await NativeBridge.stopGateway();
      _updateState(GatewayState(
        status: GatewayStatus.stopped,
        logs: _appendAndSnapshot('[INFO] Gateway stopped'),
      ));
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to stop: $e',
      ));
    }
  }

  /// Cancel both the initial delay timer and periodic health timer.
  void _cancelAllTimers() {
    _initialDelayTimer?.cancel();
    _initialDelayTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    _logFlushTimer?.cancel();
    _logFlushTimer = null;
  }

  void _startHealthCheck() {
    _cancelAllTimers();
    // Delay the first health check by 30s - Node.js inside proot needs time to start.
    // Use a Timer (not Future.delayed) so it can be cancelled on stop().
    _initialDelayTimer = Timer(const Duration(seconds: 30), () {
      _initialDelayTimer = null;
      if (_state.status == GatewayStatus.stopped) return;
      _checkHealth();
      _healthTimer = Timer.periodic(
        const Duration(milliseconds: AppConstants.healthCheckIntervalMs),
        (_) => _checkHealth(),
      );
    });
  }

  Future<void> _checkHealth() async {
    try {
      final response = await http
          .head(Uri.parse(GatewayConfig.baseUrl))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode < 500 && _state.status != GatewayStatus.running) {
        // Read the actual token from openclaw.json - source of truth (#74, #82).
        // This ensures the displayed token always matches the gateway's config,
        // even if the stdout regex didn't capture it.
        String? configUrl = _state.dashboardUrl;
        try {
          final token = await _readTokenFromConfig();
          if (token != null) {
            configUrl = GatewayConfig.dashboardUrl(token);
            final prefs = PreferencesService();
            await prefs.init();
            prefs.dashboardUrl = configUrl;
          }
        } catch (_) {}

        _updateState(_state.copyWith(
          status: GatewayStatus.running,
          startedAt: DateTime.now(),
          dashboardUrl: configUrl,
          logs: _appendAndSnapshot('[INFO] Gateway is healthy'),
        ));
      }
    } catch (_) {
      // Still starting or temporarily unreachable
      final isRunning = await NativeBridge.isGatewayRunning();
      if (!isRunning && _state.status != GatewayStatus.stopped) {
        // Grace period: if we're still within 120s of startup, don't declare dead.
        // proot + Node.js can take a long time on first boot.
        if (_startingAt != null &&
            _state.status == GatewayStatus.starting &&
            DateTime.now().difference(_startingAt!).inSeconds < 120) {
          _updateState(_state.copyWith(
            logs: _appendAndSnapshot('[INFO] Starting, waiting for gateway...'),
          ));
          return;
        }
        _updateState(_state.copyWith(
          status: GatewayStatus.stopped,
          logs: _appendAndSnapshot('[WARN] Gateway process not running'),
        ));
        _cancelAllTimers();
      }
    }
  }

  Future<bool> checkHealth() async {
    try {
      final response = await http
          .head(Uri.parse(GatewayConfig.baseUrl))
          .timeout(const Duration(seconds: 3));
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _cancelAllTimers();
    _logSubscription?.cancel();
    _stateController.close();
  }
}
