// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { GitHubIssuesPage } from "./GitHubIssuesPage";

const githubIssue = {
  id: "ghi_1",
  number: 42,
  title: "GitHub synced bug",
  labels: ["bug", "p1"],
  author: "github-user",
  state: "Open",
  comments: 3,
  linkedFeedback: "fb_42",
  url: "https://github.com/example/stacio/issues/42",
  updatedAt: "2026/07/10"
};

const failedSyncRun = {
  id: "ghsync_failed_1",
  trigger: "Manual",
  status: "Failed",
  fetched: 0,
  changed: 0,
  feedbackCreated: 0,
  error: "GitHub API returned 403",
  finishedAt: "2026/07/10"
};

describe("GitHubIssuesPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "githubIssues").mockResolvedValue([githubIssue]);
    vi.spyOn(opsClient, "githubSyncRuns").mockResolvedValue([]);
    vi.spyOn(opsClient, "pullGitHubIssues").mockResolvedValue({ id: "job_1" });
    vi.spyOn(opsClient, "commentGitHubIssue").mockResolvedValue({
      commentId: "777",
      url: "https://github.com/example/stacio/issues/42#issuecomment-777",
      body: "Thanks, we have reproduced this issue."
    });
    vi.spyOn(opsClient, "updateGitHubIssue").mockResolvedValue({
      ...githubIssue,
      labels: ["bug", "priority:p0"],
      state: "Closed"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("posts a manually confirmed GitHub issue reply from the admin console", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("POST");
    render(<GitHubIssuesPage />);

    expect(await screen.findByText("GitHub synced bug")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "回复 #42" }));
    fireEvent.change(screen.getByLabelText("GitHub 回复内容"), {
      target: { value: "Thanks, we have reproduced this issue." }
    });
    fireEvent.click(screen.getByRole("button", { name: "发布 GitHub 回复" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.commentGitHubIssue).toHaveBeenCalledWith(
        "stacio",
        "ghi_1",
        {
          body: "Thanks, we have reproduced this issue.",
          confirmation: "POST"
        }
      );
    });

    expect(await screen.findByText("GitHub 回复已发布")).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: "查看 GitHub 评论" })
    ).toHaveAttribute(
      "href",
      "https://github.com/example/stacio/issues/42#issuecomment-777"
    );
  });

  it("surfaces the latest failed GitHub sync error in status and history", async () => {
    vi.mocked(opsClient.githubSyncRuns).mockResolvedValue([failedSyncRun]);
    render(<GitHubIssuesPage />);

    expect(await screen.findByText("GitHub API returned 403")).toBeInTheDocument();
    expect(screen.getByText("最后错误：GitHub API returned 403")).toBeInTheDocument();
    expect(screen.getAllByText("Failed")).toHaveLength(2);
  });

  it("surfaces GitHub issue loading failures to operators", async () => {
    vi.mocked(opsClient.githubIssues).mockRejectedValue(new Error("GitHub issues unavailable"));

    render(<GitHubIssuesPage />);

    expect(await screen.findByRole("alert")).toHaveTextContent("GitHub issues unavailable");
  });

  it("applies GitHub label changes and closes issues only after explicit confirmation", async () => {
    vi.spyOn(window, "prompt").mockImplementation((message) => {
      if ((message ?? "").includes("关闭")) return "CLOSE";
      return "APPLY_LABELS";
    });
    render(<GitHubIssuesPage />);

    expect(await screen.findByText("GitHub synced bug")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "编辑标签 #42" }));
    fireEvent.change(screen.getByLabelText("GitHub Labels"), {
      target: { value: "bug, priority:p0" }
    });
    fireEvent.click(screen.getByRole("button", { name: "应用 GitHub 标签" }));

    await waitFor(() => {
      expect(opsClient.updateGitHubIssue).toHaveBeenCalledWith(
        "stacio",
        "ghi_1",
        {
          labels: ["bug", "priority:p0"],
          confirmation: "APPLY_LABELS"
        }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "关闭 #42" }));
    await waitFor(() => {
      expect(opsClient.updateGitHubIssue).toHaveBeenCalledWith(
        "stacio",
        "ghi_1",
        {
          state: "closed",
          confirmation: "CLOSE"
        }
      );
    });
  });
});
