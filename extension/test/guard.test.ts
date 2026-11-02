import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ASK_BLOCKED_TIMEOUT_MS, askBlocked } from "../src/shared/guard";

describe("askBlocked", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  const U = "https://example.org/";

  it("asks the worker with the url", async () => {
    const send = vi.fn(async () => ({ blocked: false }));
    expect(await askBlocked(U, send)).toBe(false);
    expect(send).toHaveBeenCalledWith({ kind: "isBlocked", url: U });
  });
  it("fails closed when the worker rejects or gives no answer", async () => {
    expect(await askBlocked(U, async () => { throw new Error("no receiver"); })).toBe(true);
    expect(await askBlocked(U, async () => undefined)).toBe(true);
    expect(await askBlocked(U, () => { throw new Error("context invalidated"); })).toBe(true);
  });
  it("{ blocked: true } is blocked", async () => {
    expect(await askBlocked(U, async () => ({ blocked: true }))).toBe(true);
  });
  it("never resolves → blocked at 1,000 ms", async () => {
    let result: boolean | undefined;
    void askBlocked(U, () => new Promise(() => {})).then((r) => { result = r; });
    await vi.advanceTimersByTimeAsync(ASK_BLOCKED_TIMEOUT_MS - 1);
    expect(result).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1);
    expect(result).toBe(true);
    expect(ASK_BLOCKED_TIMEOUT_MS).toBe(1000);
  });
});
