// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { AiAnalysisPage } from "./AiAnalysisPage";

const analysis = {
  id: "ai_feedback_triage",
  target: "feedback / fb_123",
  agent: "codex",
  model: "gpt-5",
  analysisType: "triage",
  summary: "用户反馈指向远端保存失败，应作为 P1 bug 处理。",
  classification: "bug",
  confidence: "0.91",
  inputReferencesPreview: "feedbackId: fb_123, githubIssue: #44",
  outputBodyPreview: "summary: 用户反馈指向远端保存失败，应作为 P1 bug 处理。, classification: bug",
  adoptionState: "Pending",
  createdAt: "2026/07/10"
};

const proposedAction = {
  id: "act_update_status",
  actionType: "feedback.update_status",
  target: "feedback / fb_123",
  payloadPreview: "status: in_progress",
  rationale: "保存失败影响核心流程，需要进入处理中。",
  agent: "codex",
  model: "gpt-5",
  status: "Pending",
  createdAt: "2026/07/10"
};

describe("AiAnalysisPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "aiAnalysis").mockResolvedValue([analysis]);
    vi.spyOn(opsClient, "proposedActions").mockResolvedValue([proposedAction]);
    vi.spyOn(opsClient, "reviewAiAnalysis").mockResolvedValue(undefined);
    vi.spyOn(opsClient, "reviewProposedAction").mockResolvedValue(undefined);
    vi.spyOn(opsClient, "executeProposedAction").mockResolvedValue(undefined);
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("reviews AI analyses and proposed actions with contextual controls", async () => {
    render(<AiAnalysisPage />);

    expect(await screen.findByText("feedback / fb_123")).toBeInTheDocument();
    expect(screen.getByText("输入依据")).toBeInTheDocument();
    expect(screen.getByText("feedbackId: fb_123, githubIssue: #44")).toBeInTheDocument();
    expect(screen.getByText("输出详情")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "采纳分析 feedback / fb_123" }));
    await waitFor(() => {
      expect(opsClient.reviewAiAnalysis).toHaveBeenCalledWith(
        "ai_feedback_triage",
        "accepted",
        "stacio"
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "采纳建议 feedback.update_status" }));
    await waitFor(() => {
      expect(opsClient.reviewProposedAction).toHaveBeenCalledWith(
        "act_update_status",
        "accepted",
        "stacio"
      );
    });
  });

  it("executes accepted proposed actions from the human review queue", async () => {
    vi.mocked(opsClient.proposedActions).mockResolvedValue([
      {
        ...proposedAction,
        status: "Accepted"
      }
    ]);

    render(<AiAnalysisPage />);

    expect(await screen.findByText("保存失败影响核心流程，需要进入处理中。")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "执行建议 feedback.update_status" }));

    await waitFor(() => {
      expect(opsClient.executeProposedAction).toHaveBeenCalledWith(
        "act_update_status",
        "stacio"
      );
    });
  });

  it("surfaces AI analysis loading failures to operators", async () => {
    vi.mocked(opsClient.aiAnalysis).mockRejectedValue(new Error("AI analysis unavailable"));

    render(<AiAnalysisPage />);

    expect(await screen.findByRole("alert")).toHaveTextContent("AI analysis unavailable");
  });
});
