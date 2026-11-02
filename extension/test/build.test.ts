import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { build } from "../tools/build.mjs";

const files = ["background.js", "content-page.js", "content-youtube.js", "content-youtube-main.js",
  "content-classroom.js", "content-drive.js", "options.js", "manifest.json", "options.html"];

describe("build", () => {
  let dir: string;
  beforeAll(async () => { dir = mkdtempSync(join(tmpdir(), "companion-build-")); await build(dir); }, 60_000);
  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  it("emits every file the manifest references", () => {
    for (const f of files) expect(existsSync(join(dir, f)), f).toBe(true);
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    const refs = [m.background.service_worker, m.options_page, ...m.content_scripts.flatMap((s: { js: string[] }) => s.js)];
    for (const r of refs) expect(existsSync(join(dir, r)), r).toBe(true);
  });
  it("content scripts are classic scripts", () => {
    for (const f of files.filter((n) => /^(content-.*|options)\.js$/.test(n))) {
      expect(readFileSync(join(dir, f), "utf8"), f).not.toMatch(/^(import|export)\b/m);
    }
  });
});
