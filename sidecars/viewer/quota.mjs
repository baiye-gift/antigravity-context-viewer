/**
 * Language Server RetrieveUserQuotaSummary & GetUserStatus client and 5h/weekly quota parser.
 * Uses only Node.js built-ins (node:http, node:https).
 */
import http from 'node:http';
import https from 'node:https';

const USER_STATUS_RPC_PATH = '/exa.language_server_pb.LanguageServerService/GetUserStatus';
const QUOTA_SUMMARY_RPC_PATH = '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary';

const LOCAL_CACHE_TTL_MS = 10_000;
const CLOUD_REFRESH_INTERVAL_MS = 45_000;
const MIN_FORCE_GAP_MS = 12_000;
const REQUEST_TIMEOUT_MS = 3500;
const SIX_HOURS_MS = 6 * 3600 * 1000;
const GENERIC_TOKENS = new Set(['gemini', 'claude', 'gpt', 'model', 'ai', 'antigravity']);

let loggedFirstFetch = false;
let cacheState = {
  fetchedAt: 0,
  lastCloudRefreshAt: 0,
  lastForceAttemptAt: 0,
  userStatus: null,
  summary: null,
};

function fmtShortTokens(n) {
  const v = Number(n) || 0;
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  return String(v);
}

/**
 * Format remaining reset time matching Antigravity native Usage countdown rounding (Math.floor).
 */
export function formatCountdown(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const totalMins = Math.floor(ms / 60_000);
  const days = Math.floor(totalMins / 1440);
  const hours = Math.floor((totalMins % 1440) / 60);
  const mins = totalMins % 60;
  if (days > 0) return hours > 0 ? `${days}d${hours}h` : `${days}d`;
  if (hours > 0) return mins > 0 ? `${hours}h${mins}m` : `${hours}h`;
  return mins > 0 ? `${mins}m` : '<1m';
}

function parseBucket(b, now = Date.now()) {
  if (!b || typeof b !== 'object') return null;
  const resetTime = b.resetTime || b.resetAt || '';
  const parsedReset = resetTime ? Date.parse(resetTime) : NaN;
  const resetMsRaw = Number.isFinite(parsedReset) ? parsedReset - now : 0;
  const resetMs = Math.max(0, resetMsRaw);

  let frac;
  if (b.disabled === true) {
    frac = 0;
  } else if (b.remainingFraction !== undefined && b.remainingFraction !== null) {
    frac = Number(b.remainingFraction);
  } else if (b.remaining?.case === 'remainingFraction') {
    frac = Number(b.remaining.value);
  } else if (b.remainingAmount !== undefined || b.remaining?.case === 'remainingAmount') {
    return null;
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
    const hint = `${item.bucketId || ''} ${item.window || ''} ${item.name || ''} ${item.displayName || ''} ${item.label || ''}`;
    if (pattern.test(hint)) return item;
  }
  return null;
}

/**
 * Parse RetrieveUserQuotaSummary response groups into normalized { groupName, fiveHour, weekly }.
 */
export function parseSummaryGroups(summaryPayload, now = Date.now()) {
  if (!summaryPayload || typeof summaryPayload !== 'object') return [];
  const root =
    summaryPayload.response && typeof summaryPayload.response === 'object'
      ? summaryPayload.response
      : summaryPayload;

  let rawGroups = [];
  if (Array.isArray(root.groups) && root.groups.length > 0) {
    rawGroups = root.groups;
  } else if (Array.isArray(root.buckets) && root.buckets.length > 0) {
    rawGroups = [{ displayName: root.description || 'Model Quota', buckets: root.buckets }];
  } else {
    return [];
  }

  const parsed = [];
  for (const grp of rawGroups) {
    if (!grp || typeof grp !== 'object') continue;
    const groupName = String(grp.displayName || grp.name || grp.description || 'Model Quota').trim();
    const buckets = Array.isArray(grp.buckets) ? grp.buckets : [];
    if (buckets.length === 0) continue;

    let fiveHour = null;
    let weekly = null;

    for (const b of buckets) {
      if (!b || typeof b !== 'object') continue;
      const w = String(b.window || '').trim().toLowerCase();
      const hint = `${b.window || ''} ${b.displayName || ''} ${b.bucketId || ''}`;
      const bucketParsed = parseBucket(b, now);
      if (!bucketParsed) continue;

      const isWeekly = w === 'weekly' || w === '7d' || w === '168h' || /week|7d|168h/i.test(hint);
      const isShort =
        !isWeekly &&
        (w === '5h' || /^\d+[smh]$/.test(w) || w === 'daily' || /5h|hour|daily|short/i.test(hint));

      if (isWeekly) {
        if (!weekly) weekly = bucketParsed;
      } else if (isShort) {
        if (!fiveHour) fiveHour = bucketParsed;
      } else if (buckets.length === 1) {
        if (bucketParsed.resetMs > SIX_HOURS_MS) {
          weekly = bucketParsed;
        } else {
          fiveHour = bucketParsed;
        }
      } else if (!fiveHour) {
        fiveHour = bucketParsed;
      } else if (!weekly) {
        weekly = bucketParsed;
      }
    }

    if (fiveHour || weekly) {
      parsed.push({ groupName, fiveHour, weekly });
    }
  }
  return parsed;
}

function findGroupForModel(label, modelId, summaryGroups) {
  if (!Array.isArray(summaryGroups) || summaryGroups.length === 0) return null;
  const hay = `${label || ''} ${modelId || ''}`.toLowerCase();

  if (/(gemini|orchestrator|gemma)/i.test(hay)) {
    return summaryGroups.find((g) => /gemini/i.test(g.groupName)) || null;
  }
  if (/(claude|sonnet|opus|haiku)/i.test(hay)) {
    return summaryGroups.find((g) => /(claude|anthropic)/i.test(g.groupName)) || null;
  }
  if (/(gpt|openai)/i.test(hay)) {
    return summaryGroups.find((g) => /(gpt|openai)/i.test(g.groupName)) || null;
  }

  for (const g of summaryGroups) {
    const tokens = tokenizeModel(g.groupName).filter((t) => t !== 'models' && t !== 'model');
    if (tokens.length > 0 && tokens.some((t) => hay.includes(t))) {
      return g;
    }
  }
  return null;
}

function buildModelEntryFromConfig(cfg, us, summaryGroups, weekTokens, now) {
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
  const matchedGroup = findGroupForModel(label, modelId, summaryGroups);

  let fiveHour;
  let weekly;

  if (matchedGroup) {
    fiveHour =
      matchedGroup.fiveHour ||
      (q && q.resetMs <= SIX_HOURS_MS ? q : null) ||
      q || { pct: 100, resetLabel: '' };
    weekly =
      matchedGroup.weekly ||
      w || {
        pct: null,
        status: 'normal',
        resetLabel: weekTokens > 0 ? `7d已用 ${fmtShortTokens(weekTokens)}` : '未触发周限',
      };
  } else if (q && w) {
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
}

/**
 * Parse GetUserStatus and RetrieveUserQuotaSummary payloads into normalized 5h and weekly quota state.
 */
export function parseQuotaPayload(
  payload,
  preferredModels = [],
  weekTokens = 0,
  now = Date.now(),
  summaryPayload = null
) {
  const summaryGroups = parseSummaryGroups(summaryPayload, now);
  const hasUserStatusObj = Boolean(payload && typeof payload === 'object');
  const us = hasUserStatusObj
    ? payload.userStatus && typeof payload.userStatus === 'object'
      ? payload.userStatus
      : payload
    : null;
  const configs = us?.cascadeModelConfigData?.clientModelConfigs || us?.clientModelConfigs || [];
  const hasConfigs = Array.isArray(configs) && configs.length > 0;

  if (!hasConfigs && summaryGroups.length === 0) {
    return { available: false, active: null, models: [], groups: [], credits: null };
  }

  const models = hasConfigs
    ? configs.map((cfg) => buildModelEntryFromConfig(cfg, us, summaryGroups, weekTokens, now))
    : summaryGroups.map((g) => ({
        label: g.groupName,
        modelId: g.groupName,
        fiveHour: g.fiveHour || { pct: 100, resetLabel: '' },
        weekly: g.weekly || { pct: null, status: 'normal', resetLabel: '充足' },
      }));

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
      models.find((m) => /gemini.*(pro|carbon|hydrogen|3|4|models)|claude/i.test(m.label)) ||
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
    groups: summaryGroups,
    credits,
  };
}

function postJson(protocol, host, port, rpcPath, csrf, bodyStr) {
  const client = protocol === 'https' ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request(
      {
        hostname: host,
        port,
        path: rpcPath,
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

async function callLsRpc(rpcPath, bodyObj) {
  const addr = parseAddress(process.env.ANTIGRAVITY_LS_ADDRESS);
  const csrf = process.env.ANTIGRAVITY_CSRF_TOKEN;
  if (!addr || !csrf) return null;

  const bodyStr = JSON.stringify(bodyObj);
  try {
    return await postJson('http', addr.host, addr.port, rpcPath, csrf, bodyStr);
  } catch {
    try {
      return await postJson('https', addr.host, addr.port, rpcPath, csrf, bodyStr);
    } catch {
      return null;
    }
  }
}

/**
 * Call Antigravity Language Server GetUserStatus RPC.
 */
export async function callGetUserStatus() {
  return callLsRpc(USER_STATUS_RPC_PATH, {
    metadata: {
      ideName: 'antigravity',
      extensionName: 'antigravity',
      locale: 'zh',
    },
  });
}

/**
 * Call Antigravity Language Server RetrieveUserQuotaSummary RPC (returns 5h & weekly buckets).
 */
export async function callRetrieveUserQuotaSummary(forceRefresh = false) {
  return callLsRpc(QUOTA_SUMMARY_RPC_PATH, {
    forceRefresh: Boolean(forceRefresh),
  });
}

/**
 * Return cached or fresh quota snapshot matched against conversation models.
 */
export async function getQuotaSnapshot({ preferredModels = [], weekTokens = 0, force = false } = {}) {
  const now = Date.now();
  const hasAnyCache = Boolean(cacheState.userStatus || cacheState.summary);
  const needFetch = force || !hasAnyCache || now - cacheState.fetchedAt >= LOCAL_CACHE_TTL_MS;

  if (needFetch) {
    const forceCloud =
      Boolean(force) ||
      !cacheState.lastCloudRefreshAt ||
      (now - cacheState.lastCloudRefreshAt >= CLOUD_REFRESH_INTERVAL_MS &&
        now - cacheState.lastForceAttemptAt >= MIN_FORCE_GAP_MS);

    if (forceCloud) {
      cacheState.lastForceAttemptAt = now;
    }

    const [freshSummary, freshUserStatus] = await Promise.all([
      callRetrieveUserQuotaSummary(forceCloud),
      callGetUserStatus(),
    ]);

    if (freshSummary) {
      cacheState.summary = freshSummary;
      if (forceCloud) {
        cacheState.lastCloudRefreshAt = now;
      }
    }
    if (freshUserStatus) {
      cacheState.userStatus = freshUserStatus;
    }
    if (freshSummary || freshUserStatus) {
      cacheState.fetchedAt = now;
    }

    if (!loggedFirstFetch && (freshSummary || freshUserStatus)) {
      loggedFirstFetch = true;
      const us = freshUserStatus?.userStatus || freshUserStatus;
      const configs = us?.cascadeModelConfigData?.clientModelConfigs || us?.clientModelConfigs || [];
      const sumGroups = parseSummaryGroups(freshSummary, now);
      console.log(
        '[quota] fetched configs:',
        Array.isArray(configs) ? configs.length : 0,
        'summaryGroups:',
        sumGroups.map((g) => g.groupName)
      );
    }
  }

  if (!cacheState.userStatus && !cacheState.summary) {
    return {
      available: false,
      active: null,
      models: [],
      groups: [],
      credits: null,
      updatedAt: now,
    };
  }

  const parsed = parseQuotaPayload(
    cacheState.userStatus,
    preferredModels,
    weekTokens,
    now,
    cacheState.summary
  );
  return {
    ...parsed,
    updatedAt: cacheState.fetchedAt || now,
  };
}
