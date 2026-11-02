import type { TranscriptSegment, YouTubeContext } from "../../../../contracts/ts/protocol";

/** "asr" kind = auto-generated. */
export interface CaptionTrack {
  baseUrl: string;
  languageCode: string;
  kind?: string;
  name?: string;
}
export type TranscriptResult = { status: YouTubeContext["transcriptStatus"]; segments: TranscriptSegment[]; source: "json3" | "panel" | "none" };

/** The one place to change when YouTube's DOM changes. */
export const TRANSCRIPT_SELECTORS = {
  segment: "ytd-transcript-segment-renderer",
  timestamp: ".segment-timestamp",
  text: ".segment-text",
  showButton: "ytd-video-description-transcript-section-renderer button",
  expandDescription: "#description-inline-expander #expand",
  closePanel: 'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-searchable-transcript"] #visibility-button button',
};
const PANEL_TIMEOUT_MS = 5000;

const collapse = (s: string) => s.replace(/\s+/g, " ").trim();

export function chooseTrack(tracks: CaptionTrack[]): CaptionTrack | null {
  const english = tracks.filter((t) => /^en\b/i.test(t.languageCode));
  return english.find((t) => t.kind !== "asr") ?? english[0] ?? tracks[0] ?? null;
}

export function parseJson3(json: unknown): TranscriptSegment[] {
  const events = (json as { events?: unknown } | null)?.events;
  if (!Array.isArray(events)) return [];
  const out: TranscriptSegment[] = [];
  for (const e of events) {
    if (!Array.isArray(e?.segs)) continue;
    const text = collapse(e.segs.map((s: { utf8?: string }) => s.utf8 ?? "").join(""));
    if (text) out.push({ start: (e.tStartMs ?? 0) / 1000, duration: (e.dDurationMs ?? 0) / 1000, text });
  }
  return out.sort((a, b) => a.start - b.start);
}

export function parseTimestamp(text: string): number | null {
  const t = text.trim();
  if (!/^\d+(:\d{1,2}){1,2}$/.test(t)) return null;
  return t.split(":").reduce((sum, part) => sum * 60 + Number(part), 0);
}

/** Duration = next start − start; the last one is 0. */
export function scrapeTranscriptPanel(doc: Document): TranscriptSegment[] {
  const S = TRANSCRIPT_SELECTORS;
  const rows: { start: number; text: string }[] = [];
  for (const el of doc.querySelectorAll(S.segment)) {
    const start = parseTimestamp(el.querySelector(S.timestamp)?.textContent ?? "");
    const text = collapse(el.querySelector(S.text)?.textContent ?? "");
    if (start !== null && text) rows.push({ start, text });
  }
  return rows.map((r, i) => ({ start: r.start, duration: i + 1 < rows.length ? rows[i + 1].start - r.start : 0, text: r.text }));
}

export function openPanelAndScrape(doc: Document, timeoutMs = PANEL_TIMEOUT_MS): Promise<TranscriptSegment[]> {
  const S = TRANSCRIPT_SELECTORS;
  const present = scrapeTranscriptPanel(doc);
  if (present.length > 0) return Promise.resolve(present);

  return new Promise((resolve) => {
    let opened = false;
    const clickShow = () => {
      const button = doc.querySelector<HTMLElement>(S.showButton);
      if (button && !opened) {
        opened = true;
        button.click();
      }
    };
    const finish = (segments: TranscriptSegment[]) => {
      observer.disconnect();
      clearTimeout(timer);
      if (opened) doc.querySelector<HTMLElement>(S.closePanel)?.click();
      resolve(segments);
    };
    const check = () => {
      clickShow();
      const segments = scrapeTranscriptPanel(doc);
      if (segments.length > 0) finish(segments);
    };
    const Observer = (doc.defaultView as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver;
    const observer = new Observer(check);
    const timer = setTimeout(() => finish([]), timeoutMs);
    observer.observe(doc.documentElement, { childList: true, subtree: true });
    if (!doc.querySelector(S.showButton)) doc.querySelector<HTMLElement>(S.expandDescription)?.click();
    check();
  });
}

const UNAVAILABLE: TranscriptResult = { status: "unavailable", segments: [], source: "none" };

export async function loadTranscript(
  track: CaptionTrack | null,
  deps: { fetch: typeof fetch; openPanelAndScrape(): Promise<TranscriptSegment[]> },
): Promise<TranscriptResult> {
  if (!track) return UNAVAILABLE;
  try {
    const res = await deps.fetch(track.baseUrl + "&fmt=json3");
    // YouTube often answers 200 with an empty body, so anything short of real segments goes to the panel.
    const segments = res.ok ? parseJson3(JSON.parse(await res.text())) : [];
    if (segments.length > 0) return { status: "available", segments, source: "json3" };
  } catch {
    // Fall through to the panel.
  }
  try {
    const segments = await deps.openPanelAndScrape();
    if (segments.length > 0) return { status: "available", segments, source: "panel" };
  } catch {
    // Fall through to unavailable.
  }
  return UNAVAILABLE;
}
