// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { DashboardPage } from "./DashboardPage";

describe("DashboardPage", () => {
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("renders operational health signals for licenses, email, and audit activity", async () => {
    vi.spyOn(opsClient, "dashboard").mockResolvedValue({
      productId: "stacio",
      currentStableVersion: "0.13.1-Beta",
      currentBetaVersion: "0.13.2-Beta",
      todayFeedbackCount: 4,
      unhandledFeedbackCount: 2,
      p0p1BugCount: 1,
      activeLicenseCount: 9,
      expiringLicenseCount: 1,
      latestReleaseStatus: "ready",
      githubSyncStatus: "healthy",
      aiPendingSuggestionCount: 3,
      licenseValidationErrorCount: 5,
      emailDeliveryStatus: {
        queued: 2,
        sent: 8,
        failed: 1,
        dryRun: 3
      },
      recentAuditEvents: [
        {
          id: "audit_dashboard",
          actorType: "user",
          actorId: "usr_test",
          action: "license.validate_failed",
          targetType: "license",
          targetId: "lic_test",
          productId: "stacio",
          metadata: {
            changed: 0
          },
          createdAt: "2026-07-10T00:00:00.000Z"
        }
      ]
    });

    render(<DashboardPage />);

    expect(await screen.findByText("今日反馈")).toBeInTheDocument();
    expect(screen.getByText("4")).toBeInTheDocument();
    expect(await screen.findByText("License 验证错误")).toBeInTheDocument();
    expect(screen.getByText("5")).toBeInTheDocument();
    expect(screen.getByText("邮件投递")).toBeInTheDocument();
    expect(screen.getByText("Queued")).toBeInTheDocument();
    expect(screen.getByText("Dry Run")).toBeInTheDocument();
    expect(screen.getByText("最近审计")).toBeInTheDocument();
    expect(screen.getByText("license.validate_failed")).toBeInTheDocument();
  });

  it("surfaces dashboard API failures instead of leaving operators on empty metrics", async () => {
    vi.spyOn(opsClient, "dashboard").mockRejectedValue(new Error("Dashboard API unavailable"));

    render(<DashboardPage />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Dashboard API unavailable");
  });
});
