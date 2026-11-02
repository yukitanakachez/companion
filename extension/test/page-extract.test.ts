import { describe, expect, it } from "vitest";
import { extractMath, extractPage, visibleText } from "../src/content/page-extract";
import { domFrom } from "./helpers/fixtures";

const U = "https://example.org/q";
const doc = (f: string) => domFrom(f, U).window.document;

describe("extractMath", () => {
  it("a KaTeX formula yields one latex snippet, not a MathML duplicate", () =>
    expect(extractMath(doc("pages/katex.html"))).toEqual([{ format: "latex", source: "\\frac{a}{b}" }]));
  it("MathJax v2 scripts yield latex, including display mode; assistive MathML is skipped", () =>
    expect(extractMath(doc("pages/mathjax2.html"))).toEqual([
      { format: "latex", source: "x^2" },
      { format: "latex", source: "\\int_0^1 y\\,dy" },
    ]));
  it("MathJax v3 assistive MathML yields mathml starting with <math", () => {
    const m = extractMath(doc("pages/mathjax3.html"));
    expect(m).toHaveLength(1);
    expect(m[0].format).toBe("mathml");
    expect(m[0].source.startsWith("<math")).toBe(true);
  });
  it("bare MathML yields mathml", () =>
    expect(extractMath(doc("pages/mathml.html"))).toEqual([{ format: "mathml", source: "<math><mi>z</mi></math>" }]));
  it("caps math at 50 and drops duplicates", () => {
    const k = (s: string) => `<math><semantics><annotation encoding="application/x-tex">${s}</annotation></semantics></math>`;
    const html = "<!doctype html><body>" + k("dup") + k("dup") + k("  ") + Array.from({ length: 60 }, (_, i) => k(`f_${i}`)).join("");
    const m = extractMath(domFrom(html, U).window.document);
    expect(m).toHaveLength(50);
    expect(m.filter((s) => s.source === "dup")).toHaveLength(1);
  });
  it("a page without math yields nothing", () => expect(extractMath(doc("pages/plain.html"))).toEqual([]));
});

describe("visibleText", () => {
  it("collapses whitespace and excludes script, style, noscript, template and hidden", () =>
    expect(visibleText(doc("pages/plain.html"))).toBe("Hello there world"));
  it("caps at 20,000", () => {
    const d = domFrom(`<!doctype html><body><p>${"word ".repeat(10_000)}</p>`, U).window.document;
    expect(visibleText(d)).toHaveLength(20_000);
  });
  it("uses innerText when the browser provides it", () => {
    const d = doc("pages/plain.html");
    Object.defineProperty(d.body, "innerText", { value: "  from \n innerText " });
    expect(visibleText(d)).toBe("from innerText");
  });
});

it("extractPage reads url and title from the document", () =>
  expect(extractPage(doc("pages/plain.html"))).toEqual({ url: U, title: "Plain page", visibleText: "Hello there world", math: [] }));
