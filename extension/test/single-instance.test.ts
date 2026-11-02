import { describe, expect, it, vi } from "vitest";
import { JSDOM } from "jsdom";
import { replaceInstance } from "../src/content/single-instance";
import { installPlayerDataResponder } from "../src/content/youtube/player-data";

describe("replaceInstance", () => {
  it("stops the previous instance of the same key before starting the new one", () => {
    const win = new JSDOM("").window as unknown as Window;
    const stopA = vi.fn();
    const stopB = vi.fn();
    replaceInstance(win, "page", () => stopA);
    expect(stopA).not.toHaveBeenCalled();
    replaceInstance(win, "page", () => stopB);
    expect(stopA).toHaveBeenCalledTimes(1);
    expect(stopB).not.toHaveBeenCalled();
  });
  it("keys are independent", () => {
    const win = new JSDOM("").window as unknown as Window;
    const stop = vi.fn();
    replaceInstance(win, "page", () => stop);
    replaceInstance(win, "classroom", () => () => {});
    expect(stop).not.toHaveBeenCalled();
  });
  it("a previous instance that throws while stopping doesn't prevent the new one", () => {
    const win = new JSDOM("").window as unknown as Window;
    replaceInstance(win, "page", () => () => { throw new Error("context invalidated"); });
    const start = vi.fn(() => () => {});
    replaceInstance(win, "page", start);
    expect(start).toHaveBeenCalledTimes(1);
  });
});

it("installing the player responder twice answers once", async () => {
  const win = new JSDOM('<div id="movie_player"></div>', { url: "https://www.youtube.com/watch?v=a" }).window as any;
  installPlayerDataResponder(win);
  installPlayerDataResponder(win);
  const replies: unknown[] = [];
  win.addEventListener("message", (e: MessageEvent) => { if (e.data?.source === "companion-main") replies.push(e.data); });
  win.postMessage({ source: "companion-isolated", type: "playerRequest", videoId: "a" }, "*");
  await new Promise((r) => setTimeout(r, 30));
  expect(replies).toHaveLength(1);
});
