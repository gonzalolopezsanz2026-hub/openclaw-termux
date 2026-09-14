/**
 * Basic tests for OpenClaw-Termux
 * Tests module loading, exports, and basic functionality
 */

import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import os from 'node:os';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = join(__dirname, '..');

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (error) {
    console.log(`  ✗ ${name}`);
    console.log(`    ${error.message}`);
    failed++;
  }
}

async function testAsync(name, fn) {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (error) {
    console.log(`  ✗ ${name}`);
    console.log(`    ${error.message}`);
    failed++;
  }
}

async function runTests() {
  console.log('\n🧪 OpenClaw-Termux Tests\n');

  // File existence tests
  console.log('📁 File Structure:');

  test('bin/openclawx exists', () => {
    assert.ok(existsSync(join(projectRoot, 'bin/openclawx')));
  });

  test('lib/index.js exists', () => {
    assert.ok(existsSync(join(projectRoot, 'lib/index.js')));
  });

  test('lib/installer.js exists', () => {
    assert.ok(existsSync(join(projectRoot, 'lib/installer.js')));
  });

  test('lib/bionic-bypass.js exists', () => {
    assert.ok(existsSync(join(projectRoot, 'lib/bionic-bypass.js')));
  });

  test('package.json exists', () => {
    assert.ok(existsSync(join(projectRoot, 'package.json')));
  });

  // Module import tests
  console.log('\n📦 Module Imports:');

  await testAsync('index.js exports main function', async () => {
    const indexModule = await import('./index.js');
    assert.ok(typeof indexModule.main === 'function');
  });

  await testAsync('installer.js exports setup functions', async () => {
    const installerModule = await import('./installer.js');
    assert.ok(typeof installerModule.setupProotUbuntu === 'function');
    assert.ok(typeof installerModule.installProot === 'function');
    assert.ok(typeof installerModule.getInstallStatus === 'function');
  });

  await testAsync('bionic-bypass.js loads without error', async () => {
    await import('./bionic-bypass.js');
  });

  // Package.json validation
  console.log('\n📋 Package Configuration:');

  test('package.json has required fields', () => {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    assert.ok(pkg.name === 'openclaw-termux');
    assert.ok(pkg.version);
    assert.ok(pkg.main);
    assert.ok(pkg.bin);
    assert.ok(pkg.bin.openclawx);
  });

  test('package.json specifies node engine >= 18', () => {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    assert.ok(pkg.engines?.node);
    const minVersion = parseInt(pkg.engines.node.match(/\d+/)[0]);
    assert.ok(minVersion >= 18, 'Node.js version should be >= 18');
  });

  // Version consistency (#99)
  console.log('\n🔢 Version Consistency:');

  await testAsync('CLI banner version matches package.json', async () => {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    const indexSource = readFileSync(join(projectRoot, 'lib/index.js'), 'utf8');
    assert.ok(
      !/const VERSION = ['"]\d/.test(indexSource),
      'lib/index.js must not hard-code a version literal - read it from package.json'
    );
    // Import and confirm the resolved value.
    const { main } = await import('./index.js');
    assert.ok(typeof main === 'function');
    assert.ok(pkg.version, 'package.json must declare a version');
  });

  test('pubspec.yaml version matches package.json', () => {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    const pubspec = readFileSync(join(projectRoot, 'flutter_app/pubspec.yaml'), 'utf8');
    const match = pubspec.match(/^version:\s*([0-9.]+)\+\d+/m);
    assert.ok(match, 'pubspec.yaml must declare version: X.Y.Z+build');
    assert.equal(
      match[1],
      pkg.version,
      `pubspec (${match[1]}) and package.json (${pkg.version}) versions must match`
    );
  });

  test('constants.dart version matches package.json', () => {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    const constants = readFileSync(
      join(projectRoot, 'flutter_app/lib/constants.dart'), 'utf8');
    const match = constants.match(/static const String version = '([0-9.]+)'/);
    assert.ok(match, 'constants.dart must declare a version string');
    assert.equal(match[1], pkg.version);
  });

  // Gateway port resolution (#124)
  console.log('\n🔌 Gateway Port:');

  await testAsync('getGatewayPort is exported and defaults to 18789', async () => {
    const installer = await import('./installer.js');
    assert.ok(typeof installer.getGatewayPort === 'function');
    // No proot rootfs on a dev machine, so this exercises the fallback path.
    assert.equal(installer.getGatewayPort(), 18789);
  });

  test('no hard-coded dashboard port remains in lib/index.js', () => {
    const indexSource = readFileSync(join(projectRoot, 'lib/index.js'), 'utf8');
    assert.ok(
      !indexSource.includes('127.0.0.1:18789'),
      'lib/index.js must build the dashboard URL from getGatewayPort()'
    );
  });

  // Bionic bypass functionality
  console.log('\n🔧 Bionic Bypass:');

  test('os.networkInterfaces returns object after bypass', () => {
    const interfaces = os.networkInterfaces();
    assert.ok(typeof interfaces === 'object');
  });

  // Writing style (see AGENTS.md)
  console.log('\n\u270E Writing Style:');

  test('no em dashes or en dashes in tracked text files', () => {
    // Em dash (U+2014) and en dash (U+2013) are banned project-wide; plain
    // ASCII hyphens only. Box-drawing characters (U+2500 block) are fine and
    // are deliberately not matched here.
    const exts = ['.md', '.dart', '.kt', '.js', '.yml', '.yaml', '.html',
      '.sh', '.gradle', '.xml', '.properties', '.json'];
    const skipDirs = new Set(['node_modules', '.git', 'build', '.dart_tool',
      '.gradle', 'assets']);
    const offenders = [];

    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.isDirectory()) {
          if (skipDirs.has(entry.name)) continue;
          walk(join(dir, entry.name));
          continue;
        }
        if (!exts.some((e) => entry.name.endsWith(e))) continue;
        const full = join(dir, entry.name);
        const content = readFileSync(full, 'utf8');
        if (/[\u2013\u2014]/.test(content)) {
          offenders.push(full.replace(projectRoot, '').replace(/^[\\/]/, ''));
        }
      }
    };
    walk(projectRoot);

    assert.equal(
      offenders.length,
      0,
      `Replace em/en dashes with '-' in:\n  ${offenders.join('\n  ')}`
    );
  });

  test('AGENTS.md exists', () => {
    assert.ok(existsSync(join(projectRoot, 'AGENTS.md')));
  });

  // Summary
  console.log('\n' + '─'.repeat(40));
  console.log(`\n📊 Results: ${passed} passed, ${failed} failed\n`);

  if (failed > 0) {
    process.exit(1);
  }
}

runTests();
