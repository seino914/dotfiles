// /ui-compare の撮影役。ヘッドレス Chrome を CDP（WebSocket 直叩き）で操作し、
// before / after の各パス×幅のスクリーンショットと変化率を出力先へ書く。依存は Node 標準とグローバル WebSocket のみ。
// 使い方: node capture.mjs <config.json>

import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const cfg = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- Chrome の起動と接続 ---
mkdirSync(cfg.profile, { recursive: true });
const chrome = spawn(cfg.chrome, [
  '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${cfg.profile}`,
  '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--disable-extensions', 'about:blank',
], { stdio: 'ignore' });
let chromeExited = false;
chrome.on('exit', () => { chromeExited = true; });

async function waitWsUrl() {
  const f = join(cfg.profile, 'DevToolsActivePort');
  for (let i = 0; i < 200; i++) {
    if (chromeExited) throw new Error('Chrome が起動直後に終了しました');
    if (existsSync(f)) {
      const [port, path] = readFileSync(f, 'utf8').split('\n');
      if (port && path) return `ws://127.0.0.1:${port}${path}`;
    }
    await sleep(100);
  }
  throw new Error('Chrome の DevToolsActivePort が出ませんでした');
}

let ws, nextId = 1;
const pending = new Map();
const listeners = [];
function send(method, params = {}, sessionId) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    // 60 秒応答が無ければ reject する（unref で、タイマーが終了を妨げないようにする）
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method}: 60 秒応答がありませんでした`)); }, 60000);
    timer.unref();
    pending.set(id, {
      resolve: (v) => { clearTimeout(timer); resolve(v); },
      reject: (e) => { clearTimeout(timer); reject(e); },
      method,
    });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
}
function onEvent(fn) { listeners.push(fn); return () => listeners.splice(listeners.indexOf(fn), 1); }

async function closeChrome() {
  // race の負け側のタイマーが残ると node の終了が最大 3 秒延びるので、終わったら消す
  let t;
  try {
    await Promise.race([send('Browser.close'), new Promise((r) => { t = setTimeout(r, 3000); })]);
  } catch { /* 無視 */ } finally { clearTimeout(t); }
  for (let i = 0; i < 30 && !chromeExited; i++) await sleep(100);
  if (!chromeExited) chrome.kill('SIGKILL');
}

// シグナルで止められたときも Chrome を残さない
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, async () => { await closeChrome(); process.exit(sig === 'SIGTERM' ? 143 : 130); });
}

// --- 撮影 ---
const FREEZE_JS = `(async () => {
  const s = document.createElement('style');
  s.textContent = '*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important;scroll-behavior:auto!important}';
  document.head.appendChild(s);
  await Promise.race([document.fonts.ready, new Promise((r) => setTimeout(r, 10000))]);
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 500));
  const h = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0, 1);
  return Math.min(10000, h);
})()`;

const DIFF_JS = (a, b) => `(async () => {
  const load = async (u) => createImageBitmap(await (await fetch(u)).blob());
  const A = await load(${JSON.stringify(a)}), B = await load(${JSON.stringify(b)});
  const w = Math.max(A.width, B.width), h = Math.max(A.height, B.height);
  const px = (img) => {
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const x = c.getContext('2d', { willReadFrequently: true });
    x.drawImage(img, 0, 0);
    return x.getImageData(0, 0, w, h).data;
  };
  const da = px(A), db = px(B);
  let changed = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const outA = x >= A.width || y >= A.height, outB = x >= B.width || y >= B.height;
      if (outA || outB) { if (outA !== outB) changed++; continue; }
      const i = (y * w + x) * 4;
      const d = Math.max(Math.abs(da[i] - db[i]), Math.abs(da[i + 1] - db[i + 1]), Math.abs(da[i + 2] - db[i + 2]));
      if (d > 16) changed++;
    }
  }
  return changed / (w * h) * 100;
})()`;

const safeNames = new Map();
function safeName(p) {
  if (safeNames.has(p)) return safeNames.get(p);
  let base = p.replace(/^\/+/, '').replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'root';
  let name = base, n = 2;
  while ([...safeNames.values()].includes(name)) name = `${base}_${n++}`;
  safeNames.set(p, name);
  return name;
}

async function shoot(side, path, width) {
  const origin = cfg.sides[side];
  const rel = `${side}/${safeName(path)}_${width}.png`;
  const res = { file: null, status: null, height: null, error: null };
  // 撮影ごとに新しいブラウザコンテキストで撮るので、cookie・localStorage・前のページの遅れた通信は持ち越されない
  // （修正前・修正後は同じ localhost でポートだけが違い、cookie はポートで分かれないため）
  let contextId = null, targetId = null, off = () => {};
  try {
    contextId = (await send('Target.createBrowserContext')).browserContextId;
    targetId = (await send('Target.createTarget', { url: 'about:blank', browserContextId: contextId })).targetId;
    const session = (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
    await send('Page.enable', {}, session);
    await send('Network.enable', {}, session);
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] }, session);
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width < 768 }, session);
    let loaderId = null, status = null;
    // 通信中のもの（SWR / React Query 等の表示後の通信を待つため）。EventSource・WebSocket・Ping は常時つながるので数えない
    const inflight = new Map(); // requestId → 開始時刻
    let lastActivity = Date.now();
    off = onEvent((m) => {
      if (m.sessionId !== session) return;
      if (m.method === 'Network.requestWillBeSent' && !['EventSource', 'WebSocket', 'Ping'].includes(m.params.type)) {
        if (!inflight.has(m.params.requestId)) inflight.set(m.params.requestId, Date.now()); // リダイレクトは同じ ID で来る
        lastActivity = Date.now();
      } else if (m.method === 'Network.loadingFinished' || m.method === 'Network.loadingFailed') {
        inflight.delete(m.params.requestId); lastActivity = Date.now();
      }
      if (m.method === 'Network.responseReceived' && m.params.type === 'Document' && (!loaderId || m.params.loaderId === loaderId)) {
        status = m.params.response.status;
      }
    });
    const loaded = new Promise((resolve) => {
      const off2 = onEvent((m) => {
        if (m.sessionId === session && m.method === 'Page.loadEventFired') { off2(); resolve(true); }
      });
      setTimeout(() => { off2(); resolve(false); }, 30000).unref();
    });
    const nav = await send('Page.navigate', { url: origin + path }, session);
    loaderId = nav.loaderId || null;
    if (nav.errorText) { res.error = `接続エラー: ${nav.errorText}`; return [rel, res]; }
    if (!(await loaded)) { res.error = '読み込みが 30 秒以内に終わりませんでした'; return [rel, res]; }
    res.status = status;
    // 通信が 0 件の状態が 500ms 続くまで待つ（上限 10 秒。打ち切っても撮影は続ける）。
    // 3 秒を超えて続く通信はロングポーリング等の常時接続とみなして数えない（毎ページ上限まで待たないため）
    const busy = () => [...inflight.values()].some((t) => Date.now() - t < 3000);
    for (const t0 = Date.now(); Date.now() - t0 < 10000 && (busy() || Date.now() - lastActivity < 500);) await sleep(50);
    // リダイレクト等で要求と違うページになっていないか（末尾スラッシュと # の違いは同一とみなす）
    const fin = await send('Runtime.evaluate', { expression: 'location.pathname + location.search', returnByValue: true }, session);
    const norm = (p) => p.replace(/\/+(?=\?|$)/, '') || '/';
    const want = new URL(origin + path); const wantPath = norm(want.pathname + want.search);
    if (typeof fin.result?.value === 'string' && norm(fin.result.value) !== wantPath) res.redirectedTo = fin.result.value;
    const ev = await send('Runtime.evaluate', { expression: FREEZE_JS, awaitPromise: true, returnByValue: true }, session);
    if (ev.exceptionDetails) { res.error = '描画待ちスクリプトの失敗'; return [rel, res]; }
    const height = ev.result.value;
    const shot = await send('Page.captureScreenshot', {
      format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height, scale: 1 },
    }, session);
    writeFileSync(join(cfg.out, rel), Buffer.from(shot.data, 'base64'));
    res.file = rel; res.height = height;
    if (status !== null && status >= 400) res.error = `HTTP ${status}`;
  } catch (e) {
    res.error = String(e.message || e);
  } finally {
    off();
    // 後片付けの失敗は撮影結果に影響させない
    if (targetId) { try { await send('Target.closeTarget', { targetId }); } catch { /* 無視 */ } }
    if (contextId) { try { await send('Target.disposeBrowserContext', { browserContextId: contextId }); } catch { /* 無視 */ } }
  }
  return [rel, res];
}

async function main() {
  ws = new WebSocket(await waitWsUrl());
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error('CDP 接続に失敗')); });
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      if (m.error) p.reject(new Error(`${p.method}: ${m.error.message}`)); else p.resolve(m.result);
    } else if (m.method) {
      for (const fn of [...listeners]) fn(m);
    }
  };

  // このタブは変化率の計算（canvas 比較）専用。撮影は shoot() が撮影ごとのコンテキストで行う
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, sessionId);
  for (const side of ['before', 'after']) mkdirSync(join(cfg.out, side), { recursive: true });

  const items = [];
  for (const path of cfg.paths) {
    for (const width of cfg.widths) {
      const item = { path, width };
      for (const side of ['before', 'after']) {
        const [, r] = await shoot(side, path, width);
        item[side] = r;
        console.log(`  ${side} ${path} @${width}: ${r.error ? '失敗(' + r.error + ')' : 'ok'}${r.redirectedTo ? ' → ' + r.redirectedTo + ' へリダイレクト' : ''}`);
      }
      item.changeRatio = null;
      items.push(item);
    }
  }

  // 変化率（同じ Chrome のページで canvas 比較）
  await send('Page.navigate', { url: 'about:blank' }, sessionId);
  await sleep(200);
  for (const item of items) {
    if (!item.before.file || !item.after.file) continue;
    const du = (f) => 'data:image/png;base64,' + readFileSync(join(cfg.out, f)).toString('base64');
    try {
      const r = await send('Runtime.evaluate', {
        expression: DIFF_JS(du(item.before.file), du(item.after.file)), awaitPromise: true, returnByValue: true,
      }, sessionId);
      // 0.05% 未満の小さな変化が 0.0%（変化なし）に丸められないよう、変化があれば最低 0.1 にする
      if (!r.exceptionDetails) { const v = r.result.value; item.changeRatio = v > 0 ? Math.max(0.1, Math.round(v * 10) / 10) : 0; }
    } catch { /* 比較失敗は null のまま */ }
  }

  writeFileSync(join(cfg.out, 'manifest.json'), JSON.stringify({
    title: cfg.title, base: cfg.base, baseShort: cfg.baseShort, createdAt: new Date().toISOString(),
    changedFiles: cfg.changedFiles, items,
  }, null, 2));
}

try {
  await main();
} catch (e) {
  console.error('撮影に失敗: ' + (e.message || e));
  process.exitCode = 1;
} finally {
  await closeChrome();
  try { ws && ws.close(); } catch { /* 無視 */ }
}
