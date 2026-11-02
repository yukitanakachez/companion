import type { BlocklistConfig } from "../../../contracts/ts/protocol";
import { STARTER_BLOCKED_DOMAINS, hostOf, isHostBlocked } from "../shared/blocklist";
import { STORAGE_KEYS } from "../shared/messages";

export class BlocklistStore {
  private list: readonly string[] | null = null;
  private readonly loaded: Promise<void>;

  constructor(private readonly storage: chrome.storage.StorageArea) {
    this.loaded = this.load();
  }

  async domains(): Promise<readonly string[]> {
    await this.loaded;
    return this.list ?? STARTER_BLOCKED_DOMAINS;
  }

  async isUrlBlocked(url: string): Promise<boolean> {
    const host = hostOf(url);
    return host !== null && isHostBlocked(host, await this.domains());
  }

  async setConfig(config: BlocklistConfig): Promise<void> {
    this.list = config.domains;
    await this.storage.set({ [STORAGE_KEYS.blocklist]: config });
  }

  private async load(): Promise<void> {
    try {
      const got = await this.storage.get(STORAGE_KEYS.blocklist);
      const stored = got[STORAGE_KEYS.blocklist] as BlocklistConfig | undefined;
      // A setConfig that landed during the read is newer than what was stored.
      if (this.list === null && Array.isArray(stored?.domains)) this.list = stored.domains;
    } catch {
      // Fall back to the starter list.
    }
  }
}
