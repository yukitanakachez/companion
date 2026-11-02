import { describe, expect, it, vi } from "vitest";
import { installPlayerDataResponder, readPlayerData, requestPlayerData } from "../src/content/youtube/player-data";
import { domFrom } from "./helpers/fixtures";

const ID = "abc123XYZ00";
const U = `https://www.youtube.com/watch?v=${ID}`;
const response = (videoId: string) => ({
  videoDetails: { videoId, title: "T " + videoId, author: "Math Channel", lengthSeconds: "1450" },
  captions: { playerCaptionsTracklistRenderer: { captionTracks: [{ baseUrl: "https://www.youtube.com/api/timedtext?v=1", languageCode: "en", kind: "asr", name: { simpleText: "English" } }] } },
});
const page = () => domFrom('<!doctype html><body><div id="movie_player"></div></body>', U).window as any;

describe("readPlayerData", () => {
  it("stale ytInitialPlayerResponse is ignored", () => {
    const win = page();
    win.ytInitialPlayerResponse = response("OLDOLDOLD00");
    expect(readPlayerData(win, ID)).toBeNull();
    win.document.getElementById("movie_player").getPlayerResponse = () => response(ID);
    expect(readPlayerData(win, ID)).toEqual({
      videoId: ID, title: "T " + ID, author: "Math Channel", lengthSeconds: 1450,
      captionTracks: [{ baseUrl: "https://www.youtube.com/api/timedtext?v=1", languageCode: "en", kind: "asr", name: "English" }],
    });
  });
  it("falls back to a matching ytInitialPlayerResponse", () => {
    const win = page();
    win.document.getElementById("movie_player").getPlayerResponse = () => response("OLDOLDOLD00");
    win.ytInitialPlayerResponse = response(ID);
    expect(readPlayerData(win, ID)?.videoId).toBe(ID);
  });
  it("no captions block gives an empty track list", () => {
    const win = page();
    win.ytInitialPlayerResponse = { videoDetails: { videoId: ID, title: "T", author: "A", lengthSeconds: "1" } };
    expect(readPlayerData(win, ID)?.captionTracks).toEqual([]);
  });
});

describe("responder", () => {
  it("responder answers only tagged requests", async () => {
    const win = page();
    win.ytInitialPlayerResponse = response(ID);
    installPlayerDataResponder(win);
    const replies: any[] = [];
    win.addEventListener("message", (e: MessageEvent) => { if (e.data?.source === "companion-main") replies.push(e.data); });
    win.postMessage({ type: "playerRequest", videoId: ID }, "*");
    win.postMessage({ source: "somebody", type: "playerRequest", videoId: ID }, "*");
    await new Promise((r) => setTimeout(r, 20));
    expect(replies).toEqual([]);
    win.postMessage({ source: "companion-isolated", type: "playerRequest", videoId: ID }, "*");
    await vi.waitFor(() => expect(replies).toHaveLength(1));
    expect(replies[0]).toMatchObject({ type: "playerData", videoId: ID, data: { videoId: ID } });
  });
  it("requestPlayerData retries until the player has the video", async () => {
    const win = page();
    installPlayerDataResponder(win);
    const p = requestPlayerData(win, ID);
    setTimeout(() => { win.ytInitialPlayerResponse = response(ID); }, 100);
    expect((await p)?.videoId).toBe(ID);
  });
  it("requestPlayerData gives up with null at the timeout", async () => {
    expect(await requestPlayerData(page(), ID, 50)).toBeNull();
  });
  it("ignores replies for another video", async () => {
    const win = page();
    const p = requestPlayerData(win, ID, 60);
    win.postMessage({ source: "companion-main", type: "playerData", videoId: "other", data: { videoId: "other" } }, "*");
    expect(await p).toBeNull();
  });
});
