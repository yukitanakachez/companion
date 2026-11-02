// Bundles the extension into dist/: the worker as ESM, everything else as classic IIFE scripts.
import { copyFile, mkdir } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build as esbuild } from "esbuild";

const root = fileURLToPath(new URL("..", import.meta.url));
const common = { bundle: true, target: "chrome116", logLevel: "silent" };
const classicEntries = {
  "content-page": "src/content/page-entry.ts",
  "content-youtube": "src/content/youtube/entry.ts",
  "content-youtube-main": "src/content/youtube/main-world.ts",
  "content-classroom": "src/content/classroom-entry.ts",
  "content-drive": "src/content/drive-entry.ts",
  options: "src/options/options-entry.ts",
};

export async function build(outdir = "dist") {
  const out = isAbsolute(outdir) ? outdir : resolve(root, outdir);
  await mkdir(out, { recursive: true });
  await esbuild({
    ...common,
    format: "esm",
    entryPoints: [join(root, "src/background/index.ts")],
    outfile: join(out, "background.js"),
  });
  await esbuild({
    ...common,
    format: "iife",
    entryPoints: Object.fromEntries(Object.entries(classicEntries).map(([k, v]) => [k, join(root, v)])),
    outdir: out,
  });
  await copyFile(join(root, "manifest.json"), join(out, "manifest.json"));
  await copyFile(join(root, "src/options/options.html"), join(out, "options.html"));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await build(process.argv[2] ?? "dist");
}
