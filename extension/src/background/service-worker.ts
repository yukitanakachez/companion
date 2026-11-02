import { PROTOCOL_VERSION, type AppToExtension, type BlocklistConfig } from "../../../contracts/ts/protocol";
import { hostOf, isHostBlocked } from "../shared/blocklist";
import { STORAGE_KEYS, type BackgroundToContent, type ContentToBackground } from "../shared/messages";
import { BlocklistStore } from "./blocklist-store";
import { BridgeClient, detectBrowserName, type SocketFactory } from "./bridge-client";
import { handleRequest, type ViewerHandler } from "./requests";
import { TabStore } from "./tab-store";
import { TabTracker } from "./tab-tracker";

export interface SwEnv {
  chrome: typeof chrome;
  createSocket: SocketFactory;
  fetch: typeof fetch;
  now(): number;
  ports?: readonly number[];
  viewer?: ViewerHandler | null;
}

const urlMatches = (url: string, pattern: string): boolean => {
  if (pattern === "<all_urls>") return hostOf(url) !== null;
  const re = new RegExp("^" + pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
  return re.test(url);
};

export function createServiceWorker(env: SwEnv) {
  const { chrome: api } = env;
  const blocklist = new BlocklistStore(api.storage.local);
  const store = new TabStore();
  let downloads = new AbortController();
  let resyncPending = false;

  const client: BridgeClient = new BridgeClient({
    createSocket: env.createSocket,
    getToken: async () => {
      const got = await api.storage.local.get(STORAGE_KEYS.pairingToken);
      return (got[STORAGE_KEYS.pairingToken] as string | undefined) ?? null;
    },
    extensionVersion: api.runtime.getManifest().version,
    browserName: detectBrowserName((globalThis.navigator as unknown as { userAgentData?: { brands: { brand: string }[] } } | undefined)?.userAgentData?.brands),
    ports: env.ports,
    onAppMessage,
    onConnected: () => {
      resyncPending = true;
    },
    onDisconnected: () => {
      resyncPending = false;
      downloads.abort();
      downloads = new AbortController();
    },
    onStatus: (status) => {
      void api.storage.local.set({ [STORAGE_KEYS.bridgeStatus]: status });
    },
  });
  const tracker = new TabTracker({ chrome: api, store, blocklist, send: (m) => void client.send(m) });

  function onAppMessage(msg: AppToExtension): void {
    if (msg.type === "config") void onConfig(msg.blocklist);
    else if (msg.type === "request") {
      void handleRequest(msg, {
        store, tracker, blocklist, client,
        tabs: api.tabs,
        fetch: env.fetch,
        viewer: env.viewer ?? null,
        now: env.now,
        signal: downloads.signal,
      });
    }
  }

  async function onConfig(config: BlocklistConfig): Promise<void> {
    const resync = resyncPending;
    resyncPending = false;
    await blocklist.setConfig(config);
    const isBlocked = (url: string) => {
      const host = hostOf(url);
      return host !== null && isHostBlocked(host, config.domains);
    };
    for (const context of store.purge(isBlocked, env.now())) client.send({ v: PROTOCOL_VERSION, type: "tabContext", context });
    if (resync) await runResync();
  }

  /** After a (re)connect the app knows nothing, so tell it the active tab, the snapshots, and refresh. */
  async function runResync(): Promise<void> {
    const active = await tracker.announceActive();
    for (const context of store.all()) client.send({ v: PROTOCOL_VERSION, type: "tabContext", context });
    if (active === null || store.get(active)?.blocked) return;
    const extract: BackgroundToContent = { kind: "extractNow" };
    api.tabs.sendMessage(active, extract).catch(() => {
      // No content script there, e.g. a chrome:// page.
    });
  }

  async function onContentMessage(msg: ContentToBackground, sender: chrome.runtime.MessageSender, reply: (r: unknown) => void): Promise<void> {
    const tab = sender.tab;
    const isTop = (sender.frameId ?? 0) === 0;
    switch (msg.kind) {
      case "isBlocked": {
        const tabBlocked = tab?.url ? await blocklist.isUrlBlocked(tab.url) : false;
        const blocked = tabBlocked || (await blocklist.isUrlBlocked(msg.url));
        reply({ blocked });
        if (blocked && tab?.id !== undefined && (tabBlocked || isTop)) {
          client.send({ v: PROTOCOL_VERSION, type: "tabContext", context: store.setBlocked(tab.id, tab.url ?? msg.url, env.now()) });
        }
        return;
      }
      case "contextPart": {
        if (tab?.id === undefined) return;
        const tabUrl = tab.url ?? msg.pageUrl;
        if ((await blocklist.isUrlBlocked(tabUrl)) || (isTop && (await blocklist.isUrlBlocked(msg.pageUrl)))) return;
        const context = isTop
          ? store.applyPart(tab.id, msg.pageUrl, msg.pageTitle, msg.capturedAtMs, msg.part)
          : store.applyPart(tab.id, tabUrl, tab.title ?? "", msg.capturedAtMs, msg.part);
        client.send({ v: PROTOCOL_VERSION, type: "tabContext", context });
        return;
      }
      case "playhead": {
        if (tab?.id === undefined || (tab.url && (await blocklist.isUrlBlocked(tab.url)))) return;
        store.updatePlayhead(tab.id, msg.videoId, msg.playheadSeconds, msg.chapter);
        client.send({ v: PROTOCOL_VERSION, type: "youtubePlayhead", tabId: tab.id, videoId: msg.videoId, playheadSeconds: msg.playheadSeconds, chapter: msg.chapter });
        return;
      }
      case "reconnectNow":
        await client.restart();
        return;
    }
  }

  async function injectIntoOpenTabs(): Promise<void> {
    const scripts = api.runtime.getManifest().content_scripts ?? [];
    for (const tab of await api.tabs.query({})) {
      const url = tab.url;
      if (tab.id === undefined || !url || (await blocklist.isUrlBlocked(url))) continue;
      for (const s of scripts) {
        const matched = (s.matches ?? []).some((p) => urlMatches(url, p)) && !(s.exclude_matches ?? []).some((p) => urlMatches(url, p));
        if (!matched) continue;
        const { world } = s as { world?: chrome.scripting.ExecutionWorld };
        api.scripting.executeScript({
          target: { tabId: tab.id, allFrames: s.all_frames === true },
          files: s.js ?? [],
          ...(world ? { world } : {}),
        }).catch(() => {
          // Some pages refuse injection, such as the web store.
        });
      }
    }
  }

  // Every listener is registered synchronously: anything later would miss the event that woke the worker.
  tracker.attach();
  api.runtime.onMessage.addListener((msg: ContentToBackground, sender, reply) => {
    void onContentMessage(msg, sender, reply);
    return msg.kind === "isBlocked"; // Keeps the channel open for the async answer.
  });
  api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && STORAGE_KEYS.pairingToken in changes) void client.restart();
  });
  api.runtime.onInstalled.addListener(() => void injectIntoOpenTabs());

  return { client, store, tracker, blocklist };
}
