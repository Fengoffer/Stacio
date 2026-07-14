import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");

describe("responsive app shell styles", () => {
  it("keeps the search prefix on one line", () => {
    expect(styles).toMatch(/\.search-box > span\s*{[^}]*white-space:\s*nowrap;/s);
  });

  it("collapses the shell navigation and topbar on mobile", () => {
    expect(styles).toMatch(
      /@media \(max-width: 760px\)[\s\S]*body\s*{[^}]*min-width:\s*0;/
    );
    expect(styles).toMatch(
      /@media \(max-width: 760px\)[\s\S]*\.sidebar\s*{[^}]*flex:\s*0 0 64px;/
    );
    expect(styles).toMatch(
      /@media \(max-width: 760px\)[\s\S]*\.search-box\s*{[^}]*display:\s*none;/
    );
  });

  it("keeps the sidebar fixed while the right content area scrolls", () => {
    expect(styles).toMatch(/\.app-shell\s*{[^}]*height:\s*100dvh;[^}]*overflow:\s*hidden;/s);
    expect(styles).toMatch(/\.sidebar\s*{[^}]*height:\s*100%;/s);
    expect(styles).toMatch(/\.main-panel\s*{[^}]*height:\s*100%;[^}]*overflow:\s*hidden;/s);
    expect(styles).toMatch(/\.page\s*{[^}]*min-height:\s*0;[^}]*overflow-y:\s*auto;/s);
  });

  it("allows long release and connector forms to be resized from their dialog surface", () => {
    expect(styles).toMatch(/\.connector-modal-resizable\s*{[^}]*resize:\s*both;/s);
  });

  it("keeps connector configuration forms inside a mobile modal", () => {
    expect(styles).toMatch(
      /@media \(max-width: 760px\)[\s\S]*\.connector-modal-backdrop\s*{[^}]*padding:\s*12px;/
    );
    expect(styles).toMatch(
      /@media \(max-width: 760px\)[\s\S]*\.connector-modal\s*{[^}]*height:\s*100%;/
    );
  });
});
