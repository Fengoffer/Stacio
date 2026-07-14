import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const websiteRoot = new URL("../../../../website/", import.meta.url);
const main = readFileSync(new URL("main.js", websiteRoot), "utf8");
const html = readFileSync(new URL("index.html", websiteRoot), "utf8");

describe("official website release integration", () => {
  it("loads releases from the configurable public API and sends first-party telemetry", () => {
    expect(html).toContain("data-public-api-base");
    expect(main).toMatch(/publicApiBase/);
    expect(main).toContain("/public/products/${publicProductId}/releases");
    expect(main).toContain("/public/products/${publicProductId}/telemetry");
    expect(main).toMatch(/sendBeacon|keepalive/);
    expect(main).not.toContain("api.github.com/repos/Fengoffer/Stacio/releases?per_page=1");
  });
});
