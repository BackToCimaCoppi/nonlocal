import { existsSync, readFileSync, statSync, watch } from 'node:fs';
import { loadConfig } from '../config/index.js';
import type { CliConfigOverrides } from '../config/types.js';
import { resolveServiceLogPath } from '../service/launchd.js';

export async function handleLogsCommand(opts: {
  lines?: number;
  follow?: boolean;
  service?: boolean;
  overrides: CliConfigOverrides;
}): Promise<number> {
  try {
    const cfg = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
    const targetPath = opts.service ? resolveServiceLogPath(cfg) : cfg.state.logFile;
    if (!existsSync(targetPath)) {
      console.error(`Log file not found: ${targetPath}`);
      return 1;
    }

    const n = Math.max(1, Number(opts.lines) || 50);
    const content = readFileSync(targetPath, 'utf8');
    const allLines = content.split(/\r?\n/);
    if (allLines.length > 0 && allLines[allLines.length - 1] === '') {
      allLines.pop();
    }
    const tail = allLines.slice(-n);
    if (tail.length > 0) {
      console.log(tail.join('\n'));
    }

    if (!opts.follow) {
      return 0;
    }

    let offset = statSync(targetPath).size;
    await new Promise<void>((resolve) => {
      const watcher = watch(targetPath, () => {
        try {
          const st = statSync(targetPath);
          if (st.size < offset) offset = 0;
          if (st.size > offset) {
            const buf = readFileSync(targetPath);
            process.stdout.write(buf.subarray(offset, st.size).toString('utf8'));
            offset = st.size;
          }
        } catch {
          // ignore transient rotate
        }
      });
      const stop = () => {
        watcher.close();
        resolve();
      };
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
    });
    return 0;
  } catch (err) {
    console.error(`logs failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }
}
