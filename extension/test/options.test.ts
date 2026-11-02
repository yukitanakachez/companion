import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { JSDOM } from "jsdom";
import { initOptions, normalizeToken, statusText } from "../src/options/options";
import type { BridgeState } from "../src/shared/messages";
import { asChrome, createChromeMock } from "./helpers/chrome-mock";

const html = readFileSync(new URL("../src/options/options.html", import.meta.url), "utf8");
const status = (state: BridgeState, port: number | null = null, appVersion: string | null = null) => ({ state, port, appVersion, updatedAtMs: 1 });
async function page(storage: Record<string, unknown> = {}) {
  const doc = new JSDOM(html).window.document;
  const c = createChromeMock({ storage });
  await initOptions(doc, asChrome(c));
  const $ = <T extends HTMLElement>(s: string) => doc.querySelector<T>(s)!;
  return { doc, c, $ };
}
const flush = () => vi.waitFor(() => new Promise((r) => setTimeout(r, 0)));

describe("options", () => {
  it("normalizeToken", () => {
    expect(normalizeToken(" " + "A".repeat(64) + "\n")).toBe("a".repeat(64));
    expect(normalizeToken("abc")).toBeNull();
    expect(normalizeToken("g".repeat(64))).toBeNull();
  });
  it("statusText copy for every state", () => {
    expect(statusText(status("noToken"))).toBe("Not paired — paste the token from Companion Settings.");
    expect(statusText(status("connecting"))).toBe("Connecting…");
    expect(statusText(status("connected", 47824, "0.1.0"))).toBe("Connected to Companion 0.1.0 on port 47824");
    expect(statusText(status("disconnected"))).toBe("Companion app not running — retrying");
    expect(statusText(status("tokenRejected"))).toBe("Token rejected — paste the current token from Companion Settings.");
    expect(statusText(status("versionMismatch"))).toBe("Version mismatch — update the extension and the app.");
  });
  it("the token input is a password field", async () => {
    const { $ } = await page();
    expect($<HTMLInputElement>("#token").type).toBe("password");
  });
  it("saving an invalid token shows the error and stores nothing", async () => {
    const { $, c } = await page();
    $<HTMLInputElement>("#token").value = "nope";
    $("#save").click();
    await flush();
    expect($("#error").textContent).toBe("Token must be 64 hex characters.");
    expect(c._data.pairingToken).toBeUndefined();
  });
  it("saving a valid token stores it under pairingToken and clears the error", async () => {
    const { $, c } = await page();
    $<HTMLInputElement>("#token").value = "nope";
    $("#save").click();
    $<HTMLInputElement>("#token").value = "B".repeat(64);
    $("#save").click();
    await flush();
    expect(c._data.pairingToken).toBe("b".repeat(64));
    expect($("#error").textContent).toBe("");
  });
  it("Test connection sends reconnectNow", async () => {
    const { $, c } = await page();
    $("#test").click();
    expect(c.runtime.sendMessage).toHaveBeenCalledWith({ kind: "reconnectNow" });
  });
  it("shows the stored status on load, and not-paired when there is none", async () => {
    expect((await page()).$("#status").textContent).toBe("Not paired — paste the token from Companion Settings.");
    expect((await page({ bridgeStatus: status("disconnected") })).$("#status").textContent).toBe("Companion app not running — retrying");
  });
  it("re-renders when bridgeStatus changes", async () => {
    const { $, c } = await page();
    await c.storage.local.set({ bridgeStatus: status("connected", 47823, "dev") });
    expect($("#status").textContent).toBe("Connected to Companion dev on port 47823");
  });
});
