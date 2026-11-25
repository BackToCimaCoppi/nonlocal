import { realpathSync } from 'node:fs';
import { open, readdir, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, extname, join, resolve as resolvePath } from 'node:path';

export const MAX_LIST_LIMIT = 500;
export const MAX_TEXT_READ_BYTES = 512 * 1024; // 524288
export const MAX_IMAGE_READ_BYTES = 10 * 1024 * 1024; // 10485760

export const FS_RPC_ERROR = Object.freeze({
  NOT_FOUND: -32011,
  NOT_DIRECTORY: -32012,
  PERMISSION_DENIED: -32013,
  IS_DIRECTORY: -32014,
  UNSUPPORTED_BINARY: -32015,
  FILE_TOO_LARGE: -32016,
  INVALID_PATH: -32602,
});

const IMAGE_MIME_BY_EXT = new Map<string, string>([
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.heic', 'image/heic'],
  ['.heif', 'image/heif'],
  ['.bmp', 'image/bmp'],
  ['.svg', 'image/svg+xml'],
]);

const FAST_REJECT_BINARY_EXTS = new Set([
  '.pdf',
  '.zip',
  '.gz',
  '.tar',
  '.dmg',
  '.mp4',
  '.mov',
  '.mp3',
  '.docx',
  '.xlsx',
  '.pptx',
]);

const PDF_MAGIC = Buffer.from('%PDF-', 'ascii');

export class FsRpcError extends Error {
  readonly rpcCode: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'FsRpcError';
    this.rpcCode = code;
  }
}

export function formatReadableSize(bytes: number): string {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n < 0) return '0 B';
  if (n < 1024) return `${Math.round(n)} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export function expandHomePath(rawPath: string, homeDir: string = homedir()): string {
  const trimmed = rawPath.trim();
  if (trimmed === '~') return homeDir;
  if (trimmed.startsWith('~/')) {
    return join(homeDir, trimmed.slice(2));
  }
  return trimmed;
}

function normalizeAbsolutePathNoTrailingSlash(absPath: string): string {
  if (!absPath || absPath === '/') return '/';
  return absPath.replace(/\/+$/, '') || '/';
}

export function validateRemotePathInput(
  rawPath: unknown,
  { allowEmpty = false, homeDir = homedir() }: { allowEmpty?: boolean; homeDir?: string } = {}
): string {
  if (rawPath === undefined || rawPath === null) {
    if (allowEmpty) return homeDir;
    throw new FsRpcError(FS_RPC_ERROR.INVALID_PATH, 'Invalid path: path is required');
  }
  if (typeof rawPath !== 'string') {
    throw new FsRpcError(FS_RPC_ERROR.INVALID_PATH, 'Invalid path: must be a string');
  }
  if (rawPath.includes('\0')) {
    throw new FsRpcError(FS_RPC_ERROR.INVALID_PATH, 'Invalid path: contains NUL byte');
  }
  const trimmed = rawPath.trim();
  if (!trimmed) {
    if (allowEmpty) return homeDir;
    throw new FsRpcError(FS_RPC_ERROR.INVALID_PATH, 'Invalid path: empty path');
  }
  if (trimmed === '~' || trimmed.startsWith('~/')) {
    return expandHomePath(trimmed, homeDir);
  }
  if (trimmed.startsWith('/')) {
    return trimmed;
  }
  throw new FsRpcError(FS_RPC_ERROR.INVALID_PATH, 'Invalid path: must start with "/" or "~"');
}

function mapFsErrno(err: unknown, fallbackCode: number = FS_RPC_ERROR.NOT_FOUND): FsRpcError {
  if (err instanceof FsRpcError) return err;
  const code = (err as { code?: string } | undefined)?.code;
  if (code === 'ENOENT' || code === 'ELOOP') {
    return new FsRpcError(FS_RPC_ERROR.NOT_FOUND, 'Path not found');
  }
  if (code === 'ENOTDIR') {
    return new FsRpcError(FS_RPC_ERROR.NOT_DIRECTORY, 'Path is not a directory');
  }
  if (code === 'EACCES' || code === 'EPERM') {
    return new FsRpcError(FS_RPC_ERROR.PERMISSION_DENIED, 'Permission denied');
  }
  if (code === 'EISDIR') {
    return new FsRpcError(FS_RPC_ERROR.IS_DIRECTORY, 'Path is a directory');
  }
  return new FsRpcError(fallbackCode, err instanceof Error ? err.message : 'Filesystem error');
}

async function resolveHomePathCanonical(homeDir: string): Promise<string> {
  try {
    return normalizeAbsolutePathNoTrailingSlash(await realpath(homeDir));
  } catch {
    return normalizeAbsolutePathNoTrailingSlash(resolvePath(homeDir));
  }
}

export function canonicalizeCwdWithHome(
  rawCwd: unknown,
  fallbackCwd: string | null = null,
  homeDir: string = homedir()
): string | null {
  const raw = typeof rawCwd === 'string' && rawCwd.trim().length > 0 ? rawCwd.trim() : fallbackCwd;
  if (!raw) return null;
  const expanded = expandHomePath(raw, homeDir);
  const resolved = resolvePath(expanded);
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

export function trimIncompleteUtf8Tail(buf: Buffer): Buffer {
  if (!buf || buf.length === 0) return buf;
  const len = buf.length;
  let start = len - 1;
  const minStart = Math.max(0, len - 4);
  while (start > minStart && (buf[start] & 0xc0) === 0x80) {
    start -= 1;
  }
  const lead = buf[start];
  let expectedLen = 1;
  if ((lead & 0x80) === 0x00) {
    expectedLen = 1;
  } else if ((lead & 0xe0) === 0xc0) {
    expectedLen = 2;
  } else if ((lead & 0xf0) === 0xe0) {
    expectedLen = 3;
  } else if ((lead & 0xf8) === 0xf0) {
    expectedLen = 4;
  } else {
    return buf.subarray(0, start);
  }
  const actualLen = len - start;
  if (actualLen < expectedLen) {
    return buf.subarray(0, start);
  }
  return buf;
}

async function readUpToBytes(fh: Awaited<ReturnType<typeof open>>, maxBytes: number): Promise<Buffer> {
  if (maxBytes <= 0) return Buffer.alloc(0);
  const buf = Buffer.allocUnsafe(maxBytes);
  let totalRead = 0;
  while (totalRead < maxBytes) {
    const { bytesRead } = await fh.read(buf, totalRead, maxBytes - totalRead, totalRead);
    if (bytesRead <= 0) break;
    totalRead += bytesRead;
  }
  return buf.subarray(0, totalRead);
}

function resolveTextMimeType(ext: string): string {
  if (ext === '.md' || ext === '.markdown') return 'text/markdown';
  if (ext === '.html' || ext === '.htm') return 'text/html';
  return 'text/plain';
}

export type RemoteFsBeforeReturnHook = (ctx: {
  op: 'list' | 'read';
  path: string;
  kind?: 'text' | 'image';
}) => Promise<void> | void;

export interface RemoteFsListResult {
  path: string;
  parentPath: string | null;
  homePath: string;
  totalCount: number;
  truncated: boolean;
  entries: Array<{
    name: string;
    path: string;
    type: string;
    targetType?: string;
    size?: number;
    mtimeMs?: number;
  }>;
}

export interface RemoteFsReadResult {
  path: string;
  name: string;
  kind: 'text' | 'image';
  mimeType: string;
  content: string;
  size: number;
  bytesRead: number;
  truncated: boolean;
  mtimeMs: number;
}

export class RemoteFsService {
  private readonly homeDir: string;
  beforeReturnHook: RemoteFsBeforeReturnHook | null;

  constructor(opts: { homeDir?: string; beforeReturnHook?: RemoteFsBeforeReturnHook | null } = {}) {
    this.homeDir = opts.homeDir ?? homedir();
    this.beforeReturnHook = opts.beforeReturnHook ?? null;
  }

  async list(params: Record<string, unknown> = {}): Promise<RemoteFsListResult> {
    const safeParams = params && typeof params === 'object' ? params : {};
    const expanded = validateRemotePathInput(safeParams.path, { allowEmpty: true, homeDir: this.homeDir });
    const includeFiles = Boolean(safeParams.includeFiles);
    const showHidden = Boolean(safeParams.showHidden);
    const query = typeof safeParams.query === 'string' ? safeParams.query.trim().toLowerCase() : '';

    let limit = MAX_LIST_LIMIT;
    if (safeParams.limit !== undefined && safeParams.limit !== null) {
      const parsedLimit = Number(safeParams.limit);
      if (Number.isFinite(parsedLimit)) {
        limit = Math.min(MAX_LIST_LIMIT, Math.max(1, Math.trunc(parsedLimit)));
      }
    }

    let canonicalPath: string;
    try {
      canonicalPath = normalizeAbsolutePathNoTrailingSlash(await realpath(expanded));
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.NOT_FOUND);
    }

    let dirStat;
    try {
      dirStat = await stat(canonicalPath);
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.NOT_FOUND);
    }
    if (!dirStat.isDirectory()) {
      throw new FsRpcError(FS_RPC_ERROR.NOT_DIRECTORY, 'Path is not a directory');
    }

    let dirents;
    try {
      dirents = await readdir(canonicalPath, { withFileTypes: true });
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.PERMISSION_DENIED);
    }

    interface Candidate {
      name: string;
      path: string;
      type: string;
      targetType?: string;
      isDirLike: boolean;
      size?: number;
      mtimeMs?: number;
      needsStat: boolean;
    }

    const candidates: Candidate[] = [];
    const symlinksToStat: Array<{ name: string; path: string }> = [];

    for (const dirent of dirents) {
      const name = dirent.name;
      if (!showHidden && name.startsWith('.')) continue;
      if (query && !name.toLowerCase().includes(query)) continue;

      const fullPath = canonicalPath === '/' ? `/${name}` : join(canonicalPath, name);
      if (dirent.isDirectory()) {
        candidates.push({ name, path: fullPath, type: 'dir', isDirLike: true, needsStat: true });
      } else if (dirent.isFile()) {
        if (!includeFiles) continue;
        candidates.push({ name, path: fullPath, type: 'file', isDirLike: false, needsStat: true });
      } else if (dirent.isSymbolicLink()) {
        symlinksToStat.push({ name, path: fullPath });
      }
    }

    if (symlinksToStat.length > 0) {
      const symlinkResults = await Promise.all(
        symlinksToStat.map(async (item): Promise<Candidate | null> => {
          try {
            const st = await stat(item.path);
            if (st.isDirectory()) {
              return {
                name: item.name,
                path: item.path,
                type: 'symlink',
                targetType: 'dir',
                isDirLike: true,
                mtimeMs: Math.trunc(st.mtimeMs),
                needsStat: false,
              };
            }
            if (st.isFile()) {
              if (!includeFiles) return null;
              return {
                name: item.name,
                path: item.path,
                type: 'symlink',
                targetType: 'file',
                isDirLike: false,
                size: st.size,
                mtimeMs: Math.trunc(st.mtimeMs),
                needsStat: false,
              };
            }
            return null;
          } catch {
            if (!includeFiles) return null;
            return {
              name: item.name,
              path: item.path,
              type: 'symlink',
              targetType: 'broken',
              isDirLike: false,
              needsStat: false,
            };
          }
        })
      );
      for (const res of symlinkResults) {
        if (res) candidates.push(res);
      }
    }

    candidates.sort((a, b) => {
      if (a.isDirLike !== b.isDirLike) return a.isDirLike ? -1 : 1;
      const al = a.name.toLowerCase();
      const bl = b.name.toLowerCase();
      if (al < bl) return -1;
      if (al > bl) return 1;
      if (a.name < b.name) return -1;
      if (a.name > b.name) return 1;
      return 0;
    });

    const totalCount = candidates.length;
    const sliced = candidates.slice(0, limit);
    const truncated = totalCount > sliced.length;

    await Promise.all(
      sliced.map(async (entry) => {
        if (!entry.needsStat) return;
        try {
          const st = await stat(entry.path);
          entry.mtimeMs = Math.trunc(st.mtimeMs);
          if (entry.type === 'file') {
            entry.size = st.size;
          }
        } catch {
          // keep entry
        }
      })
    );

    const entries = sliced.map((entry) => {
      const out: {
        name: string;
        path: string;
        type: string;
        targetType?: string;
        size?: number;
        mtimeMs?: number;
      } = {
        name: entry.name,
        path: entry.path,
        type: entry.type,
      };
      if (entry.targetType !== undefined) out.targetType = entry.targetType;
      if (entry.size !== undefined) out.size = entry.size;
      if (entry.mtimeMs !== undefined) out.mtimeMs = entry.mtimeMs;
      return out;
    });

    const homePath = await resolveHomePathCanonical(this.homeDir);
    const parentPath = canonicalPath === '/' ? null : normalizeAbsolutePathNoTrailingSlash(dirname(canonicalPath));

    if (typeof this.beforeReturnHook === 'function') {
      await this.beforeReturnHook({ op: 'list', path: canonicalPath });
    }

    return {
      path: canonicalPath,
      parentPath,
      homePath,
      totalCount,
      truncated,
      entries,
    };
  }

  async readFile(params: Record<string, unknown> = {}): Promise<RemoteFsReadResult> {
    const safeParams = params && typeof params === 'object' ? params : {};
    const expanded = validateRemotePathInput(safeParams.path, { allowEmpty: false, homeDir: this.homeDir });

    let canonicalPath: string;
    try {
      canonicalPath = normalizeAbsolutePathNoTrailingSlash(await realpath(expanded));
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.NOT_FOUND);
    }

    let preStat;
    try {
      preStat = await stat(canonicalPath);
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.NOT_FOUND);
    }

    if (preStat.isDirectory()) {
      throw new FsRpcError(FS_RPC_ERROR.IS_DIRECTORY, 'Path is a directory');
    }
    if (!preStat.isFile()) {
      throw new FsRpcError(FS_RPC_ERROR.UNSUPPORTED_BINARY, 'Unsupported special file');
    }

    const ext = extname(canonicalPath).toLowerCase();
    const imageMime = IMAGE_MIME_BY_EXT.get(ext) || null;

    if (!imageMime && FAST_REJECT_BINARY_EXTS.has(ext)) {
      throw new FsRpcError(
        FS_RPC_ERROR.UNSUPPORTED_BINARY,
        `Unsupported binary file (${formatReadableSize(preStat.size)})`
      );
    }

    if (imageMime) {
      if (preStat.size > MAX_IMAGE_READ_BYTES) {
        throw new FsRpcError(
          FS_RPC_ERROR.FILE_TOO_LARGE,
          `Image file too large (${formatReadableSize(preStat.size)}, max 10 MB)`
        );
      }

      let fh;
      try {
        fh = await open(canonicalPath, 'r');
      } catch (err) {
        throw mapFsErrno(err, FS_RPC_ERROR.PERMISSION_DENIED);
      }

      try {
        const fhStat = await fh.stat();
        if (!fhStat.isFile()) {
          throw new FsRpcError(FS_RPC_ERROR.UNSUPPORTED_BINARY, 'Unsupported special file');
        }
        if (fhStat.size > MAX_IMAGE_READ_BYTES) {
          throw new FsRpcError(
            FS_RPC_ERROR.FILE_TOO_LARGE,
            `Image file too large (${formatReadableSize(fhStat.size)}, max 10 MB)`
          );
        }
        const rawBuf = await readUpToBytes(fh, fhStat.size);
        if (typeof this.beforeReturnHook === 'function') {
          await this.beforeReturnHook({ op: 'read', path: canonicalPath, kind: 'image' });
        }
        return {
          path: canonicalPath,
          name: basename(canonicalPath),
          kind: 'image',
          mimeType: imageMime,
          content: rawBuf.toString('base64'),
          size: fhStat.size,
          bytesRead: rawBuf.length,
          truncated: false,
          mtimeMs: Math.trunc(fhStat.mtimeMs),
        };
      } finally {
        await fh.close().catch(() => {});
      }
    }

    let fh;
    try {
      fh = await open(canonicalPath, 'r');
    } catch (err) {
      throw mapFsErrno(err, FS_RPC_ERROR.PERMISSION_DENIED);
    }

    try {
      const fhStat = await fh.stat();
      if (!fhStat.isFile()) {
        throw new FsRpcError(FS_RPC_ERROR.UNSUPPORTED_BINARY, 'Unsupported special file');
      }
      const targetBytes = Math.min(fhStat.size, MAX_TEXT_READ_BYTES);
      const rawBuf = await readUpToBytes(fh, targetBytes);

      if (rawBuf.length >= PDF_MAGIC.length && rawBuf.subarray(0, PDF_MAGIC.length).equals(PDF_MAGIC)) {
        throw new FsRpcError(
          FS_RPC_ERROR.UNSUPPORTED_BINARY,
          `Unsupported binary file (${formatReadableSize(fhStat.size)})`
        );
      }
      if (rawBuf.includes(0)) {
        throw new FsRpcError(
          FS_RPC_ERROR.UNSUPPORTED_BINARY,
          `Unsupported binary file (${formatReadableSize(fhStat.size)})`
        );
      }

      const hitCap = fhStat.size > rawBuf.length;
      const finalBuf = hitCap ? trimIncompleteUtf8Tail(rawBuf) : rawBuf;
      const truncated = fhStat.size > finalBuf.length;

      if (typeof this.beforeReturnHook === 'function') {
        await this.beforeReturnHook({ op: 'read', path: canonicalPath, kind: 'text' });
      }

      return {
        path: canonicalPath,
        name: basename(canonicalPath),
        kind: 'text',
        mimeType: resolveTextMimeType(ext),
        content: finalBuf.toString('utf8'),
        size: fhStat.size,
        bytesRead: finalBuf.length,
        truncated,
        mtimeMs: Math.trunc(fhStat.mtimeMs),
      };
    } finally {
      await fh.close().catch(() => {});
    }
  }
}
