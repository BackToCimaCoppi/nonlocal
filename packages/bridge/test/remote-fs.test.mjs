import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { RemoteFsService, FS_RPC_ERROR } from '../dist/fs/remote-fs.js';
import { makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

test('AC-46: RemoteFsService.list parameters, clamping, two-stage lstat, broken/loop symlinks, FIFO and errors', async () => {
  const root = makeTempDir('nonlocal-fs-ac46-');
  try {
    const home = join(root, 'home');
    const work = join(home, 'work');
    mkdirSync(work, { recursive: true });

    // Create 10 dirs, hidden files, normal files
    for (let i = 0; i < 10; i++) {
      mkdirSync(join(work, `Dir-${String(i).padStart(2, '0')}`));
    }
    mkdirSync(join(work, '.hidden-dir'));
    writeFileSync(join(work, '.hidden.txt'), 'secret');
    writeFileSync(join(work, 'alpha.txt'), 'hello');
    writeFileSync(join(work, 'Beta.md'), 'world');

    // 600 file symlinks
    const targetFile = join(work, 'alpha.txt');
    for (let i = 0; i < 600; i++) {
      symlinkSync(targetFile, join(work, `sym-${String(i).padStart(3, '0')}.txt`));
    }

    // Dangling and ELOOP symlinks
    symlinkSync(join(work, 'does-not-exist'), join(work, 'dangling.link'));
    symlinkSync(join(work, 'loop-b.link'), join(work, 'loop-a.link'));
    symlinkSync(join(work, 'loop-a.link'), join(work, 'loop-b.link'));

    // FIFO special node
    execFileSync('mkfifo', [join(work, 'pipe.fifo')]);

    // Restricted dir (0000)
    const noPermDir = join(root, 'noperm');
    mkdirSync(noPermDir);
    chmodSync(noPermDir, 0o000);

    const svc = new RemoteFsService({ homeDir: home });

    // Default path (~)
    const homeRes = await svc.list({});
    assert.equal(homeRes.homePath.endsWith('home'), true);
    assert.ok(homeRes.entries.some((e) => e.name === 'work' && e.type === 'dir'));

    // "/" has parentPath === null
    const rootRes = await svc.list({ path: '/' });
    assert.equal(rootRes.parentPath, null);

    // includeFiles:false + showHidden:false -> 600 file symlinks & broken links don't crowd out the 10 dirs
    const dirsOnly = await svc.list({ path: '~/work', limit: 999 });
    assert.equal(dirsOnly.entries.length, 10);
    assert.equal(dirsOnly.totalCount, 10);
    assert.equal(dirsOnly.truncated, false);
    assert.ok(dirsOnly.entries.every((e) => e.type === 'dir'));

    // includeFiles:true + limit clamping [1, 500] + broken symlinks + FIFO skipped
    const withFiles = await svc.list({ path: work, includeFiles: true, limit: 999 });
    assert.equal(withFiles.entries.length, 500);
    assert.equal(withFiles.truncated, true);
    assert.ok(withFiles.totalCount >= 604);
    // Dirs come before files
    assert.equal(withFiles.entries[0].type, 'dir');
    assert.equal(withFiles.entries[10].type, 'file');
    assert.ok(!withFiles.entries.some((e) => e.name === 'pipe.fifo'));

    const minLimit = await svc.list({ path: work, includeFiles: true, limit: 0 });
    assert.equal(minLimit.entries.length, 1);

    // query lowercase substring & broken symlink targetType
    const brokenList = await svc.list({ path: work, includeFiles: true, query: 'LINK' });
    const dangling = brokenList.entries.find((e) => e.name === 'dangling.link');
    const loopA = brokenList.entries.find((e) => e.name === 'loop-a.link');
    assert.equal(dangling?.targetType, 'broken');
    assert.equal(loopA?.targetType, 'broken');

    // showHidden:true
    const hiddenRes = await svc.list({ path: work, includeFiles: true, showHidden: true, query: '.hidden' });
    assert.equal(hiddenRes.entries.length, 2);

    // Error codes
    await assert.rejects(() => svc.list({ path: 'relative/path' }), (e) => e.rpcCode === FS_RPC_ERROR.INVALID_PATH);
    await assert.rejects(() => svc.list({ path: '~other/dir' }), (e) => e.rpcCode === FS_RPC_ERROR.INVALID_PATH);
    await assert.rejects(() => svc.list({ path: `${work}\0bad` }), (e) => e.rpcCode === FS_RPC_ERROR.INVALID_PATH);
    await assert.rejects(() => svc.list({ path: join(root, 'missing') }), (e) => e.rpcCode === FS_RPC_ERROR.NOT_FOUND);
    await assert.rejects(() => svc.list({ path: targetFile }), (e) => e.rpcCode === FS_RPC_ERROR.NOT_DIRECTORY);
    if (process.getuid?.() !== 0) {
      await assert.rejects(() => svc.list({ path: noPermDir }), (e) => e.rpcCode === FS_RPC_ERROR.PERMISSION_DENIED);
    }

    chmodSync(noPermDir, 0o755);
  } finally {
    rmTempDir(root);
  }
});

test('AC-47 (fs part): RemoteFsService.readFile exact 524288B UTF-8, >512KiB trim, MIME, binary/size/perm errors & beforeReturnHook', async () => {
  const root = makeTempDir('nonlocal-fs-ac47-');
  try {
    // Exact 524288B of 3-byte Chinese characters: 524288 - 2 = 524286 (divisible by 3) + 'ab'
    const exact512k = join(root, 'exact.txt');
    const cjk3 = '中'.repeat(524286 / 3) + 'ab';
    assert.equal(Buffer.byteLength(cjk3, 'utf8'), 524288);
    writeFileSync(exact512k, cjk3, 'utf8');

    // >512KiB with unaligned 3-byte Chinese at 524288 boundary ('x' + 174762*'中' + extra)
    const over512k = join(root, 'over.md');
    const overStr = 'x' + '中'.repeat(175000);
    writeFileSync(over512k, overStr, 'utf8');

    const htmlFile = join(root, 'page.html');
    writeFileSync(htmlFile, '<h1>hi</h1>', 'utf8');
    const pngFile = join(root, 'img.png');
    writeFileSync(pngFile, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    const jpgFile = join(root, 'photo.JPG');
    writeFileSync(jpgFile, Buffer.from([0xff, 0xd8, 0xff, 0xe0]));

    const bigImg = join(root, 'big.png');
    writeFileSync(bigImg, Buffer.alloc(10 * 1024 * 1024 + 1));

    const pdfMagic = join(root, 'fake.txt');
    writeFileSync(pdfMagic, '%PDF-1.7\n...');
    const nulFile = join(root, 'nul.txt');
    writeFileSync(nulFile, Buffer.from([0x41, 0x00, 0x42]));
    const pdfExt = join(root, 'doc.pdf');
    writeFileSync(pdfExt, 'plain text');
    const fifoPath = join(root, 'fifo.txt');
    execFileSync('mkfifo', [fifoPath]);
    const dirPath = join(root, 'subdir');
    mkdirSync(dirPath);
    const noPermFile = join(root, 'secret.txt');
    writeFileSync(noPermFile, 'hidden');
    chmodSync(noPermFile, 0o000);

    let hookCalled = 0;
    const svc = new RemoteFsService({
      homeDir: root,
      beforeReturnHook: () => {
        hookCalled += 1;
      },
    });

    const exactRes = await svc.readFile({ path: exact512k });
    assert.equal(exactRes.kind, 'text');
    assert.equal(exactRes.mimeType, 'text/plain');
    assert.equal(exactRes.bytesRead, 524288);
    assert.equal(exactRes.truncated, false);

    const overRes = await svc.readFile({ path: over512k });
    assert.equal(overRes.kind, 'text');
    assert.equal(overRes.mimeType, 'text/markdown');
    assert.equal(overRes.truncated, true);
    assert.equal(overRes.content.includes('\uFFFD'), false);

    assert.equal((await svc.readFile({ path: htmlFile })).mimeType, 'text/html');
    const pngRes = await svc.readFile({ path: pngFile });
    assert.equal(pngRes.kind, 'image');
    assert.equal(pngRes.mimeType, 'image/png');
    assert.equal((await svc.readFile({ path: jpgFile })).mimeType, 'image/jpeg');
    assert.ok(hookCalled >= 5);

    await assert.rejects(() => svc.readFile({ path: bigImg }), (e) => e.rpcCode === FS_RPC_ERROR.FILE_TOO_LARGE);
    await assert.rejects(() => svc.readFile({ path: pdfMagic }), (e) => e.rpcCode === FS_RPC_ERROR.UNSUPPORTED_BINARY);
    await assert.rejects(() => svc.readFile({ path: nulFile }), (e) => e.rpcCode === FS_RPC_ERROR.UNSUPPORTED_BINARY);
    await assert.rejects(() => svc.readFile({ path: pdfExt }), (e) => e.rpcCode === FS_RPC_ERROR.UNSUPPORTED_BINARY);
    await assert.rejects(() => svc.readFile({ path: fifoPath }), (e) => e.rpcCode === FS_RPC_ERROR.UNSUPPORTED_BINARY);
    await assert.rejects(() => svc.readFile({ path: dirPath }), (e) => e.rpcCode === FS_RPC_ERROR.IS_DIRECTORY);
    if (process.getuid?.() !== 0) {
      await assert.rejects(() => svc.readFile({ path: noPermFile }), (e) => e.rpcCode === FS_RPC_ERROR.PERMISSION_DENIED);
    }
    await assert.rejects(() => svc.readFile({ path: join(root, 'missing.txt') }), (e) => e.rpcCode === FS_RPC_ERROR.NOT_FOUND);
    await assert.rejects(() => svc.readFile({ path: 'relative.txt' }), (e) => e.rpcCode === FS_RPC_ERROR.INVALID_PATH);

    chmodSync(noPermFile, 0o600);
  } finally {
    rmTempDir(root);
  }
});

test('AC-50 & SH-T5-01: WS 4001 preemption during in-flight fs_list / fs_read_file suppresses stale response cleanly', async () => {
  const { createDefaultConfig } = await import('../dist/config/schema.js');
  const { WsServerTransport } = await import('../dist/transport/ws-server-transport.js');
  const { NonlocalGateway } = await import('../dist/gateway/gateway.js');
  const { StateStore } = await import('../dist/store/state-store.js');
  const { SanitizedLogger } = await import('../dist/log/logger.js');
  const { FakeTestAdapter } = await import('./helpers/fake-adapter.mjs');
  const { connectWs } = await import('./helpers/ws-client.mjs');
  const { createTestToken } = await import('./helpers/test-utils.mjs');

  const root = makeTempDir('nonlocal-fs-preempt-');
  const sampleFile = join(root, 'sample.txt');
  writeFileSync(sampleFile, 'concurrent-safe', 'utf8');

  let releaseHook = null;
  let onHookReached = null;
  const fsService = new RemoteFsService({
    homeDir: root,
    beforeReturnHook: async () => {
      onHookReached?.();
      await new Promise((resolve) => {
        releaseHook = resolve;
      });
    },
  });

  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  const gateway = new NonlocalGateway({
    config: cfg,
    transport: new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfg.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg.security.rateLimit,
      getHealthState: () => ({ childAlive: false, activeClient: true }),
    }),
    adapter: new FakeTestAdapter(),
    store: new StateStore({ stateDir: cfg.state.dir }),
    logger: new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] }),
    fsService,
  });

  try {
    const { port } = await gateway.start();
    const url = `ws://127.0.0.1:${port}/acp`;

    const c1 = await connectWs(url, token);
    const hookHitPromise = new Promise((r) => {
      onHookReached = r;
    });
    const c1ClosePromise = c1.waitForClose();
    c1.sendJson({ jsonrpc: '2.0', id: 77, method: 'nonlocal/fs_read_file', params: { path: sampleFile } });
    await hookHitPromise;

    // Preempt c1 with c2 BEFORE RemoteFsService finishes returning
    const c2 = await connectWs(url, token);
    const c1Close = await c1ClosePromise;
    assert.equal(c1Close.code, 4001);

    // Unblock RemoteFsService: c2 must NOT receive c1's id=77 response, and c2 works normally
    releaseHook?.();
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(c2.messages.some((m) => m.id === 77), false);

    // Unblock c2's own fs_list after hook passes
    const fsNoBlock = fsService;
    onHookReached = () => queueMicrotask(() => releaseHook?.());
    c2.sendJson({ jsonrpc: '2.0', id: 78, method: 'nonlocal/fs_list', params: { path: root } });
    const listRes = await c2.waitFor((m) => m.id === 78);
    assert.ok(listRes.result.entries.some((e) => e.name === 'state'));
    assert.ok(fsNoBlock);

    c2.close();
    await c2.waitForClose();
  } finally {
    releaseHook?.();
    await gateway.stop();
    rmTempDir(root);
  }
});
