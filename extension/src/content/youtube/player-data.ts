import type { CaptionTrack } from "./transcript";

export interface PlayerData {
  videoId: string;
  title: string;
  author: string;
  lengthSeconds: number;
  captionTracks: CaptionTrack[];
}
const RETRY_MS = 500;
const REQUEST_TIMEOUT_MS = 5000;

function fromResponse(res: any, videoId: string): PlayerData | null {
  const d = res?.videoDetails;
  if (d?.videoId !== videoId) return null;
  const tracks: any[] = res.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
  return {
    videoId,
    title: d.title ?? "",
    author: d.author ?? "",
    lengthSeconds: Number(d.lengthSeconds) || 0,
    captionTracks: tracks.map((t) => ({
      baseUrl: t.baseUrl,
      languageCode: t.languageCode,
      ...(t.kind ? { kind: t.kind } : {}),
      ...(t.name?.simpleText ? { name: t.name.simpleText } : {}),
    })),
  };
}

/** movie_player.getPlayerResponse() first, then window.ytInitialPlayerResponse; null unless the video id matches. */
export function readPlayerData(win: Window, videoId: string): PlayerData | null {
  const player = win.document.getElementById("movie_player") as any;
  let live: unknown = null;
  try {
    live = player?.getPlayerResponse?.();
  } catch {
    // Player not ready.
  }
  return fromResponse(live, videoId) ?? fromResponse((win as any).ytInitialPlayerResponse, videoId);
}

/** MAIN world. Answers requests only; it never initiates a message. */
export function installPlayerDataResponder(win: Window): void {
  const flagged = win as unknown as { __companionPlayerResponder?: boolean };
  if (flagged.__companionPlayerResponder) return;
  flagged.__companionPlayerResponder = true;
  win.addEventListener("message", (ev: MessageEvent) => {
    if (ev.source && ev.source !== win) return;
    const m = ev.data;
    if (m?.source !== "companion-isolated" || m.type !== "playerRequest" || typeof m.videoId !== "string") return;
    win.postMessage({ source: "companion-main", type: "playerData", videoId: m.videoId, data: readPlayerData(win, m.videoId) }, win.location.origin);
  });
}

/** Isolated world. Retries every 500 ms because the player fills in after navigation. */
export function requestPlayerData(win: Window, videoId: string, timeoutMs = REQUEST_TIMEOUT_MS): Promise<PlayerData | null> {
  return new Promise((resolve) => {
    const ask = () => win.postMessage({ source: "companion-isolated", type: "playerRequest", videoId }, win.location.origin);
    const finish = (data: PlayerData | null) => {
      clearInterval(retry);
      clearTimeout(timer);
      win.removeEventListener("message", onMessage);
      resolve(data);
    };
    const onMessage = (ev: MessageEvent) => {
      if (ev.source && ev.source !== win) return;
      const m = ev.data;
      if (m?.source === "companion-main" && m.type === "playerData" && m.videoId === videoId && m.data) finish(m.data);
    };
    win.addEventListener("message", onMessage);
    const retry = setInterval(ask, RETRY_MS);
    const timer = setTimeout(() => finish(null), timeoutMs);
    ask();
  });
}
