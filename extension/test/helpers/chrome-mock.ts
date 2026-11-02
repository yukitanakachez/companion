import { vi } from "vitest";

export interface MockEvent<A extends unknown[] = any[]> {
  addListener: (l: (...a: A) => unknown) => void;
  hasListeners: () => boolean;
  fire: (...a: A) => unknown[];
}
function event<A extends unknown[] = any[]>(): MockEvent<A> {
  const ls: ((...a: A) => unknown)[] = [];
  return {
    addListener: vi.fn((l: (...a: A) => unknown) => { ls.push(l); }),
    hasListeners: () => ls.length > 0,
    fire: (...a: A) => ls.map((l) => l(...a)),
  };
}

export function createChromeMock(init: {
  tabs?: Partial<chrome.tabs.Tab>[];
  focusedWindowId?: number;
  storage?: Record<string, unknown>;
  storageGetDelayMs?: number;
  manifest?: unknown;
} = {}) {
  const data: Record<string, unknown> = { ...init.storage };
  const tabs: Partial<chrome.tabs.Tab>[] = [...(init.tabs ?? [])];
  const focused = { id: init.focusedWindowId ?? 1 };
  const onChanged = event<[Record<string, { oldValue?: unknown; newValue?: unknown }>, string]>();
  const onMessage = event<[unknown, unknown, (r: unknown) => void]>();

  const mock = {
    _data: data,
    _tabs: tabs,
    _focused: focused,
    storage: {
      onChanged,
      local: {
        get: vi.fn(async (keys?: string | string[] | null) => {
          if (init.storageGetDelayMs) await new Promise((r) => setTimeout(r, init.storageGetDelayMs));
          const wanted = keys == null ? Object.keys(data) : Array.isArray(keys) ? keys : [keys];
          return Object.fromEntries(wanted.filter((k) => k in data).map((k) => [k, data[k]]));
        }),
        set: vi.fn(async (items: Record<string, unknown>) => {
          const changes: Record<string, { oldValue?: unknown; newValue?: unknown }> = {};
          for (const [k, v] of Object.entries(items)) { changes[k] = { oldValue: data[k], newValue: v }; data[k] = v; }
          onChanged.fire(changes, "local");
        }),
        onChanged,
      },
    },
    runtime: {
      getManifest: vi.fn(() => init.manifest ?? { version: "0.1.0", content_scripts: [] }),
      sendMessage: vi.fn(async (_m: unknown) => undefined as unknown),
      onMessage,
      onInstalled: event<[unknown]>(),
    },
    tabs: {
      get: vi.fn(async (id: number) => {
        const t = tabs.find((x) => x.id === id);
        if (!t) throw new Error(`No tab with id: ${id}`);
        return t;
      }),
      query: vi.fn(async (q: { active?: boolean; windowId?: number; lastFocusedWindow?: boolean }) =>
        tabs.filter((t) => (q.active === undefined || t.active === q.active) && (q.windowId === undefined || t.windowId === q.windowId))),
      sendMessage: vi.fn(async (_id: number, _m: unknown, _o?: unknown) => undefined as unknown),
      captureVisibleTab: vi.fn(async (_w: number, _o: unknown) => "data:image/png;base64,AAAA"),
      onActivated: event<[{ tabId: number; windowId: number }]>(),
      onUpdated: event<[number, { url?: string; title?: string; status?: string }, Partial<chrome.tabs.Tab>]>(),
      onRemoved: event<[number, unknown]>(),
    },
    windows: {
      WINDOW_ID_NONE: -1,
      getLastFocused: vi.fn(async () => ({ id: focused.id })),
      onFocusChanged: event<[number]>(),
    },
    scripting: { executeScript: vi.fn(async (_i: unknown) => [] as unknown[]) },
    /** Runs the runtime.onMessage listeners and resolves with the value passed to sendResponse. */
    deliver(msg: unknown, sender: unknown = {}): Promise<unknown> {
      return new Promise((resolve) => {
        const results = onMessage.fire(msg, sender, resolve);
        if (!results.some((r) => r === true)) resolve(undefined);
      });
    },
  };
  return mock;
}
export type ChromeMock = ReturnType<typeof createChromeMock>;
/** The mock, typed as the API surface production code asks for. */
export const asChrome = (m: ChromeMock) => m as unknown as typeof chrome;
