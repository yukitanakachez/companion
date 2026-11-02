import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const out = path.join(here, '../Sources/CompanionUI/Resources/web');
const katexDist = path.join(here, 'node_modules/katex/dist');

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, 'fonts'), { recursive: true });

await build({
  entryPoints: [path.join(here, 'src/main.js')],
  outfile: path.join(out, 'renderer.js'),
  bundle: true,
  format: 'iife',
  target: 'safari17',
  minify: true,
  legalComments: 'eof',
});

fs.copyFileSync(path.join(here, 'static/index.html'), path.join(out, 'index.html'));
fs.copyFileSync(path.join(katexDist, 'katex.min.css'), path.join(out, 'katex.min.css'));
for (const font of fs.readdirSync(path.join(katexDist, 'fonts'))) {
  if (font.endsWith('.woff2')) fs.copyFileSync(path.join(katexDist, 'fonts', font), path.join(out, 'fonts', font));
}
