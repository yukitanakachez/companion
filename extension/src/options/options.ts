import { STORAGE_KEYS, type ContentToBackground, type ExtensionBridgeStatus } from "../shared/messages";

export function normalizeToken(input: string): string | null {
  const t = input.trim();
  return /^[0-9a-f]{64}$/i.test(t) ? t.toLowerCase() : null;
}

export function statusText(s: ExtensionBridgeStatus): string {
  switch (s.state) {
    case "noToken": return "Not paired — paste the token from Companion Settings.";
    case "connecting": return "Connecting…";
    case "connected": return `Connected to Companion ${s.appVersion} on port ${s.port}`;
    case "disconnected": return "Companion app not running — retrying";
    case "tokenRejected": return "Token rejected — paste the current token from Companion Settings.";
    case "versionMismatch": return "Version mismatch — update the extension and the app.";
  }
}

export async function initOptions(doc: Document, chromeApi: typeof chrome): Promise<void> {
  const el = <T extends HTMLElement>(id: string) => doc.getElementById(id) as T;
  const render = (s: ExtensionBridgeStatus | undefined) => {
    el("status").textContent = statusText(s ?? { state: "noToken", port: null, appVersion: null, updatedAtMs: 0 });
  };

  el("save").addEventListener("click", () => {
    const input = el<HTMLInputElement>("token");
    const token = normalizeToken(input.value);
    if (!token) {
      el("error").textContent = "Token must be 64 hex characters.";
      return;
    }
    el("error").textContent = "";
    input.value = "";
    void chromeApi.storage.local.set({ [STORAGE_KEYS.pairingToken]: token });
  });
  el("test").addEventListener("click", () => {
    const msg: ContentToBackground = { kind: "reconnectNow" };
    chromeApi.runtime.sendMessage(msg).catch(() => {
      // The status line reports whatever the worker manages.
    });
  });
  chromeApi.storage.onChanged.addListener((changes, area) => {
    const change = changes[STORAGE_KEYS.bridgeStatus];
    if (area === "local" && change) render(change.newValue as ExtensionBridgeStatus | undefined);
  });

  const got = await chromeApi.storage.local.get(STORAGE_KEYS.bridgeStatus);
  render(got[STORAGE_KEYS.bridgeStatus] as ExtensionBridgeStatus | undefined);
}
