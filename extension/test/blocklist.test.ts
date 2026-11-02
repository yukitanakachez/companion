import { describe, expect, it } from "vitest";
import { STARTER_BLOCKED_DOMAINS, hostOf, isHostBlocked } from "../src/shared/blocklist";
import { BlocklistStore } from "../src/background/blocklist-store";
import { asChrome, createChromeMock } from "./helpers/chrome-mock";

const area = (m: ReturnType<typeof createChromeMock>) => asChrome(m).storage.local;

describe("blocklist", () => {
  it("matches the host or a dot-suffix only", () => {
    const d = ["chase.com", "web.whatsapp.com"];
    expect(isHostBlocked("secure.chase.com", d)).toBe(true);
    expect(isHostBlocked("CHASE.COM.", d)).toBe(true);
    expect(isHostBlocked("notchase.com", d)).toBe(false);
    expect(isHostBlocked("chase.com.evil.io", d)).toBe(false);
    expect(isHostBlocked("whatsapp.com", d)).toBe(false);
  });
  it("hostOf", () => {
    expect(hostOf("https://Secure.Chase.com/x")).toBe("secure.chase.com");
    expect(hostOf("https://chase.com./x")).toBe("chase.com");
    expect(hostOf("chrome://extensions")).toBeNull();
    expect(hostOf("file:///a")).toBeNull();
    expect(hostOf("not a url")).toBeNull();
  });
  it("starter list is WS0's 18 domains", () => {
    expect(STARTER_BLOCKED_DOMAINS).toHaveLength(18);
    expect(STARTER_BLOCKED_DOMAINS).toContain("messages.google.com");
  });
  it("uses the starter domains until a config is stored", async () => {
    const s = new BlocklistStore(area(createChromeMock()));
    expect(await s.isUrlBlocked("https://www.chase.com/")).toBe(true);
    expect(await s.isUrlBlocked("https://example.org/")).toBe(false);
    expect(await s.isUrlBlocked("chrome://settings")).toBe(false);
  });
  it("answers wait for the stored blocklist", async () => {
    const c = createChromeMock({ storage: { blocklist: { bundleIDs: [], domains: ["example.org"] } }, storageGetDelayMs: 50 });
    const s = new BlocklistStore(area(c));
    expect(await s.isUrlBlocked("https://www.example.org/")).toBe(true);
    expect(await s.isUrlBlocked("https://chase.com/")).toBe(false);
  });
  it("a failed storage read falls back to the starter list", async () => {
    const c = createChromeMock();
    c.storage.local.get.mockRejectedValueOnce(new Error("io"));
    const s = new BlocklistStore(area(c));
    expect(await s.isUrlBlocked("https://chase.com/")).toBe(true);
  });
  it("setConfig persists and a new store instance reads it", async () => {
    const c = createChromeMock();
    await new BlocklistStore(area(c)).setConfig({ bundleIDs: [], domains: ["example.org"] });
    expect(c._data.blocklist).toEqual({ bundleIDs: [], domains: ["example.org"] });
    const next = new BlocklistStore(area(c));
    expect(await next.isUrlBlocked("https://example.org/")).toBe(true);
    expect(await next.isUrlBlocked("https://chase.com/")).toBe(false);
  });
  it("setConfig wins over a load still in flight", async () => {
    const c = createChromeMock({ storage: { blocklist: { bundleIDs: [], domains: ["old.org"] } }, storageGetDelayMs: 50 });
    const s = new BlocklistStore(area(c));
    await s.setConfig({ bundleIDs: [], domains: ["new.org"] });
    expect(await s.domains()).toEqual(["new.org"]);
  });
});
