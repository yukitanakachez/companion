import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const m = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));
const scripts: { matches: string[]; exclude_matches?: string[]; js: string[]; world?: string; all_frames?: boolean }[] = m.content_scripts;

describe("manifest", () => {
  it("declares MV3 basics", () => {
    expect(m.manifest_version).toBe(3);
    expect(m.name).toBe("Companion Bridge");
    expect(m.background).toEqual({ service_worker: "background.js", type: "module" });
    expect([...m.permissions].sort()).toEqual(["scripting", "storage", "tabs"]);
    expect(m.host_permissions).toEqual(["<all_urls>"]);
    expect(m.options_page).toBe("options.html");
  });
  it("youtube has an isolated and a MAIN-world script", () => {
    const yt = scripts.filter((s) => s.matches.includes("https://www.youtube.com/*"));
    expect(yt.filter((s) => s.world === "MAIN").map((s) => s.js)).toEqual([["content-youtube-main.js"]]);
    expect(yt.filter((s) => s.world === undefined).map((s) => s.js)).toEqual([["content-youtube.js"]]);
  });
  it("drive script runs in all frames", () => {
    expect(scripts.find((s) => s.js.includes("content-drive.js"))?.all_frames).toBe(true);
  });
  it("generic extractor excludes youtube and drive", () => {
    expect(scripts.find((s) => s.js.includes("content-page.js"))?.exclude_matches).toEqual([
      "https://www.youtube.com/*",
      "https://drive.google.com/*",
    ]);
  });
});
