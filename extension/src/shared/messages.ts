// Extension-internal message types. These are not wire types; those come from contracts/ts/protocol.ts.
import type { ClassroomContext, DriveViewerContext, WebPageContext, YouTubeContext } from "../../../contracts/ts/protocol";

/** A field set to null clears that field. */
export type ContextPart = {
  page?: WebPageContext | null;
  youtube?: YouTubeContext | null;
  classroom?: ClassroomContext | null;
  drive?: DriveViewerContext | null;
};
export type ContentToBackground =
  | { kind: "isBlocked"; url: string } // reply: { blocked: boolean }
  | { kind: "contextPart"; pageUrl: string; pageTitle: string; capturedAtMs: number; part: ContextPart }
  | { kind: "playhead"; videoId: string; playheadSeconds: number; chapter: string | null }
  | { kind: "reconnectNow" };
export type BackgroundToContent =
  | { kind: "extractNow" }
  | { kind: "viewer"; op: "info" }
  | { kind: "viewer"; op: "scrollTo"; index: number };
export type BridgeState = "noToken" | "connecting" | "connected" | "disconnected" | "tokenRejected" | "versionMismatch";
export interface ExtensionBridgeStatus {
  state: BridgeState;
  port: number | null;
  appVersion: string | null;
  updatedAtMs: number;
}
export const STORAGE_KEYS = { pairingToken: "pairingToken", blocklist: "blocklist", bridgeStatus: "bridgeStatus" } as const;
