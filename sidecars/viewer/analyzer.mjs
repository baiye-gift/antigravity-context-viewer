/**
 * Read-only Antigravity conversation transcript analyzer.
 * Parses <appData>/brain/<convId>/.system_generated/logs/transcript.jsonl
 * using only Node.js built-ins (node:fs, node:os, node:path).
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';

const ID_RE = /^[0-9a-f-]{8,}$/i;

// Cache keyed by transcript file path; invalidated whenever mtime/size changes.
const transcriptCache = new Map();

function safeReaddir(dir) {
  try {
    return readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

function safeStat(filePath) {
  try {
    const s = statSync(filePath);
    return { exists: true, mtimeMs: Math.round(s.mtimeMs), size: s.size };
  } catch {
    return { exists: false, mtimeMs: 0, size: 0 };
  }
}

function byteLen(val) {
  if (val == null) return 0;
  const s = typeof val === 'string' ? val : String(val);
  return s ? Buffer.byteLength(s, 'utf8') : 0;
}

function extractTitle(content) {
  const raw = String(content ?? '');
  const reqMatch = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(raw);
  const cleaned = (
    reqMatch
      ? reqMatch[1]
      : raw.replace(/<([A-Z_]+)>[\s\S]*?<\/\1>/g, ' ').replace(/<[^>]+>/g, ' ')
  )
    .replace(/\s+/g, ' ')
    .trim();
  if (!cleaned) return '未命名会话';
  return cleaned.slice(0, 64);
}

/**
 * Locate Antigravity app data directories containing a brain/ folder.
 */
export function findAppDataDirs() {
  const seen = new Set();
  const dirs = [];

  const addIfBrain = (candidate) => {
    if (!candidate) return;
    const normalized = resolve(candidate);
    const key = process.platform === 'win32' ? normalized.toLowerCase() : normalized;
    if (seen.has(key)) return;
    if (existsSync(join(normalized, 'brain'))) {
      seen.add(key);
      dirs.push(normalized);
    }
  };

  const execDataDir = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
  if (execDataDir) {
    for (let d = execDataDir; d !== dirname(d); d = dirname(d)) {
      if (basename(d) === 'sidecar_data') {
        addIfBrain(dirname(d));
        break;
      }
    }
  }

  if (process.env.ANTIGRAVITY_APP_DATA_DIR) {
    addIfBrain(process.env.ANTIGRAVITY_APP_DATA_DIR);
  }

  if (dirs.length > 0) return dirs;

  const geminiRoot = join(homedir(), '.gemini');
  for (const entry of safeReaddir(geminiRoot)) {
    if (entry.isDirectory()) {
      addIfBrain(join(geminiRoot, entry.name));
    }
  }
  return dirs;
}

/**
 * Analyze a single conversation's transcript.jsonl (read-only, cached by mtime/size).
 */
export function analyzeConversation(appDataDir, convId) {
  const logsDir = join(appDataDir, 'brain', convId, '.system_generated', 'logs');
  const transcriptPath = join(logsDir, 'transcript.jsonl');
  const tStat = safeStat(transcriptPath);
  if (!tStat.exists) return null;

  const fullPath = join(logsDir, 'transcript_full.jsonl');
  const fStat = safeStat(fullPath);

  const cacheKey = `${tStat.mtimeMs}:${tStat.size}|${fStat.mtimeMs}:${fStat.size}`;
  const cached = transcriptCache.get(transcriptPath);
  if (cached && cached.cacheKey === cacheKey) {
    return cached.detail;
  }

  let text = '';
  try {
    text = readFileSync(transcriptPath, 'utf8');
  } catch {
    return null;
  }

  const lines = text.split(/\r?\n/);
  let title = '';
  let totalSteps = 0;
  let userTurns = 0;
  let toolSteps = 0;

  let userBytes = 0;
  let thinkingBytes = 0;
  let assistantBytes = 0;
  let toolOutputBytes = 0;

  let totalInputTokens = 0;
  let totalCacheReadTokens = 0;
  let totalOutputTokens = 0;
  let basePromptTokens = 0;
  let peakContextTokens = 0;
  let activeModel = '';
  let activeContextTokens = 0;
  let latestInputTokens = 0;
  let latestCacheReadTokens = 0;
  let prevContext = null;
  let lastStepTs = 0;

  const steps = [];
  const toolCounts = new Map();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    let step;
    try {
      step = JSON.parse(line);
    } catch {
      continue;
    }
    if (!step || typeof step !== 'object') continue;

    totalSteps += 1;
    const stepTs = step.created_at ? Date.parse(step.created_at) : 0;
    if (Number.isFinite(stepTs) && stepTs > lastStepTs) {
      lastStepTs = stepTs;
    }

    if (step.type === 'USER_INPUT') {
      userTurns += 1;
      userBytes += byteLen(step.content);
      if (!title) {
        title = extractTitle(step.content);
      }
      continue;
    }

    if (step.type === 'GENERIC') {
      toolSteps += 1;
      toolOutputBytes += byteLen(step.content);
      continue;
    }

    if (step.type === 'PLANNER_RESPONSE') {
      thinkingBytes += byteLen(step.thinking);
      assistantBytes += byteLen(step.content);

      const rawTools = Array.isArray(step.tool_calls) ? step.tool_calls : [];
      if (rawTools.length > 0) {
        try {
          assistantBytes += byteLen(JSON.stringify(rawTools));
        } catch {
          // Ignore unserializable tool payload
        }
      }

      const tools = [];
      for (const tc of rawTools) {
        const name = tc?.name;
        if (typeof name === 'string' && name) {
          tools.push(name);
          toolCounts.set(name, (toolCounts.get(name) || 0) + 1);
        }
      }

      const hasTokenFields = step.input_tokens != null || step.cache_read_tokens != null || step.output_tokens != null;
      const inputTokens = Number(step.input_tokens) || 0;
      const cacheReadTokens = Number(step.cache_read_tokens) || 0;
      const contextTokens = inputTokens + cacheReadTokens;
      const outputTokens = Number(step.output_tokens) || 0;
      const model = typeof step.model === 'string' && step.model ? step.model : 'unknown';

      if (model !== 'unknown') {
        activeModel = model;
      }

      if (hasTokenFields) {
        totalInputTokens += inputTokens;
        totalCacheReadTokens += cacheReadTokens;
        totalOutputTokens += outputTokens;

        if (basePromptTokens === 0 && contextTokens > 0) {
          basePromptTokens = contextTokens;
        }
        if (contextTokens > peakContextTokens) {
          peakContextTokens = contextTokens;
        }

        const deltaContextTokens = prevContext !== null ? contextTokens - prevContext : contextTokens;
        if (contextTokens > 0 || prevContext === null) {
          activeContextTokens = contextTokens;
          latestInputTokens = inputTokens;
          latestCacheReadTokens = cacheReadTokens;
          prevContext = contextTokens;
        }

        const stepCacheHitRate = contextTokens > 0
          ? Math.round((cacheReadTokens / contextTokens) * 1000) / 10
          : 0;

        steps.push({
          stepIndex: Number.isFinite(Number(step.step_index)) ? Number(step.step_index) : i,
          createdAt: step.created_at || '',
          ts: Number.isFinite(stepTs) ? stepTs : 0,
          model,
          inputTokens,
          cacheReadTokens,
          contextTokens,
          outputTokens,
          deltaContextTokens,
          cacheHitRate: stepCacheHitRate,
          tools,
        });
      }
    }
  }

  const cacheHitRate = activeContextTokens > 0
    ? Math.round((latestCacheReadTokens / activeContextTokens) * 1000) / 10
    : 0;

  const topTools = [...toolCounts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));

  const updatedAt = tStat.mtimeMs || lastStepTs || 0;

  const detail = {
    conversationId: convId,
    title: title || `会话 ${convId.slice(0, 8)}`,
    activeModel: activeModel || 'unknown',
    activeContextTokens,
    latestInputTokens,
    latestCacheReadTokens,
    cacheHitRate,
    basePromptTokens,
    peakContextTokens,
    totalInputTokens,
    totalCacheReadTokens,
    totalOutputTokens,
    llmCallCount: steps.length,
    totalSteps,
    userTurns,
    toolSteps,
    transcriptBytes: tStat.size,
    fullTranscriptBytes: fStat.size,
    updatedAt,
    steps,
    topTools,
    composition: {
      userBytes,
      thinkingBytes,
      assistantBytes,
      toolOutputBytes,
      basePromptTokens,
    },
  };

  transcriptCache.set(transcriptPath, { cacheKey, detail });
  return detail;
}

function hashStrings(parts) {
  let h1 = 0x811c9dc5;
  let h2 = 0x9e3779b9;
  for (const part of parts) {
    for (let i = 0; i < part.length; i++) {
      const c = part.charCodeAt(i);
      h1 ^= c;
      h1 = Math.imul(h1, 0x01000193);
      h2 ^= c + i;
      h2 = Math.imul(h2, 0x85ebca6b);
    }
  }
  return `${(h1 >>> 0).toString(16)}${(h2 >>> 0).toString(16)}`;
}

function emptyBucket() {
  return {
    sessions: 0,
    llmCalls: 0,
    inputTokens: 0,
    cacheReadTokens: 0,
    outputTokens: 0,
  };
}

/**
 * Build a complete snapshot for the requested conversation plus global statistics.
 */
export function buildSnapshot(requestedConvId = '', clientEtag = '') {
  const appDataDirs = findAppDataDirs();
  const conversationsMap = new Map();

  for (const appDataDir of appDataDirs) {
    const brainDir = join(appDataDir, 'brain');
    for (const entry of safeReaddir(brainDir)) {
      if (!entry.isDirectory() || !ID_RE.test(entry.name)) continue;
      const detail = analyzeConversation(appDataDir, entry.name);
      if (!detail) continue;
      const prev = conversationsMap.get(entry.name);
      if (!prev || detail.updatedAt > prev.updatedAt) {
        conversationsMap.set(entry.name, detail);
      }
    }
  }

  const conversations = [...conversationsMap.values()]
    .sort((a, b) => b.updatedAt - a.updatedAt || a.conversationId.localeCompare(b.conversationId));

  const requested = typeof requestedConvId === 'string' && requestedConvId ? requestedConvId : null;
  let current = requested ? conversationsMap.get(requested) || null : null;
  if (!current && conversations.length > 0) {
    current = conversations[0];
  }
  const resolvedConversationId = current ? current.conversationId : null;

  const globalHash = hashStrings(
    conversations.map(
      (c) => `${c.conversationId}:${c.updatedAt}:${c.transcriptBytes}:${c.fullTranscriptBytes}:${c.llmCallCount}`
    )
  );
  const etag = `${resolvedConversationId || ''}|${globalHash}`;

  if (clientEtag && clientEtag === etag) {
    return {
      unchanged: true,
      etag,
      requestedConversationId: requested,
      resolvedConversationId,
    };
  }

  const now = Date.now();
  const todayDate = new Date(now);
  todayDate.setHours(0, 0, 0, 0);
  const todayStart = todayDate.getTime();
  const last7dStart = now - 7 * 86400 * 1000;

  const today = emptyBucket();
  const last7d = emptyBucket();
  const allTime = emptyBucket();
  const modelMap = new Map();

  for (const conv of conversations) {
    allTime.sessions += 1;
    allTime.llmCalls += conv.llmCallCount;
    allTime.inputTokens += conv.totalInputTokens;
    allTime.cacheReadTokens += conv.totalCacheReadTokens;
    allTime.outputTokens += conv.totalOutputTokens;

    let hasTodayStep = false;
    let has7dStep = false;

    for (const s of conv.steps) {
      const ts = s.ts || conv.updatedAt;
      if (ts >= todayStart) {
        hasTodayStep = true;
        today.llmCalls += 1;
        today.inputTokens += s.inputTokens;
        today.cacheReadTokens += s.cacheReadTokens;
        today.outputTokens += s.outputTokens;
      }
      if (ts >= last7dStart) {
        has7dStep = true;
        last7d.llmCalls += 1;
        last7d.inputTokens += s.inputTokens;
        last7d.cacheReadTokens += s.cacheReadTokens;
        last7d.outputTokens += s.outputTokens;
      }

      const mKey = s.model || 'unknown';
      let mEntry = modelMap.get(mKey);
      if (!mEntry) {
        mEntry = {
          model: mKey,
          calls: 0,
          inputTokens: 0,
          cacheReadTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
        };
        modelMap.set(mKey, mEntry);
      }
      mEntry.calls += 1;
      mEntry.inputTokens += s.inputTokens;
      mEntry.cacheReadTokens += s.cacheReadTokens;
      mEntry.outputTokens += s.outputTokens;
      mEntry.totalTokens += s.inputTokens + s.cacheReadTokens + s.outputTokens;
    }

    if (hasTodayStep || conv.updatedAt >= todayStart) {
      today.sessions += 1;
    }
    if (has7dStep || conv.updatedAt >= last7dStart) {
      last7d.sessions += 1;
    }
  }

  const byModel = [...modelMap.values()]
    .sort((a, b) => b.totalTokens - a.totalTokens || a.model.localeCompare(b.model));

  const recentSessions = conversations.slice(0, 30).map((c) => ({
    conversationId: c.conversationId,
    title: c.title,
    activeModel: c.activeModel,
    activeContextTokens: c.activeContextTokens,
    totalInputTokens: c.totalInputTokens,
    totalCacheReadTokens: c.totalCacheReadTokens,
    totalOutputTokens: c.totalOutputTokens,
    llmCallCount: c.llmCallCount,
    cacheHitRate: c.cacheHitRate,
    updatedAt: c.updatedAt,
    transcriptBytes: c.transcriptBytes,
  }));

  return {
    unchanged: false,
    etag,
    generatedAt: now,
    requestedConversationId: requested,
    resolvedConversationId,
    current,
    global: {
      today,
      last7d,
      allTime,
      byModel,
      recentSessions,
    },
  };
}
