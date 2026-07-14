// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { ReleasesPage } from "./ReleasesPage";

const readyRelease = {
  id: "release_0140",
  version: "0.14.0",
  build: "140",
  channel: "stable",
  status: "Ready",
  artifact: "Stacio-0.14.0.dmg",
  artifactName: "Stacio-0.14.0.dmg",
  artifactUrl: "https://updates.example.com/Stacio-0.14.0.dmg",
  artifactType: "application/x-apple-diskimage",
  artifactSize: 2048,
  minimumSystemVersion: "14.0",
  sparkleEdDsaSignature: "old-signature",
  releaseNotes: "Initial release notes.",
  createdBy: "usr_development_owner",
  publishedBy: "usr_release_admin",
  checks: "12/12",
  updatedAt: "2026/7/10",
  aiReleaseSummary: "AI summary: stable rollout is low risk.",
  aiRiskSummary: "Risk: Sparkle signature must be verified before publish."
};

describe("ReleasesPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "releases").mockResolvedValue([readyRelease]);
    vi.spyOn(opsClient, "createRelease").mockResolvedValue({
      id: "release_0141",
      productId: "stacio",
      version: "0.14.1",
      buildNumber: "141",
      channel: "beta",
      status: "draft",
      artifactName: "Stacio-0.14.1-Beta.dmg",
      artifactUrl: "https://objects.example.com/Stacio-0.14.1-Beta.dmg",
      artifactSize: 1048576,
      sparkleEdDsaSignature: "signature",
      releaseNotes: "Beta release notes",
      createdAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "updateReleaseDraft").mockResolvedValue({
      id: "release_0140",
      productId: "stacio",
      version: "0.14.0",
      buildNumber: "140",
      channel: "stable",
      status: "draft",
      artifactName: "Stacio-0.14.0.dmg",
      artifactUrl: "https://objects.example.com/Stacio-0.14.0.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 4096,
      sparkleEdDsaSignature: "new-signature",
      releaseNotes: "Edited release notes.",
      aiReleaseSummary: "Edited AI summary.",
      aiRiskSummary: "Edited risk summary.",
      createdAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "validateRelease").mockResolvedValue({
      passed: true,
      checks: [
        { key: "artifact_url", passed: true, message: "Artifact URL is present" }
      ]
    });
    vi.spyOn(opsClient, "presignReleaseArtifactUpload").mockResolvedValue({
      objectKey: "products/stacio/release_artifact/Stacio-0.14.1-Beta.dmg",
      uploadUrl: "https://storage.example.com/upload/Stacio-0.14.1-Beta.dmg",
      publicUrl: "https://objects.example.com/Stacio-0.14.1-Beta.dmg"
    });
    vi.spyOn(opsClient, "publishRelease").mockResolvedValue({ id: "release_0140" });
    vi.spyOn(opsClient, "updateReleaseLifecycle").mockResolvedValue({ id: "release_0140" });
    vi.spyOn(opsClient, "previewReleaseAppcastDiff").mockResolvedValue({
      releaseId: "release_0140",
      channel: "stable",
      addedItem: {
        version: "0.14.0",
        buildNumber: "140"
      },
      currentItemCount: 1,
      previewItemCount: 2,
      currentXml: "<rss><channel></channel></rss>",
      previewXml: "<rss><channel><title>Stacio 0.14.0</title></channel></rss>"
    });
    vi.spyOn(opsClient, "appcastEntries").mockResolvedValue([
      {
        id: "appcast_1",
        productId: "stacio",
        channelId: "channel_stacio_stable",
        channelName: "stable",
        releaseId: "release_0140",
        xml: "<rss><channel><title>Stacio 0.14.0</title></channel></rss>",
        objectKey: "products/stacio/releases/stable/appcast.xml",
        publishedAt: "2026-07-10T10:00:00.000Z",
        createdAt: "2026-07-10T10:00:00.000Z"
      }
    ]);
    vi.spyOn(opsClient, "releaseArtifacts").mockResolvedValue([
      {
        id: "artifact_1",
        productId: "stacio",
        releaseId: "release_0140",
        objectKey: "products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
        url: "https://objects.example.com/Stacio-0.14.0.dmg",
        fileName: "Stacio-0.14.0.dmg",
        contentType: "application/x-apple-diskimage",
        sizeBytes: 2048,
        sha256: "a".repeat(64),
        signatureEvidence: {},
        createdAt: "2026-07-10T09:00:00.000Z"
      }
    ]);
    vi.spyOn(opsClient, "checkReleaseDownload").mockResolvedValue({
      release: {
        id: "release_0140",
        productId: "stacio",
        version: "0.14.0",
        buildNumber: "140",
        channel: "stable",
        status: "draft",
        artifactName: "Stacio-0.14.0.dmg",
        createdAt: "2026-07-10T00:00:00.000Z"
      },
      downloadReachabilityEvidence: {
        status: "reachable",
        statusCode: 200,
        contentLength: 2048,
        summary: "Download URL responded to HEAD"
      }
    });
    vi.spyOn(opsClient, "createReleaseAgentRequest").mockResolvedValue({
      id: "agent_req_release_notes",
      productId: "stacio",
      targetType: "release",
      targetId: "release_0140",
      requestType: "release_notes",
      agentHint: "codex",
      prompt: "请基于 0.14.0 生成面向用户的发布说明草稿。",
      status: "Queued",
      metadata: {},
      createdAt: "2026/7/10",
      updatedAt: "2026/7/10"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates, validates, and manually publishes an OTA release", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("PUBLISH");
    render(<ReleasesPage />);

    expect(await screen.findByText("0.14.0")).toBeInTheDocument();
    expect(screen.getByRole("table")).toHaveClass("release-data-table");
    const stepper = screen.getByRole("list", { name: "Release workflow" });
    expect(within(stepper).getByText("Draft")).toBeInTheDocument();
    expect(within(stepper).getByText("Validate")).toBeInTheDocument();
    expect(within(stepper).getByText("Review")).toBeInTheDocument();
    expect(within(stepper).getByText("Publish")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "创建发布" }));
    expect(screen.getByRole("dialog", { name: "创建发布草稿" })).toHaveClass("connector-modal-resizable");
    fireEvent.change(screen.getByLabelText("版本号"), {
      target: { value: "0.14.1" }
    });
    fireEvent.change(screen.getByLabelText("Build Number"), {
      target: { value: "141" }
    });
    fireEvent.change(screen.getByLabelText("发布通道"), {
      target: { value: "beta" }
    });
    fireEvent.change(screen.getByLabelText("Artifact 名称"), {
      target: { value: "Stacio-0.14.1-Beta.dmg" }
    });
    fireEvent.change(screen.getByLabelText("Artifact URL"), {
      target: { value: "https://objects.example.com/Stacio-0.14.1-Beta.dmg" }
    });
    fireEvent.change(screen.getByLabelText("Artifact 大小"), {
      target: { value: "1048576" }
    });
    fireEvent.change(screen.getByLabelText("Sparkle EdDSA 签名"), {
      target: { value: "signature" }
    });
    fireEvent.change(screen.getByLabelText("最低 macOS 版本"), {
      target: { value: "14.0" }
    });
    fireEvent.change(screen.getByLabelText("发布说明"), {
      target: { value: "Beta release notes" }
    });
    fireEvent.change(screen.getByLabelText("AI 发布摘要"), {
      target: { value: "AI generated release summary" }
    });
    fireEvent.change(screen.getByLabelText("AI 风险摘要"), {
      target: { value: "AI generated risk summary" }
    });
    fireEvent.change(screen.getByLabelText("包签名验证状态"), {
      target: { value: "passed" }
    });
    fireEvent.change(screen.getByLabelText("包签名验证工具"), {
      target: { value: "codesign" }
    });
    fireEvent.change(screen.getByLabelText("包签名验证摘要"), {
      target: { value: "Developer ID signature verified." }
    });
    fireEvent.change(screen.getByLabelText("下载可达性状态"), {
      target: { value: "reachable" }
    });
    fireEvent.change(screen.getByLabelText("下载 HTTP 状态码"), {
      target: { value: "200" }
    });
    fireEvent.change(screen.getByLabelText("下载 Content-Length"), {
      target: { value: "1048576" }
    });
    fireEvent.change(screen.getByLabelText("下载可达性摘要"), {
      target: { value: "HEAD request returned 200." }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存发布草稿" }));

    await waitFor(() => {
      expect(opsClient.createRelease).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          version: "0.14.1",
          buildNumber: "141",
          channel: "beta",
          artifactName: "Stacio-0.14.1-Beta.dmg",
          artifactSize: 1048576,
          sparkleEdDsaSignature: "signature",
          minimumSystemVersion: "14.0",
          releaseNotes: "Beta release notes",
          aiReleaseSummary: "AI generated release summary",
          aiRiskSummary: "AI generated risk summary",
          packageSignatureEvidence: {
            status: "passed",
            tool: "codesign",
            summary: "Developer ID signature verified."
          },
          downloadReachabilityEvidence: {
            status: "reachable",
            statusCode: 200,
            contentLength: 1048576,
            summary: "HEAD request returned 200."
          }
        })
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "校验 0.14.0" }));
    await waitFor(() => {
      expect(opsClient.validateRelease).toHaveBeenCalledWith("stacio", "release_0140");
    });
    expect(await screen.findByText("Artifact URL is present")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "发布 0.14.0" }));
    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.publishRelease).toHaveBeenCalledWith("release_0140", "stacio");
    });
  });

  it("generates an object-storage upload URL for release artifacts", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "创建发布" }));
    fireEvent.change(screen.getByLabelText("Artifact 名称"), {
      target: { value: "Stacio-0.14.1-Beta.dmg" }
    });
    fireEvent.change(screen.getByLabelText("Artifact 类型"), {
      target: { value: "application/x-apple-diskimage" }
    });
    fireEvent.change(screen.getByLabelText("Artifact 大小"), {
      target: { value: "1048576" }
    });

    fireEvent.click(screen.getByRole("button", { name: "生成上传 URL" }));

    await waitFor(() => {
      expect(opsClient.presignReleaseArtifactUpload).toHaveBeenCalledWith(
        "stacio",
        {
          fileName: "Stacio-0.14.1-Beta.dmg",
          contentType: "application/x-apple-diskimage",
          sizeBytes: 1048576
        }
      );
    });
    expect(screen.getByLabelText("Artifact URL")).toHaveValue(
      "https://objects.example.com/Stacio-0.14.1-Beta.dmg"
    );
    expect(screen.getByText(/上传 URL 已生成/)).toBeInTheDocument();
  });

  it("previews the Sparkle appcast diff before publishing", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "预览 appcast diff 0.14.0" }));

    await waitFor(() => {
      expect(opsClient.previewReleaseAppcastDiff).toHaveBeenCalledWith("stacio", "release_0140");
    });
    const diffPanel = screen.getByRole("heading", { name: "Appcast Diff" }).closest("section");
    expect(diffPanel).not.toBeNull();
    expect(within(diffPanel as HTMLElement).getByText("0.14.0")).toBeInTheDocument();
    expect(within(diffPanel as HTMLElement).getByText(/preview items: 2/)).toBeInTheDocument();
  });

  it("shows persisted appcast snapshots from published releases", async () => {
    render(<ReleasesPage />);

    expect(await screen.findByRole("heading", { name: "Appcast 快照" })).toBeInTheDocument();
    const panel = screen.getByRole("heading", { name: "Appcast 快照" }).closest("section");
    expect(panel).not.toBeNull();
    expect(opsClient.appcastEntries).toHaveBeenCalledWith("stacio");
    expect(
      await within(panel as HTMLElement).findByText(
        "products/stacio/releases/stable/appcast.xml"
      )
    ).toBeInTheDocument();
    expect(within(panel as HTMLElement).getByText("stable")).toBeInTheDocument();
  });

  it("shows per-target publication status for a released version", async () => {
    vi.spyOn(opsClient, "releasePublications").mockResolvedValue([
      {
        id: "release_publication_storage",
        productId: "stacio",
        releaseId: "release_0140",
        target: "object_storage",
        status: "succeeded",
        attempts: 1,
        objectKey: "products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
        metadata: {},
        createdAt: "2026-07-11T00:00:00.000Z",
        updatedAt: "2026-07-11T00:00:00.000Z"
      },
      {
        id: "release_publication_github",
        productId: "stacio",
        releaseId: "release_0140",
        target: "github",
        status: "failed",
        attempts: 2,
        lastError: "GitHub token is not configured",
        metadata: {},
        createdAt: "2026-07-11T00:00:00.000Z",
        updatedAt: "2026-07-11T00:00:00.000Z"
      }
    ]);
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看同步状态 0.14.0" }));
    const dialog = await screen.findByRole("dialog", { name: "0.14.0 同步状态" });
    expect(within(dialog).getByText("object_storage")).toBeInTheDocument();
    expect(within(dialog).getByText("succeeded")).toBeInTheDocument();
    expect(within(dialog).getByText("GitHub token is not configured")).toBeInTheDocument();
  });

  it("loads release artifact history from a release row", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看 Artifacts 0.14.0" }));

    await waitFor(() => {
      expect(opsClient.releaseArtifacts).toHaveBeenCalledWith("stacio", "release_0140");
    });
    const panel = screen.getByRole("heading", { name: "Artifact 记录" }).closest("section");
    expect(panel).not.toBeNull();
    expect(within(panel as HTMLElement).getByText("Stacio-0.14.0.dmg")).toBeInTheDocument();
    expect(within(panel as HTMLElement).getByText("products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg")).toBeInTheDocument();
  });

  it("checks artifact download reachability from a release row", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "检查下载 0.14.0" }));

    await waitFor(() => {
      expect(opsClient.checkReleaseDownload).toHaveBeenCalledWith("stacio", "release_0140");
    });
    expect(await screen.findByText("下载检查完成：reachable")).toBeInTheDocument();
  });

  it("surfaces AI release summary and risk summary on release rows", async () => {
    render(<ReleasesPage />);

    expect(await screen.findByText("AI summary: stable rollout is low risk.")).toBeInTheDocument();
    expect(screen.getByText("Risk: Sparkle signature must be verified before publish.")).toBeInTheDocument();
  });

  it("shows release creator and publisher for auditability", async () => {
    render(<ReleasesPage />);

    expect(await screen.findByText("created: usr_development_owner")).toBeInTheDocument();
    expect(screen.getByText("published: usr_release_admin")).toBeInTheDocument();
  });

  it("edits an existing release draft without publishing OTA", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "编辑 0.14.0" }));
    expect(screen.getByRole("heading", { name: "编辑发布草稿" })).toBeInTheDocument();
    expect(screen.getByLabelText("Artifact URL")).toHaveValue(
      "https://updates.example.com/Stacio-0.14.0.dmg"
    );

    fireEvent.change(screen.getByLabelText("Artifact URL"), {
      target: { value: "https://objects.example.com/Stacio-0.14.0.dmg" }
    });
    fireEvent.change(screen.getByLabelText("Artifact 大小"), {
      target: { value: "4096" }
    });
    fireEvent.change(screen.getByLabelText("Sparkle EdDSA 签名"), {
      target: { value: "new-signature" }
    });
    fireEvent.change(screen.getByLabelText("发布说明"), {
      target: { value: "Edited release notes." }
    });
    fireEvent.change(screen.getByLabelText("AI 发布摘要"), {
      target: { value: "Edited AI summary." }
    });
    fireEvent.change(screen.getByLabelText("AI 风险摘要"), {
      target: { value: "Edited risk summary." }
    });

    fireEvent.click(screen.getByRole("button", { name: "更新发布草稿" }));

    await waitFor(() => {
      expect(opsClient.updateReleaseDraft).toHaveBeenCalledWith(
        "stacio",
        "release_0140",
        expect.objectContaining({
          artifactUrl: "https://objects.example.com/Stacio-0.14.0.dmg",
          artifactSize: 4096,
          sparkleEdDsaSignature: "new-signature",
          releaseNotes: "Edited release notes.",
          aiReleaseSummary: "Edited AI summary.",
          aiRiskSummary: "Edited risk summary."
        })
      );
    });
    expect(opsClient.publishRelease).not.toHaveBeenCalled();
    expect(await screen.findByText("发布草稿已更新，预检状态已重置")).toBeInTheDocument();
  });

  it("queues Agent release notes and risk summary requests from a release row", async () => {
    render(<ReleasesPage />);

    fireEvent.click(await screen.findByRole("button", { name: "请求 Agent 发布说明 0.14.0" }));
    await waitFor(() => {
      expect(opsClient.createReleaseAgentRequest).toHaveBeenCalledWith(
        "stacio",
        "release_0140",
        expect.objectContaining({
          requestType: "release_notes",
          agentHint: "codex",
          prompt: expect.stringContaining("0.14.0")
        })
      );
    });
    expect(await screen.findByText("Agent 请求已排队：release_notes")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "请求 Agent 风险摘要 0.14.0" }));
    await waitFor(() => {
      expect(opsClient.createReleaseAgentRequest).toHaveBeenCalledWith(
        "stacio",
        "release_0140",
        expect.objectContaining({
          requestType: "release_risk",
          agentHint: "claude",
          prompt: expect.stringContaining("0.14.0")
        })
      );
    });
  });
});
