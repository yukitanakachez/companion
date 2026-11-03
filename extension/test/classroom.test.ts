import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { driveFileIdFromUrl, parseAssignmentTitle, parseAttachments, startClassroomScript } from "../src/content/classroom";
import { contractFixture, domFrom, localFixtureText } from "./helpers/fixtures";
import { fakeDeps } from "./helpers/content-deps";

const U = "https://classroom.google.com/c/MTIz/a/NDU2/details";
const IMG = "1ImgImgImgImgImgImgImgImg00000";
const fx = () => domFrom("classroom/assignment.html", U).window.document;
const main = () => localFixtureText("classroom/assignment.html").match(/<div role="main">[\s\S]*<\/div>/)![0];
const card = (id: string, name: string) => `<a href="https://drive.google.com/file/d/${id}/view" title="Attachment: ${name}"><div>${name}</div></a>`;

describe("parsing", () => {
  it("parses the assignment fixture into the contract's classroom value", () => {
    const want = contractFixture("ext-tabContext-classroom.json").context.classroom;
    const doc = fx();
    expect({ assignmentTitle: parseAssignmentTitle(doc), attachments: parseAttachments(doc).filter((a) => a.mimeType) }).toEqual(want);
  });
  it("duplicate anchors give one ref; Docs links ignored; Image card → mimeType null", () => {
    const all = parseAttachments(fx());
    expect(all).toHaveLength(3);
    expect(all[2]).toEqual({ fileId: IMG, title: "diagram.png", mimeType: null });
  });
  it("a PDF label without .pdf in the title gives application/pdf", () => {
    const d = domFrom(`<!doctype html><a href="/file/d/1234567890ab/view"><div>Chapter 5</div><div>PDF</div></a>`, U).window.document;
    expect(parseAttachments(d)).toEqual([{ fileId: "1234567890ab", title: "Chapter 5", mimeType: "application/pdf" }]);
  });
  it("aria-label wins, and a thumbnail anchor first doesn't lose the title", () => {
    const d = domFrom(`<!doctype html><a href="/file/d/1234567890ab/view"><img></a><a href="/file/d/1234567890ab/view" aria-label="Attachment: Book.PDF"></a>`, U).window.document;
    expect(parseAttachments(d)).toEqual([{ fileId: "1234567890ab", title: "Book.PDF", mimeType: "application/pdf" }]);
  });
  it("real classwork page: one clean PDF title per file, folder links ignored", () => {
    const d = domFrom("classroom/real-classwork.html", "https://classroom.google.com/w/MTIz/t/all").window.document;
    expect(parseAttachments(d)).toEqual([
      { fileId: "AAAAAAAAAAAAAAAA", title: "AP Calculus AB Chap 3B test a 2526 Name.pdf", mimeType: "application/pdf" },
      { fileId: "BBBBBBBBBBBBBBBB", title: "Rogawski's Calculus Early Transcendentals for AP_.pdf", mimeType: "application/pdf" },
      { fileId: "CCCCCCCCCCCCCCCC", title: "Stewart Precalculus 7th ed_.pdf", mimeType: "application/pdf" },
    ]);
  });
  it("a colon in the title survives; only a known type label is stripped", () => {
    const anchor = (label: string) => `<a href="/file/d/1234567890ab/view" aria-label="${label}"></a>`;
    const title = (label: string) => parseAttachments(domFrom(`<!doctype html>${anchor(label)}`, U).window.document)[0].title;
    expect(title("Attachment: Chapter 3: Limits.pdf")).toBe("Chapter 3: Limits.pdf");
    expect(title("Attachment: PDF: Chapter 3: Limits.pdf")).toBe("Chapter 3: Limits.pdf");
    expect(title("Attachment: PDF: PDF: odd.pdf")).toBe("PDF: odd.pdf");
  });
  it("whitespace runs collapse in a title read from the card text", () => {
    const d = domFrom(`<!doctype html><a href="/file/d/1234567890ab/view"><div>Chapter   5.pdf</div></a>`, U).window.document;
    expect(parseAttachments(d)[0].title).toBe("Chapter 5.pdf");
  });
  it("driveFileIdFromUrl", () => {
    expect(driveFileIdFromUrl("https://drive.google.com/file/d/1AbC_d-EfGhIj/view")).toBe("1AbC_d-EfGhIj");
    expect(driveFileIdFromUrl("https://drive.google.com/file/d/short/view")).toBeNull();
    expect(driveFileIdFromUrl("https://docs.google.com/document/d/1AbCdEfGhIjKl/edit")).toBeNull();
  });
  it("assignment title prefers main's h1 over the first h1, and null when none", () => {
    expect(parseAssignmentTitle(fx())).toBe("Read 5.2 and do 1-15");
    expect(parseAssignmentTitle(domFrom("<!doctype html><h1>Only</h1>", U).window.document)).toBe("Only");
    expect(parseAssignmentTitle(domFrom("<!doctype html><p>none</p>", U).window.document)).toBeNull();
  });
});

describe("startClassroomScript", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("attachments rendered late are sent once", async () => {
    const dom = domFrom('<!doctype html><head><title>T</title></head><body><div id="root"><div role="main"></div></div></body>', U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startClassroomScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ kind: "contextPart", pageUrl: U, part: { classroom: { attachments: [] } } });
    await vi.advanceTimersByTimeAsync(2000);
    dom.window.document.getElementById("root")!.innerHTML = main();
    await vi.advanceTimersByTimeAsync(499);
    expect(sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(sent).toHaveLength(2);
    expect((sent[1] as any).part.classroom.attachments).toHaveLength(3);
    dom.window.document.getElementById("root")!.innerHTML = main();
    await vi.advanceTimersByTimeAsync(1000);
    expect(sent).toHaveLength(2);
    stop();
  });
  it("SPA nav to another assignment starts fresh", async () => {
    const dom = domFrom(`<!doctype html><head><title>A</title></head><body><div id="root"><div role="main"><h1>A</h1>${card("1AAAAAAAAAAAA", "a.pdf")}</div></div></body>`, U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startClassroomScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/c/MTIz/a/OTk5/details");
    dom.window.document.getElementById("root")!.innerHTML = `<div role="main"><h1>B</h1>${card("1BBBBBBBBBBBB", "b.pdf")}</div>`;
    await vi.advanceTimersByTimeAsync(1600);
    const last = sent.at(-1) as any;
    expect(last.pageUrl).toContain("OTk5");
    expect(last.part.classroom.assignmentTitle).toBe("B");
    expect(last.part.classroom.attachments.map((a: any) => a.fileId)).toEqual(["1BBBBBBBBBBBB"]);
    stop();
  });
  it("navigating sends the new page even when its result looks identical", async () => {
    const dom = domFrom(`<!doctype html><head><title>A</title></head><body><div role="main"><h1>Same</h1></div></body>`, U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startClassroomScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/c/MTIz/a/OTk5/details");
    await vi.advanceTimersByTimeAsync(1600);
    expect(sent).toHaveLength(2);
    stop();
  });
  it("extractNow re-sends an unchanged result", async () => {
    const { deps, sent, extractNow } = fakeDeps(domFrom("classroom/assignment.html", U));
    const stop = startClassroomScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(2);
    stop();
  });
  it("blocked host: classroom script sends nothing", async () => {
    const dom = domFrom("classroom/assignment.html", U);
    const { deps, sent, extractNow } = fakeDeps(dom, true);
    const spy = vi.spyOn(dom.window.document, "querySelectorAll");
    const stop = startClassroomScript(deps);
    extractNow();
    await vi.advanceTimersByTimeAsync(2000);
    expect(sent).toEqual([]);
    expect(spy).not.toHaveBeenCalled();
    stop();
  });
});
