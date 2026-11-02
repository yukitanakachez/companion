type Registry = Record<string, () => void>;

/**
 * Injecting into open tabs after an extension update can land on a tab already running this script.
 * The newest instance takes over, whether or not the older one's extension context is still alive.
 */
export function replaceInstance(win: Window, key: string, start: () => () => void): void {
  const holder = win as unknown as { __companionInstances?: Registry };
  const registry = (holder.__companionInstances ??= {});
  try {
    registry[key]?.();
  } catch {
    // An orphaned script may fail while stopping; the new instance still starts.
  }
  registry[key] = start();
}
