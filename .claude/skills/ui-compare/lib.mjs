// ui-compare の共通処理（Playwright の読み込み・Chrome の場所）
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

/**
 * 対象リポジトリの node_modules から playwright-core（無ければ playwright）を読む。
 * どれも無ければ nixpkgs の playwright-driver（中身は playwright-core そのもの）を
 * ストアに取得して使う。プロジェクトにもグローバル環境にも何も入れない
 */
export function loadChromium(repo) {
  const require = createRequire(join(repo, 'package.json'));
  for (const name of ['playwright-core', 'playwright', '@playwright/test']) {
    try {
      return require(name).chromium;
    } catch {
      // 次の候補を試す（見つからなければ Nix から取る）
    }
  }
  let storePath;
  try {
    storePath = execFileSync(
      'nix',
      ['build', 'nixpkgs#playwright-driver', '--no-link', '--print-out-paths'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] },
    )
      .trim()
      .split('\n')
      .pop();
  } catch (e) {
    throw new Error(
      `${repo} に playwright-core / playwright が無く、Nix からの取得（nix build nixpkgs#playwright-driver）にも失敗しました: ${e.message}`,
    );
  }
  return require(storePath).chromium;
}

/** Chrome の実行ファイル。UI_COMPARE_CHROME → Playwright の Chromium → システムの Chrome の順 */
export function chromePath() {
  if (process.env.UI_COMPARE_CHROME) return process.env.UI_COMPARE_CHROME;
  const cache = join(process.env.HOME ?? '', 'Library/Caches/ms-playwright');
  if (existsSync(cache)) {
    const dirs = readdirSync(cache)
      .filter((d) => /^chromium-\d+$/.test(d))
      .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
    for (const d of dirs) {
      for (const sub of ['chrome-mac-arm64', 'chrome-mac']) {
        const p = join(
          cache,
          d,
          sub,
          'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
        );
        if (existsSync(p)) return p;
      }
    }
  }
  const system = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  if (existsSync(system)) return system;
  throw new Error('Chrome が見つかりません（UI_COMPARE_CHROME で指定できます）');
}
