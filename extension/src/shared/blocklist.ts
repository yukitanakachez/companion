export { STARTER_BLOCKED_DOMAINS } from "../../../contracts/ts/protocol";

const normalize = (host: string) => host.toLowerCase().replace(/\.$/, "");

/** Lowercased, trailing dot removed; null unless http(s). */
export function hostOf(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:" ? normalize(u.hostname) : null;
  } catch {
    return null;
  }
}

export function isHostBlocked(host: string, domains: readonly string[]): boolean {
  const h = normalize(host);
  return domains.some((d) => h === d || h.endsWith("." + d));
}
