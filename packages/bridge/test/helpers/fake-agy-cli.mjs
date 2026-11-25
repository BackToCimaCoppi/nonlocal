#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const args = process.argv.slice(2);
if (args[0] === 'acp') {
  const here = dirname(fileURLToPath(import.meta.url));
  await import(join(here, 'fake-acp-server.mjs'));
} else if (args.includes('/usage')) {
  const mode = process.env.FAKE_AGY_USAGE_MODE || 'ok';
  const countFile = process.env.FAKE_AGY_USAGE_COUNT_FILE || '';
  if (countFile) {
    const cur = existsSync(countFile) ? Number(readFileSync(countFile, 'utf8').trim()) || 0 : 0;
    writeFileSync(countFile, String(cur + 1), 'utf8');
  }
  const secretLeak = 'SECRET_RAW_CLI_TOKEN_LEAK';
  const grandchildPidFile = process.env.FAKE_AGY_USAGE_GRANDCHILD_PID_FILE || '';
  if (grandchildPidFile && (mode === 'hang' || mode === 'auth')) {
    const { spawn } = await import('node:child_process');
    const gc = spawn(process.execPath, ['-e', 'setInterval(() => {}, 10000);'], { stdio: 'ignore' });
    writeFileSync(grandchildPidFile, String(gc.pid), 'utf8');
  }
  if (mode === 'hang') {
    setInterval(() => {}, 10000);
  } else if (mode === 'auth') {
    process.stderr.write(`Please log in first (${secretLeak})\n`);
    process.exit(1);
  } else if (mode === 'ansi_fail') {
    process.stdout.write(`\x1b[31mError: ${secretLeak}\x1b[0m\n`);
    process.exit(2);
  } else if (mode === 'bad_json') {
    process.stdout.write(`not json output ${secretLeak}\n`);
    process.exit(0);
  } else {
    const delayMs = Number(process.env.FAKE_AGY_USAGE_DELAY_MS || '40');
    setTimeout(() => {
      const payload = {
        command: {
          data: {
            groups: [
              {
                name: 'Claude Opus',
                description: 'Flagship reasoning',
                buckets: [
                  { id: 'c_5h', name: '5-Hour Limit', window: '5 hour', remaining_fraction: 80, reset_time: '2026-11-24T04:00:00Z' },
                  { id: 'c_wk', name: 'Weekly Limit', window: '7d', remaining_fraction: 0.9, reset_time: '2026-11-30T00:00:00Z' },
                ],
              },
            ],
          },
        },
      };
      process.stdout.write(`\x1b[32m${JSON.stringify(payload)}\x1b[0m\n`);
      process.exit(0);
    }, delayMs);
  }
} else {
  process.stderr.write(`Unknown fake-agy args: ${args.join(' ')}\n`);
  process.exit(1);
}
