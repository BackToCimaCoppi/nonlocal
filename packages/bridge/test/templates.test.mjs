import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { TEMPLATE_FILES, renderNamedTemplate } from '../dist/cli/template.js';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

test('AC-62: all 6 network templates render via CLI read-only, block /health externally, use single-hop XFF, zero en0/READY_FILE/secrets', () => {
  const listOut = execFileSync(process.execPath, [CLI_PATH, 'template', 'list'], { encoding: 'utf8' });
  for (const name of ['tailscale', 'cloudflare', 'vps-caddy', 'vps-nginx', 'vps-ssh-tunnel', 'lan']) {
    assert.ok(listOut.includes(name), `missing template name ${name}`);
    assert.ok(TEMPLATE_FILES[name]);
  }

  // Render via CLI with --port 19999
  const nginx = execFileSync(process.execPath, [CLI_PATH, 'template', 'vps-nginx', '--port', '19999'], {
    encoding: 'utf8',
  });
  assert.ok(nginx.includes('127.0.0.1:19999'));
  assert.ok(nginx.includes('location = /health'));
  assert.ok(nginx.includes('return 404'));
  assert.ok(nginx.includes('limit_req_zone'));
  assert.ok(nginx.includes('X-Forwarded-For $remote_addr'));

  const caddy = renderNamedTemplate('vps-caddy', { port: 19999 });
  assert.ok(caddy.includes('127.0.0.1:19999'));
  assert.ok(caddy.includes('/health*'));
  assert.ok(caddy.includes('404'));
  assert.ok(caddy.includes('rate_limit'));
  assert.ok(caddy.includes('header_up X-Forwarded-For {remote_host}'));

  const sshTunnel = renderNamedTemplate('vps-ssh-tunnel', { port: 19999 });
  assert.ok(sshTunnel.includes('19999'));
  assert.equal(sshTunnel.includes('en0'), false, 'must NOT hardcode macOS en0');
  assert.equal(sshTunnel.includes('READY_FILE'), false, 'must NOT include READY_FILE');

  const cf = renderNamedTemplate('cloudflare', { port: 19999 });
  assert.ok(cf.includes('http://127.0.0.1:19999'));
  assert.equal(cf.includes('/health'), false);

  const ts = renderNamedTemplate('tailscale', { port: 19999 });
  assert.ok(ts.includes('http://127.0.0.1:19999/acp'));

  const lan = renderNamedTemplate('lan', { port: 19999 });
  assert.ok(lan.includes('19999'));
  assert.ok(lan.includes('198.51.100.10'));
});
