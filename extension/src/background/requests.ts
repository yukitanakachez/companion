import type { ExtensionToApp, TabContext, ViewerInfo, ViewerPageResult } from "../../../contracts/ts/protocol";
import { encodeBinaryFrame } from "../shared/binary-frame";
import { RequestError, errorResponse, okResponse, type BridgeRequestMessage } from "../shared/protocol-codec";
import type { BlocklistStore } from "./blocklist-store";
import type { BridgeClient } from "./bridge-client";
import { downloadDrivePdf, driveDownloadUrl } from "./drive-download";
import type { TabStore } from "./tab-store";
import type { TabTracker } from "./tab-tracker";

export const EXTRACT_NOW_TIMEOUT_MS = 250;

export interface ViewerHandler {
  info(tabId: number): Promise<ViewerInfo>;
  capturePage(requestId: string, tabId: number, pageIndex: number): Promise<ViewerPageResult>;
  restore(tabId: number, pageIndex: number): Promise<void>;
}
export interface RequestDeps {
  store: TabStore;
  tracker: TabTracker;
  blocklist: BlocklistStore;
  tabs: typeof chrome.tabs;
  client: Pick<BridgeClient, "send" | "sendBinary">;
  fetch: typeof fetch;
  viewer: ViewerHandler | null;
  now(): number;
  /** Aborts an in-flight download when the connection drops. */
  signal?: AbortSignal;
}

async function readTab(tabId: number, deps: RequestDeps): Promise<chrome.tabs.Tab> {
  try {
    return await deps.tabs.get(tabId);
  } catch {
    throw new RequestError("notFound", `No tab with id ${tabId}.`);
  }
}

async function getTabContext(requested: number | null, deps: RequestDeps): Promise<{ context: TabContext | null }> {
  // A worker that just woke may not have seen an activation yet.
  const tabId = requested ?? deps.tracker.activeTabId() ?? (await deps.tracker.announceActive());
  if (tabId === null) return { context: null };
  const tab = await readTab(tabId, deps);
  const url = tab.url ?? tab.pendingUrl ?? "";
  if (await deps.blocklist.isUrlBlocked(url)) return { context: deps.store.setBlocked(tabId, url, deps.now()) };
  const snapshot = deps.store.get(tabId);
  if (snapshot && !snapshot.blocked) return { context: snapshot };
  const fresh = deps.store.waitFor(tabId, EXTRACT_NOW_TIMEOUT_MS);
  deps.tabs.sendMessage(tabId, { kind: "extractNow" }).catch(() => {
    // No content script in that tab; the wait above ends in null.
  });
  return { context: await fresh };
}

async function fetchDrivePdf(id: string, fileId: string, deps: RequestDeps) {
  if (await deps.blocklist.isUrlBlocked(driveDownloadUrl(fileId))) throw new RequestError("blocked", "Google Drive is on the blocklist.");
  return downloadDrivePdf(
    fileId,
    (chunk, seq, last) => deps.client.sendBinary(encodeBinaryFrame({ id, seq, last }, chunk)),
    deps.fetch,
    deps.signal,
  );
}

async function viewerFor(tabId: number, deps: RequestDeps): Promise<ViewerHandler> {
  if (!deps.viewer) throw new RequestError("noViewer", "The Drive viewer fallback isn't available.");
  const tab = await readTab(tabId, deps);
  if (await deps.blocklist.isUrlBlocked(tab.url ?? "")) throw new RequestError("blocked", "This site is on the blocklist.");
  return deps.viewer;
}

async function answer(req: BridgeRequestMessage, deps: RequestDeps): Promise<unknown> {
  switch (req.method) {
    case "getTabContext":
      return getTabContext(req.params.tabId, deps);
    case "fetchDrivePdf":
      return fetchDrivePdf(req.id, req.params.fileId, deps);
    case "viewerInfo":
      return (await viewerFor(req.params.tabId, deps)).info(req.params.tabId);
    case "viewerCapturePage":
      return (await viewerFor(req.params.tabId, deps)).capturePage(req.id, req.params.tabId, req.params.pageIndex);
    case "viewerRestore":
      await (await viewerFor(req.params.tabId, deps)).restore(req.params.tabId, req.params.pageIndex);
      return {};
  }
}

/** Always sends exactly one response. */
export async function handleRequest(req: BridgeRequestMessage, deps: RequestDeps): Promise<void> {
  let response: ExtensionToApp;
  try {
    response = okResponse(req.id, await answer(req, deps));
  } catch (e) {
    response = e instanceof RequestError
      ? errorResponse(req.id, e.code, e.message)
      : errorResponse(req.id, "internal", e instanceof Error ? e.message : String(e));
  }
  deps.client.send(response);
}
