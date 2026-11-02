import { afterEach, describe, expect, it, vi } from "vitest";
import { TRANSCRIPT_SELECTORS, chooseTrack, loadTranscript, openPanelAndScrape, parseJson3, parseTimestamp, scrapeTranscriptPanel } from "../src/content/youtube/transcript";
import { contractFixture, domFrom, localFixtureText } from "./helpers/fixtures";

const json3Sample = JSON.parse(localFixtureText("youtube/json3-sample.json"));
const U = "https://www.youtube.com/watch?v=abc123XYZ00";
const track = { baseUrl: "https://www.youtube.com/api/timedtext?v=abc", languageCode: "en" };
const segs = [{ start: 1, duration: 2, text: "from the panel" }];

describe("chooseTrack", () => {
  it("prefers manual English over auto English over first", () => {
    const es = { baseUrl: "es", languageCode: "es" };
    const auto = { baseUrl: "auto", languageCode: "en", kind: "asr" };
    const manual = { baseUrl: "man", languageCode: "en-GB" };
    expect(chooseTrack([es, auto, manual])).toBe(manual);
    expect(chooseTrack([es, auto])).toBe(auto);
    expect(chooseTrack([es])).toBe(es);
    expect(chooseTrack([])).toBeNull();
  });
});

describe("parseJson3", () => {
  it("reproduces the contract fixture's transcript", () =>
    expect(parseJson3(json3Sample)).toEqual(contractFixture("ext-tabContext-youtube.json").context.youtube.transcript));
  it("parses a 3-hour json3 transcript", () => {
    const events = Array.from({ length: 4000 }, (_, i) => ({ tStartMs: i * 2700, dDurationMs: 2700, segs: [{ utf8: `line ${i}` }] }));
    const t0 = performance.now();
    const out = parseJson3({ events });
    expect(performance.now() - t0).toBeLessThan(500);
    expect(out).toHaveLength(4000);
    expect(out[3999].start).toBe(10797.3);
  });
  it("sorts by start and tolerates garbage", () => {
    expect(parseJson3({ events: [{ tStartMs: 2000, segs: [{ utf8: "b" }] }, { tStartMs: 1000, segs: [{ utf8: "a" }] }] }).map((s) => s.text)).toEqual(["a", "b"]);
    expect(parseJson3(null)).toEqual([]);
    expect(parseJson3({ events: "no" })).toEqual([]);
  });
});

it("parseTimestamp", () => {
  expect(parseTimestamp("1:02:05")).toBe(3725);
  expect(parseTimestamp("9:41")).toBe(581);
  expect(parseTimestamp("0:00")).toBe(0);
  expect(parseTimestamp("abc")).toBeNull();
});

it("scrapes the transcript panel", () => {
  const out = scrapeTranscriptPanel(domFrom("youtube/transcript-panel.html", U).window.document);
  expect(out.map((s) => s.start)).toEqual([0, 5, 3725]);
  expect(out.map((s) => s.duration)).toEqual([5, 3720, 0]);
  expect(out[0].text).toBe("welcome back");
});

describe("loadTranscript", () => {
  afterEach(() => vi.useRealTimers());
  const panel = vi.fn(async () => segs);

  it('fetches baseUrl + "&fmt=json3"', async () => {
    const fetchFn = vi.fn(async () => new Response(JSON.stringify(json3Sample)));
    const r = await loadTranscript(track, { fetch: fetchFn as unknown as typeof fetch, openPanelAndScrape: panel });
    expect(fetchFn.mock.calls[0]).toContain(track.baseUrl + "&fmt=json3");
    expect(r.source).toBe("json3");
    expect(r.status).toBe("available");
    expect(r.segments).toHaveLength(3);
  });
  it("empty json3 body falls back to the transcript panel", async () => {
    const r = await loadTranscript(track, { fetch: async () => new Response("", { status: 200 }), openPanelAndScrape: async () => segs });
    expect(r).toEqual({ status: "available", segments: segs, source: "panel" });
  });
  it("fetch rejection, a 500 or zero events also fall back to the panel", async () => {
    const want = { status: "available", segments: segs, source: "panel" };
    const rejected = (async () => { throw new Error("net"); }) as typeof fetch;
    expect(await loadTranscript(track, { fetch: rejected, openPanelAndScrape: async () => segs })).toEqual(want);
    expect(await loadTranscript(track, { fetch: async () => new Response("{}", { status: 500 }), openPanelAndScrape: async () => segs })).toEqual(want);
    expect(await loadTranscript(track, { fetch: async () => new Response('{"events":[]}'), openPanelAndScrape: async () => segs })).toEqual(want);
  });
  it("panel never renders → unavailable", async () => {
    vi.useFakeTimers();
    const doc = domFrom("<!doctype html><body></body>", U).window.document;
    const p = loadTranscript(track, { fetch: async () => new Response(""), openPanelAndScrape: () => openPanelAndScrape(doc) });
    await vi.advanceTimersByTimeAsync(5000);
    expect(await p).toEqual({ status: "unavailable", segments: [], source: "none" });
  });
  it("a throwing panel → unavailable, never stuck", async () => {
    const r = await loadTranscript(track, { fetch: async () => new Response(""), openPanelAndScrape: async () => { throw new Error("dom"); } });
    expect(r.status).toBe("unavailable");
  });
  it("no track → unavailable without fetch or panel", async () => {
    const fetchFn = vi.fn();
    const p = vi.fn();
    expect(await loadTranscript(null, { fetch: fetchFn as unknown as typeof fetch, openPanelAndScrape: p }))
      .toEqual({ status: "unavailable", segments: [], source: "none" });
    expect(fetchFn).not.toHaveBeenCalled();
    expect(p).not.toHaveBeenCalled();
  });
});

describe("openPanelAndScrape", () => {
  const S = TRANSCRIPT_SELECTORS;
  const panelHtml = localFixtureText("youtube/transcript-panel.html").match(/<div id="panel">[\s\S]*<\/div>/)![0];

  it("scrapes immediately if segments already exist, without clicking", async () => {
    const doc = domFrom("youtube/transcript-panel.html", U).window.document;
    expect(await openPanelAndScrape(doc)).toHaveLength(3);
  });
  it("clicks Show transcript, waits for segments, closes the panel", async () => {
    const doc = domFrom(`<!doctype html><body><ytd-video-description-transcript-section-renderer><button>Show transcript</button></ytd-video-description-transcript-section-renderer><div id="host"></div>
      <ytd-engagement-panel-section-list-renderer target-id="engagement-panel-searchable-transcript"><div id="visibility-button"><button>x</button></div></ytd-engagement-panel-section-list-renderer></body>`, U).window.document;
    const show = doc.querySelector<HTMLElement>(S.showButton)!;
    const close = doc.querySelector<HTMLElement>(S.closePanel)!;
    const closed = vi.fn();
    close.addEventListener("click", closed);
    show.addEventListener("click", () => setTimeout(() => { doc.getElementById("host")!.innerHTML = panelHtml; }, 10));
    const out = await openPanelAndScrape(doc);
    expect(out).toHaveLength(3);
    expect(closed).toHaveBeenCalledTimes(1);
  });
  it("expands the description first when the button isn't there yet", async () => {
    const doc = domFrom(`<!doctype html><body><div id="description-inline-expander"><tp-yt-paper-button id="expand">more</tp-yt-paper-button></div><div id="slot"></div></body>`, U).window.document;
    const expanded = vi.fn(() => {
      doc.getElementById("slot")!.innerHTML = `<ytd-video-description-transcript-section-renderer><button>Show</button></ytd-video-description-transcript-section-renderer>`;
      doc.querySelector<HTMLElement>(S.showButton)!.addEventListener("click", () => { doc.getElementById("slot")!.insertAdjacentHTML("beforeend", panelHtml); });
    });
    doc.querySelector(S.expandDescription)!.addEventListener("click", expanded);
    expect(await openPanelAndScrape(doc)).toHaveLength(3);
    expect(expanded).toHaveBeenCalledTimes(1);
  });
});

describe("openPanelAndScrape with rows already in the DOM", () => {
  const S = TRANSCRIPT_SELECTORS;
  const row = (t: string, text: string) => `<ytd-transcript-segment-renderer><div class="segment-timestamp">${t}</div><div class="segment-text">${text}</div></ytd-transcript-segment-renderer>`;
  const shell = (rows: string) => domFrom(`<!doctype html><body><div id="host">${rows}</div><ytd-video-description-transcript-section-renderer><button>Show</button></ytd-video-description-transcript-section-renderer></body>`, U).window.document;
  afterEach(() => vi.useRealTimers());

  it("waits for leftover rows to be replaced rather than returning them at once", async () => {
    const doc = shell(row("0:00", "video A"));
    const p = openPanelAndScrape(doc, 5000, 200);
    doc.getElementById("host")!.innerHTML = row("0:00", "video B");
    expect((await p)[0].text).toBe("video B");
  });
  it("accepts rows that stay unchanged through the settle period", async () => {
    vi.useFakeTimers();
    const doc = shell(row("0:00", "mine"));
    let out: unknown;
    void openPanelAndScrape(doc, 5000, 1000).then((r) => { out = r; });
    await vi.advanceTimersByTimeAsync(999);
    expect(out).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1);
    expect((out as any[])[0].text).toBe("mine");
  });
  it("never returns the rows it returned for the previous video", async () => {
    vi.useFakeTimers();
    const doc = shell(row("0:00", "video A"));
    const first = openPanelAndScrape(doc, 5000, 10);
    await vi.advanceTimersByTimeAsync(10);
    expect((await first)[0].text).toBe("video A");
    const second = openPanelAndScrape(doc, 5000, 10);
    await vi.advanceTimersByTimeAsync(5000);
    expect(await second).toEqual([]);
  });
  it("rows cleared by navigation lead to clicking Show transcript", async () => {
    const doc = shell(row("0:00", "video A"));
    const show = vi.fn(() => { doc.getElementById("host")!.innerHTML = row("0:00", "video B"); });
    doc.querySelector(S.showButton)!.addEventListener("click", show);
    const p = openPanelAndScrape(doc, 5000, 500);
    doc.getElementById("host")!.innerHTML = "";
    expect((await p)[0].text).toBe("video B");
    expect(show).toHaveBeenCalledTimes(1);
  });
});
