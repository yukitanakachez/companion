import { describe, expect, it } from "vitest";
import { encodeMessage, errorResponse, isAppToExtension, isExtensionToApp, okResponse, parseAppMessage } from "../src/shared/protocol-codec";
import { contractFixture, contractFixtureNames, contractFixtureText } from "./helpers/fixtures";

const names = contractFixtureNames();
const extNames = names.filter((n) => n.startsWith("ext-"));
const appNames = names.filter((n) => n.startsWith("app-"));

describe("protocol codec", () => {
  it("checks all 24 fixtures", () => expect(names).toHaveLength(24));
  it.each(extNames)("%s is ExtensionToApp and not AppToExtension", (n) => {
    expect(isExtensionToApp(contractFixture(n))).toBe(true);
    expect(isAppToExtension(contractFixture(n))).toBe(false);
  });
  it.each(appNames)("%s is AppToExtension and parses", (n) => {
    expect(isAppToExtension(contractFixture(n))).toBe(true);
    expect(parseAppMessage(contractFixtureText(n))).toEqual(contractFixture(n));
  });
  it("rejects invalid-version", () => {
    expect(isAppToExtension(contractFixture("invalid-version.json"))).toBe(false);
    expect(() => parseAppMessage(contractFixtureText("invalid-version.json"))).toThrow(expect.objectContaining({ code: "versionMismatch" }));
  });
  it("rejects malformed shapes", () => {
    const ctx = contractFixture("ext-tabContext-blocked.json");
    expect(isExtensionToApp({ ...ctx, context: { ...ctx.context, blocked: "no" } })).toBe(false);
    expect(isAppToExtension({ v: 1, type: "request", id: "x", method: "deleteAll", params: {} })).toBe(false);
    expect(isAppToExtension({ v: 1, type: "config", blocklist: { bundleIDs: [] } })).toBe(false);
    expect(isExtensionToApp({ v: 1, type: "response", id: "x", ok: false, error: { code: "nope", message: "m" } })).toBe(false);
    expect(isAppToExtension({ v: 1, type: "request", id: "x", method: "fetchDrivePdf", params: {} })).toBe(false);
    expect(isExtensionToApp({ v: 1, type: "tabContext", context: { ...ctx.context, youtube: { videoId: "a" } } })).toBe(false);
    expect(() => parseAppMessage("not json")).toThrow(expect.objectContaining({ code: "malformed" }));
    expect(() => parseAppMessage('{"v":1,"type":"mystery"}')).toThrow(expect.objectContaining({ code: "malformed" }));
  });
  it("builders reproduce fixtures", () => {
    expect(JSON.parse(encodeMessage(okResponse("r-1", { context: null })))).toEqual(contractFixture("ext-response-tabContext.json"));
    expect(JSON.parse(encodeMessage(errorResponse("r-3", "downloadBlocked", "The owner has disabled downloads for this file."))))
      .toEqual(contractFixture("ext-response-downloadBlocked.json"));
  });
});
