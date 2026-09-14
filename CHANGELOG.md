# Changelog

## v2026.9.14 - Custom Ports, Node Command Policy, Ollama & Toolchain Refresh

### Bug Fixes

- **Custom Gateway Port Ignored (#124)** - The app hard-coded `18789` in the health check, dashboard URL, token-URL regex, node WebSocket, port probe and notification, so setting `gateway.port` to anything else left the app talking to the wrong address (and eventually declaring a healthy gateway dead). A new `GatewayConfig` service resolves `gateway.port` from `openclaw.json` on every init and start; `GatewayService.kt` reads it natively, passes `--port` explicitly for non-default ports, and reports it in logs and the notification. Token URLs are now matched on any port. The Termux CLI got the same fix via `getGatewayPort()`
- **Node Commands Were Never Authorised (#81, #95)** - The app wrote `gateway.nodes.allowCommands` / `gateway.nodes.denyCommands`, which OpenClaw does not read. The canonical keys are `gateway.nodes.commands.allow` / `.deny`. Classified commands such as `camera.snap` and `screen.record` were therefore silently unauthorised. Now written correctly, the legacy keys are deleted, and `gateway.nodes.pairing.autoApproveLocal` is set so the local node pairs without manual approval
- **OpenClaw Install Failure (#133)** - `npm install -g openclaw` aborted with `ENOTEMPTY: rename '/usr/local/lib/node_modules/openclaw' -> '.openclaw-XXXX'` when a previous attempt was interrupted. Stale `openclaw` and `.openclaw-*` directories plus the npm cache temp dir are now removed before installing, and the install retries once after a hard cache clean. Same cleanup added to the Termux CLI installer
- **EBADENGINE Warning (#133)** - Node.js bumped 22.14.0 → **22.23.2**, satisfying `undici`'s `engines.node >= 22.19.0`
- **npm Package Lagged the Repo (#99)** - `lib/index.js` hard-coded `VERSION = '1.7.3'` while the package was 1.8.7. The version is now read from `package.json`, a new `npm-publish.yml` workflow publishes on version change, and tests assert that `package.json`, `pubspec.yaml` and `constants.dart` agree

### New Features

- **Ollama Provider (#117)** - Run local and self-hosted open models with no API key. Configured per upstream requirements: native API base URL (**no `/v1`** - that path breaks tool calling), explicit `api: "ollama"`, a `300s` timeout for cold local models, and provider-qualified model refs (`ollama/qwen3:8b`). The base URL is editable in the app for LAN or Ollama Cloud hosts, and a trailing `/v1` is stripped automatically
- **Editable Provider Base URL** - Providers that support it expose a Base URL field; the API key field is optional for local runtimes

### Security

- **Credentials Excluded From Backup** - `FlutterSharedPreferences.xml` holds the node Ed25519 private key, the paired device token and the gateway auth token, and was included in Android cloud backup and device transfer. Both are now excluded
- **SSH Refuses to Expose a Passwordless Root (#107)** - sshd binds `0.0.0.0`, so it is reachable from the whole LAN. It now performs a pre-flight check for a real root password hash in `/etc/shadow` and exits instead of starting, and `PermitEmptyPasswords no` is pinned explicitly
- **Pairing Code Validated Before Shell Use** - the gateway-supplied pairing code is checked against `^[A-Za-z0-9_-]{4,32}$` before being interpolated into the auto-approve command
- **Settings Snapshot No Longer Leaks Tokens** - the exported snapshot is written to shared storage; device and gateway tokens are now omitted

### Maintenance

- **Toolchain Refresh** - Gradle 8.3 → **8.14.3**, AGP 8.1.0 → **8.11.1**, Kotlin 1.9.0 → **2.2.20**, `compileSdk` 35 → **36**. The project could not build on any current Flutter before this (Gradle 8.3 is below Flutter's 8.7 minimum). CI Flutter pinned 3.24.0 → **3.44.8**. `ndkVersion` added to the plugin subproject defaults so the `jni` plugin configures
- **Tests** - First Dart test suite (`flutter_app/test/`, 17 tests) covering port resolution, token-URL parsing and the provider contract; npm suite expanded to 16 tests. CI now runs `flutter test` and no longer swallows `flutter analyze` failures
- **Analyzer Clean** - Migrated `CardTheme`/`DialogTheme` to `CardThemeData`/`DialogThemeData`, clearing 4 pre-existing errors
- **Branding** - All NextGenX references removed from the app, README, privacy policy and release assets
- **Docs** - README capability table corrected to **9 capabilities / 21 commands** (`battery.status` and `serial.*` were undocumented), structure tree updated, new Gateway Port / SSH / Ollama sections. Privacy policy gained a Node Device Capabilities section disclosing that camera, location, screen and sensor data can reach your configured AI provider

---

## v1.8.6 - Config Repair, Gateway Mode & Node.js Update

### Bug Fixes

- **Config Corruption Fix (#83, #88)** - Provider model entries were written as bare strings instead of objects (`{ id: "model-name" }`), causing OpenClaw config validation to reject the file with "expected object, received string". Fixed both the Node.js script path and the direct file I/O fallback in `ProviderConfigService`. Existing corrupted configs are now auto-repaired on gateway init
- **Gateway Start Failure (#93, #90)** - The gateway blocked with "set gateway.mode=local (current: unset)". Now `gateway.mode=local` is set automatically in openclaw.json during provider config saves, gateway config writes, bionic bypass installation, and on startup repair
- **Config Auto-Repair on Init (#88)** - Added `_repairConfigFile()` that runs on every `GatewayService.init()` to fix corrupted model entries and missing `gateway.mode`, preventing the crash-restart loop (5 restarts → stopped)
- **Bionic Bypass Installation Robustness (#94)** - Added retry logic with parent directory creation if the initial `mkdirs()` fails silently on some devices
- **Pre-seed Config on Setup** - `installBionicBypass()` now creates a default `openclaw.json` with `gateway.mode=local` during initial setup, so the gateway works immediately after installation
- **Setup Re-prompt After Node Upgrade (#97)** - Expanded auto-repair on splash screen to reinstall Node.js and OpenClaw when their binaries are missing but rootfs is intact, instead of forcing a full re-setup

### Enhancements

- **Node.js Updated to 22.14.0** - Upgraded from 22.13.1 to latest 22.x LTS for better stability and compatibility (#87)
- **npm Package Synced to 1.8.6** - Updated package.json version, refreshed dependencies, bumped engine to Node >= 22
- **Removed Outdated Model** - Dropped `claude-3-5-sonnet-20241022` from Anthropic provider defaults

---

## v1.8.4 - Serial, Log Timestamps & ADB Backup

### New Features

- **Serial over Bluetooth & USB (#21)** - New `serial` node capability with 5 commands (`list`, `connect`, `disconnect`, `write`, `read`). Supports USB serial devices via `usb_serial` and BLE devices via Nordic UART Service (flutter_blue_plus). Device IDs prefixed with `usb:` or `ble:` for disambiguation
- **Gateway Log Timestamps (#54)** - All gateway log messages (both Kotlin and Dart side) now include ISO 8601 UTC timestamps for easier debugging
- **ADB Backup Support (#55)** - Added `android:allowBackup="true"` to AndroidManifest so users can back up app data via `adb backup`

### Enhancements

- **Check for Updates (#59)** - New "Check for Updates" option in Settings > About. Queries the GitHub Releases API, compares semver versions, and shows an update dialog with a download link if a newer release is available

### Bug Fixes

- **Node Capabilities Not Available to AI (#56)** - `_writeNodeAllowConfig()` silently failed when proot/node wasn't ready, causing the gateway to start with no `allowCommands`. Added direct file I/O fallback to write `openclaw.json` directly on the Android filesystem. Also fixed `node.capabilities` event to send both `commands` and `caps` fields matching the connect frame format

### Node Command Reference Update

| Capability | Commands |
|------------|----------|
| Serial | `serial.list`, `serial.connect`, `serial.disconnect`, `serial.write`, `serial.read` |

---

## v1.8.3 - Multi-Instance Guard

### Bug Fixes

- **Duplicate Gateway Processes (#48)** - Services now guard against re-entry when Android re-delivers `onStartCommand` via `START_STICKY`, preventing duplicate processes, leaked wakelocks, and repeated answers to connected apps
- **Wakelock Leaks** - All 5 foreground services release any existing wakelock before acquiring a new one
- **Orphan PTY Instances** - Terminal, onboarding, configure, and package install screens now kill the previous PTY before starting a new one on retry
- **Notification ID Collisions** - SetupService and ScreenCaptureService no longer share notification IDs with other services

---

## v1.8.2 - DNS Reliability, Screenshot Capture, Custom Models & Setup Detection

### Bug Fixes

- **Setup State Detection (#44)** - `openclawx onboard` no longer says setup isn't done after a successful setup. Replaced slow proot exec check with fast filesystem check for openclaw detection, with a longer-timeout fallback
- **DNS / No Internet Inside Proot (#45)** - resolv.conf is now written to both `config/resolv.conf` (bind-mount source) and `rootfs/ubuntu/etc/resolv.conf` (direct fallback) at every entry point: app start, every proot invocation, gateway start, SSH start, and all terminal screens. Survives APK updates
- **NVIDIA NIM Config Breaks Onboarding (#46)** - Provider config save now falls back to direct file write if the proot Node.js one-liner fails (e.g. due to DNS issues)

### New Features

- **Screenshot Capture** - All terminal and log screens now have a camera button to capture the current view as a PNG image saved to device storage
- **Custom Model Support (#46)** - AI Providers screen now allows entering any custom model name (e.g. `kimi-k2.5`) via a "Custom..." option in the model dropdown
- **Updated NVIDIA Models (#46)** - Added `meta/llama-3.3-70b-instruct` and `deepseek-ai/deepseek-r1` to NVIDIA NIM default models

### Reliability

- **resolv.conf at Every Entry Point** - `MainActivity.configureFlutterEngine()` ensures directories and resolv.conf exist on every app launch. `ProcessManager.ensureResolvConf()` guarantees it before every proot invocation. All Kotlin services and Dart screens have independent fallbacks writing to both paths
- **APK Update Resilience** - Directories and DNS config are recreated on engine init, so the app recovers automatically after an APK update clears filesDir

---

## v1.8.0 - AI Providers, SSH Access, Ctrl Keys & Configure Menu

### New Features

- **AI Providers** - New "AI Providers" screen to configure API keys and select models for 7 providers: Anthropic, OpenAI, Google Gemini, OpenRouter, NVIDIA NIM, DeepSeek, and xAI. Writes configuration directly to `~/.openclaw/openclaw.json`
- **SSH Remote Access** - New "SSH Access" screen to start/stop an SSH server (sshd) inside proot, set the root password, and view connection info with copyable `ssh` commands. Runs as an Android foreground service for persistence
- **Configure Menu** - New "Configure" dashboard card opens `openclaw configure` in a built-in terminal for managing gateway settings
- **Clickable URLs** - Terminal and onboarding screens detect URLs at tap position (joining adjacent lines, stripping box-drawing characters) and offer Open/Copy/Cancel dialog

### Bug Fixes

- **Ctrl Key with Soft Keyboard (#37)** - Ctrl and Alt modifier state from the toolbar now applies to soft keyboard input across all terminal screens (terminal, configure, onboarding, package install). Previously only worked with toolbar buttons
- **Ctrl+Arrow/Home/End/PgUp/PgDn (#38)** - Toolbar Ctrl modifier now sends correct escape sequences for arrow keys and navigation keys (e.g. `Ctrl+Left` sends `ESC[1;5D`)
- **resolv.conf ENOENT after Update (#40)** - DNS resolution failed after app update because `resolv.conf` was missing. Now ensured on every app launch (splash screen), before every proot operation (`getProotShellConfig`), and in the gateway service init - covering reinstall, update, and normal launch

### Dashboard

- Added "AI Providers" and "SSH Access" quick action cards

---

## v1.7.3 - DNS Fix, Snapshot & Version Sync

### Bug Fixes

- **DNS Breaks After a While (#34)** - `resolv.conf` is now written before every gateway start (in both the Flutter service and the Android foreground service), not just during initial setup. This prevents DNS resolution failures when Android clears the app's file cache
- **Version Mismatch (#35)** - Synced version strings across `constants.dart`, `pubspec.yaml`, `package.json`, and `lib/index.js` so they all report `1.7.3`

### New Features

- **Config Snapshot (#27)** - Added Export/Import Snapshot buttons under Settings > Maintenance. Export saves `openclaw.json` and app preferences to a JSON file; Import restores them. A "Snapshot" quick action card is also available on the dashboard
- **Storage Access** - Added Termux-style "Setup Storage" in Settings. Grants shared storage permission and bind-mounts `/sdcard` into proot, so files in `/sdcard/Download` (etc.) are accessible from inside the Ubuntu environment. Snapshots are saved to `/sdcard/Download/` when permission is granted

---

## v1.7.2 - Setup Fix

### Bug Fixes

- **node-gyp Python Error** - Fixed `PlatformException(PROOT_ERROR)` during setup caused by npm's bundled node-gyp failing to find Python. Now installs `python3`, `make`, and `g++` in the rootfs so native addon compilation works properly
- **tzdata Interactive Prompt** - Fixed setup hanging on continent/timezone selection by pre-configuring timezone to UTC before installing python3
- **proot-compat Spawn Mock** - Removed `node-gyp` and `make` from the mocked side-effect command list since real build tools are now installed

---

## v1.7.1 - Background Persistence & Camera Fix

> Requires Android 10+ (API 29)

### Node Background Persistence

- **Lifecycle-Aware Reconnection** - Handles both `resumed` and `paused` lifecycle states; forces connection health check on app resume since Dart timers freeze while backgrounded
- **Foreground Service Verification** - Watchdog, resume handler, and pause handler all verify the Android foreground service is still alive and restart it if killed
- **Stale Connection Recovery** - On app resume, detects if the WebSocket went stale (no data for 90s+) and forces a full reconnect instead of silently staying in "paired" state
- **Live Notification Status** - Foreground notification text updates in real-time to reflect node state (connected, connecting, reconnecting, error)

### Camera Fix

- **Immediate Camera Release** - Camera hardware is now released immediately after each snap/clip using `try/finally`, preventing "Failed to submit capture request" errors on repeated use
- **Auto-Exposure Settle** - Added 500ms settle time before snap for proper auto-exposure/focus
- **Flash Conflict Prevention** - Flash capability releases the camera when torch is turned off, so subsequent snap/clip operations don't conflict
- **Stale Controller Recovery** - Flash capability detects errored/stale controllers and recreates them instead of failing silently

---

## v1.7.0 - Clean Modern UI Redesign

> Requires Android 10+ (API 29)

### UI Overhaul

- **New Color System** - Replaced default Material 3 purple with a professional black/white palette and red (#DC2626) accent, inspired by Linear/Vercel design language
- **Inter Typography** - Added Google Fonts Inter across the entire app for a clean, modern feel
- **AppColors Class** - Centralized color constants for consistent theming (dark bg, surfaces, borders, status colors)
- **Dark Mode** - Near-black backgrounds (#0A0A0A), subtle surface (#121212), bordered cards
- **Light Mode** - Clean white backgrounds, light borders (#E5E5E5), bordered cards

### Component Redesign

- **Zero-Elevation Cards** - All cards now use 1px borders with 12px radius instead of drop shadows
- **Pill Status Badges** - Gateway and Node controls show pill-shaped badges (icon + label) instead of 12px status dots
- **Monochrome Dashboard** - Removed rainbow icon colors from quick action cards; all icons use neutral muted tones
- **Uppercase Section Headers** - Settings, Node, and Setup screens use letterspaced muted grey headers
- **Red Accent Buttons** - Primary actions (Start Gateway, Enable Node, Install) use red filled buttons; destructive/secondary actions use outlined buttons
- **Terminal Toolbar** - Aligned colors to new palette; CTRL/ALT active state uses red accent; bumped border radius

### Splash Screen

- **Fade-In Animation** - 800ms fade-in on launch with easeOut curve
- **App Icon Branding** - Uses ic_launcher.png instead of generic cloud icon
- **Inter Bold Wordmark** - "OpenClaw" displayed in Inter weight 800 with letter-spacing

### Polish

- **Log Colors** - INFO lines use muted grey (not red); WARN uses amber instead of orange
- **Installed Badges** - Package screens use consistent green (#22C55E) for "Installed" badges
- **Capability Icons** - Node screen capabilities use muted color instead of primary red
- **Input Focus** - Text fields highlight with red border on focus
- **Switches** - Red thumb when active, grey when inactive
- **Progress Indicators** - All use red accent color

### CI

- Removed OpenClaw Node app build from workflow (gateway-only CI now)

---

## v1.6.1 - Node Capabilities & Background Resilience

> Requires Android 10+ (API 29)

### New Features

- **7 Node Capabilities (15 commands)** - Camera, Flash, Location, Screen, Sensor, Haptic, and Canvas now fully registered and exposed to the AI via WebSocket node protocol
- **Proactive Permission Requests** - Camera, location, and sensor permissions are requested upfront when the node is enabled, before the gateway sends invoke requests
- **Battery Optimization Prompt** - Automatically asks user to exempt the app from battery restrictions when enabling the node

### Background Resilience

- **WebSocket Keep-Alive** - 30-second periodic ping prevents idle connection timeout
- **Connection Watchdog** - 45-second timer detects dropped connections and triggers reconnect
- **Stale Connection Detection** - Forces reconnect if no data received for 90+ seconds
- **App Lifecycle Handling** - Auto-reconnects node when app returns to foreground after being backgrounded
- **Exponential Backoff** - Reconnect attempts use 350ms-8s backoff to avoid flooding

### Fixes

- **Gateway Config** - Patches `/root/.openclaw/openclaw.json` to clear `denyCommands` and set `allowCommands` for all 15 commands (previously wrote to wrong config file)
- **Location Timeout** - Added 10-second time limit to GPS fix with fallback to last known position
- **Canvas Errors** - Returns honest `NOT_IMPLEMENTED` errors instead of fake success responses
- **Node Display Name** - Renamed from "OpenClaw Termux" to "OpenClawX Node"

### Node Command Reference

| Capability | Commands |
|------------|----------|
| Camera | `camera.snap`, `camera.clip`, `camera.list` |
| Canvas | `canvas.navigate`, `canvas.eval`, `canvas.snapshot` |
| Flash | `flash.on`, `flash.off`, `flash.toggle`, `flash.status` |
| Location | `location.get` |
| Screen | `screen.record` |
| Sensor | `sensor.read`, `sensor.list` |
| Haptic | `haptic.vibrate` |

---

## v1.5.5

- Initial release with gateway management, terminal emulator, and basic node support
