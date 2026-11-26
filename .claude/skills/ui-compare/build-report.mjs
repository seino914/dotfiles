// 修正前・修正後の比較レポート（画像を base64 で埋め込んだ 1 枚の HTML）を作る。
// 使い方: node build-report.mjs <report.json> <撮影ディレクトリ> <出力 HTML>
// 仕様の書き方は SKILL.md の「レポートの仕様（report.json）」を参照。
// 文字列は HTML としてそのまま埋め込む（<b>・<code> を使える）。仕様は Claude が書くもので、外部の入力は入れない
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [specPath, shotsDir, outFile] = process.argv.slice(2);
if (!specPath || !shotsDir || !outFile) {
  console.error('使い方: node build-report.mjs <report.json> <撮影ディレクトリ> <出力 HTML>');
  process.exit(1);
}
const r = JSON.parse(readFileSync(specPath, 'utf8'));
const missing = [];

const img = (file, alt) => {
  const p = join(shotsDir, `${file}.png`);
  if (!existsSync(p)) {
    missing.push(file);
    return `<p class="note">画像がありません: <code>${file}.png</code></p>`;
  }
  return `<img src="data:image/png;base64,${readFileSync(p).toString('base64')}" alt="${alt}">`;
};

const pair = (p) => `
  <div class="pair">
    <figure class="before"><figcaption><span class="tag tag-before">修正前</span>${p.before}</figcaption>${img(`${p.shot}-before`, '修正前')}</figure>
    <figure class="after"><figcaption><span class="tag tag-after">修正後</span>${p.after}</figcaption>${img(`${p.shot}-after`, '修正後')}</figure>
  </div>`;

const SIDE_LABEL = { before: '修正前', after: '修正後' };
const single = (s) => {
  const side = s.side ?? 'after';
  return `
  ${s.h3 ? `<h3>${s.h3}</h3>` : ''}
  ${s.p ? `<p>${s.p}</p>` : ''}
  <div class="single"><figure class="${side}"><figcaption><span class="tag tag-${side}">${SIDE_LABEL[side]}</span>${s.caption ?? ''}</figcaption>${img(`${s.shot}-${side}`, s.caption ?? SIDE_LABEL[side])}</figure></div>`;
};

const table = (t) => `
  <table class="fixes">
    <tr>${t.head.map((h) => `<th>${h}</th>`).join('')}</tr>
    ${t.rows.map((row) => `<tr>${row.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('\n    ')}
  </table>`;

const pad = (n) => String(n).padStart(2, '0');
const sections = r.sections
  .map(
    (s, i) => `
<section id="s${i + 1}">
  <h2><span class="num">${pad(i + 1)}</span>${s.title}</h2>
  ${s.desc ? `<p>${s.desc}</p>` : ''}
  ${s.pair ? pair(s.pair) : ''}
  ${(s.singles ?? []).map(single).join('')}
  ${s.table ? table(s.table) : ''}
  ${s.note ? `<div class="note">${s.note}</div>` : ''}
</section>`,
  )
  .join('\n');

const nav = r.sections
  .map(
    (s, i) =>
      `<a href="#s${i + 1}"><b>${i + 1}. ${s.navTitle ?? s.title}</b><span>${s.navSub ?? ''}</span></a>`,
  )
  .join('\n    ');

const html = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${r.htmlTitle ?? r.title}</title>
<style>
  :root {
    --ink: #1f2430; --ink-soft: #4a5263; --mute: #6b7384; --line: #e3e6ec;
    --paper: #f7f8fa; --card: #fff; --accent: #0075de;
    --before: #b54708; --before-bg: #fff4e5; --after: #1e7f43; --after-bg: #e8f6ee;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --ink: #e8eaf0; --ink-soft: #c3c8d3; --mute: #9aa1b0; --line: #2f3442;
      --paper: #14161c; --card: #1c1f27; --accent: #5aa8ff;
      --before: #ffb35c; --before-bg: #3a2a14; --after: #6fd39a; --after-bg: #16321f;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--paper); color: var(--ink);
    font: 15px/1.75 "Hiragino Sans", "Noto Sans JP", system-ui, sans-serif; }
  .wrap { max-width: 1240px; margin: 0 auto; padding: 40px 24px 80px; }
  header { margin-bottom: 32px; }
  .eyebrow { font: 600 12px/1 ui-monospace, monospace; letter-spacing: .12em; color: var(--mute); }
  h1 { font-size: 28px; line-height: 1.35; margin: 10px 0 12px; }
  h2 { font-size: 21px; margin: 0 0 6px; }
  h3 { font-size: 16px; margin: 28px 0 8px; }
  p { margin: 0 0 10px; color: var(--ink-soft); }
  .lead { font-size: 16px; color: var(--ink-soft); max-width: 860px; }
  .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; margin: 24px 0 8px; }
  .summary a { display: block; background: var(--card); border: 1px solid var(--line); border-radius: 10px;
    padding: 14px 16px; color: inherit; text-decoration: none; }
  .summary a:hover { border-color: var(--accent); }
  .summary b { display: block; font-size: 14px; margin-bottom: 2px; }
  .summary span { font-size: 13px; color: var(--mute); }
  .note { background: var(--card); border: 1px solid var(--line); border-left: 4px solid var(--accent);
    border-radius: 8px; padding: 12px 16px; margin: 16px 0; font-size: 14px; color: var(--ink-soft); }
  section { background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 28px; margin-top: 28px; scroll-margin-top: 16px; }
  .num { display: inline-block; font: 700 13px/1 ui-monospace, monospace; color: var(--accent); margin-right: 6px; }
  .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 16px; align-items: start; }
  @media (max-width: 900px) { .pair { grid-template-columns: 1fr; } }
  figure { margin: 0; }
  figcaption { font-size: 13.5px; color: var(--ink-soft); margin-bottom: 8px; line-height: 1.6; }
  figure img { display: block; width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
  .before img { outline: 3px solid var(--before-bg); }
  .after img { outline: 3px solid var(--after-bg); }
  .tag { display: inline-block; font-size: 12px; font-weight: 700; border-radius: 999px; padding: 1px 10px; margin-right: 8px; }
  .tag-before { color: var(--before); background: var(--before-bg); }
  .tag-after { color: var(--after); background: var(--after-bg); }
  .single { max-width: 620px; margin-top: 16px; }
  ul { margin: 6px 0 0; padding-left: 1.3em; color: var(--ink-soft); }
  li { margin: 2px 0; }
  code { font: 13px ui-monospace, monospace; background: var(--paper); border: 1px solid var(--line); border-radius: 4px; padding: 0 4px; }
  table.fixes { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 14px; }
  table.fixes th, table.fixes td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid var(--line); }
  table.fixes th { color: var(--mute); font-weight: 600; font-size: 13px; }
  table.fixes td:first-child { white-space: nowrap; color: var(--ink); font-weight: 600; }
</style>
</head>
<body>
<div class="wrap">
<header>
  <div class="eyebrow">${r.eyebrow ?? ''}</div>
  <h1>${r.title}</h1>
  ${r.lead ? `<p class="lead">${r.lead}</p>` : ''}
  <nav class="summary">
    ${nav}
  </nav>
  ${r.note ? `<div class="note">${r.note}</div>` : ''}
</header>
${sections}
</div>
</body>
</html>
`;

writeFileSync(outFile, html);
console.log(`書き出し: ${outFile}（${Math.round(html.length / 1024)} KB）`);
if (missing.length) {
  console.log(`画像が無かったもの: ${missing.join(', ')}`);
  process.exit(2);
}
