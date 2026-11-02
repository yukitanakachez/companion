import type { YouTubeContext } from "../../../../contracts/ts/protocol";
import type { ContentDeps } from "../content-deps";
import type { PlayerData } from "./player-data";
import { chooseTrack, type CaptionTrack, type TranscriptResult } from "./transcript";

export const PLAYHEAD_INTERVAL_MS = 5000;

export function videoIdFromUrl(url: string): string | null {
  try {
    const u = new URL(url);
    return u.pathname === "/watch" ? u.searchParams.get("v") || null : null;
  } catch {
    return null;
  }
}
export function readChapter(doc: Document): string | null {
  return doc.querySelector(".ytp-chapter-title-content")?.textContent?.trim() || null;
}

export interface YouTubeDeps extends ContentDeps {
  requestPlayerData(videoId: string): Promise<PlayerData | null>;
  loadTranscript(track: CaptionTrack | null): Promise<TranscriptResult>;
}

export class YouTubeController {
  private generation = 0;
  private context: YouTubeContext | null = null;
  private ticker: ReturnType<typeof setInterval> | null = null;
  private stopped = false;
  private readonly onNavigateEvent = () => void this.onNavigate();
  private readonly onPlay = () => this.startTicker();
  private readonly onHalt = () => this.stopTicker();
  private readonly onSeeked = () => this.sendPlayhead();

  constructor(private readonly deps: YouTubeDeps) {}

  /** Guard, first onNavigate, then binds yt-navigate-finish, video events and extractNow. */
  async start(): Promise<void> {
    const { doc } = this.deps;
    // Media events don't bubble but do pass through capture, which also survives the player replacing its <video>.
    doc.addEventListener("yt-navigate-finish", this.onNavigateEvent);
    doc.addEventListener("play", this.onPlay, true);
    doc.addEventListener("pause", this.onHalt, true);
    doc.addEventListener("ended", this.onHalt, true);
    doc.addEventListener("seeked", this.onSeeked, true);
    this.deps.onExtractNow(() => void this.onExtractNow());
    const video = this.video();
    await this.onNavigate();
    if (video && !video.paused && !video.ended) this.startTicker();
  }

  async onNavigate(): Promise<void> {
    const { deps } = this;
    if (await deps.askBlocked(this.href())) {
      this.generation++;
      this.context = null;
      return;
    }
    if (this.stopped) return;
    const videoId = videoIdFromUrl(this.href());
    if (videoId && this.context?.videoId === videoId) return; // Same video: its transcript is loaded or on the way.
    const generation = ++this.generation;
    if (!videoId) {
      this.context = null;
      return;
    }
    this.context = {
      videoId,
      title: this.domTitle() ?? "",
      channel: this.domChannel(),
      chapter: readChapter(deps.doc),
      playheadSeconds: this.video()?.currentTime ?? 0,
      durationSeconds: this.domDuration(),
      transcriptStatus: "loading",
      transcript: [],
    };
    this.sendContext();

    let player: PlayerData | null = null;
    let result: TranscriptResult;
    try {
      player = await deps.requestPlayerData(videoId);
      if (generation !== this.generation) return;
      result = await deps.loadTranscript(player ? chooseTrack(player.captionTracks) : null);
    } catch {
      result = { status: "unavailable", segments: [], source: "none" };
    }
    // The URL check covers the gap between YouTube changing the address and its navigate event.
    if (generation !== this.generation) return;
    if (videoIdFromUrl(this.href()) !== videoId || !this.context) {
      this.context = null; // Forgotten, so coming back to this video loads it again.
      return;
    }
    this.context = {
      ...this.context,
      title: this.domTitle() ?? player?.title ?? this.context.title,
      channel: this.domChannel() ?? player?.author ?? null,
      chapter: readChapter(deps.doc),
      playheadSeconds: this.video()?.currentTime ?? this.context.playheadSeconds,
      durationSeconds: this.domDuration() ?? player?.lengthSeconds ?? null,
      transcriptStatus: result.status,
      transcript: result.segments,
    };
    this.sendContext();
  }

  current(): YouTubeContext | null {
    return this.context;
  }

  stop(): void {
    this.stopped = true;
    this.generation++;
    this.stopTicker();
    const { doc } = this.deps;
    doc.removeEventListener("yt-navigate-finish", this.onNavigateEvent);
    doc.removeEventListener("play", this.onPlay, true);
    doc.removeEventListener("pause", this.onHalt, true);
    doc.removeEventListener("ended", this.onHalt, true);
    doc.removeEventListener("seeked", this.onSeeked, true);
  }

  private async onExtractNow(): Promise<void> {
    if (!this.context) return this.onNavigate();
    if (await this.deps.askBlocked(this.href())) {
      this.generation++;
      this.context = null;
      return;
    }
    if (this.context && !this.stopped) this.sendContext();
  }

  private sendContext(): void {
    const { deps } = this;
    if (!this.context) return;
    deps.send({
      kind: "contextPart",
      pageUrl: this.href(),
      pageTitle: deps.doc.title,
      capturedAtMs: deps.now(),
      part: { youtube: this.context },
    });
  }

  private sendPlayhead(): void {
    const c = this.context;
    const video = this.video();
    if (!c || !video || videoIdFromUrl(this.href()) !== c.videoId) return;
    const chapter = readChapter(this.deps.doc);
    // Keeps the cached context current, so a re-send after a worker restart isn't minutes behind.
    this.context = { ...c, playheadSeconds: video.currentTime, chapter };
    this.deps.send({ kind: "playhead", videoId: c.videoId, playheadSeconds: video.currentTime, chapter });
  }

  private startTicker(): void {
    if (this.ticker === null) this.ticker = setInterval(() => this.sendPlayhead(), PLAYHEAD_INTERVAL_MS);
  }
  private stopTicker(): void {
    if (this.ticker !== null) clearInterval(this.ticker);
    this.ticker = null;
  }

  private href(): string {
    return this.deps.doc.location.href;
  }
  private video(): HTMLVideoElement | null {
    const { doc } = this.deps;
    return doc.querySelector<HTMLVideoElement>("#movie_player video") ?? doc.querySelector<HTMLVideoElement>("video");
  }
  private domTitle(): string | null {
    return this.deps.doc.querySelector("h1.ytd-watch-metadata")?.textContent?.trim() || null;
  }
  private domChannel(): string | null {
    return this.deps.doc.querySelector("#owner ytd-channel-name a")?.textContent?.trim() || null;
  }
  private domDuration(): number | null {
    const d = this.video()?.duration;
    return d !== undefined && Number.isFinite(d) ? d : null;
  }
}
