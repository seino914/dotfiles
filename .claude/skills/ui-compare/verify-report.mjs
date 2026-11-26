// できた HTML をヘッドレス Chrome で開き、画像の数・壊れた画像の数を出して、確認用のスクリーンショットを撮る。
// 使い方: node verify-report.mjs <HTML> <確認用 PNG の出力先ディレクトリ> [Playwright のあるリポジトリ（既定: カレント）]
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { chromePath, loadChromium } from './lib.mjs';

const [htmlPath, outDir, repoArg] = process.argv.slice(2);
if (!htmlPath || !outDir) {
  console.error('使い方: node verify-report.mjs <HTML> <出力先> [リポジトリ]');
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });
const chromium = loadChromium(resolve(repoArg ?? process.cwd()));
const browser = await chromium.launch({ executablePath: chromePath() });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(pathToFileURL(resolve(htmlPath)).toString());
  await page.screenshot({ path: join(outDir, 'report-top.png') });
  const sections = await page.locator('section').count();
  for (let i = 0; i < sections; i++) {
    await page.locator('section').nth(i).screenshot({ path: join(outDir, `report-s${i + 1}.png`) });
  }
  const stats = await page.evaluate(() => ({
    images: document.images.length,
    broken: [...document.images].filter((i) => !i.naturalWidth).length,
    // build-report は画像が無い所に <img> を出さず注記を出すので、それも欠落として数える
    missing: [...document.querySelectorAll('.note')].filter((n) =>
      n.textContent.includes('画像がありません'),
    ).length,
  }));
  console.log(
    `節: ${sections}／画像: ${stats.images}／壊れた画像: ${stats.broken}／欠落した画像: ${stats.missing}`,
  );
  console.log(`確認用: ${outDir}/report-top.png, report-s1.png …`);
  if (stats.broken > 0 || stats.missing > 0) process.exitCode = 2;
} finally {
  await browser.close();
}
