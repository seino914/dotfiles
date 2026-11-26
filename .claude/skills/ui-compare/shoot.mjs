// 修正前・修正後の 2 つのサーバーを、同じ操作で撮る。
// 使い方: node shoot.mjs <shots.json> <出力ディレクトリ> [撮る id をカンマ区切り]
// 仕様の書き方は SKILL.md の「撮影の仕様（shots.json）」を参照
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';

import { chromePath, loadChromium } from './lib.mjs';

const [specPath, outDir, onlyArg] = process.argv.slice(2);
if (!specPath || !outDir) {
  console.error('使い方: node shoot.mjs <shots.json> <出力ディレクトリ> [id,...]');
  process.exit(1);
}
const spec = JSON.parse(readFileSync(specPath, 'utf8'));
const repo = resolve(spec.repo ?? process.cwd());
const only = onlyArg
  ? onlyArg
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
  : null;
if (only) {
  // 打ち間違えた id で「0 枚撮って成功」にしない（古い画像のままレポートを作ってしまう）
  const known = new Set(spec.shots.map((s) => s.id));
  const unknown = only.filter((id) => !known.has(id));
  if (unknown.length) {
    console.error(`仕様に無い id: ${unknown.join(', ')}（ある id: ${[...known].join(', ')}）`);
    process.exit(1);
  }
}
mkdirSync(outDir, { recursive: true });

// ログイン情報はファイルの 1 行から読む（パスワードを仕様やチャットに書かないため）
function readCredentials(cfg) {
  if (!cfg) return {};
  const file = isAbsolute(cfg.file) ? cfg.file : join(repo, cfg.file);
  const line = readFileSync(file, 'utf8')
    .split('\n')
    .find((l) => l.startsWith(cfg.linePrefix));
  if (!line) throw new Error(`${cfg.file} に「${cfg.linePrefix}」で始まる行がありません`);
  const cols = line.split(cfg.separator ?? '|').map((s) => s.trim());
  const [ei, pi] = cfg.columns ?? [1, 2];
  return { email: cols[ei], password: cols[pi] };
}
const creds = readCredentials(spec.login?.credentials);
// 置換は関数で渡す（文字列で渡すと、パスワードに含まれる $& $$ などが特殊な意味になって化ける）
const fillValue = (v) =>
  String(v)
    .replaceAll('$email', () => creds.email ?? '')
    .replaceAll('$password', () => creds.password ?? '');

const HIDE_CSS = [
  'nextjs-portal{display:none!important}',
  '[data-sonner-toaster]{display:none!important}',
  spec.hideCss ?? '',
].join('\n');

const timeout = spec.timeoutMs ?? 120000;

async function settle(page, ms) {
  await page.waitForLoadState('networkidle', { timeout: 60000 }).catch(() => {});
  if (ms) await page.waitForTimeout(ms);
}

async function runStep(page, step) {
  if (step.fill) return page.locator(step.fill).first().fill(fillValue(step.value ?? ''));
  if (step.click) return page.locator(step.click).first().click();
  if (step.clickRole) {
    const [role, name] = step.clickRole;
    return page.getByRole(role, { name }).first().click();
  }
  if (step.clickText) return page.getByText(step.clickText, { exact: step.exact ?? false }).first().click();
  if (step.waitFor) return page.locator(step.waitFor).first().waitFor({ timeout });
  if (step.waitText) return page.getByText(step.waitText, { exact: step.exact ?? false }).first().waitFor({ timeout });
  if (step.waitUrl) return page.waitForURL(new RegExp(step.waitUrl), { timeout });
  if (step.scrollToBottom) {
    return page.locator(step.scrollToBottom).first().evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
  }
  if (step.scrollIntoView) return page.locator(step.scrollIntoView).first().scrollIntoViewIfNeeded();
  if (step.wait) return page.waitForTimeout(step.wait);
  if (step.press) return page.keyboard.press(step.press);
  throw new Error(`知らない手順: ${JSON.stringify(step)}`);
}

async function capture(page, cap) {
  if (!cap || cap === 'viewport') return page.screenshot();
  if (cap === 'fullPage') return page.screenshot({ fullPage: true });
  if (cap.selector) return page.locator(cap.selector).first().screenshot();
  if (cap.textAncestor) {
    // 文字を含む要素から、class に指定の語を含む直近の祖先を撮る（カードだけ切り出す等）
    const { text, classContains } = cap.textAncestor;
    const el = page
      .getByText(text, { exact: true })
      .first()
      .locator(`xpath=ancestor::*[contains(@class,"${classContains}")][1]`);
    return el.screenshot();
  }
  if (cap.clip) {
    const [x, y, width, height] = cap.clip;
    return page.screenshot({ clip: { x, y, width, height } });
  }
  throw new Error(`知らない撮り方: ${JSON.stringify(cap)}`);
}

async function login(context, base) {
  const l = spec.login;
  const page = await context.newPage();
  await page.goto(`${base}${l.path}`, { waitUntil: 'domcontentloaded', timeout });
  await page.locator(l.fields.email).first().fill(creds.email);
  await page.locator(l.fields.password).first().fill(creds.password);
  await page.locator(l.fields.submit).first().click();
  const away = l.waitAwayFrom ?? l.path;
  await page.waitForURL((u) => !u.pathname.startsWith(away), { timeout });
  await page.close();
}

const chromium = loadChromium(repo);
const browser = await chromium.launch({ executablePath: chromePath() });
const results = [];
try {
  for (const [side, base] of Object.entries(spec.sides)) {
    const authCtx = await browser.newContext({ deviceScaleFactor: spec.scale ?? 1 });
    let authed = false;
    let loginError = null;
    for (const shot of spec.shots) {
      if (only && !only.includes(shot.id)) continue;
      if (shot.only && shot.only !== side) continue;
      const needAuth = shot.auth !== false && Boolean(spec.login);
      let ctx = authCtx;
      let anon = null;
      // 前回の画像を先に消す（撮り直しに失敗した側が古い画像のままレポートに入らないように）
      rmSync(join(outDir, `${shot.id}-${side}.png`), { force: true });
      if (needAuth && !authed && !loginError) {
        // ログインに失敗しても止めず、この側の認証つき撮影だけを失敗として記録して進む
        try {
          await login(authCtx, base);
          authed = true;
        } catch (e) {
          loginError = `ログイン失敗: ${e.message.split('\n')[0]}`;
        }
      }
      if (needAuth && loginError) {
        const name = `${shot.id}-${side}`;
        results.push({ name, ok: false, error: loginError });
        console.log('失敗', name, loginError);
        continue;
      }
      if (!needAuth) {
        anon = await browser.newContext({ deviceScaleFactor: spec.scale ?? 1 });
        ctx = anon;
      }
      const page = await ctx.newPage();
      const name = `${shot.id}-${side}`;
      try {
        const [w, h] = shot.viewport ?? [1280, 800];
        await page.setViewportSize({ width: w, height: h });
        await page.goto(`${base}${shot.path}`, { waitUntil: 'domcontentloaded', timeout });
        if (shot.waitText) await page.getByText(shot.waitText).first().waitFor({ timeout });
        if (shot.waitFor) await page.locator(shot.waitFor).first().waitFor({ timeout });
        await settle(page, shot.settleMs ?? 2500);
        for (const step of shot.steps ?? []) await runStep(page, step);
        if (shot.steps?.length) await settle(page, shot.afterStepsMs ?? 1000);
        await page.addStyleTag({ content: HIDE_CSS });
        writeFileSync(join(outDir, `${name}.png`), await capture(page, shot.capture));
        results.push({ name, ok: true });
        console.log('撮影', name);
      } catch (e) {
        results.push({ name, ok: false, error: e.message.split('\n')[0] });
        console.log('失敗', name, e.message.split('\n')[0]);
      }
      await page.close();
      if (anon) await anon.close();
    }
    await authCtx.close();
  }
} finally {
  await browser.close();
}
const failed = results.filter((r) => !r.ok);
console.log(`完了: ${results.length - failed.length} 枚／失敗 ${failed.length} 枚`);
process.exit(failed.length > 0 ? 2 : 0);
