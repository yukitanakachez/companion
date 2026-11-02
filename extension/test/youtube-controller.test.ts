import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { JSDOM } from "jsdom";
import { YouTubeController, readChapter, videoIdFromUrl, type YouTubeDeps } from "../src/content/youtube/controller";
import type { PlayerData } from "../src/content/youtube/player-data";
import type { TranscriptResult } from "../src/content/youtube/transcript";
import { contractFixture, domFrom } from "./helpers/fixtures";
import { fakeDeps } from "./helpers/content-deps";

const ID = "abc123XYZ00";
const U = `https://www.youtube.com/watch?v=${ID}`;
const HTML = `<!doctype html><html><head><title>Solving - YouTube</title></head><body>
<h1 class="ytd-watch-metadata"> Solving Quadratics </h1><div id="owner"><ytd-channel-name><a>Math Channel</a></ytd-channel-name></div>
<div class="ytp-chapter-title-content">Finding the roots</div>
<div id="movie_player"><video></video></div></body></html>`;
const segs = contractFixture("ext-tabContext-youtube.json").context.youtube.transcript;
const data = (videoId: string): PlayerData => ({ videoId, title: "Player title", author: "Player author", lengthSeconds: 1450,
  captionTracks: [{ baseUrl: "https://www.youtube.com/api/timedtext?v=" + videoId, languageCode: "en" }] });
const ok: TranscriptResult = { status: "available", segments: segs, source: "json3" };

function setup(over: Partial<YouTubeDeps> = {}, blocked = false, html = HTML, url = U) {
  const dom = domFrom(html, url);
  const f = fakeDeps(dom, blocked);
  const deps: YouTubeDeps = {
    ...f.deps,
    requestPlayerData: vi.fn(async (id: string) => data(id)),
    loadTranscript: vi.fn(async () => ok),
    ...over,
  };
  const video = dom.window.document.querySelector("video");
  return { ...f, dom, deps, video: video as HTMLVideoElement, c: new YouTubeController(deps) };
}
const nav = (dom: JSDOM, url?: string) => {
  if (url) dom.window.history.pushState({}, "", url);
  dom.window.document.dispatchEvent(new dom.window.Event("yt-navigate-finish"));
};
const fire = (dom: JSDOM, v: HTMLVideoElement, type: string) => v.dispatchEvent(new dom.window.Event(type));
const parts = (sent: any[]) => sent.filter((m) => m.kind === "contextPart");
const playheads = (sent: any[]) => sent.filter((m) => m.kind === "playhead");

describe("helpers", () => {
  it("videoIdFromUrl accepts /watch?v= only", () => {
    expect(videoIdFromUrl(U)).toBe(ID);
    expect(videoIdFromUrl("https://www.youtube.com/")).toBeNull();
    expect(videoIdFromUrl("https://www.youtube.com/shorts/abc")).toBeNull();
    expect(videoIdFromUrl("https://www.youtube.com/watch")).toBeNull();
  });
  it("chapter from .ytp-chapter-title-content, null when empty", () => {
    const yes = domFrom(HTML, U).window.document;
    expect(readChapter(yes)).toBe("Finding the roots");
    yes.querySelector(".ytp-chapter-title-content")!.textContent = "   ";
    expect(readChapter(yes)).toBeNull();
    expect(readChapter(domFrom("<!doctype html><body>", U).window.document)).toBeNull();
  });
});

describe("YouTubeController", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("sends loading then available parts, once per video", async () => {
    const { c, sent, dom } = setup();
    await c.start();
    const [p1, p2] = parts(sent) as any[];
    expect(p1.part.youtube).toMatchObject({ videoId: ID, transcriptStatus: "loading", transcript: [] });
    expect(p2.part.youtube).toMatchObject({ videoId: ID, transcriptStatus: "available", transcript: segs,
      title: "Solving Quadratics", channel: "Math Channel", chapter: "Finding the roots", durationSeconds: 1450 });
    expect(Object.keys(p2.part.youtube).sort()).toEqual(Object.keys(contractFixture("ext-tabContext-youtube.json").context.youtube).sort());
    expect(p2).toMatchObject({ pageUrl: U, pageTitle: "Solving - YouTube" });
    nav(dom);
    await vi.advanceTimersByTimeAsync(0);
    expect(parts(sent)).toHaveLength(2);
    c.stop();
  });
  it("falls back to player title and author when the DOM has none", async () => {
    const { c, sent } = setup({}, false, '<!doctype html><body><video></video></body>');
    await c.start();
    expect((parts(sent)[1] as any).part.youtube).toMatchObject({ title: "Player title", channel: "Player author" });
    c.stop();
  });
  it("late transcript for the previous video is discarded", async () => {
    let releaseA: (r: TranscriptResult) => void = () => {};
    const loadTranscript = vi.fn((t: any) => t.baseUrl.endsWith("=" + ID)
      ? new Promise<TranscriptResult>((r) => { releaseA = r; }) : Promise.resolve(ok));
    const { c, sent, dom } = setup({ loadTranscript });
    const started = c.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(loadTranscript).toHaveBeenCalledTimes(1);
    const B = "BBBBBBBBBBB";
    nav(dom, `/watch?v=${B}`);
    await vi.advanceTimersByTimeAsync(0);
    const count = parts(sent).length;
    releaseA(ok);
    await started;
    await vi.advanceTimersByTimeAsync(0);
    expect(parts(sent).slice(count).filter((m: any) => m.part.youtube.videoId === ID)).toEqual([]);
    expect(parts(sent).at(-1)).toMatchObject({ part: { youtube: { videoId: B, transcriptStatus: "available" } } });
    expect(c.current()?.videoId).toBe(B);
    c.stop();
  });
  it("a transcript landing after the URL moved on, before the navigate event, is discarded", async () => {
    let releaseA: (r: TranscriptResult) => void = () => {};
    const { c, sent, dom } = setup({ loadTranscript: vi.fn(() => new Promise<TranscriptResult>((r) => { releaseA = r; })) });
    const started = c.start();
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/watch?v=BBBBBBBBBBB");
    releaseA(ok);
    await started;
    expect(parts(sent)).toHaveLength(1);
    c.stop();
  });
  it("loader failure ends at unavailable, never stuck at loading", async () => {
    const { c, sent } = setup({ requestPlayerData: vi.fn(async () => { throw new Error("x"); }) });
    await c.start();
    expect(parts(sent).at(-1)).toMatchObject({ part: { youtube: { transcriptStatus: "unavailable", transcript: [] } } });
    c.stop();
  });
  it("no player data still resolves through the loader with no track", async () => {
    const loadTranscript = vi.fn(async (): Promise<TranscriptResult> => ({ status: "unavailable", segments: [], source: "none" }));
    const { c, sent } = setup({ requestPlayerData: vi.fn(async () => null), loadTranscript });
    await c.start();
    expect(loadTranscript).toHaveBeenCalledWith(null);
    expect(parts(sent).at(-1)).toMatchObject({ part: { youtube: { transcriptStatus: "unavailable" } } });
    c.stop();
  });
  it("playhead every 5 s while playing, none while paused, immediately on seeked", async () => {
    const { c, sent, dom, video } = setup();
    await c.start();
    video.currentTime = 42;
    fire(dom, video, "play");
    await vi.advanceTimersByTimeAsync(15_000);
    expect(playheads(sent)).toHaveLength(3);
    expect(playheads(sent)[0]).toEqual({ kind: "playhead", videoId: ID, playheadSeconds: video.currentTime, chapter: "Finding the roots" });
    fire(dom, video, "pause");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(playheads(sent)).toHaveLength(3);
    fire(dom, video, "seeked");
    expect(playheads(sent)).toHaveLength(4);
    c.stop();
  });
  it("10 minutes of playback: 120 playheads, no context parts", async () => {
    const { c, sent, dom, video } = setup();
    await c.start();
    const before = parts(sent).length;
    fire(dom, video, "play");
    await vi.advanceTimersByTimeAsync(600_000);
    expect(playheads(sent)).toHaveLength(120);
    expect(parts(sent)).toHaveLength(before);
    c.stop();
  });
  it("repeated play events run one timer", async () => {
    const { c, sent, dom, video } = setup();
    await c.start();
    fire(dom, video, "play");
    fire(dom, video, "play");
    await vi.advanceTimersByTimeAsync(5000);
    expect(playheads(sent)).toHaveLength(1);
    c.stop();
  });
  it("blocked host: nothing posted to the MAIN world, nothing sent", async () => {
    const { c, sent, deps, dom, video } = setup({}, true);
    await c.start();
    fire(dom, video, "seeked");
    expect(deps.requestPlayerData).not.toHaveBeenCalled();
    expect(sent).toEqual([]);
    c.stop();
  });
  it("non-watch page sends no youtube part", async () => {
    const { c, sent } = setup({}, false, HTML, "https://www.youtube.com/feed/subscriptions");
    await c.start();
    expect(sent).toEqual([]);
    c.stop();
  });
  it("leaving a video for a non-watch page stops its playheads", async () => {
    const { c, sent, dom, video } = setup();
    await c.start();
    nav(dom, "/feed/subscriptions");
    await vi.advanceTimersByTimeAsync(0);
    expect(c.current()).toBeNull();
    fire(dom, video, "seeked");
    expect(playheads(sent)).toEqual([]);
    c.stop();
  });
  it("extractNow re-sends the cached context without refetching", async () => {
    const { c, sent, deps, extractNow } = setup();
    await c.start();
    const before = parts(sent).length;
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(parts(sent)).toHaveLength(before + 1);
    expect(parts(sent).at(-1)).toMatchObject({ part: { youtube: { transcriptStatus: "available" } } });
    expect(deps.loadTranscript).toHaveBeenCalledTimes(1);
    c.stop();
  });
  it("extractNow on a newly blocked host sends nothing", async () => {
    const { c, sent, deps, extractNow } = setup();
    await c.start();
    const before = sent.length;
    (deps.askBlocked as any).mockResolvedValue(true);
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(before);
    c.stop();
  });
});

describe("YouTubeController after a discarded load", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  it("returning to the video reloads it instead of staying at loading", async () => {
    let releaseA: (r: TranscriptResult) => void = () => {};
    const load = vi.fn(() => new Promise<TranscriptResult>((r) => { releaseA = r; }));
    const { c, sent, dom } = setup({ loadTranscript: load });
    const started = c.start();
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/watch?v=BBBBBBBBBBB");
    releaseA(ok);
    await started;
    load.mockImplementation(async () => ok);
    nav(dom, `/watch?v=${ID}`);
    await vi.advanceTimersByTimeAsync(0);
    expect(parts(sent).at(-1)).toMatchObject({ part: { youtube: { videoId: ID, transcriptStatus: "available" } } });
    c.stop();
  });
});
