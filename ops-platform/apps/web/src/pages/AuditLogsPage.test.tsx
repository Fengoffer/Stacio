// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { AuditLogsPage } from "./AuditLogsPage";

describe("AuditLogsPage", () => {
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
    window.history.pushState({}, "", "/audit-logs");
  });

  it("loads URL target filters for linked audit investigations", async () => {
    window.history.pushState({}, "", "/audit-logs?targetType=connector&targetId=github");
    vi.spyOn(opsClient, "auditLogs").mockResolvedValue([
      {
        id: "audit_connector_github",
        time: "2026/07/10",
        actor: "usr_admin",
        actorType: "User",
        action: "connector.test",
        target: "connector / github",
        detail: "GitHub connector tested",
        ip: "203.0.113.10"
      }
    ]);

    render(<AuditLogsPage />);

    expect(await screen.findByText("connector.test")).toBeInTheDocument();
    expect(screen.getByLabelText("目标类型")).toHaveValue("connector");
    expect(screen.getByLabelText("目标 ID")).toHaveValue("github");

    await waitFor(() => {
      expect(opsClient.auditLogs).toHaveBeenLastCalledWith(
        "stacio",
        expect.objectContaining({
          targetType: "connector",
          targetId: "github"
        })
      );
    });
  });

  it("applies server-side audit filters for investigation workflows", async () => {
    vi.spyOn(opsClient, "auditLogs").mockResolvedValue([
      {
        id: "audit_release_publish",
        time: "2026/07/10",
        actor: "usr_release_admin",
        actorType: "User",
        action: "release.publish",
        target: "release / rel_0140",
        detail: "version: 0.14.0",
        ip: "203.0.113.10"
      }
    ]);

    render(<AuditLogsPage />);

    expect(await screen.findByText("release.publish")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("搜索审计日志"), {
      target: { value: "0.14.0" }
    });
    fireEvent.change(screen.getByLabelText("操作者类型"), {
      target: { value: "user" }
    });
    fireEvent.change(screen.getByLabelText("操作者 ID"), {
      target: { value: "usr_release_admin" }
    });
    fireEvent.change(screen.getByLabelText("操作类型"), {
      target: { value: "release.publish" }
    });
    fireEvent.change(screen.getByLabelText("目标类型"), {
      target: { value: "release" }
    });
    fireEvent.change(screen.getByLabelText("目标 ID"), {
      target: { value: "rel_0140" }
    });
    fireEvent.change(screen.getByLabelText("IP 地址"), {
      target: { value: "203.0.113.10" }
    });
    fireEvent.change(screen.getByLabelText("开始时间"), {
      target: { value: "2026-07-10" }
    });
    fireEvent.change(screen.getByLabelText("结束时间"), {
      target: { value: "2026-07-11" }
    });
    fireEvent.click(screen.getByRole("button", { name: "应用筛选" }));

    await waitFor(() => {
      expect(opsClient.auditLogs).toHaveBeenLastCalledWith(
        "stacio",
        expect.objectContaining({
          search: "0.14.0",
          actorType: "user",
          actorId: "usr_release_admin",
          action: "release.publish",
          targetType: "release",
          targetId: "rel_0140",
          ipAddress: "203.0.113.10",
          createdFrom: "2026-07-10T00:00:00.000Z",
          createdTo: "2026-07-11T23:59:59.999Z"
        })
      );
    });
  });
});
