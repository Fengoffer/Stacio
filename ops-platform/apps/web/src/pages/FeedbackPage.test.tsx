// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { FeedbackPage } from "./FeedbackPage";

const product = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  iconUrl: "",
  description: "",
  currentStableVersion: "1.0.0",
  currentBetaVersion: "1.1.0-beta",
  supportEmail: "support@example.com",
  githubOwner: "example",
  githubRepository: "stacio",
  updateBaseUrl: "",
  appcastBaseUrl: "",
  licensePolicy: {},
  dataRetentionPolicy: {},
  emailBrand: {},
  objectStoragePrefix: "products/stacio",
  status: "active" as const,
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const feedback = {
  id: "fb_1",
  productId: "stacio",
  title: "登录后崩溃",
  description: "用户登录后应用立即退出。",
  type: "bug",
  status: "new",
  priority: "P1",
  source: "app",
  contactEmail: "customer@example.com",
  appVersion: "1.0.0",
  buildNumber: "100",
  osVersion: "macOS 15.5",
  diagnosticsSummary: { crash: true },
  aiSummary: "登录流程出现崩溃。",
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const duplicateTargetFeedback = {
  ...feedback,
  id: "fb_2",
  title: "同类登录崩溃",
  description: "另一位用户提交的同类登录崩溃。",
  priority: "P2",
  contactEmail: "second@example.com",
  aiSummary: "同类登录问题。",
  createdAt: "2026-07-09T00:00:00.000Z",
  updatedAt: "2026-07-09T00:00:00.000Z"
};

const detail = {
  ...feedback,
  comments: [],
  attachments: [],
  linkedGitHubIssues: [],
  auditEvents: [
    {
      id: "audit_1",
      actorType: "user",
      actorId: "usr_owner",
      action: "feedback.updated",
      targetType: "feedback",
      targetId: "fb_1",
      metadata: {},
      createdAt: "2026-07-10T00:30:00.000Z"
    }
  ]
};

const issue = {
  id: "ghi_1",
  productId: "stacio",
  githubIssueId: "1001",
  number: 101,
  title: "Login crash",
  body: "Crash after login",
  labels: ["bug"],
  author: "octocat",
  state: "open",
  commentsCount: 1,
  url: "https://github.com/example/stacio/issues/101",
  syncedAt: "2026-07-10T00:00:00.000Z",
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const githubListIssue = {
  id: "ghi_1",
  number: 101,
  title: "Login crash",
  labels: ["bug"],
  author: "octocat",
  state: "Open",
  comments: 1,
  linkedFeedback: "-",
  url: "https://github.com/example/stacio/issues/101",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const release = {
  id: "rel_002",
  version: "0.13.2-Beta",
  build: "12",
  channel: "beta",
  status: "Ready",
  artifact: "Stacio-0.13.2-Beta.dmg",
  checks: "12/12",
  updatedAt: "2026/07/10"
};

const agentSummary = {
  id: "ai_feedback_summary",
  target: "feedback / fb_1",
  targetType: "feedback",
  targetId: "fb_1",
  agent: "codex",
  model: "gpt-5",
  analysisType: "Feedback Triage",
  summary: "登录崩溃集中发生在 1.0.0，应按 P1 处理。",
  classification: "bug",
  outputBody: {
    summary: "登录崩溃集中发生在 1.0.0，应按 P1 处理。",
    classification: "bug",
    suggestedPriority: "P1"
  },
  confidence: "0.92",
  adoptionState: "Pending",
  createdAt: "2026/07/10"
};

const agentReplyDraft = {
  id: "ai_feedback_reply",
  target: "feedback / fb_1",
  targetType: "feedback",
  targetId: "fb_1",
  agent: "claude",
  model: "claude-opus",
  analysisType: "Feedback Reply Draft",
  summary: "建议回复客户安装新版并提供日志。",
  classification: "reply_draft",
  replyDraft: "请升级到 1.0.1 后重试，如果仍然崩溃请把诊断日志发给我们。",
  outputBody: {
    replyDraft: "请升级到 1.0.1 后重试，如果仍然崩溃请把诊断日志发给我们。"
  },
  confidence: "0.88",
  adoptionState: "Pending",
  createdAt: "2026/07/10"
};

const agentRequest = {
  id: "agent_req_1",
  productId: "stacio",
  targetType: "feedback",
  targetId: "fb_1",
  requestType: "summary",
  agentHint: "codex",
  prompt: "请总结这条反馈并给出建议优先级。",
  status: "queued",
  requestedBy: "usr_owner",
  metadata: {},
  createdAt: "2026/07/10",
  updatedAt: "2026/07/10"
};

describe("FeedbackPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue([product]);
    vi.spyOn(opsClient, "feedback").mockResolvedValue([feedback, duplicateTargetFeedback]);
    vi.spyOn(opsClient, "feedbackDetail").mockResolvedValue(detail);
    vi.spyOn(opsClient, "githubIssues").mockResolvedValue([githubListIssue]);
    vi.spyOn(opsClient, "releases").mockResolvedValue([release]);
    vi.spyOn(opsClient, "aiAnalysis").mockResolvedValue([agentSummary, agentReplyDraft]);
    vi.spyOn(opsClient, "reviewAiAnalysis").mockResolvedValue(undefined);
    vi.spyOn(opsClient, "feedbackAgentRequests").mockResolvedValue([]);
    vi.spyOn(opsClient, "createFeedbackAgentRequest").mockResolvedValue(agentRequest);
    vi.spyOn(opsClient, "updateFeedback").mockResolvedValue({
      ...feedback,
      status: "in_progress"
    });
    vi.spyOn(opsClient, "batchUpdateFeedback").mockResolvedValue([
      {
        ...feedback,
        status: "triaged",
        priority: "P0",
        assignedUserId: "owner-1"
      }
    ]);
    vi.spyOn(opsClient, "addFeedbackComment").mockResolvedValue({
      id: "comment_1",
      feedbackId: "fb_1",
      authorType: "user",
      visibility: "internal",
      body: "正在排查。",
      deliveryStatus: "not_applicable",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "sendFeedbackReply").mockResolvedValue({
      comment: {
        id: "comment_2",
        feedbackId: "fb_1",
        authorType: "user",
        visibility: "public",
        body: "请重试最新版本。",
        deliveryStatus: "queued",
        createdAt: "2026-07-10T00:00:00.000Z",
        updatedAt: "2026-07-10T00:00:00.000Z"
      }
    });
    vi.spyOn(opsClient, "linkFeedbackGitHubIssue").mockResolvedValue(issue);
    vi.spyOn(opsClient, "unlinkFeedbackGitHubIssue").mockResolvedValue(issue);
    vi.spyOn(opsClient, "redactFeedback").mockResolvedValue(feedback);
    vi.spyOn(opsClient, "deleteFeedback").mockResolvedValue({
      ...feedback,
      deletedAt: "2026-07-10T01:00:00.000Z"
    });
    vi.spyOn(opsClient, "pullGitHubIssues").mockResolvedValue({ id: "job_1" });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("triages feedback, adds an internal note, sends a reply, and links GitHub", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("SEND");
    render(<FeedbackPage />);

    expect(await screen.findByRole("heading", { name: "用户反馈" })).toBeInTheDocument();
    expect(screen.getByLabelText("当前产品")).toHaveValue("stacio");
    expect(screen.getByText("总反馈")).toBeInTheDocument();
    expect(screen.getByLabelText("搜索反馈")).toHaveAttribute(
      "placeholder",
      "标题、内容、邮箱、版本、GitHub Issue 或 ID"
    );

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();
    expect(screen.getByText("审计轨迹")).toBeInTheDocument();
    expect(screen.getByText("feedback.updated")).toBeInTheDocument();
    await waitFor(() => {
      expect(opsClient.aiAnalysis).toHaveBeenCalledWith("stacio", {
        targetType: "feedback",
        targetId: "fb_1"
      });
    });

    fireEvent.change(screen.getByLabelText("反馈状态"), {
      target: { value: "in_progress" }
    });
    await waitFor(() => {
      expect(opsClient.updateFeedback).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        { status: "in_progress" }
      );
    });

    fireEvent.change(screen.getByLabelText("内部备注"), {
      target: { value: "正在排查。" }
    });
    fireEvent.click(screen.getByRole("button", { name: "添加内部备注" }));
    await waitFor(() => {
      expect(opsClient.addFeedbackComment).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        { visibility: "internal", body: "正在排查。" }
      );
    });

    fireEvent.change(screen.getByLabelText("客户回复"), {
      target: { value: "请重试最新版本。" }
    });
    fireEvent.click(screen.getByRole("button", { name: "确认并发送回复" }));
    await waitFor(() => {
      expect(opsClient.sendFeedbackReply).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        "请重试最新版本。"
      );
    });

    fireEvent.change(screen.getByLabelText("关联 GitHub Issue"), {
      target: { value: "ghi_1" }
    });
    fireEvent.click(screen.getByRole("button", { name: "关联 Issue" }));
    await waitFor(() => {
      expect(opsClient.linkFeedbackGitHubIssue).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        "ghi_1"
      );
    });
  });

  it("reviews agent feedback analysis and applies reply drafts without sending email", async () => {
    render(<FeedbackPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();
    expect(await screen.findByText("登录崩溃集中发生在 1.0.0，应按 P1 处理。")).toBeInTheDocument();
    expect(screen.getByText("请升级到 1.0.1 后重试，如果仍然崩溃请把诊断日志发给我们。")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "采纳 AI 摘要 codex" }));
    await waitFor(() => {
      expect(opsClient.reviewAiAnalysis).toHaveBeenCalledWith(
        "ai_feedback_summary",
        "accepted",
        "stacio"
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "使用回复草稿 claude" }));
    expect(screen.getByLabelText("客户回复")).toHaveValue(
      "请升级到 1.0.1 后重试，如果仍然崩溃请把诊断日志发给我们。"
    );
    expect(opsClient.sendFeedbackReply).not.toHaveBeenCalled();
  });

  it("queues Agent summary and reply draft requests from the feedback detail", async () => {
    render(<FeedbackPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "请求 Agent 摘要" }));
    await waitFor(() => {
      expect(opsClient.createFeedbackAgentRequest).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        expect.objectContaining({
          requestType: "summary",
          prompt: expect.stringContaining("总结")
        })
      );
    });
    expect(await screen.findByText("Agent 请求已排队：summary")).toBeInTheDocument();

    vi.mocked(opsClient.createFeedbackAgentRequest).mockResolvedValueOnce({
      ...agentRequest,
      id: "agent_req_2",
      requestType: "reply_draft",
      prompt: "请基于当前反馈起草一封客户可见回复。"
    });
    fireEvent.click(screen.getByRole("button", { name: "请求 Agent 回复草稿" }));
    await waitFor(() => {
      expect(opsClient.createFeedbackAgentRequest).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        expect.objectContaining({
          requestType: "reply_draft",
          prompt: expect.stringContaining("客户可见回复")
        })
      );
    });
    expect(await screen.findByText("Agent 请求已排队：reply_draft")).toBeInTheDocument();
    expect(opsClient.sendFeedbackReply).not.toHaveBeenCalled();
  });

  it("marks feedback as duplicate from the detail panel", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("DUPLICATE");
    vi.mocked(opsClient.updateFeedback).mockResolvedValueOnce({
      ...feedback,
      status: "duplicate",
      duplicateOfId: "fb_2"
    });
    render(<FeedbackPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("重复目标"), {
      target: { value: "fb_2" }
    });
    fireEvent.click(screen.getByRole("button", { name: "标记为重复" }));

    await waitFor(() => {
      expect(opsClient.updateFeedback).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        {
          status: "duplicate",
          duplicateOfId: "fb_2"
        }
      );
    });
  });

  it("links feedback to a related release from the detail panel", async () => {
    vi.mocked(opsClient.updateFeedback).mockResolvedValueOnce({
      ...feedback,
      relatedReleaseId: "rel_002"
    });
    render(<FeedbackPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("关联发布版本"), {
      target: { value: "rel_002" }
    });
    fireEvent.click(screen.getByRole("button", { name: "关联发布" }));

    await waitFor(() => {
      expect(opsClient.updateFeedback).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        {
          relatedReleaseId: "rel_002"
        }
      );
    });
  });

  it("assigns a feedback owner from the detail panel", async () => {
    vi.mocked(opsClient.updateFeedback).mockResolvedValueOnce({
      ...feedback,
      assignedUserId: "usr_owner"
    });
    render(<FeedbackPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看反馈 登录后崩溃" }));
    expect(await screen.findByRole("heading", { name: "登录后崩溃" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("指派负责人"), {
      target: { value: "usr_owner" }
    });
    fireEvent.click(screen.getByRole("button", { name: "指派" }));

    await waitFor(() => {
      expect(opsClient.updateFeedback).toHaveBeenCalledWith(
        "stacio",
        "fb_1",
        {
          assignedUserId: "usr_owner"
        }
      );
    });
  });

  it("supports batch status, priority, and assignee updates from the list", async () => {
    render(<FeedbackPage />);

    expect(await screen.findByRole("heading", { name: "用户反馈" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: "选择反馈 登录后崩溃" }));
    fireEvent.change(screen.getByLabelText("批量状态"), {
      target: { value: "triaged" }
    });
    fireEvent.change(screen.getByLabelText("批量优先级"), {
      target: { value: "P0" }
    });
    fireEvent.change(screen.getByLabelText("批量指派人"), {
      target: { value: "owner-1" }
    });
    fireEvent.click(screen.getByRole("button", { name: "应用批量更新" }));

    await waitFor(() => {
      expect(opsClient.batchUpdateFeedback).toHaveBeenCalledWith(
        "stacio",
        ["fb_1"],
        {
          status: "triaged",
          priority: "P0",
          assignedUserId: "owner-1"
        }
      );
    });
  });

  it("filters by version, license state, and created date range", async () => {
    render(<FeedbackPage />);

    expect(await screen.findByRole("heading", { name: "用户反馈" })).toBeInTheDocument();
    vi.mocked(opsClient.feedback).mockClear();

    fireEvent.change(screen.getByLabelText("筛选版本"), {
      target: { value: "0.13.2-Beta" }
    });
    fireEvent.change(screen.getByLabelText("筛选 License"), {
      target: { value: "licensed" }
    });
    fireEvent.change(screen.getByLabelText("开始日期"), {
      target: { value: "2026-07-01" }
    });
    fireEvent.change(screen.getByLabelText("结束日期"), {
      target: { value: "2026-07-10" }
    });

    await waitFor(() => {
      expect(opsClient.feedback).toHaveBeenLastCalledWith(
        "stacio",
        expect.objectContaining({
          version: "0.13.2-Beta",
          licenseState: "licensed",
          createdFrom: "2026-07-01",
          createdTo: "2026-07-10"
        })
      );
    });
  });

  it("shows API errors instead of silently replacing the workspace", async () => {
    vi.mocked(opsClient.feedback).mockRejectedValueOnce(new Error("Feedback unavailable"));
    render(<FeedbackPage />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Feedback unavailable");
  });
});
