# AGENTS.md

Instructions for AI agents working in this repository.

## Writing style (applies to code, comments, docs, commits, PRs)

- **Never use em dashes (U+2014) or en dashes (U+2013).** Use a plain ASCII
  hyphen `-` instead. This is enforced by `npm test`.
- Do not use "smart" quotes. Plain ASCII `'` and `"` only.
- Box-drawing characters (`|`, and the U+2500 block used in the README
  architecture diagram and in the `_boxDrawing` regexes) are fine and must not
  be replaced. They are not dashes.
- Keep comments about *why*, not *what*. This codebase carries a lot of
  non-obvious platform workarounds; when you add one, say which issue it fixes.

## What this project is

Two products in one repo, both wrapping the upstream OpenClaw AI gateway:

| Path | What it is |
|------|-----------|
| `flutter_app/` | The main product. Standalone Android app: Flutter UI + Kotlin native layer, runs Ubuntu under a bundled `proot`, no root, no Termux. |
| `lib/`, `bin/openclawx` | Legacy Termux CLI published to npm as `openclaw-termux`. |

The Kotlin layer (`flutter_app/android/app/src/main/kotlin/com/nxg/openclawproot/`)
is where the hard parts live. `ProcessManager.kt` deliberately mirrors Termux
`proot-distro` semantics; `BootstrapManager.kt` handles rootfs extraction and
permission repair.

## Environment

Development here is on **Windows** with **PowerShell**.

- PowerShell has no heredocs. Write a file and use `git commit -F <file>` rather
  than `<<<`.
- `$pid` is read-only in PowerShell. Use a different variable name.
- `npm install` fails with `EBADPLATFORM` because `package.json` declares
  `"os": ["android", "linux"]`. Use `npm install --force` for local dev only.
- Shell scripts in `scripts/` are checked out with CRLF. Run them as
  `bash -c "tr -d '\r' < scripts/x.sh > scripts/.x-lf.sh && bash scripts/.x-lf.sh"`.
  Run from the repo so `$SCRIPT_DIR` resolves correctly, then delete the temp copy.

## Build and verify

Always run these before claiming a change works:

```powershell
cd flutter_app
flutter analyze          # must report 0 errors
flutter test             # must be green
flutter build apk --release

cd ..
npm test                 # includes the no-dash and version-consistency checks
npx eslint .
```

`flutter analyze` currently reports 5 pre-existing `deprecated_member_use`
infos (Radio `groupValue`/`onChanged`, DropdownButtonFormField `value`). Zero
**errors** is the bar.

### PRoot binaries are required for a working APK

`flutter_app/android/app/src/main/jniLibs/` is gitignored and empty in a fresh
clone, so a locally built APK will install but fail setup with
`CANNOT LINK EXECUTABLE`. Fetch them first:

```powershell
bash scripts/fetch-proot-binaries.sh
```

proot declares `Depends: libandroid-shmem, libtalloc`. All four files
(`libproot.so`, `libprootloader.so`, `libtalloc.so`, `libandroid-shmem.so`)
must be present per ABI or setup cannot work. CI verifies this and fails.

### Device testing

```powershell
$env:Path += ';C:\android-sdk\platform-tools'
adb install -r flutter_app\build\app\outputs\flutter-apk\app-release.apk
adb shell am start -n com.nxg.openclawproot/.MainActivity
adb logcat -d | Select-String -Pattern 'FATAL|AndroidRuntime'
```

Use `adb install -r`, never uninstall: uninstalling destroys the ~500 MB rootfs
and all user config.

## Hard rules

- **Do not rename the `com.nxg.openclawproot` application ID.** It would break
  updates for every existing user.
- **Never delete outside the app's private directory.** `BootstrapManager`
  deletion must keep its symlink check and `canonicalPath.startsWith(filesDir)`
  boundary check. Ignoring this destroyed user photos once (#67, #63).
- **Match upstream OpenClaw config keys exactly.** Check the docs at
  <https://docs.openclaw.ai> before writing to `openclaw.json`. Inventing a
  plausible key produces a silent no-op: the app wrote
  `gateway.nodes.allowCommands` for months when upstream reads
  `gateway.nodes.commands.allow`.
- **Do not hard-code port 18789.** Resolve it through `GatewayConfig` /
  `readConfiguredPort()`. Upstream precedence is
  `--port` > `OPENCLAW_GATEWAY_PORT` > `gateway.port` > `18789`.
- **Do not log or export credentials.** The node Ed25519 private key, device
  token and gateway auth token live in SharedPreferences, are excluded from
  Android backup, and must stay out of snapshots written to shared storage.
- **Keep versions in sync.** `package.json`, `flutter_app/pubspec.yaml` and
  `flutter_app/lib/constants.dart` must agree, and `pubspec.yaml` must also bump
  its `+build` number. `npm test` asserts this.

## Conventions

- Config writes to `openclaw.json` go through a Node.js one-liner inside proot,
  with a `dart:io` fallback for when proot is not ready. Keep both paths in sync.
- Model entries must be objects (`{ id: "name" }`), never bare strings, or
  OpenClaw rejects the config.
- Long-running work (downloads, `npm install`, `apt`) belongs in the setup
  wizard behind a foreground service with progress, never inline on the splash
  screen.
- Commit messages follow conventional commits: `fix:`, `feat:`, `perf:`,
  `chore:`, `docs:`, with the issue number where one exists.
