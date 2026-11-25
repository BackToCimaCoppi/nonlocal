import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { createDefaultConfig } from '../dist/config/schema.js';
import {
  installLaunchdService,
  uninstallLaunchdService,
  renderLaunchdPlist,
} from '../dist/service/launchd.js';
import {
  installSystemdService,
  uninstallSystemdService,
  renderSystemdUnit,
  checkSystemdLingerReadOnly,
} from '../dist/service/systemd.js';
import { makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

test('AC-60 & AC-61: launchd plist & systemd user unit generation, plutil lint, ephemeral path gate, linger read-only diagnostics, zero secrets (PP-60-service)', () => {
  const root = makeTempDir('nonlocal-svc-ac60-');
  try {
    const cfg = createDefaultConfig(process.env, root);
    cfg.configPath = join(root, 'cfg & dir', 'config.json');
    cfg.state.dir = join(root, 'state');
    cfg.state.logFile = join(root, 'state', 'bridge.log');

    const validEntry = join(root, 'pkg', 'dist', 'cli.js');
    const badNpxEntry = join(root, '.npm', '_npx', '12345', 'node_modules', 'nonlocal-bridge', 'dist', 'cli.js');

    // Ephemeral /_npx/ rejected by default, allowed with flag
    assert.throws(() => renderLaunchdPlist({ config: cfg, entryScript: badNpxEntry }), /ephemeral/i);
    assert.throws(() => renderSystemdUnit({ config: cfg, entryScript: badNpxEntry }), /ephemeral/i);
    assert.doesNotThrow(() =>
      renderLaunchdPlist({ config: cfg, entryScript: badNpxEntry, allowEphemeralPath: true })
    );

    // AC-60: launchd plist generation (XML escaping/fields verified on all platforms; plutil -lint & install/uninstall on darwin)
    const renderedPlistXml = renderLaunchdPlist({ config: cfg, entryScript: validEntry, homeDir: root });
    assert.ok(renderedPlistXml.includes('<string>com.nonlocal.bridge</string>'));
    assert.ok(renderedPlistXml.includes('&amp;')); // XML escaped
    assert.ok(renderedPlistXml.includes('<integer>63</integer>')); // Umask 63
    assert.ok(renderedPlistXml.includes('<integer>5</integer>')); // ThrottleInterval 5
    assert.ok(renderedPlistXml.includes('<key>KeepAlive</key>\n  <true/>'));
    assert.ok(renderedPlistXml.includes('<key>ProcessType</key>\n  <string>Interactive</string>'));
    assert.ok(renderedPlistXml.includes('service.log'));
    assert.equal(renderedPlistXml.includes('bridge.log'), false);
    assert.equal(renderedPlistXml.includes('<string></string>'), false);

    if (process.platform === 'darwin') {
      const plistPath = join(root, 'LaunchAgents', 'com.nonlocal.bridge.plist');
      const resLaunchd = installLaunchdService({
        config: cfg,
        entryScript: validEntry,
        plistPath,
        homeDir: root,
        dryRun: true,
      });
      assert.equal(resLaunchd.plutilOk, true);
      assert.equal(statSync(plistPath).mode & 0o777, 0o600);
      const plistXml = readFileSync(plistPath, 'utf8');
      assert.equal(plistXml, renderedPlistXml);

      // Mock launchctl delegation on install & uninstall
      const launchctlCalls = [];
      installLaunchdService({
        config: cfg,
        entryScript: validEntry,
        plistPath,
        homeDir: root,
        runLaunchctl: (args) => {
          launchctlCalls.push(args);
          return { ok: true, stdout: '', stderr: '' };
        },
      });
      assert.ok(launchctlCalls.some((a) => a[0] === 'bootstrap'));
      uninstallLaunchdService({
        plistPath,
        runLaunchctl: (args) => {
          launchctlCalls.push(args);
          return { ok: true, stdout: '', stderr: '' };
        },
      });
      assert.ok(launchctlCalls.some((a) => a[0] === 'bootout'));
      assert.equal(existsSync(plistPath), false);
    }

    // AC-61: systemd --user unit + mocked systemctl + read-only linger diagnostics
    const unitPath = join(root, 'systemd', 'nonlocal-bridge.service');
    const calls = [];
    const mockCmd = (bin, args) => {
      calls.push([bin, ...args]);
      if (bin === 'loginctl') return { ok: true, stdout: 'no\n', stderr: '' };
      return { ok: true, stdout: '', stderr: '' };
    };
    const resSysd = installSystemdService({
      config: cfg,
      entryScript: validEntry,
      unitPath,
      homeDir: root,
      userName: 'demo',
      runSystemdCmd: mockCmd,
    });
    assert.equal(resSysd.started, true);
    assert.equal(resSysd.linger.lingerEnabled, false);
    assert.ok(resSysd.linger.fixCommand.includes('enable-linger demo'));
    // Zero enable-linger mutation command issued
    assert.equal(calls.some((c) => c[0] === 'loginctl' && c.includes('enable-linger')), false);

    const unitText = readFileSync(unitPath, 'utf8');
    assert.ok(unitText.includes('UMask=0077'));
    assert.ok(unitText.includes('KillMode=control-group'));
    assert.ok(unitText.includes('Restart=always'));
    assert.ok(unitText.includes('RestartSec=5'));
    assert.ok(unitText.includes('start --foreground --config'));
    assert.ok(unitText.includes('service.log'));

    // systemctl D-Bus failure throws clear diagnostic
    assert.throws(
      () =>
        installSystemdService({
          config: cfg,
          entryScript: validEntry,
          unitPath,
          homeDir: root,
          userName: 'demo',
          runSystemdCmd: () => ({ ok: false, stdout: '', stderr: 'Failed to connect to bus' }),
        }),
      /daemon-reload failed/i
    );

    // D-Bus unavailable diagnostic
    const dbusDiag = checkSystemdLingerReadOnly('demo', () => ({
      ok: false,
      stdout: '',
      stderr: 'Failed to connect to bus: No medium found',
    }));
    assert.equal(dbusDiag.lingerEnabled, null);
    assert.match(dbusDiag.diagnostic, /D-Bus/i);

    uninstallSystemdService({ unitPath, dryRun: true });
    assert.equal(existsSync(unitPath), false);
  } finally {
    rmTempDir(root);
  }
});
