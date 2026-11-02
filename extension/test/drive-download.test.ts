import { describe, expect, it, vi } from "vitest";
import { downloadDrivePdf, driveDownloadUrl, filenameFromContentDisposition, parseConfirmForm } from "../src/background/drive-download";
import { RequestError } from "../src/shared/protocol-codec";
import { localFixtureText } from "./helpers/fixtures";

const ID = "1AbCdEfGhIjKlMnOpQrStUvWxYz012345";
const MiB = 1048576;
const CD = "attachment; filename*=UTF-8''Algebra%202%20Textbook.pdf";

function pdfStream(total: number, piece = 300_000): ReadableStream<Uint8Array> {
  let sent = 0;
  return new ReadableStream({
    pull(c) {
      if (sent >= total) return c.close();
      const n = Math.min(piece, total - sent);
      const chunk = new Uint8Array(n);
      if (sent === 0) chunk.set(new TextEncoder().encode("%PDF-"));
      sent += n;
      c.enqueue(chunk);
    },
  });
}
const pdf = (total: number, headers: Record<string, string> = { "content-disposition": CD }) =>
  new Response(pdfStream(total), { headers: { "content-type": "application/pdf", ...headers } });
const html = (body: string, status = 200) => new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8" } });

function collect() {
  const emitted: { chunk: Uint8Array; seq: number; last: boolean }[] = [];
  return { emitted, emit: async (chunk: Uint8Array, seq: number, last: boolean) => { emitted.push({ chunk, seq, last }); } };
}
const fetchOf = (...rs: Response[]) => {
  const f = vi.fn(async (_u: string, _o?: RequestInit) => rs.shift()!);
  return f as unknown as typeof fetch & typeof f;
};

describe("helpers", () => {
  it("driveDownloadUrl", () => expect(driveDownloadUrl("a b")).toBe("https://drive.google.com/uc?export=download&id=a%20b"));
  it("parseConfirmForm builds the URL from action and hidden inputs", () =>
    expect(parseConfirmForm(localFixtureText("drive/confirm.html"))).toBe(`https://drive.usercontent.google.com/download?id=${ID}&export=download&confirm=t&uuid=abc-123`));
  it("parseConfirmForm returns null for a page with no form", () => expect(parseConfirmForm(localFixtureText("drive/denied.html"))).toBeNull());
  it("parseConfirmForm refuses a form pointing outside Google", () =>
    expect(parseConfirmForm('<form action="https://evil.example/x"><input type="hidden" name="a" value="b"></form>')).toBeNull());
  it("filenameFromContentDisposition prefers filename*", () => {
    expect(filenameFromContentDisposition(`attachment; filename="plain.pdf"; filename*=UTF-8''A%20B.pdf`)).toBe("A B.pdf");
    expect(filenameFromContentDisposition('attachment; filename="plain.pdf"')).toBe("plain.pdf");
    expect(filenameFromContentDisposition("attachment")).toBeNull();
    expect(filenameFromContentDisposition(null)).toBeNull();
  });
});

describe("downloadDrivePdf", () => {
  it("2.5 MiB PDF → 3 frames, seq 0..2, last only on the final one", async () => {
    const { emitted, emit } = collect();
    const result = await downloadDrivePdf(ID, emit, fetchOf(pdf(2_621_440)));
    expect(emitted.map((e) => [e.chunk.length, e.seq, e.last])).toEqual([[MiB, 0, false], [MiB, 1, false], [524288, 2, true]]);
    expect(result).toEqual({ fileId: ID, title: "Algebra 2 Textbook.pdf", byteLength: 2621440 });
    expect(new TextDecoder().decode(emitted[0].chunk.subarray(0, 5))).toBe("%PDF-");
  });
  it("exactly 1 MiB → one frame with last true", async () => {
    const { emitted, emit } = collect();
    await downloadDrivePdf(ID, emit, fetchOf(pdf(MiB)));
    expect(emitted.map((e) => [e.chunk.length, e.seq, e.last])).toEqual([[MiB, 0, true]]);
  });
  it("exactly 2 MiB → two frames, no empty trailer", async () => {
    const { emitted, emit } = collect();
    await downloadDrivePdf(ID, emit, fetchOf(pdf(2 * MiB)));
    expect(emitted.map((e) => [e.chunk.length, e.last])).toEqual([[MiB, false], [MiB, true]]);
  });
  it("a %PDF- header split across stream pieces still passes", async () => {
    const { emitted, emit } = collect();
    const body = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("%P")); c.enqueue(new TextEncoder().encode("DF-1")); c.close(); } });
    await downloadDrivePdf(ID, emit, fetchOf(new Response(body, { headers: { "content-type": "application/pdf" } })));
    expect(emitted.map((e) => e.chunk.length)).toEqual([6]);
  });
  it("title falls back to the file id", async () => {
    const { emit } = collect();
    expect((await downloadDrivePdf(ID, emit, fetchOf(pdf(10, {})))).title).toBe(ID);
  });
  it("requests the uc URL with credentials include", async () => {
    const f = fetchOf(pdf(10));
    const signal = new AbortController().signal;
    await downloadDrivePdf(ID, collect().emit, f, signal);
    expect(f.mock.calls[0]).toEqual([driveDownloadUrl(ID), { credentials: "include", redirect: "follow", signal }]);
  });
  it("follows the large-file confirm form", async () => {
    const f = fetchOf(html(localFixtureText("drive/confirm.html")), pdf(10));
    await downloadDrivePdf(ID, collect().emit, f);
    expect(f.mock.calls[1][0]).toBe(`https://drive.usercontent.google.com/download?id=${ID}&export=download&confirm=t&uuid=abc-123`);
    expect(f.mock.calls[1][1]).toMatchObject({ credentials: "include" });
  });
  it("follows the form once only", async () => {
    const confirm = localFixtureText("drive/confirm.html");
    const f = fetchOf(html(confirm), html(confirm));
    await expect(downloadDrivePdf(ID, collect().emit, f)).rejects.toMatchObject({ code: "downloadBlocked" });
    expect(f).toHaveBeenCalledTimes(2);
  });
  it.each([
    ["denied.html", () => html(localFixtureText("drive/denied.html")), "downloadBlocked"],
    ["403", () => new Response("", { status: 403 }), "downloadBlocked"],
    ["401", () => new Response("", { status: 401 }), "downloadBlocked"],
    ["404", () => new Response("", { status: 404 }), "notFound"],
    ["500", () => new Response("", { status: 500 }), "internal"],
    ["a zip", () => new Response("PK\x03\x04aaaaaaaa", { headers: { "content-type": "application/zip" } }), "notPdf"],
    ["empty body", () => new Response("", { headers: { "content-type": "application/pdf" } }), "notPdf"],
    ["too short", () => new Response("%PD", { headers: { "content-type": "application/pdf" } }), "notPdf"],
  ])("maps %s to an error code and emits nothing", async (_n, res, code) => {
    const { emitted, emit } = collect();
    const err = await downloadDrivePdf(ID, emit, fetchOf(res())).catch((e) => e);
    expect(err).toBeInstanceOf(RequestError);
    expect(err.code).toBe(code);
    expect(emitted).toEqual([]);
  });
});
