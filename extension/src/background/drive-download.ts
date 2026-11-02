import { MAX_CHUNK_BYTES, type DrivePdfResult } from "../../../contracts/ts/protocol";
import { RequestError } from "../shared/protocol-codec";

const PDF_MAGIC = [0x25, 0x50, 0x44, 0x46, 0x2d]; // "%PDF-"

export function driveDownloadUrl(fileId: string): string {
  return `https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`;
}

const attr = (tag: string, name: string) =>
  new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i").exec(tag)?.slice(1).find((v) => v !== undefined) ?? null;
const unescapeHtml = (s: string) => s.replace(/&amp;/g, "&");

/** Regex, because a service worker has no DOMParser. Form action + hidden inputs → URL. Google hosts only. */
export function parseConfirmForm(html: string): string | null {
  const form = /<form\b[^>]*>[\s\S]*?<\/form>/i.exec(html)?.[0];
  if (!form) return null;
  const action = attr(/<form\b[^>]*>/i.exec(form)![0], "action");
  if (!action) return null;
  let url: URL;
  try {
    url = new URL(unescapeHtml(action), "https://drive.google.com/");
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || !(url.hostname === "google.com" || url.hostname.endsWith(".google.com"))) return null;
  for (const [tag] of form.matchAll(/<input\b[^>]*>/gi)) {
    const name = attr(tag, "name");
    if (attr(tag, "type")?.toLowerCase() === "hidden" && name) url.searchParams.set(name, unescapeHtml(attr(tag, "value") ?? ""));
  }
  return url.toString();
}

export function filenameFromContentDisposition(header: string | null): string | null {
  if (!header) return null;
  const extended = /filename\*\s*=\s*UTF-8''([^;]+)/i.exec(header)?.[1];
  if (extended) {
    try {
      return decodeURIComponent(extended.trim());
    } catch {
      // Fall through to the plain form.
    }
  }
  return /filename\s*=\s*"([^"]*)"/i.exec(header)?.[1] ?? /filename\s*=\s*([^;\s]+)/i.exec(header)?.[1] ?? null;
}

function checkStatus(res: Response): void {
  if (res.status === 404) throw new RequestError("notFound", "The file doesn't exist or isn't shared with this account.");
  if (res.status === 401 || res.status === 403) throw new RequestError("downloadBlocked", "The owner has disabled downloads for this file.");
  if (!res.ok) throw new RequestError("internal", `Drive answered HTTP ${res.status}.`);
}
const isHtml = (res: Response) => (res.headers.get("content-type") ?? "").toLowerCase().includes("text/html");

/** Throws RequestError; nothing is emitted before the %PDF- check passes. */
export async function downloadDrivePdf(
  fileId: string,
  emit: (chunk: Uint8Array, seq: number, last: boolean) => Promise<void>,
  fetchFn: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<DrivePdfResult> {
  const options: RequestInit = { credentials: "include", redirect: "follow", signal };
  let res = await fetchFn(driveDownloadUrl(fileId), options);
  checkStatus(res);
  if (isHtml(res)) {
    const confirm = parseConfirmForm(await res.text());
    if (!confirm) throw new RequestError("downloadBlocked", "The owner has disabled downloads for this file.");
    res = await fetchFn(confirm, options);
    checkStatus(res);
    if (isHtml(res)) throw new RequestError("downloadBlocked", "Drive wouldn't release this file for download.");
  }

  const notPdf = () => new RequestError("notPdf", "The file isn't a PDF.");
  if (!res.body) throw notPdf();
  const reader = res.body.getReader();
  let current = new Uint8Array(MAX_CHUNK_BYTES);
  let filled = 0;
  let byteLength = 0;
  let verified = false;
  let held: Uint8Array | null = null; // A full chunk kept back until we know whether it's the last.
  let seq = 0;

  const verify = () => {
    if (!PDF_MAGIC.every((b, i) => current[i] === b)) throw notPdf();
    verified = true;
  };
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      let offset = 0;
      while (offset < value.length) {
        if (held) {
          const out: Uint8Array = held;
          held = null;
          await emit(out, seq++, false);
        }
        const n = Math.min(value.length - offset, MAX_CHUNK_BYTES - filled);
        current.set(value.subarray(offset, offset + n), filled);
        filled += n;
        offset += n;
        byteLength += n;
        if (!verified && filled >= PDF_MAGIC.length) verify();
        if (filled === MAX_CHUNK_BYTES) {
          held = current;
          current = new Uint8Array(MAX_CHUNK_BYTES);
          filled = 0;
        }
      }
    }
    if (!verified) throw notPdf();
    const final: Uint8Array = held ?? current.subarray(0, filled);
    await emit(final, seq, true);
  } catch (e) {
    void reader.cancel().catch(() => {});
    throw e;
  }
  return { fileId, title: filenameFromContentDisposition(res.headers.get("content-disposition")) ?? fileId, byteLength };
}
