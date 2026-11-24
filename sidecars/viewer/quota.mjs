/**
 * Language Server GetUserStatus client & 5h/weekly quota parser.
 * Uses only Node.js built-ins (node:http, node:https).
 */
import http from 'node:http';
import https from 'node:https';

const RPC_PATH = '/exa.language_server_pb.LanguageServerService/GetUserStatus';
const CACHE_TTL_MS = 15_000;
const REQUEST_TIMEOUT_MS = 3500;
const SIX_HOURS_MS = 6 * 3600 * 1000;
const GENERIC_TOKENS = new Set(['gemini', 'claude', 'gpt', 'model', 'ai', 'antigravity']);

let loggedFirstFetch = false;
let cacheState = {
  fetchedAt: 0,
  payload: null,
};

function fmtShortTokens(n) {
  const v = Number(n) || 0;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  return String(v);
}

function formatCountdown(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  if (ms >= 86_400_000) {
    const days = Math.floor(ms / 86_400_000);
    const hours = Math.floor((ms % 86_400_000) / 3_600_000);
    return `${days}d${hours}h`;
  }
  if (ms >= 3_600_000) {
    const hours = Math.floor(ms / 3_600_000);
    const mins = Math.floor((ms % 3_600_000) / 60_000);
    return `${hours}h${mins}m`;
  }
  const mins = Math.max(1, Math.ceil(ms / 60_000));
  return `${mins}m`;
}

function parseBucket(b, now = Date.now()) {
  if (!b || typeof b !== 'object') return null;
  const resetTime = b.resetTime || b.resetAt || '';
  const parsedReset = resetTime ? Date.parse(resetTime) : NaN;
  const resetMsRaw = Number.isFinite(parsedReset) ? parsedReset - now : 0;
  const resetMs = Math.max(0, resetMsRaw);

  let frac;
  if (b.remainingFraction !== undefined && b.remainingFraction !== null) {
    frac = Number(b.remainingFraction);
  } else if (resetMs > 0) {
    // Proto3 omits default 0.0 float values when a quota bucket is exhausted.
    frac = 0;
  } else {
    frac = 1;
  }
  if (!Number.isFinite(frac)) frac = 1;
  frac = Math.min(1, Math.max(0, frac));

  return {
    pct: Math.round(frac * 100),
    remainingFraction: frac,
    resetTime,
    resetMs,
    resetLabel: formatCountdown(resetMs),
  };
}

function tokenizeModel(str) {
  return String(str || '')
    .toLowerCase()
    .split(/[^a-z0-9.]+/)
    .filter(Boolean);
}

function scoreCandidate(cfg, modelTokensList) {
  const rawLabel = `${cfg.label} ${cfg.modelId}`;
  const cfgTokens = new Set(tokenizeModel(rawLabel));
  const isInternal = /\b(internal|executor|subagent|background|flash_lite)\b/i.test(rawLabel);

  let bestScore = -1;
  for (let i = 0; i < modelTokensList.length; i++) {
    const mTokens = modelTokensList[i];
    let sharedTotal = 0;
    let sharedNonGeneric = 0;
    for (const tok of mTokens) {
      if (cfgTokens.has(tok)) {
        sharedTotal += 1;
        if (!GENERIC_TOKENS.has(tok)) {
          sharedNonGeneric += 1;
        }
      }
    }
    if (sharedNonGeneric === 0 && sharedTotal === 0) continue;
    const recencyBonus = Math.max(0, 10 - i) * 0.25;
    let score = sharedNonGeneric * 10 + sharedTotal * 2 + recencyBonus;
    if (sharedNonGeneric >= 2 && !isInternal) score += 15;
    if (isInternal) score -= 8;
    if (score > bestScore) bestScore = score;
  }
  return bestScore;
}

function pickFromBuckets(buckets, pattern) {
  if (!Array.isArray(buckets)) return null;
  for (const item of buckets) {
    if (!item || typeof item !== 'object') continue;
    const hint = `${item.bucketId || ''} ${item.window || ''} ${item.name || ''} ${item.label || ''}`;
    if (pattern.test(hint)) return item;
  }
  return null;
}

/**
 * Parse GetUserStatus response payload into normalized 5h and weekly quota state.
 */
export function parseQuotaPayload(payload, preferredModels = [], weekTokens = 0, now = Date.now()) {
  if (!payload || typeof payload !== 'object') {
    return { available: false, active: null, models: [], credits: null };
  }

  const us = payload.userStatus && typeof payload.userStatus === 'object' ? payload.userStatus : payload;
  const configs =
    us?.cascadeModelConfigData?.clientModelConfigs ||
    us?.clientModelConfigs ||
    [];

  if (!Array.isArray(configs) || configs.length === 0) {
    return { available: false, active: null, models: [], credits: null };
  }

  const models = configs.map((cfg) => {
    const modelId = cfg?.modelOrAlias?.model || cfg?.model || '';
    const label = cfg?.label || cfg?.displayName || modelId || 'Model';
    const buckets = cfg?.quotaBuckets || cfg?.buckets || us?.quotaBuckets || [];

    const primaryRaw = cfg?.quotaInfo || pickFromBuckets(buckets, /5h|hour|short/i) || null;
    const weeklyRaw =
      cfg?.weeklyQuotaInfo ||
      cfg?.secondaryQuotaInfo ||
      cfg?.longTermQuotaInfo ||
      pickFromBuckets(buckets, /week|7d|168h/i) ||
      null;

    const q = parseBucket(primaryRaw, now);
    const w = parseBucket(weeklyRaw, now);

    let fiveHour;
    let weekly;

    if (q && w) {
      fiveHour = q;
      weekly = w;
    } else if (q && q.resetMs > SIX_HOURS_MS) {
      weekly = { ...q, binding: true };
      fiveHour = { pct: q.pct, resetLabel: '受周限约束', bindingWeekly: true };
    } else if (q) {
      fiveHour = q;
      weekly = {
        pct: null,
        status: 'normal',
        resetLabel: weekTokens > 0 ? `7d已用 ${fmtShortTokens(weekTokens)}` : '未触发周限',
      };
    } else {
      fiveHour = { pct: 100, resetLabel: '' };
      weekly = { pct: null, status: 'normal', resetLabel: '充足' };
    }

    return {
      label,
      modelId,
      fiveHour,
      weekly,
    };
  });

  const modelTokensList = (Array.isArray(preferredModels) ? preferredModels : [])
    .filter((m) => typeof m === 'string' && m && m !== 'unknown')
    .map((m) => tokenizeModel(m));

  let active = null;
  let topScore = -Infinity;
  for (const m of models) {
    const s = scoreCandidate(m, modelTokensList);
    if (s > topScore && s > 0) {
      topScore = s;
      active = m;
    }
  }

  if (!active) {
    active =
      models.find((m) => /gemini.*(pro|carbon|hydrogen|3|4)|claude/i.test(m.label)) ||
      models[0];
  }

  const credits =
    us?.aiCredits ||
    us?.credits ||
    (us?.availableAiCredits !== undefined ? { available: us.availableAiCredits } : null);

  return {
    available: true,
    active,
    models,
    credits,
  };
}

function postJson(protocol, host, port, csrf, bodyStr) {
  const client = protocol === 'https' ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request(
      {
        hostname: host,
        port,
        path: RPC_PATH,
        method: 'POST',
        timeout: REQUEST_TIMEOUT_MS,
        rejectUnauthorized: false,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(bodyStr, 'utf8'),
          'Connect-Protocol-Version': '1',
          'x-codeium-csrf-token': csrf,
        },
      },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          raw += chunk;
        });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`HTTP ${res.statusCode}`));
          }
          try {
            resolve(JSON.parse(raw));
          } catch (err) {
            reject(err);
          }
        });
      }
    );
    req.on('timeout', () => {
      req.destroy(new Error('timeout'));
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function parseAddress(rawAddr) {
  const cleaned = String(rawAddr || '')
    .trim()
    .replace(/^https?:\/\//i, '');
  const idx = cleaned.lastIndexOf(':');
  if (idx <= 0) return null;
  const host = cleaned.slice(0, idx);
  const port = Number(cleaned.slice(idx + 1));
  if (!host || !Number.isFinite(port) || port <= 0) return null;
  return { host, port };
}

/**
 * Call Antigravity Language Server GetUserStatus RPC.
 */
export async function callGetUserStatus() {
  const addr = parseAddress(process.env.ANTIGRAVITY_LS_ADDRESS);
  const csrf = process.env.ANTIGRAVITY_CSRF_TOKEN;
  if (!addr || !csrf) return null;

  const bodyStr = JSON.stringify({
    metadata: {
      ideName: 'antigravity',
      extensionName: 'antigravity',
      locale: 'zh',
    },
  });

  let payload = null;
  try {
    payload = await postJson('http', addr.host, addr.port, csrf, bodyStr);
  } catch {
    try {
      payload = await postJson('https', addr.host, addr.port, csrf, bodyStr);
    } catch {
      return null;
    }
  }

  if (!loggedFirstFetch && payload) {
    loggedFirstFetch = true;
    const us = payload.userStatus || payload;
    const configs = us?.cascadeModelConfigData?.clientModelConfigs || us?.clientModelConfigs || [];
    console.log('[quota] fetched clientModelConfigs count:', Array.isArray(configs) ? configs.length : 0);
  }
  return payload;
}

/**
 * Return cached or fresh quota snapshot matched against conversation models.
 */
export async function getQuotaSnapshot({ preferredModels = [], weekTokens = 0, force = false } = {}) {
  const now = Date.now();
  if (force || !cacheState.payload || now - cacheState.fetchedAt >= CACHE_TTL_MS) {
    const fresh = await callGetUserStatus();
    if (fresh) {
      cacheState = { fetchedAt: now, payload: fresh };
    }
  }

  if (!cacheState.payload) {
    return {
      available: false,
      active: null,
      models: [],
      credits: null,
      updatedAt: now,
    };
  }

  const parsed = parseQuotaPayload(cacheState.payload, preferredModels, weekTokens, now);
  return {
    ...parsed,
    updatedAt: cacheState.fetchedAt || now,
  };
}
