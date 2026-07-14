// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "./api/client";
import { App } from "./App";

const stacioProduct = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  iconUrl: "",
  description: "",
  currentStableVersion: "0.14.0",
  currentBetaVersion: "0.15.0-beta",
  supportEmail: "support@example.com",
  githubOwner: "",
  githubRepository: "",
  updateBaseUrl: "",
  appcastBaseUrl: "",
  licensePolicy: {},
  dataRetentionPolicy: {},
  emailBrand: {},
  objectStoragePrefix: "products/stacio",
  status: "active",
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const secondProduct = {
  ...stacioProduct,
  id: "second-product",
  name: "Second Product",
  bundleId: "com.example.Second",
  currentStableVersion: "1.0.0",
  currentBetaVersion: "",
  objectStoragePrefix: "products/second-product"
};

describe("Stacio Ops web shell", () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.history.pushState({}, "", "/");
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("renders the login screen before authentication", () => {
    render(<App />);

    expect(screen.getByRole("heading", { name: "管理后台登录" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "登录" })).toBeInTheDocument();
    expect(screen.getByLabelText("邮箱")).toHaveValue("");
    expect(screen.getByLabelText("密码")).toHaveValue("");
  });

  it("renders the operations navigation and dashboard", () => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    render(<App />);

    expect(screen.getByRole("heading", { name: "工作台" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /用户反馈/ })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /版本发布/ })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /许可证/ })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "官网数据" }).querySelector("svg.lucide-chart-no-axes-combined")).not.toBeNull();
    expect(screen.getByRole("link", { name: "系统设置" }).querySelector("svg.lucide-settings-2")).not.toBeNull();
    expect(screen.getByText("Stacio Ops")).toBeInTheDocument();
    expect(screen.getByText("未处理反馈")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "新建发布草稿" })).toHaveAttribute(
      "href",
      "/releases?create=1"
    );
    expect(screen.getByRole("button", { name: "退出" }).closest(".topbar")).not.toBeNull();
  });

  it("opens the self-service account page for authenticated users", () => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/account");
    render(<App />);

    expect(screen.getByRole("heading", { name: "我的账号" })).toBeInTheDocument();
    expect(screen.getByLabelText("当前密码")).toBeInTheDocument();
  });

  it("loads products into the global selector and persists the active product", async () => {
    const dashboardSpy = vi.spyOn(opsClient, "dashboard");
    vi.spyOn(opsClient, "products").mockResolvedValue([stacioProduct, secondProduct]);
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    render(<App />);

    const selector = await screen.findByLabelText("当前产品");
    expect(selector).toHaveValue("stacio");

    fireEvent.change(selector, { target: { value: "second-product" } });

    await waitFor(() => {
      expect(window.localStorage.getItem("stacio.ops.productId")).toBe("second-product");
      expect(selector).toHaveValue("second-product");
      expect(dashboardSpy).toHaveBeenLastCalledWith("second-product");
    });
  });

  function renderWithSecondProduct(path: string) {
    vi.spyOn(opsClient, "products").mockResolvedValue([stacioProduct, secondProduct]);
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.localStorage.setItem("stacio.ops.productId", "second-product");
    window.history.pushState({}, "", path);
    render(<App />);
  }

  it("loads releases for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "releases");
    renderWithSecondProduct("/releases");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads licenses for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "licenses");
    renderWithSecondProduct("/licenses");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads notifications for the persisted product", async () => {
    const templateLoader = vi.spyOn(opsClient, "notificationTemplates");
    const queueLoader = vi.spyOn(opsClient, "notifications");
    renderWithSecondProduct("/notifications");
    await waitFor(() => {
      expect(templateLoader).toHaveBeenCalledWith("second-product");
      expect(queueLoader).toHaveBeenCalledWith("second-product");
    });
  });

  it("loads GitHub issues and sync runs for the persisted product", async () => {
    const issuesLoader = vi.spyOn(opsClient, "githubIssues");
    const runsLoader = vi.spyOn(opsClient, "githubSyncRuns");
    renderWithSecondProduct("/github-issues");
    await waitFor(() => {
      expect(issuesLoader).toHaveBeenCalledWith("second-product");
      expect(runsLoader).toHaveBeenCalledWith("second-product");
    });
  });

  it("loads AI analysis for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "aiAnalysis");
    const actionLoader = vi.spyOn(opsClient, "proposedActions");
    renderWithSecondProduct("/ai-analysis");
    await waitFor(() => {
      expect(loader).toHaveBeenCalledWith("second-product");
      expect(actionLoader).toHaveBeenCalledWith("second-product");
    });
  });

  it("loads audit logs for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "auditLogs");
    renderWithSecondProduct("/audit-logs");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads settings for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "settingsSummary");
    renderWithSecondProduct("/settings");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads feedback for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "feedback");
    renderWithSecondProduct("/feedback");
    await waitFor(() => {
      expect(loader).toHaveBeenCalledWith("second-product", expect.any(Object));
    });
  });

  it("loads channels for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "channels");
    renderWithSecondProduct("/channels");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads customers for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "customers");
    renderWithSecondProduct("/customers");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads plans for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "plans");
    renderWithSecondProduct("/plans");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("loads connectors for the persisted product", async () => {
    const loader = vi.spyOn(opsClient, "connectors");
    renderWithSecondProduct("/connectors");
    await waitFor(() => expect(loader).toHaveBeenCalledWith("second-product"));
  });

  it("opens the release form from the dashboard deep link", async () => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/releases?create=1");

    render(<App />);

    expect(screen.getByRole("heading", { name: "创建发布草稿" })).toBeInTheDocument();
  });

  it("links GitHub configuration to the connector workspace", () => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/github-issues");

    render(<App />);

    expect(screen.getByRole("link", { name: "配置 GitHub" })).toHaveAttribute(
      "href",
      "/connectors?type=github"
    );
  });

  it("links Agent configuration to the connector workspace", () => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/ai-analysis");

    render(<App />);

    expect(screen.getByRole("link", { name: "配置 Agent API" })).toHaveAttribute(
      "href",
      "/connectors?type=agent_api"
    );
  });

  it("opens a connector configuration form from the query parameter", async () => {
    renderWithSecondProduct("/connectors?type=github");

    expect(
      await screen.findByRole("heading", { name: "配置 GitHub Issues" })
    ).toBeInTheDocument();
  });

  it("does not reset the connector form after the user selects another connector", async () => {
    renderWithSecondProduct("/connectors?type=github");

    expect(
      await screen.findByRole("heading", { name: "配置 GitHub Issues" })
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "配置 SMTP" }));

    await waitFor(() => {
      expect(screen.getByRole("heading", { name: "配置 SMTP" })).toBeInTheDocument();
      expect(
        screen.queryByRole("heading", { name: "配置 GitHub Issues" })
      ).not.toBeInTheDocument();
    });
  });

  it("edits an AI analysis and saves it as edited and accepted", async () => {
    const analysis = {
      id: "ai_edit",
      target: "feedback / fb_edit",
      agent: "codex",
      model: "gpt-5",
      analysisType: "triage",
      summary: "旧摘要",
      classification: "bug",
      confidence: "0.9",
      adoptionState: "Pending",
      createdAt: "刚刚"
    };
    vi.spyOn(opsClient, "aiAnalysis").mockResolvedValue([analysis]);
    const review = vi.spyOn(opsClient, "reviewAiAnalysis").mockResolvedValue(undefined);
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/ai-analysis");

    render(<App />);

    fireEvent.click(await screen.findByRole("button", { name: "编辑 feedback / fb_edit" }));
    fireEvent.change(screen.getByLabelText("编辑摘要"), {
      target: { value: "人工修订后的摘要" }
    });
    fireEvent.change(screen.getByLabelText("编辑分类"), {
      target: { value: "feature" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存并采纳" }));

    await waitFor(() => {
      expect(review).toHaveBeenCalledWith(
        "ai_edit",
        "edited_accepted",
        "stacio",
        {
          summary: "人工修订后的摘要",
          classification: "feature"
        }
      );
    });
  });

  it("reviews a proposed action from the AI analysis page", async () => {
    const proposedAction = {
      id: "act_review",
      actionType: "feedback.update_status",
      target: "feedback / fb_001",
      payloadPreview: "status: in_progress",
      rationale: "保存失败影响核心链路。",
      agent: "codex-action-agent",
      model: "gpt-5",
      status: "Pending",
      createdAt: "刚刚"
    };
    vi.spyOn(opsClient, "aiAnalysis").mockResolvedValue([]);
    vi.spyOn(opsClient, "proposedActions").mockResolvedValue([proposedAction]);
    const review = vi.spyOn(opsClient, "reviewProposedAction").mockResolvedValue({
      ...proposedAction,
      status: "Accepted"
    });
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/ai-analysis");

    render(<App />);

    expect(await screen.findByText("保存失败影响核心链路。")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "采纳建议 feedback.update_status" }));

    await waitFor(() => {
      expect(review).toHaveBeenCalledWith("act_review", "accepted", "stacio");
    });
  });

  it("filters audit events by action category", async () => {
    vi.spyOn(opsClient, "auditLogs").mockResolvedValue([
      {
        id: "audit_release",
        time: "刚刚",
        actor: "owner",
        actorType: "User",
        action: "release.publish",
        target: "release / rel_1",
        detail: "published",
        ip: "127.0.0.1"
      },
      {
        id: "audit_login",
        time: "刚刚",
        actor: "owner",
        actorType: "User",
        action: "auth.login",
        target: "session",
        detail: "success",
        ip: "127.0.0.1"
      }
    ]);
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/audit-logs");

    render(<App />);

    await screen.findByText("release.publish");
    fireEvent.click(screen.getByRole("button", { name: "发布" }));

    expect(screen.getByText("release.publish")).toBeInTheDocument();
    expect(screen.queryByText("auth.login")).not.toBeInTheDocument();
  });

  it("refreshes the settings summary on demand", async () => {
    const loader = vi.spyOn(opsClient, "settingsSummary");
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", "/settings");

    render(<App />);
    await waitFor(() => expect(loader).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole("button", { name: "刷新状态" }));

    await waitFor(() => expect(loader).toHaveBeenCalledTimes(2));
  });

  it.each([
    ["/products", "产品管理", "产品资料"],
    ["/github-issues", "GitHub 问题", "同步入队"],
    ["/ai-analysis", "AI 分析中心", "分析队列"],
    ["/channels", "分发渠道", "发布护栏"],
    ["/customers", "客户管理", "合并到客户"],
    ["/plans", "订阅计划", "License 策略"],
    ["/notifications", "通知中心", "邮件模板"],
    ["/connectors", "连接器", "GitHub Issues"],
    ["/audit-logs", "审计日志", "事件明细"],
    ["/settings", "系统设置", "外部服务"]
  ])("renders the connected admin page for %s", (path, heading, marker) => {
    window.localStorage.setItem("stacio.ops.authToken", "test-token");
    window.history.pushState({}, "", path);

    render(<App />);

    expect(screen.getByRole("heading", { name: heading })).toBeInTheDocument();
    expect(screen.getByText(marker)).toBeInTheDocument();
  });
});
