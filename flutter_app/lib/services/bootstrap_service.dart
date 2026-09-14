import 'dart:io';
import 'package:dio/dio.dart';
import '../constants.dart';
import '../models/setup_state.dart';
import 'native_bridge.dart';

class BootstrapService {
  final Dio _dio = Dio();

  void _updateSetupNotification(String text, {int progress = -1}) {
    try {
      NativeBridge.updateSetupNotification(text, progress: progress);
    } catch (_) {}
  }

  void _stopSetupService() {
    try {
      NativeBridge.stopSetupService();
    } catch (_) {}
  }

  Future<SetupState> checkStatus() async {
    try {
      final complete = await NativeBridge.isBootstrapComplete();
      if (complete) {
        return const SetupState(
          step: SetupStep.complete,
          progress: 1.0,
          message: 'Setup complete',
        );
      }
      return const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Setup required',
      );
    } catch (e) {
      return SetupState(
        step: SetupStep.error,
        error: 'Failed to check status: $e',
      );
    }
  }

  /// Repair a partially-installed environment without re-downloading the
  /// rootfs.
  ///
  /// This used to run inline on the splash screen behind a static spinner: a
  /// Node.js download plus `npm install -g openclaw` (up to a 30 minute
  /// timeout) with no progress, no notification and no foreground service, so
  /// the app looked frozen and Android could kill it mid-install and lose all
  /// the work (#125). Repair now runs here, with the same progress plumbing
  /// and wake-lock-holding foreground service as a full setup.
  Future<void> runRepair({
    required void Function(SetupState) onProgress,
  }) async {
    try {
      try {
        await NativeBridge.startSetupService();
      } catch (_) {}

      onProgress(const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Checking what needs repairing...',
      ));
      _updateSetupNotification('Checking environment...', progress: 2);

      try { await NativeBridge.setupDirs(); } catch (_) {}
      try { await NativeBridge.writeResolv(); } catch (_) {}

      final status = await NativeBridge.getBootstrapStatus();
      final nodeOk = status['nodeInstalled'] == true;
      final openclawOk = status['openclawInstalled'] == true;
      final bypassOk = status['bypassInstalled'] == true;

      // Bionic bypass - a cheap native file write.
      if (!bypassOk) {
        onProgress(const SetupState(
          step: SetupStep.configuringBypass,
          progress: 0.1,
          message: 'Repairing Bionic Bypass...',
        ));
        _updateSetupNotification('Repairing Bionic Bypass...', progress: 10);
        await NativeBridge.installBionicBypass();
      }

      final filesDir = await NativeBridge.getFilesDir();

      // Node.js
      if (!nodeOk) {
        final arch = await NativeBridge.getArch();
        final nodeTarUrl = AppConstants.getNodeTarballUrl(arch);
        final nodeTarPath = '$filesDir/tmp/nodejs.tar.xz';
        onProgress(const SetupState(
          step: SetupStep.installingNode,
          progress: 0.2,
          message: 'Reinstalling Node.js...',
        ));
        await _dio.download(
          nodeTarUrl,
          nodeTarPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final pct = received / total;
              final mb = (received / 1024 / 1024).toStringAsFixed(1);
              final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
              _updateSetupNotification(
                'Downloading Node.js: $mb / $totalMb MB',
                progress: 15 + (pct * 25).round(),
              );
              onProgress(SetupState(
                step: SetupStep.installingNode,
                progress: 0.2 + pct * 0.3,
                message: 'Downloading Node.js: $mb MB / $totalMb MB',
              ));
            }
          },
        );
        _updateSetupNotification('Extracting Node.js...', progress: 42);
        onProgress(const SetupState(
          step: SetupStep.installingNode,
          progress: 0.5,
          message: 'Extracting Node.js...',
        ));
        await NativeBridge.extractNodeTarball(nodeTarPath);
      }

      // OpenClaw
      if (!openclawOk) {
        onProgress(const SetupState(
          step: SetupStep.installingOpenClaw,
          progress: 0.6,
          message: 'Reinstalling OpenClaw (this may take a few minutes)...',
        ));
        _updateSetupNotification('Reinstalling OpenClaw...', progress: 60);
        await _installOpenClaw(onProgress: onProgress);
        await NativeBridge.createBinWrappers('openclaw');
      }

      _updateSetupNotification('Repair complete!', progress: 100);
      _stopSetupService();
      onProgress(const SetupState(
        step: SetupStep.complete,
        progress: 1.0,
        message: 'Repair complete! Ready to start the gateway.',
      ));
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Download failed: ${e.message}. Check your internet connection.',
      ));
    } catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Repair failed: $e',
      ));
    }
  }

  /// Install openclaw globally, clearing stale npm state first and falling
  /// back to installing the node-gyp build toolchain only if needed (#133).
  Future<void> _installOpenClaw({
    required void Function(SetupState) onProgress,
  }) async {
    const wrapper = '/root/.openclaw/node-wrapper.js';
    const nodeRun = 'node $wrapper';
    const npmCli = '/usr/local/lib/node_modules/npm/bin/npm-cli.js';
    const npmFlags = '--omit=dev --no-audit --no-fund --loglevel=error';

    await NativeBridge.runInProot(
      'rm -rf /usr/local/lib/node_modules/openclaw '
      '/usr/local/lib/node_modules/.openclaw-* '
      '/usr/local/lib/node_modules/.staging 2>/dev/null; '
      'rm -rf /tmp/npm-cache/_cacache/tmp 2>/dev/null; '
      'echo npm_state_cleaned',
      timeout: 120,
    );
    try {
      await NativeBridge.runInProot(
        '$nodeRun $npmCli install -g openclaw $npmFlags',
        timeout: 1800,
      );
    } catch (_) {
      onProgress(const SetupState(
        step: SetupStep.installingOpenClaw,
        progress: 0.7,
        message: 'Retrying with build tools (this takes longer)...',
      ));
      _updateSetupNotification('Installing build tools...', progress: 85);
      await NativeBridge.runInProot(
        '$nodeRun $npmCli cache clean --force 2>/dev/null; '
        'rm -rf /usr/local/lib/node_modules/openclaw '
        '/usr/local/lib/node_modules/.openclaw-* '
        '/tmp/npm-cache 2>/dev/null; '
        'echo npm_cache_cleaned',
        timeout: 180,
      );
      await NativeBridge.runInProot(
        'apt-get install -y --no-install-recommends python3 make g++',
        timeout: 1800,
      );
      _updateSetupNotification('Retrying OpenClaw install...', progress: 88);
      await NativeBridge.runInProot(
        '$nodeRun $npmCli install -g openclaw $npmFlags',
        timeout: 1800,
      );
    }
  }

  Future<void> runFullSetup({
    required void Function(SetupState) onProgress,
  }) async {
    try {
      // Start foreground service to keep app alive during setup
      try {
        await NativeBridge.startSetupService();
      } catch (_) {} // Non-fatal if service fails to start

      // Step 0: Setup directories
      onProgress(const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Setting up directories...',
      ));
      _updateSetupNotification('Setting up directories...', progress: 2);
      try { await NativeBridge.setupDirs(); } catch (_) {}
      try { await NativeBridge.writeResolv(); } catch (_) {}

      // Step 1: Download rootfs
      final arch = await NativeBridge.getArch();
      final rootfsUrl = AppConstants.getRootfsUrl(arch);
      final filesDir = await NativeBridge.getFilesDir();

      // Direct Dart fallback: ensure config dir + resolv.conf exist (#40).
      const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';
      try {
        final configDir = '$filesDir/config';
        final resolvFile = File('$configDir/resolv.conf');
        if (!resolvFile.existsSync()) {
          Directory(configDir).createSync(recursive: true);
          resolvFile.writeAsStringSync(resolvContent);
        }
        // Also write into rootfs /etc/ so DNS works even if bind-mount fails
        final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
        if (!rootfsResolv.existsSync()) {
          rootfsResolv.parent.createSync(recursive: true);
          rootfsResolv.writeAsStringSync(resolvContent);
        }
      } catch (_) {}
      final tarPath = '$filesDir/tmp/ubuntu-rootfs.tar.gz';

      _updateSetupNotification('Downloading Ubuntu rootfs...', progress: 5);
      onProgress(const SetupState(
        step: SetupStep.downloadingRootfs,
        progress: 0.0,
        message: 'Downloading Ubuntu rootfs...',
      ));

      await _dio.download(
        rootfsUrl,
        tarPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            final mb = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
            // Map download to 5-30% of overall progress
            final notifProgress = 5 + (progress * 25).round();
            _updateSetupNotification('Downloading rootfs: $mb / $totalMb MB', progress: notifProgress);
            onProgress(SetupState(
              step: SetupStep.downloadingRootfs,
              progress: progress,
              message: 'Downloading: $mb MB / $totalMb MB',
            ));
          }
        },
      );

      // Step 2: Extract rootfs (30-45%)
      _updateSetupNotification('Extracting rootfs...', progress: 30);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 0.0,
        message: 'Extracting rootfs (this takes a while)...',
      ));
      await NativeBridge.extractRootfs(tarPath);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 1.0,
        message: 'Rootfs extracted',
      ));

      // Install bionic bypass + cwd-fix + node-wrapper BEFORE using node.
      // The wrapper patches process.cwd() which returns ENOSYS in proot.
      await NativeBridge.installBionicBypass();

      // Step 3: Install Node.js (45-80%)
      // Fix permissions inside proot (Java extraction may miss execute bits)
      _updateSetupNotification('Fixing rootfs permissions...', progress: 45);
      onProgress(const SetupState(
        step: SetupStep.installingNode,
        progress: 0.0,
        message: 'Fixing rootfs permissions...',
      ));
      // Blanket recursive chmod on all bin/lib directories.
      // Java tar extraction loses execute bits; dpkg needs tar, xz,
      // gzip, rm, mv, etc. - easier to fix everything than enumerate.
      await NativeBridge.runInProot(
        'chmod -R 755 /usr/bin /usr/sbin /bin /sbin '
        '/usr/local/bin /usr/local/sbin 2>/dev/null; '
        'chmod -R +x /usr/lib/apt/ /usr/lib/dpkg/ /usr/libexec/ '
        '/var/lib/dpkg/info/ /usr/share/debconf/ 2>/dev/null; '
        'chmod 755 /lib/*/ld-linux-*.so* /usr/lib/*/ld-linux-*.so* 2>/dev/null; '
        'mkdir -p /var/lib/dpkg/updates /var/lib/dpkg/triggers; '
        'echo permissions_fixed',
      );

      // --- Install base packages via apt-get (like Termux proot-distro) ---
      // Now that our proot matches Termux exactly (env -i, clean host env,
      // proper flags), dpkg works normally. No need for Java-side deb
      // extraction - let dpkg+tar handle it inside proot like Termux does.
      //
      // PERF: the Node.js tarball download is independent of apt, so start it
      // now and await it after apt finishes. Previously the ~30 MB download
      // only began once apt had completed, making two slow phases fully
      // serial.
      final nodeTarUrl = AppConstants.getNodeTarballUrl(arch);
      final nodeTarPath = '$filesDir/tmp/nodejs.tar.xz';
      var nodeDownloadPct = 0;
      final nodeDownloadFuture = _dio.download(
        nodeTarUrl,
        nodeTarPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            nodeDownloadPct = ((received / total) * 100).round();
          }
        },
      );

      _updateSetupNotification('Updating package lists...', progress: 48);
      onProgress(const SetupState(
        step: SetupStep.installingNode,
        progress: 0.1,
        message: 'Updating package lists...',
      ));
      // Acquire::Languages=none skips the translation indexes, which are a
      // large download nobody reads here. Retries help on flaky mobile data.
      await NativeBridge.runInProot(
        'apt-get -o Acquire::Retries=3 -o Acquire::Languages=none update -y');

      _updateSetupNotification('Installing base packages...', progress: 52);
      onProgress(SetupState(
        step: SetupStep.installingNode,
        progress: 0.15,
        message: 'Installing base packages... '
            '(Node.js download $nodeDownloadPct%)',
      ));
      // Pre-configure tzdata to avoid an interactive continent/timezone prompt
      // (tzdata ignores DEBIAN_FRONTEND on first install if no zone is set).
      await NativeBridge.runInProot(
        'ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && '
        'echo "Etc/UTC" > /etc/timezone',
      );
      // Keep this set minimal - every package costs download time plus slow
      // dpkg work under proot:
      //   ca-certificates: HTTPS for npm/git
      //   git:             openclaw has git deps (@whiskeysockets/libsignal-node)
      //   curl, wget:      used by optional package installers
      //
      // python3/make/g++ (a few hundred MB) are only needed when npm has to
      // compile a native addon with node-gyp. They are no longer installed
      // up front; the openclaw install below falls back to installing them
      // and retrying if it actually needs them. On the common path this saves
      // a large download and a long dpkg run.
      await NativeBridge.runInProot(
        'apt-get install -y --no-install-recommends '
        'ca-certificates git curl wget',
      );

      // Git config (.gitconfig) is written by installBionicBypass() on the
      // Java side - directly to $rootfsDir/root/.gitconfig - rewrites
      // SSH→HTTPS for npm git deps (no SSH keys in proot).

      // --- Node.js via binary tarball (downloaded above, in parallel) ---
      // Fetched directly from nodejs.org, bypassing curl/gpg/NodeSource which
      // fail inside proot. Includes node + npm + corepack.
      onProgress(SetupState(
        step: SetupStep.installingNode,
        progress: 0.3,
        message: nodeDownloadPct >= 100
            ? 'Node.js ${AppConstants.nodeVersion} downloaded'
            : 'Downloading Node.js ${AppConstants.nodeVersion}... '
                '$nodeDownloadPct%',
      ));
      _updateSetupNotification(
        'Downloading Node.js... $nodeDownloadPct%',
        progress: 55,
      );
      await nodeDownloadFuture;

      _updateSetupNotification('Extracting Node.js...', progress: 72);
      onProgress(const SetupState(
        step: SetupStep.installingNode,
        progress: 0.75,
        message: 'Extracting Node.js...',
      ));
      await NativeBridge.extractNodeTarball(nodeTarPath);

      _updateSetupNotification('Verifying Node.js...', progress: 78);
      onProgress(const SetupState(
        step: SetupStep.installingNode,
        progress: 0.9,
        message: 'Verifying Node.js...',
      ));
      // node-wrapper.js patches broken proot syscalls before loading npm.
      // /usr/local/bin is on PATH, so node finds the tarball's npm.
      const wrapper = '/root/.openclaw/node-wrapper.js';
      const nodeRun = 'node $wrapper';
      // npm from nodejs.org tarball is at /usr/local/lib/node_modules/npm
      const npmCli = '/usr/local/lib/node_modules/npm/bin/npm-cli.js';
      await NativeBridge.runInProot(
        'node --version && $nodeRun $npmCli --version',
      );
      onProgress(const SetupState(
        step: SetupStep.installingNode,
        progress: 1.0,
        message: 'Node.js installed',
      ));

      // Step 4: Install OpenClaw (80-98%)
      _updateSetupNotification('Installing OpenClaw...', progress: 82);
      onProgress(const SetupState(
        step: SetupStep.installingOpenClaw,
        progress: 0.0,
        message: 'Installing OpenClaw (this may take a few minutes)...',
      ));
      // A previous interrupted install leaves a partial
      // /usr/local/lib/node_modules/openclaw plus .openclaw-* staging dirs
      // behind. npm then fails with `ENOTEMPTY: rename ... .openclaw-XXXX`
      // because it cannot stage over them (#133). Remove them first - this is
      // confined to the proot rootfs, never the Android filesystem.
      await NativeBridge.runInProot(
        'rm -rf /usr/local/lib/node_modules/openclaw '
        '/usr/local/lib/node_modules/.openclaw-* '
        '/usr/local/lib/node_modules/.staging 2>/dev/null; '
        'rm -rf /tmp/npm-cache/_cacache/tmp 2>/dev/null; '
        'echo npm_state_cleaned',
        timeout: 120,
      );
      // PERF: skip the audit and funding round-trips and omit dev
      // dependencies. Under proot every extra network call and file write is
      // expensive, and none of this is needed for a global runtime install.
      const npmFlags = '--omit=dev --no-audit --no-fund --loglevel=error';
      try {
        await NativeBridge.runInProot(
          '$nodeRun $npmCli install -g openclaw $npmFlags',
          timeout: 1800,
        );
      } catch (e) {
        // Two known causes, handled in one ladder:
        //  1. stale npm state -> ENOTEMPTY/EEXIST (#133)
        //  2. a dependency needs node-gyp, so python3/make/g++ are required.
        //     Those are deliberately not installed up front because they cost
        //     several hundred MB and a long dpkg run that most installs never
        //     need.
        onProgress(const SetupState(
          step: SetupStep.installingOpenClaw,
          progress: 0.3,
          message: 'Retrying with build tools (this takes longer)...',
        ));
        _updateSetupNotification('Installing build tools...', progress: 85);
        await NativeBridge.runInProot(
          '$nodeRun $npmCli cache clean --force 2>/dev/null; '
          'rm -rf /usr/local/lib/node_modules/openclaw '
          '/usr/local/lib/node_modules/.openclaw-* '
          '/tmp/npm-cache 2>/dev/null; '
          'echo npm_cache_cleaned',
          timeout: 180,
        );
        await NativeBridge.runInProot(
          'apt-get install -y --no-install-recommends python3 make g++',
          timeout: 1800,
        );
        _updateSetupNotification('Retrying OpenClaw install...', progress: 88);
        await NativeBridge.runInProot(
          '$nodeRun $npmCli install -g openclaw $npmFlags',
          timeout: 1800,
        );
      }

      _updateSetupNotification('Creating bin wrappers...', progress: 92);
      onProgress(const SetupState(
        step: SetupStep.installingOpenClaw,
        progress: 0.7,
        message: 'Creating bin wrappers...',
      ));
      // npm global install creates symlinks for bin entries, but symlinks
      // can fail silently in proot. Create shell wrappers from Java side
      // (reads package.json directly from rootfs filesystem - no escaping).
      await NativeBridge.createBinWrappers('openclaw');

      _updateSetupNotification('Verifying OpenClaw...', progress: 96);
      onProgress(const SetupState(
        step: SetupStep.installingOpenClaw,
        progress: 0.9,
        message: 'Verifying OpenClaw...',
      ));
      await NativeBridge.runInProot('openclaw --version || echo openclaw_installed');
      onProgress(const SetupState(
        step: SetupStep.installingOpenClaw,
        progress: 1.0,
        message: 'OpenClaw installed',
      ));

      // Step 5: Bionic Bypass already installed (before node verification)
      _updateSetupNotification('Setup complete!', progress: 100);
      onProgress(const SetupState(
        step: SetupStep.configuringBypass,
        progress: 1.0,
        message: 'Bionic Bypass configured',
      ));

      // Done
      _stopSetupService();
      onProgress(const SetupState(
        step: SetupStep.complete,
        progress: 1.0,
        message: 'Setup complete! Ready to start the gateway.',
      ));
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Download failed: ${e.message}. Check your internet connection.',
      ));
    } catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Setup failed: $e',
      ));
    }
  }
}
