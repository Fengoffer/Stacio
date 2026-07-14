import { describe, expect, it } from "vitest";
import { requiredNotificationTemplateTypes } from "../src/data/seed.js";
import { createMemoryStore } from "../src/data/store.js";

describe("default notification templates", () => {
  it("seeds all PRD-required admin and customer email template types", async () => {
    const store = createMemoryStore();

    const templates = await store.listNotificationTemplates("stacio");

    expect(templates.map((template) => template.type).sort()).toEqual([...requiredNotificationTemplateTypes].sort());
    expect(templates).toEqual(
      expect.arrayContaining(
        requiredNotificationTemplateTypes.map((type) =>
          expect.objectContaining({
            type,
            status: "active",
            subjectTemplate: expect.stringContaining("Stacio"),
            htmlTemplate: expect.stringContaining("{{")
          })
        )
      )
    );
  });
});
