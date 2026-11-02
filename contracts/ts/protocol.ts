// TypeScript mirror of the bridge wire protocol. See ../bridge-protocol.md.
// The JSON in ../fixtures is the source of truth; Swift lives in Sources/CompanionCore/Bridge.swift.
// No runtime code besides constants.

export const PROTOCOL_VERSION = 1;
export const PORTS = [47823, 47824, 47825, 47826, 47827];
export const MAX_CHUNK_BYTES = 1048576;
export const PING_INTERVAL_MS = 20000;
export const CLOSE_UNAUTHORIZED = 4001;
export const CLOSE_VERSION_MISMATCH = 4002;
export const HELLO_TIMEOUT_MS = 5000;
/** Exactly `BlocklistConfig.starter.domains`, same order. */
export const STARTER_BLOCKED_DOMAINS = [
  "1password.com",
  "bitwarden.com",
  "lastpass.com",
  "dashlane.com",
  "chase.com",
  "bankofamerica.com",
  "wellsfargo.com",
  "citi.com",
  "capitalone.com",
  "usbank.com",
  "pnc.com",
  "schwab.com",
  "fidelity.com",
  "paypal.com",
  "venmo.com",
  "discord.com",
  "web.whatsapp.com",
  "messages.google.com",
];

// Payloads

export interface TranscriptSegment {
  start: number;
  duration: number;
  text: string;
}

export type TranscriptStatus = "loading" | "available" | "unavailable";

export interface YouTubeContext {
  videoId: string;
  title: string;
  channel?: string | null;
  chapter?: string | null;
  playheadSeconds: number;
  durationSeconds?: number | null;
  transcriptStatus: TranscriptStatus;
  /** Empty unless transcriptStatus is "available". */
  transcript: TranscriptSegment[];
}

export interface MathSnippet {
  format: "latex" | "mathml";
  source: string;
}

export interface WebPageContext {
  url: string;
  title: string;
  visibleText: string;
  math: MathSnippet[];
}

export interface DriveFileRef {
  fileId: string;
  title: string;
  mimeType?: string | null;
}

export interface ClassroomContext {
  assignmentTitle?: string | null;
  attachments: DriveFileRef[];
}

export interface DriveViewerContext {
  file: DriveFileRef;
}

export interface TabContext {
  tabId: number;
  url: string;
  title: string;
  capturedAtMs: number;
  blocked: boolean;
  page?: WebPageContext | null;
  youtube?: YouTubeContext | null;
  classroom?: ClassroomContext | null;
  drive?: DriveViewerContext | null;
}

export interface BlocklistConfig {
  bundleIDs: string[];
  domains: string[];
}

export type BridgeErrorCode =
  | "notConnected"
  | "notFound"
  | "downloadBlocked"
  | "notPdf"
  | "noViewer"
  | "timeout"
  | "blocked"
  | "unauthorized"
  | "versionMismatch"
  | "internal";

export interface BridgeError {
  code: BridgeErrorCode;
  message: string;
}

// Results

export interface TabContextResult {
  context?: TabContext | null;
}

export interface DrivePdfResult {
  fileId: string;
  title: string;
  byteLength: number;
}

export interface ViewerInfo {
  pageCount: number;
  /** 0-based. */
  currentIndex: number;
}

export interface ViewerPageResult {
  pageIndex: number;
  pngBase64: string;
}

/** Sent as `{}` or null. */
export type EmptyResult = Record<string, never> | null;

export interface BinaryFrameHeader {
  id: string;
  seq: number;
  last: boolean;
}

// Extension → app

export interface HelloMessage {
  v: 1;
  type: "hello";
  token: string;
  extensionVersion: string;
  browserName: string;
}

export interface TabActivatedMessage {
  v: 1;
  type: "tabActivated";
  tabId: number;
  windowId: number;
  url: string;
  title: string;
}

export interface TabContextMessage {
  v: 1;
  type: "tabContext";
  context: TabContext;
}

export interface YouTubePlayheadMessage {
  v: 1;
  type: "youtubePlayhead";
  tabId: number;
  videoId: string;
  playheadSeconds: number;
  chapter?: string | null;
}

export interface TabClosedMessage {
  v: 1;
  type: "tabClosed";
  tabId: number;
}

export interface BridgeResponse {
  v: 1;
  type: "response";
  id: string;
  ok: boolean;
  result?: unknown;
  error?: BridgeError | null;
}

export interface ProgressMessage {
  v: 1;
  type: "progress";
  id: string;
  step: string;
}

export type ExtensionToApp =
  | HelloMessage
  | TabActivatedMessage
  | TabContextMessage
  | YouTubePlayheadMessage
  | TabClosedMessage
  | BridgeResponse
  | ProgressMessage;

// App → extension

export interface HelloAckMessage {
  v: 1;
  type: "helloAck";
  appVersion: string;
}

export interface ConfigMessage {
  v: 1;
  type: "config";
  blocklist: BlocklistConfig;
}

interface RequestEnvelope {
  v: 1;
  type: "request";
  id: string;
}

export interface GetTabContextRequest extends RequestEnvelope {
  method: "getTabContext";
  params: { tabId: number | null };
}

export interface FetchDrivePdfRequest extends RequestEnvelope {
  method: "fetchDrivePdf";
  params: { fileId: string };
}

export interface ViewerInfoRequest extends RequestEnvelope {
  method: "viewerInfo";
  params: { tabId: number };
}

export interface ViewerCapturePageRequest extends RequestEnvelope {
  method: "viewerCapturePage";
  params: { tabId: number; pageIndex: number };
}

export interface ViewerRestoreRequest extends RequestEnvelope {
  method: "viewerRestore";
  params: { tabId: number; pageIndex: number };
}

export type BridgeRequest =
  | GetTabContextRequest
  | FetchDrivePdfRequest
  | ViewerInfoRequest
  | ViewerCapturePageRequest
  | ViewerRestoreRequest;

export interface PingMessage {
  v: 1;
  type: "ping";
}

export type AppToExtension = HelloAckMessage | ConfigMessage | BridgeRequest | PingMessage;
