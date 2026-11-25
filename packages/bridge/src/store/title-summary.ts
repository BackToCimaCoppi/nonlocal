import type { TitleLanguage, TitleSummaryConfig } from '../config/types.js';
import type { SanitizedLogger } from '../log/logger.js';

const MAX_PROMPT_SUMMARY_BYTES = 2048;

export function getSummarySystemPrompt(language: TitleLanguage): string {
  if (language === 'zh') {
    return '你是一个编程助手会话标题生成器。请根据用户的第一条提问提炼核心意图，生成一个简短的简体中文标题。严格要求：1) 必须使用简体中文；2) 控制在 20 个字符以内；3) 只输出标题正文，不要引号、句号、冒号或解释。';
  }
  if (language === 'en') {
    return 'You are a coding assistant session title generator. Summarize the user first prompt into a short English title. Strict rules: 1) Always write in concise English; 2) Keep it at or under 20 characters; 3) Output only the title text without quotes, punctuation, or explanation.';
  }
  return 'You are a coding assistant session title generator. Summarize the user first prompt into a short title matching the primary language of the user prompt (e.g. Simplified Chinese if prompt is Chinese, English if English). Keep it <= 20 characters and output only the plain title text without quotes or explanation.';
}

export function normalizeEndpointUrl(rawUrl: string): string {
  const trimmed = String(rawUrl || '').trim();
  if (!trimmed) return '';
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error(`Invalid titleSummary endpoint "${trimmed}"`);
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error(`Invalid titleSummary endpoint protocol "${parsed.protocol}": only http/https allowed`);
  }
  if (!parsed.pathname.endsWith('/chat/completions')) {
    parsed.pathname = parsed.pathname.replace(/\/+$/, '') + '/chat/completions';
  }
  return parsed.toString();
}

export function truncatePromptForSummary(promptText: string, maxBytes: number = MAX_PROMPT_SUMMARY_BYTES): string {
  if (typeof promptText !== 'string') return '';
  const normalized = promptText.replace(/\s+/g, ' ').trim();
  if (!normalized) return '';
  if (Buffer.byteLength(normalized, 'utf8') <= maxBytes) return normalized;
  const chars = Array.from(normalized);
  let totalBytes = 0;
  const kept: string[] = [];
  for (const ch of chars) {
    const chBytes = Buffer.byteLength(ch, 'utf8');
    if (totalBytes + chBytes > maxBytes) break;
    kept.push(ch);
    totalBytes += chBytes;
  }
  return kept.join('').trim();
}

export function sanitizeAiTitle(rawOutput: unknown): string | null {
  if (typeof rawOutput !== 'string') return null;
  let cleaned = rawOutput
    .replace(/<think>[\s\S]*?<\/think>/gi, ' ')
    .replace(/<think>[\s\S]*$/gi, ' ')
    .trim();
  if (!cleaned) return null;

  const lines = cleaned
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  if (lines.length === 0) return null;
  cleaned = lines[0];

  cleaned = cleaned.replace(/^(?:标题|title)\s*[：:]\s*/i, '').trim();
  const wrapperPairs: Array<[string, string]> = [
    ['"', '"'],
    ["'", "'"],
    ['`', '`'],
    ['“', '”'],
    ['‘', '’'],
    ['「', '」'],
    ['『', '』'],
    ['《', '》'],
    ['【', '】'],
  ];
  let changed = true;
  while (changed && cleaned.length >= 2) {
    changed = false;
    for (const [open, close] of wrapperPairs) {
      if (cleaned.startsWith(open) && cleaned.endsWith(close)) {
        cleaned = cleaned.slice(open.length, cleaned.length - close.length).trim();
        changed = true;
      }
    }
  }
  cleaned = cleaned
    .replace(/^["'`“‘「『《【\s]+/, '')
    .replace(/["'`”’」』》】\s。\.：:！!？?]+$/, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!cleaned) return null;

  const clamped = Array.from(cleaned).slice(0, 20).join('').trim();
  return clamped || null;
}

export class TitleSummaryService {
  readonly enabled: boolean;
  private readonly endpointUrl: string;
  private readonly model: string;
  private readonly apiKey: string;
  private readonly language: TitleLanguage;
  private readonly timeoutMs: number;
  private readonly logger?: SanitizedLogger;

  constructor(config: TitleSummaryConfig, logger?: SanitizedLogger) {
    this.enabled = Boolean(config.enabled && config.endpoint && config.model);
    this.endpointUrl = this.enabled ? normalizeEndpointUrl(config.endpoint) : '';
    this.model = config.model;
    this.apiKey = config.apiKey || '';
    this.language = config.language || 'auto';
    this.timeoutMs = Math.max(50, config.timeoutMs || 8000);
    this.logger = logger;
  }

  async summarizeTitle(params: {
    sessionId: string;
    promptText: string;
  }): Promise<{ ok: boolean; status: string; title: string | null }> {
    const { sessionId, promptText } = params;
    if (!this.enabled || !this.endpointUrl || !this.model) {
      return { ok: false, status: 'skipped_disabled', title: null };
    }
    const truncated = truncatePromptForSummary(promptText, MAX_PROMPT_SUMMARY_BYTES);
    if (!truncated) {
      return { ok: false, status: 'skipped_empty', title: null };
    }

    const startedAt = Date.now();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) {
      headers.Authorization = `Bearer ${this.apiKey}`;
    }

    try {
      const response = await fetch(this.endpointUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model: this.model,
          messages: [
            { role: 'system', content: getSummarySystemPrompt(this.language) },
            { role: 'user', content: truncated },
          ],
          temperature: 0.2,
          max_tokens: 64,
        }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });

      const durationMs = Date.now() - startedAt;
      if (!response.ok) {
        this.logger?.log('warn', 'title_summary_failed', {
          sessionId,
          model: this.model,
          code: response.status,
          durationMs,
          reason: 'http_status',
        });
        return { ok: false, status: `http_${response.status}`, title: null };
      }

      const payload = (await response.json()) as {
        choices?: Array<{ message?: { content?: unknown } }>;
      };
      const rawContent = payload?.choices?.[0]?.message?.content;
      const cleanTitle = sanitizeAiTitle(rawContent);
      if (!cleanTitle) {
        this.logger?.log('warn', 'title_summary_failed', {
          sessionId,
          model: this.model,
          durationMs,
          reason: 'empty_output',
        });
        return { ok: false, status: 'empty_output', title: null };
      }

      this.logger?.log('info', 'title_summary_completed', {
        sessionId,
        model: this.model,
        durationMs,
        count: Array.from(cleanTitle).length,
      });
      return { ok: true, status: 'succeeded', title: cleanTitle };
    } catch (err) {
      const durationMs = Date.now() - startedAt;
      const errName = err instanceof Error ? err.name : '';
      this.logger?.log('warn', 'title_summary_failed', {
        sessionId,
        model: this.model,
        durationMs,
        reason: errName === 'TimeoutError' || errName === 'AbortError' ? 'timeout' : 'fetch_error',
      });
      return { ok: false, status: 'fetch_error', title: null };
    }
  }
}
