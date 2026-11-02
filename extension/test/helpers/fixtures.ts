import { readdirSync, readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const contracts = new URL("../../../contracts/fixtures/", import.meta.url);
const local = new URL("../fixtures/", import.meta.url);

export function contractFixtureNames(): string[] {
  return readdirSync(contracts).filter((n) => n.endsWith(".json")).sort();
}
export function contractFixtureText(name: string): string {
  return readFileSync(new URL(name, contracts), "utf8");
}
export function contractFixture(name: string): any {
  return JSON.parse(contractFixtureText(name));
}
export function localFixtureText(path: string): string {
  return readFileSync(new URL(path, local), "utf8");
}
/** `fixturePathOrHtml` is markup if it starts with "<", otherwise a path under test/fixtures. */
export function domFrom(fixturePathOrHtml: string, url: string): JSDOM {
  const html = fixturePathOrHtml.trimStart().startsWith("<") ? fixturePathOrHtml : localFixtureText(fixturePathOrHtml);
  return new JSDOM(html, { url, pretendToBeVisual: true });
}
