/**
 * Native Context Viewer sidecar server.
 * Serves the web UI, exposes /api/context and /api/hud (transcript + 5h/weekly quota),
 * and automatically supervises the docked desktop HUD overlay (hud-overlay.ps1).
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp, Response } from 'sidecar_sdk';
import { buildSnapshot } from './analyzer.mjs';
import { getQuotaSnapshot } from './quota.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = new SidecarApp();

const psExe = join(
  process.env.SystemRoot || 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe'
);
const hudScriptPath = join(__dirname, '..', '..', 'hud-overlay.ps1');

let hudPort = 0;
let hudChild = null;
let hudStartedAt = 0;
let userHidden = false;
let respawnCount = 0;
let respawnTimer = null;
let shuttingDown = false;

function preferredModelsFromSteps(steps) {
  if (!Array.isArray(steps) || steps.length === 0) return [];
  const seen = new Set();
  const list = [];
  for (let i = steps.length - 1; i >= 0; i--) {
    const m = steps[i]?.model;
    if (typeof m === 'string' && m && m !== 'unknown' && !seen.has(m)) {
      seen.add(m);
      list.push(m);
    }
  }
  return list;
}

function weekTokensFromSnapshot(snap) {
  const w = snap?.global?.last7d;
  if (!w) return 0;
  return (w.inputTokens || 0) + (w.cacheReadTokens || 0) + (w.outputTokens || 0);
}

function spawnHud(forceShow = false) {
  if (shuttingDown || !hudPort || !existsSync(hudScriptPath)) {
    return { launched: false, reason: 'unavailable' };
  }
  if (userHidden && !forceShow) {
    return { launched: false, reason: 'hidden_by_user' };
  }
  if (forceShow) {
    userHidden = false;
    respawnCount = 0;
  }
  if (respawnTimer) {
    clearTimeout(respawnTimer);
    respawnTimer = null;
  }
  if (hudChild && hudChild.exitCode === null && !forceShow) {
    return { launched: true, alreadyRunning: true };
  }

  const apiUrl = `http://127.0.0.1:${hudPort}/api/hud`;
  let child;
  try {
    child = spawn(
      psExe,
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Sta',
        '-File',
        hudScriptPath,
        '-ApiUrl',
        apiUrl,
        '-ParentPid',
        String(process.pid),
      ],
      {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      }
    );
  } catch (err) {
    console.error('[hud] failed to spawn:', err?.message || err);
    return { launched: false, error: err?.message || String(err) };
  }

  hudChild = child;
  hudStartedAt = Date.now();

  if (child.stdout) {
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      const msg = String(chunk).trim();
      if (msg) console.log('[hud]', msg);
    });
  }
  if (child.stderr) {
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      const msg = String(chunk).trim();
      if (msg) console.error('[hud]', msg);
    });
  }

  child.on('exit', (code) => {
    if (hudChild === child) {
      hudChild = null;
    }
    if (shuttingDown) return;
    if (code === 42) {
      userHidden = true;
      console.log('[hud] hidden by user (exit 42)');
      return;
    }
    if (code === 0 && Date.now() - hudStartedAt > 10_000) {
      respawnCount = 0;
      console.log('[hud] exited 0 after clean run, respawning in 1s');
      respawnTimer = setTimeout(() => spawnHud(false), 1000);
      return;
    }
    console.error('[hud] exited with code:', code);
    if (respawnCount < 3) {
      respawnCount += 1;
      respawnTimer = setTimeout(() => spawnHud(false), 5000);
    }
  });

  return { launched: true };
}

function cleanupHud() {
  shuttingDown = true;
  if (respawnTimer) {
    clearTimeout(respawnTimer);
    respawnTimer = null;
  }
  if (hudChild && hudChild.exitCode === null) {
    try {
      hudChild.kill();
    } catch {
      // Ignore cleanup errors
    }
  }
}

process.on('SIGINT', () => {
  cleanupHud();
  process.exit(0);
});
process.on('SIGTERM', () => {
  cleanupHud();
  process.exit(0);
});
process.on('exit', cleanupHud);

app.page('/', () => new Response(readFileSync(join(__dirname, 'index.html'), 'utf8'), {
  contentType: 'text/html; charset=utf-8',
  headers: { 'Cache-Control': 'no-store' },
}));

app.api(
  '/api/context',
  async (data) => {
    const conv = data?.conversationId || app.config.conversationId || '';
    const forceQuota = data?.refresh === '1';
    const etag = forceQuota ? '' : (typeof data?.etag === 'string' ? data.etag : '');
    const snap = buildSnapshot(conv, etag);
    if (snap.unchanged) {
      return snap;
    }
    const weekTokens = weekTokensFromSnapshot(snap);
    const quota = await getQuotaSnapshot({
      preferredModels: preferredModelsFromSteps(snap.current?.steps),
      weekTokens,
      force: forceQuota,
    });
    return {
      ...snap,
      quota,
    };
  },
  'GET'
);

app.api(
  '/api/hud',
  async (data) => {
    const conv = data?.conversationId || app.config.conversationId || '';
    const snap = buildSnapshot(conv);
    const weekTokens = weekTokensFromSnapshot(snap);
    const quota = await getQuotaSnapshot({
      preferredModels: preferredModelsFromSteps(snap.current?.steps),
      weekTokens,
      force: data?.refresh === '1',
    });
    const steps = snap.current?.steps || [];
    const lastStep = steps.length ? steps[steps.length - 1] : null;
    return {
      current: snap.current
        ? {
            conversationId: snap.current.conversationId,
            title: snap.current.title,
            activeModel: snap.current.activeModel,
            activeContextTokens: snap.current.activeContextTokens,
            cacheHitRate: snap.current.cacheHitRate,
            deltaContextTokens: lastStep ? lastStep.deltaContextTokens : 0,
            totalOutputTokens: snap.current.totalOutputTokens,
            llmCallCount: snap.current.llmCallCount,
            userTurns: snap.current.userTurns,
            basePromptTokens: snap.current.basePromptTokens,
            updatedAt: snap.current.updatedAt || 0,
            recentStepTokens: steps.slice(-14).map((s) => s.contextTokens),
          }
        : null,
      weekTokens,
      quota,
    };
  },
  'GET'
);

app.api('/api/capsule', () => spawnHud(true), 'POST');

app.run().then((server) => {
  hudPort = server?.address()?.port || Number(process.env.ANTIGRAVITY_SIDECAR_WEB_PORT) || 0;
  spawnHud(false);
});
