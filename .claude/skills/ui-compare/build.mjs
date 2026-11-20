// /ui-compare の HTML 生成役。出力先の manifest.json と PNG を読み、画像を data URL にして
// template.html に埋め込んだ自己完結の index.html を書く。stdout に変化率の表と file:// URL を出す。
// 使い方: node build.mjs <出力先ディレクトリ>

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const out = process.argv[2];
if (!out) { console.error('使い方: node build.mjs <出力先>'); process.exit(1); }

const manifest = JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8'));
const withSrc = (side) => ({
  ...side,
  src: side.file ? 'data:image/png;base64,' + readFileSync(join(out, side.file)).toString('base64') : null,
});
const data = { ...manifest, items: manifest.items.map((it) => ({ ...it, before: withSrc(it.before), after: withSrc(it.after) })) };

const MARK = '/*__UI_COMPARE_DATA__*/';
const tpl = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'template.html'), 'utf8');
if (!tpl.includes(MARK)) { console.error('template.html に目印がありません'); process.exit(1); }
const json = JSON.stringify(data).replace(/<\/script/gi, '<\\/script').replace(/<!--/g, '<\\!--');
// replace に関数を渡して、データ中の $ が置換パターンとして解釈されないようにする
const html = tpl.replace(MARK, () => `const DATA = ${json};`);
const file = join(out, 'index.html');
writeFileSync(file, html);

const cell = (s) => (s.error ? `失敗(${s.error})` : 'ok');
const redir = (s) => (s.redirectedTo ? `${s.redirectedTo} へリダイレクト` : '');
console.log('');
console.log('| パス | 幅 | 変化率 | 備考 |');
console.log('|---|---|---|---|');
for (const it of manifest.items) {
  const note = [it.before.error && `修正前: ${cell(it.before)}`, it.after.error && `修正後: ${cell(it.after)}`,
    it.before.redirectedTo && `修正前: → ${redir(it.before)}`, it.after.redirectedTo && `修正後: → ${redir(it.after)}`].filter(Boolean).join(' / ');
  console.log(`| ${it.path} | ${it.width} | ${it.changeRatio === null ? '-' : it.changeRatio.toFixed(1) + '%'} | ${note} |`);
}
console.log('');
console.log(pathToFileURL(file).href);
