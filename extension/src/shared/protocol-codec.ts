import {
  PROTOCOL_VERSION,
  type AppToExtension,
  type BridgeErrorCode,
  type ExtensionToApp,
} from "../../../contracts/ts/protocol";

export type BridgeRequestMessage = Extract<AppToExtension, { type: "request" }>;

export class ProtocolError extends Error {
  constructor(readonly code: "versionMismatch" | "malformed", message: string) {
    super(message);
  }
}
export class RequestError extends Error {
  constructor(readonly code: BridgeErrorCode, message: string) {
    super(message);
  }
}

type Obj = Record<string, unknown>;
const isObj = (x: unknown): x is Obj => typeof x === "object" && x !== null && !Array.isArray(x);
const isStr = (x: unknown): x is string => typeof x === "string";
const isNum = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);
const isBool = (x: unknown): x is boolean => typeof x === "boolean";
const absent = (x: unknown): x is undefined | null => x === undefined || x === null;
const optStr = (x: unknown) => absent(x) || isStr(x);
const optNum = (x: unknown) => absent(x) || isNum(x);
const arrayOf = (x: unknown, each: (y: unknown) => boolean) => Array.isArray(x) && x.every(each);

const ERROR_CODES: readonly string[] = ["notConnected", "notFound", "downloadBlocked", "notPdf", "noViewer", "timeout",
  "blocked", "unauthorized", "versionMismatch", "internal"] satisfies BridgeErrorCode[];

const isSegment = (x: unknown) => isObj(x) && isNum(x.start) && isNum(x.duration) && isStr(x.text);
const isYouTube = (x: unknown) =>
  isObj(x) && isStr(x.videoId) && isStr(x.title) && optStr(x.channel) && optStr(x.chapter) && isNum(x.playheadSeconds) &&
  optNum(x.durationSeconds) && (x.transcriptStatus === "loading" || x.transcriptStatus === "available" || x.transcriptStatus === "unavailable") &&
  arrayOf(x.transcript, isSegment);
const isMath = (x: unknown) => isObj(x) && (x.format === "latex" || x.format === "mathml") && isStr(x.source);
const isPage = (x: unknown) => isObj(x) && isStr(x.url) && isStr(x.title) && isStr(x.visibleText) && arrayOf(x.math, isMath);
const isFile = (x: unknown) => isObj(x) && isStr(x.fileId) && isStr(x.title) && optStr(x.mimeType);
const isClassroom = (x: unknown) => isObj(x) && optStr(x.assignmentTitle) && arrayOf(x.attachments, isFile);
const isDrive = (x: unknown) => isObj(x) && isFile(x.file);
const isTabContext = (x: unknown) =>
  isObj(x) && isNum(x.tabId) && isStr(x.url) && isStr(x.title) && isNum(x.capturedAtMs) && isBool(x.blocked) &&
  (absent(x.page) || isPage(x.page)) && (absent(x.youtube) || isYouTube(x.youtube)) &&
  (absent(x.classroom) || isClassroom(x.classroom)) && (absent(x.drive) || isDrive(x.drive));
const isError = (x: unknown) => isObj(x) && isStr(x.code) && ERROR_CODES.includes(x.code) && isStr(x.message);

/** Deep check, including TabContext fields. */
export function isExtensionToApp(x: unknown): x is ExtensionToApp {
  if (!isObj(x) || x.v !== PROTOCOL_VERSION) return false;
  switch (x.type) {
    case "hello": return isStr(x.token) && isStr(x.extensionVersion) && isStr(x.browserName);
    case "tabActivated": return isNum(x.tabId) && isNum(x.windowId) && isStr(x.url) && isStr(x.title);
    case "tabContext": return isTabContext(x.context);
    case "youtubePlayhead": return isNum(x.tabId) && isStr(x.videoId) && isNum(x.playheadSeconds) && optStr(x.chapter);
    case "tabClosed": return isNum(x.tabId);
    case "response": return isStr(x.id) && isBool(x.ok) && (absent(x.error) || isError(x.error));
    case "progress": return isStr(x.id) && isStr(x.step);
    default: return false;
  }
}

function isRequestParams(method: unknown, p: unknown): boolean {
  if (!isObj(p)) return false;
  switch (method) {
    case "getTabContext": return p.tabId === null || isNum(p.tabId);
    case "fetchDrivePdf": return isStr(p.fileId);
    case "viewerInfo": return isNum(p.tabId);
    case "viewerCapturePage":
    case "viewerRestore": return isNum(p.tabId) && isNum(p.pageIndex);
    default: return false;
  }
}

export function isAppToExtension(x: unknown): x is AppToExtension {
  if (!isObj(x) || x.v !== PROTOCOL_VERSION) return false;
  switch (x.type) {
    case "helloAck": return isStr(x.appVersion);
    case "config": return isObj(x.blocklist) && arrayOf(x.blocklist.bundleIDs, isStr) && arrayOf(x.blocklist.domains, isStr);
    case "ping": return true;
    case "request": return isStr(x.id) && isRequestParams(x.method, x.params);
    default: return false;
  }
}

export function parseAppMessage(text: string): AppToExtension {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ProtocolError("malformed", "frame is not JSON");
  }
  if (isObj(value) && value.v !== PROTOCOL_VERSION) throw new ProtocolError("versionMismatch", `unsupported protocol version ${String(value.v)}`);
  if (!isAppToExtension(value)) throw new ProtocolError("malformed", "unknown or malformed message");
  return value;
}

export function encodeMessage(msg: ExtensionToApp): string {
  return JSON.stringify({ ...msg, v: PROTOCOL_VERSION });
}
export function okResponse(id: string, result: unknown): ExtensionToApp {
  return { v: PROTOCOL_VERSION, type: "response", id, ok: true, result };
}
export function errorResponse(id: string, code: BridgeErrorCode, message: string): ExtensionToApp {
  return { v: PROTOCOL_VERSION, type: "response", id, ok: false, error: { code, message } };
}
