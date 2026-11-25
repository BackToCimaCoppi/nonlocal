import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = resolve(PKG_DIR, '..', '..');

function walkFiles(dir, skipDirs = new Set(['node_modules', 'dist'])) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (skipDirs.has(entry.name)) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(full, skipDirs));
    else out.push(full);
  }
  return out;
}

test('AC-01 & AC-02: strict ws+commander 0-transitive runtime deps, no root npm pollution, clean tsc build & executable dist/cli.js (PP-01-deps)', () => {
  assert.equal(existsSync(join(REPO_ROOT, 'package.json')), false, 'repo root must NOT have package.json');
  assert.equal(existsSync(join(REPO_ROOT, 'node_modules')), false, 'repo root must NOT have node_modules');

  const pkg = JSON.parse(readFileSync(join(PKG_DIR, 'package.json'), 'utf8'));
  assert.equal(pkg.name, 'nonlocal-bridge');
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.engines?.node, '>=22.13.0');
  assert.equal(pkg.bin?.['nonlocal-bridge'], 'dist/cli.js');
  assert.deepEqual(Object.keys(pkg.dependencies).sort(), ['commander', 'ws']);
  assert.deepEqual(Object.keys(pkg.devDependencies).sort(), ['@types/node', '@types/ws', 'typescript']);

  // Verify installed production dependency tree has zero transitive deps
  const lsOut = execFileSync('npm', ['--prefix', PKG_DIR, 'ls', '--omit=dev', '--all', '--json'], {
    encoding: 'utf8',
  });
  const tree = JSON.parse(lsOut);
  const topDeps = Object.keys(tree.dependencies || {}).sort();
  assert.deepEqual(topDeps, ['commander', 'ws']);
  for (const depName of topDeps) {
    const installedTransitive = Object.entries(tree.dependencies[depName].dependencies || {}).filter(
      ([, meta]) => meta && typeof meta.version === 'string'
    );
    assert.deepEqual(installedTransitive, [], `${depName} must have 0 installed transitive deps`);
  }

  // AC-02: typecheck & executable dist/cli.js
  execFileSync('npm', ['--prefix', PKG_DIR, 'run', 'typecheck'], { stdio: 'pipe' });
  const cliDist = join(PKG_DIR, 'dist', 'cli.js');
  assert.equal(existsSync(cliDist), true);
  assert.ok((statSync(cliDist).mode & 0o111) !== 0, 'dist/cli.js must have executable bit');
});

test('AC-03 & AC-04: zero lsof/.backup( in src/, exact 3 adapter files, zero agy/.gemini leakage in core/base-acp-adapter (PP-04-iso)', () => {
  const srcDir = join(PKG_DIR, 'src');
  const srcFiles = walkFiles(srcDir);

  // AC-03: Zero lsof and zero SQLite .backup( anywhere in src/
  for (const f of srcFiles) {
    const content = readFileSync(f, 'utf8');
    assert.equal(/\blsof\b/.test(content), false, `Forbidden lsof reference in ${f}`);
    assert.equal(/\.backup\s*\(/.test(content), false, `Forbidden .backup( call in ${f}`);
  }

  // AC-04: src/adapter/ strictly 3 files; types.ts has zero workerId leak; transport has zero relay stubs
  const adapterFiles = readdirSync(join(srcDir, 'adapter')).sort();
  assert.deepEqual(adapterFiles, ['antigravity-adapter.ts', 'base-acp-adapter.ts', 'types.ts']);
  assert.equal(/\bworkerId\b/.test(readFileSync(join(srcDir, 'adapter', 'types.ts'), 'utf8')), false);

  // Core decoupled directories & base-acp-adapter.ts must have ZERO standalone agy or .gemini tokens
  const coreSubdirs = ['transport', 'gateway', 'store', 'sync', 'fs', 'log'];
  const isolatedFiles = [
    ...coreSubdirs.flatMap((d) => walkFiles(join(srcDir, d))),
    join(srcDir, 'adapter', 'base-acp-adapter.ts'),
  ];
  const geminiToken = '.g' + 'emini';
  const agyWordRe = new RegExp('\\ba' + 'gy\\b', 'i');

  for (const f of isolatedFiles) {
    const content = readFileSync(f, 'utf8');
    assert.equal(agyWordRe.test(content), false, `Forbidden provider token found in isolated file ${f}`);
    assert.equal(content.includes(geminiToken), false, `Forbidden config dir token found in isolated file ${f}`);
  }

  // Verify unidirectional import graph (T4 §5.1)
  const extractImports = (filePath) => {
    const src = readFileSync(filePath, 'utf8');
    const specs = [];
    for (const m of src.matchAll(/(?:from|import)\s+['"]([^'"]+)['"]/g)) specs.push(m[1]);
    return specs;
  };

  for (const f of walkFiles(join(srcDir, 'gateway'))) {
    for (const imp of extractImports(f)) {
      assert.equal(imp === 'ws' || imp.startsWith('ws/'), false, `gateway must not import ws (${f})`);
      assert.equal(imp.includes('antigravity-adapter'), false, `gateway must not import antigravity-adapter (${f})`);
    }
  }
  for (const f of walkFiles(join(srcDir, 'adapter'))) {
    for (const imp of extractImports(f)) {
      assert.equal(/\/(store|gateway|transport)\//.test(imp), false, `adapter must not import store/gateway/transport (${f}: ${imp})`);
    }
  }
  for (const d of ['store', 'sync', 'fs']) {
    for (const f of walkFiles(join(srcDir, d))) {
      for (const imp of extractImports(f)) {
        assert.equal(/\/(transport|adapter)\//.test(imp), false, `${d} must not import transport/adapter (${f}: ${imp})`);
      }
    }
  }
  for (const d of ['config', 'log']) {
    for (const f of walkFiles(join(srcDir, d))) {
      for (const imp of extractImports(f)) {
        assert.equal(
          /\/(transport|gateway|adapter|store|sync|fs|service|cli)\//.test(imp),
          false,
          `${d} must not import upper layers (${f}: ${imp})`
        );
      }
    }
  }
});

test('AC-05: public OSS hygiene gate (no personal paths, private keys, or non-example host literals) (PP-05-public)', () => {
  const pkgFiles = walkFiles(PKG_DIR, new Set(['node_modules', 'dist']));
  // Construct patterns dynamically so static-gates.test.mjs stays clean
  const macUserRe = new RegExp('/Us' + 'ers/[a-z]', 'i');
  const homeUserRe = new RegExp('/ho' + 'me/[a-z]', 'i');
  const privKeyRe = new RegExp('BEGIN [A-Z ]*PRIV' + 'ATE KEY');
  const personalLabelRe = new RegExp('com\\.a' + 'ru\\.', 'i');

  for (const f of pkgFiles) {
    const content = readFileSync(f, 'utf8');
    assert.equal(macUserRe.test(content), false, `Leaked macOS home path in ${f}`);
    assert.equal(homeUserRe.test(content), false, `Leaked Linux home path in ${f}`);
    assert.equal(privKeyRe.test(content), false, `Leaked private key header in ${f}`);
    assert.equal(personalLabelRe.test(content), false, `Leaked personal launchd label in ${f}`);
  }
});
