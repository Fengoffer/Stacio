import { useEffect, useState, type FormEvent } from "react";
import {
  type AppcastEntryRecord,
  demoModeEnabled,
  opsClient,
  type ReleaseArtifactRecord,
  type ReleaseAppcastDiff,
  type ReleaseInput,
  type ReleasePublicationRecord,
  type ReleaseValidationResult
} from "../api/client";
import { releases } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type ReleaseRow = Awaited<ReturnType<typeof opsClient.releases>>[number];

interface ReleaseFormState {
  version: string;
  buildNumber: string;
  channel: ReleaseInput["channel"];
  minimumSystemVersion: string;
  artifactName: string;
  artifactUrl: string;
  artifactObjectKey: string;
  artifactType: string;
  artifactSize: string;
  artifactSha256: string;
  sparkleEdDsaSignature: string;
  releaseNotes: string;
  aiReleaseSummary: string;
  aiRiskSummary: string;
  packageSignatureStatus: "" | "passed" | "failed" | "not_available";
  packageSignatureTool: string;
  packageSignatureCheckedAt: string;
  packageSignatureSigner: string;
  packageSignatureSummary: string;
  downloadReachabilityStatus: "" | "reachable" | "unreachable" | "not_checked";
  downloadReachabilityCheckedAt: string;
  downloadReachabilityStatusCode: string;
  downloadReachabilityContentLength: string;
  downloadReachabilityError: string;
  downloadReachabilitySummary: string;
}

const emptyForm: ReleaseFormState = {
  version: "",
  buildNumber: "",
  channel: "stable",
  minimumSystemVersion: "14.0",
  artifactName: "",
  artifactUrl: "",
  artifactObjectKey: "",
  artifactType: "application/x-apple-diskimage",
  artifactSize: "",
  artifactSha256: "",
  sparkleEdDsaSignature: "",
  releaseNotes: "",
  aiReleaseSummary: "",
  aiRiskSummary: "",
  packageSignatureStatus: "",
  packageSignatureTool: "",
  packageSignatureCheckedAt: "",
  packageSignatureSigner: "",
  packageSignatureSummary: "",
  downloadReachabilityStatus: "",
  downloadReachabilityCheckedAt: "",
  downloadReachabilityStatusCode: "",
  downloadReachabilityContentLength: "",
  downloadReachabilityError: "",
  downloadReachabilitySummary: ""
};

const releaseWorkflowSteps = ["Draft", "Validate", "Review", "Publish"];

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback;
}

function releaseChannelFromRow(row: ReleaseRow): ReleaseInput["channel"] {
  if (["stable", "beta", "dev", "internal"].includes(row.channel)) {
    return row.channel as ReleaseInput["channel"];
  }
  return "stable";
}

function objectRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function formFromRelease(row: ReleaseRow): ReleaseFormState {
  const packageSignatureEvidence = objectRecord(row.preflightEvidence?.packageSignatureEvidence);
  const packageSignatureStatus = packageSignatureEvidence?.status;
  const downloadReachabilityEvidence = objectRecord(row.preflightEvidence?.downloadReachabilityEvidence);
  const downloadReachabilityStatus = downloadReachabilityEvidence?.status;
  return {
    version: row.version,
    buildNumber: row.build,
    channel: releaseChannelFromRow(row),
    minimumSystemVersion: row.minimumSystemVersion ?? "",
    artifactName: row.artifactName ?? row.artifact,
    artifactUrl: row.artifactUrl ?? "",
    artifactObjectKey: "",
    artifactType: row.artifactType ?? "application/x-apple-diskimage",
    artifactSize: row.artifactSize ? String(row.artifactSize) : "",
    artifactSha256: "",
    sparkleEdDsaSignature: row.sparkleEdDsaSignature ?? "",
    releaseNotes: row.releaseNotes ?? "",
    aiReleaseSummary: row.aiReleaseSummary ?? "",
    aiRiskSummary: row.aiRiskSummary ?? "",
    packageSignatureStatus:
      packageSignatureStatus === "passed" ||
      packageSignatureStatus === "failed" ||
      packageSignatureStatus === "not_available"
        ? packageSignatureStatus
        : "",
    packageSignatureTool: String(packageSignatureEvidence?.tool ?? ""),
    packageSignatureCheckedAt: String(packageSignatureEvidence?.checkedAt ?? ""),
    packageSignatureSigner: String(packageSignatureEvidence?.signer ?? ""),
    packageSignatureSummary: String(packageSignatureEvidence?.summary ?? ""),
    downloadReachabilityStatus:
      downloadReachabilityStatus === "reachable" ||
      downloadReachabilityStatus === "unreachable" ||
      downloadReachabilityStatus === "not_checked"
        ? downloadReachabilityStatus
        : "",
    downloadReachabilityCheckedAt: String(downloadReachabilityEvidence?.checkedAt ?? ""),
    downloadReachabilityStatusCode: String(downloadReachabilityEvidence?.statusCode ?? ""),
    downloadReachabilityContentLength: String(downloadReachabilityEvidence?.contentLength ?? ""),
    downloadReachabilityError: String(downloadReachabilityEvidence?.error ?? ""),
    downloadReachabilitySummary: String(downloadReachabilityEvidence?.summary ?? "")
  };
}

export function ReleasesPage() {
  const { productId } = useProduct();
  const [rows, setRows] = useState<ReleaseRow[]>(demoModeEnabled() ? releases : []);
  const [editingRelease, setEditingRelease] = useState<ReleaseRow | null>(null);
  const [formOpen, setFormOpen] = useState(() => {
    if (typeof window === "undefined") {
      return false;
    }
    return new URLSearchParams(window.location.search).get("create") === "1";
  });
  const [form, setForm] = useState<ReleaseFormState>(emptyForm);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [actionState, setActionState] = useState("等待人工操作");
  const [error, setError] = useState("");
  const [validation, setValidation] = useState<ReleaseValidationResult | null>(null);
  const [appcastDiff, setAppcastDiff] = useState<ReleaseAppcastDiff | null>(null);
  const [appcastEntries, setAppcastEntries] = useState<AppcastEntryRecord[]>([]);
  const [artifactRelease, setArtifactRelease] = useState<ReleaseRow | null>(null);
  const [artifactRows, setArtifactRows] = useState<ReleaseArtifactRecord[]>([]);
  const [publicationRelease, setPublicationRelease] = useState<ReleaseRow | null>(null);
  const [publicationRows, setPublicationRows] = useState<ReleasePublicationRecord[]>([]);

  async function reload() {
    const [releaseRows, entries] = await Promise.all([
      opsClient.releases(productId),
      opsClient.appcastEntries(productId)
    ]);
    setRows(releaseRows);
    setAppcastEntries(entries);
  }

  useEffect(() => {
    let mounted = true;
    void Promise.all([
      opsClient.releases(productId),
      opsClient.appcastEntries(productId)
    ])
      .then(([items, entries]) => {
        if (mounted) {
          setRows(items);
          setAppcastEntries(entries);
        }
      })
      .catch((nextError: unknown) => {
        if (mounted) setError(errorMessage(nextError, "发布列表加载失败"));
      });
    return () => {
      mounted = false;
    };
  }, [productId]);

  async function saveRelease(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId(editingRelease ? "update" : "create");
    setError("");
    try {
      const draftInput = {
        minimumSystemVersion: form.minimumSystemVersion.trim() || undefined,
        artifactName: form.artifactName.trim(),
        artifactUrl: form.artifactUrl.trim() || undefined,
        artifactObjectKey: form.artifactObjectKey.trim() || undefined,
        artifactType: form.artifactType.trim() || undefined,
        artifactSize: form.artifactSize.trim() ? Number(form.artifactSize) : undefined,
        artifactSha256: form.artifactSha256.trim() || undefined,
        sparkleEdDsaSignature: form.sparkleEdDsaSignature.trim() || undefined,
        releaseNotes: form.releaseNotes.trim() || undefined,
        aiReleaseSummary: form.aiReleaseSummary.trim() || undefined,
        aiRiskSummary: form.aiRiskSummary.trim() || undefined,
        packageSignatureEvidence: form.packageSignatureStatus
          ? {
              status: form.packageSignatureStatus,
              tool: form.packageSignatureTool.trim() || undefined,
              checkedAt: form.packageSignatureCheckedAt.trim() || undefined,
              signer: form.packageSignatureSigner.trim() || undefined,
              summary: form.packageSignatureSummary.trim() || undefined
            }
          : undefined,
        downloadReachabilityEvidence: form.downloadReachabilityStatus
          ? {
              status: form.downloadReachabilityStatus,
              checkedAt: form.downloadReachabilityCheckedAt.trim() || undefined,
              statusCode: form.downloadReachabilityStatusCode.trim()
                ? Number(form.downloadReachabilityStatusCode)
                : undefined,
              contentLength: form.downloadReachabilityContentLength.trim()
                ? Number(form.downloadReachabilityContentLength)
                : undefined,
              error: form.downloadReachabilityError.trim() || undefined,
              summary: form.downloadReachabilitySummary.trim() || undefined
            }
          : undefined
      };
      if (editingRelease) {
        await opsClient.updateReleaseDraft(productId, editingRelease.id, draftInput);
        setActionState("发布草稿已更新，预检状态已重置");
      } else {
        await opsClient.createRelease(productId, {
          channel: form.channel,
          version: form.version.trim(),
          buildNumber: form.buildNumber.trim(),
          ...draftInput
        });
        setActionState("发布草稿已创建，必须完成预检后才能发布");
      }
      setFormOpen(false);
      setEditingRelease(null);
      setForm(emptyForm);
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, editingRelease ? "更新发布失败" : "创建发布失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function generateArtifactUploadUrl() {
    const fileName = form.artifactName.trim();
    const contentType = form.artifactType.trim();
    const sizeBytes = form.artifactSize.trim() ? Number(form.artifactSize) : 0;
    if (!fileName || !contentType || !Number.isFinite(sizeBytes) || sizeBytes <= 0) {
      setError("请先填写 Artifact 名称、类型和大小");
      return;
    }
    setBusyId("artifact-upload");
    setError("");
    setActionState("正在生成对象存储上传 URL");
    try {
      const upload = await opsClient.presignReleaseArtifactUpload(productId, {
        fileName,
        contentType,
        sizeBytes
      });
      setForm((current) => ({
        ...current,
        artifactUrl: upload.publicUrl ?? upload.uploadUrl,
        artifactObjectKey: upload.objectKey
      }));
      setActionState(`上传 URL 已生成：${upload.objectKey}`);
    } catch (nextError) {
      setError(errorMessage(nextError, "上传 URL 生成失败"));
      setActionState("上传 URL 生成失败");
    } finally {
      setBusyId(null);
    }
  }

  async function validate(row: ReleaseRow) {
    setBusyId(row.id);
    setError("");
    setValidation(null);
    setAppcastDiff(null);
    setActionState("正在执行发布预检");
    try {
      const result = await opsClient.validateRelease(productId, row.id);
      setValidation(result);
      setActionState(result.passed ? "预检通过，可以进入人工发布确认" : "预检未通过，禁止发布");
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "发布预检失败"));
      setActionState("预检失败");
    } finally {
      setBusyId(null);
    }
  }

  async function previewAppcastDiff(row: ReleaseRow) {
    setBusyId(`diff:${row.id}`);
    setError("");
    setAppcastDiff(null);
    setActionState("正在生成 appcast diff 预览");
    try {
      const diff = await opsClient.previewReleaseAppcastDiff(productId, row.id);
      setAppcastDiff(diff);
      setActionState("appcast diff 已生成，发布仍需人工确认");
    } catch (nextError) {
      setError(errorMessage(nextError, "appcast diff 预览失败"));
      setActionState("appcast diff 预览失败");
    } finally {
      setBusyId(null);
    }
  }

  async function checkDownload(row: ReleaseRow) {
    setBusyId(`download:${row.id}`);
    setError("");
    setActionState("正在检查 Artifact 下载地址");
    try {
      const result = await opsClient.checkReleaseDownload(productId, row.id);
      setActionState(`下载检查完成：${result.downloadReachabilityEvidence.status}`);
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "下载地址检查失败"));
      setActionState("下载地址检查失败");
    } finally {
      setBusyId(null);
    }
  }

  async function loadArtifacts(row: ReleaseRow) {
    setBusyId(`artifacts:${row.id}`);
    setError("");
    setArtifactRelease(row);
    setActionState("正在加载 Artifact 注册记录");
    try {
      const artifacts = await opsClient.releaseArtifacts(productId, row.id);
      setArtifactRows(artifacts);
      setActionState("Artifact 注册记录已加载");
    } catch (nextError) {
      setError(errorMessage(nextError, "Artifact 记录加载失败"));
      setActionState("Artifact 记录加载失败");
    } finally {
      setBusyId(null);
    }
  }

  async function publish(row: ReleaseRow) {
    const confirmation = window.prompt(
      `发布 ${row.version} 到 ${row.channel} 通道？请输入 PUBLISH 确认。`
    );
    if (confirmation !== "PUBLISH") {
      setActionState("已取消发布，未执行任何变更");
      return;
    }
    setBusyId(row.id);
    setError("");
    setActionState("正在人工确认发布");
    try {
      await opsClient.publishRelease(row.id, productId);
      setActionState("发布完成");
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "发布失败或未通过预检"));
      setActionState("发布失败或未通过预检");
    } finally {
      setBusyId(null);
    }
  }

  async function queueReleaseAgentRequest(
    row: ReleaseRow,
    requestType: "release_notes" | "release_risk"
  ) {
    const isRiskRequest = requestType === "release_risk";
    setBusyId(`agent:${requestType}:${row.id}`);
    setError("");
    setActionState(isRiskRequest ? "正在请求 Agent 风险摘要" : "正在请求 Agent 发布说明");
    try {
      await opsClient.createReleaseAgentRequest(productId, row.id, {
        requestType,
        agentHint: isRiskRequest ? "claude" : "codex",
        prompt: isRiskRequest
          ? `请基于 ${row.version} (${row.channel}) 生成发布风险摘要，只输出草稿，不要发布 OTA。`
          : `请基于 ${row.version} (${row.channel}) 生成面向用户的发布说明草稿，只输出草稿，不要发布 OTA。`
      });
      setActionState(`Agent 请求已排队：${requestType}`);
    } catch (nextError) {
      setError(errorMessage(nextError, "Agent 请求创建失败"));
      setActionState("Agent 请求创建失败");
    } finally {
      setBusyId(null);
    }
  }

  async function lifecycle(
    row: ReleaseRow,
    action: "pause" | "resume" | "withdraw"
  ) {
    const keyword =
      action === "pause" ? "PAUSE" : action === "resume" ? "RESUME" : "WITHDRAW";
    const actionName =
      action === "pause" ? "暂停" : action === "resume" ? "恢复" : "撤回";
    if (window.prompt(`请输入 ${keyword} 确认${actionName} ${row.version}。`) !== keyword) {
      setActionState("已取消操作");
      return;
    }
    setBusyId(row.id);
    setError("");
    setActionState(`正在${actionName}发布`);
    try {
      await opsClient.updateReleaseLifecycle(row.id, action, productId);
      setActionState("发布状态已更新");
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "发布状态更新失败"));
      setActionState("操作失败");
    } finally {
      setBusyId(null);
    }
  }

  function openCreateForm() {
    setEditingRelease(null);
    setForm(emptyForm);
    setFormOpen(true);
    setError("");
  }

  function openEditForm(row: ReleaseRow) {
    setEditingRelease(row);
    setForm(formFromRelease(row));
    setFormOpen(true);
    setValidation(null);
    setAppcastDiff(null);
    setError("");
    setActionState("正在编辑发布草稿，保存后需重新预检");
  }

  function closeForm() {
    setFormOpen(false);
    setEditingRelease(null);
    setForm(emptyForm);
  }

  useEffect(() => {
    if (!formOpen) return;
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") {
        closeForm();
      }
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [formOpen]);

  async function loadPublicationStatus(row: ReleaseRow) {
    setBusyId(`publication:${row.id}`);
    setPublicationRelease(row);
    setPublicationRows([]);
    setError("");
    try {
      setPublicationRows(await opsClient.releasePublications(productId, row.id));
    } catch (nextError) {
      setError(errorMessage(nextError, "发布同步状态加载失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function retryFailedPublication(row: ReleaseRow) {
    setBusyId(`retry-publication:${row.id}`);
    setError("");
    try {
      const result = await opsClient.retryReleasePublication(productId, row.id);
      setActionState(`已重新提交 ${result.targets.length} 个失败同步目标`);
      await loadPublicationStatus(row);
    } catch (nextError) {
      setError(errorMessage(nextError, "重新提交发布同步失败"));
    } finally {
      setBusyId(null);
    }
  }

  function closePublicationStatus() {
    setPublicationRelease(null);
    setPublicationRows([]);
  }

  const columns: DataColumn<ReleaseRow>[] = [
    {
      key: "version",
      title: "版本",
      className: "release-column-version",
      render: (row) => <strong>{row.version}</strong>
    },
    { key: "build", title: "Build", className: "release-column-build", render: (row) => row.build },
    {
      key: "channel",
      title: "通道",
      className: "release-column-channel",
      render: (row) => <StatusBadge tone="blue">{row.channel}</StatusBadge>
    },
    {
      key: "status",
      title: "状态",
      className: "release-column-status",
      render: (row) => (
        <StatusBadge
          tone={
            row.status === "Published"
              ? "green"
              : row.status === "Failed"
                ? "red"
                : "orange"
          }
        >
          {row.status}
        </StatusBadge>
      )
    },
    {
      key: "artifact",
      title: "Artifact",
      className: "release-column-artifact",
      render: (row) => row.artifact
    },
    {
      key: "ai",
      title: "AI 摘要",
      className: "release-column-ai",
      render: (row) => (
        <div className="release-ai-summary">
          <p>{row.aiReleaseSummary ?? "-"}</p>
          {row.aiRiskSummary ? <p>{row.aiRiskSummary}</p> : null}
        </div>
      )
    },
    {
      key: "checks",
      title: "校验",
      className: "release-column-checks",
      render: (row) => row.checks
    },
    {
      key: "actors",
      title: "操作者",
      className: "release-column-actors",
      render: (row) => (
        <div className="release-ai-summary">
          <p>created: {row.createdBy ?? "-"}</p>
          <p>published: {row.publishedBy ?? "-"}</p>
        </div>
      )
    },
    {
      key: "updatedAt",
      title: "更新",
      className: "release-column-updated-at",
      render: (row) => row.updatedAt
    },
    {
      key: "actions",
      title: "操作",
      className: "release-column-actions",
      render: (row) => {
        const status = row.status.toLowerCase();
        return (
          <div className="release-action-group">
            {status.includes("draft") ||
            status.includes("failed") ||
            status.includes("ready") ||
            status.includes("validating") ? (
              <button
                aria-label={`编辑 ${row.version}`}
                className="secondary-button"
                onClick={() => openEditForm(row)}
                type="button"
              >
                编辑
              </button>
            ) : null}
            <button
              aria-label={`预览 appcast diff ${row.version}`}
              className="secondary-button"
              disabled={busyId === `diff:${row.id}`}
              onClick={() => void previewAppcastDiff(row)}
              type="button"
            >
              Diff
            </button>
            <button
              aria-label={`检查下载 ${row.version}`}
              className="secondary-button"
              disabled={busyId === `download:${row.id}`}
              onClick={() => void checkDownload(row)}
              type="button"
            >
              Check URL
            </button>
            <button
              aria-label={`查看 Artifacts ${row.version}`}
              className="secondary-button"
              disabled={busyId === `artifacts:${row.id}`}
              onClick={() => void loadArtifacts(row)}
              type="button"
            >
              Artifacts
            </button>
            <button
              aria-label={`查看同步状态 ${row.version}`}
              className="secondary-button"
              disabled={busyId === `publication:${row.id}`}
              onClick={() => void loadPublicationStatus(row)}
              type="button"
            >
              同步
            </button>
            <button
              aria-label={`请求 Agent 发布说明 ${row.version}`}
              className="secondary-button"
              disabled={busyId === `agent:release_notes:${row.id}`}
              onClick={() => void queueReleaseAgentRequest(row, "release_notes")}
              type="button"
            >
              Agent Notes
            </button>
            <button
              aria-label={`请求 Agent 风险摘要 ${row.version}`}
              className="secondary-button"
              disabled={busyId === `agent:release_risk:${row.id}`}
              onClick={() => void queueReleaseAgentRequest(row, "release_risk")}
              type="button"
            >
              Agent Risk
            </button>
            {status.includes("draft") ||
            status.includes("failed") ||
            status.includes("ready") ? (
              <button
                aria-label={`校验 ${row.version}`}
                className="secondary-button"
                disabled={busyId === row.id}
                onClick={() => void validate(row)}
                type="button"
              >
                校验
              </button>
            ) : null}
            {status.includes("ready") ? (
              <button
                aria-label={`发布 ${row.version}`}
                className="primary-button"
                disabled={busyId === row.id}
                onClick={() => void publish(row)}
                type="button"
              >
                发布
              </button>
            ) : null}
            {status.includes("published") ? (
              <button
                aria-label={`暂停 ${row.version}`}
                className="secondary-button"
                disabled={busyId === row.id}
                onClick={() => void lifecycle(row, "pause")}
                type="button"
              >
                暂停
              </button>
            ) : null}
            {status.includes("paused") ? (
              <button
                aria-label={`恢复 ${row.version}`}
                className="secondary-button"
                disabled={busyId === row.id}
                onClick={() => void lifecycle(row, "resume")}
                type="button"
              >
                恢复
              </button>
            ) : null}
            {!status.includes("withdrawn") ? (
              <button
                aria-label={`撤回 ${row.version}`}
                className="secondary-button"
                disabled={busyId === row.id}
                onClick={() => void lifecycle(row, "withdraw")}
                type="button"
              >
                撤回
              </button>
            ) : null}
          </div>
        );
      }
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">OTA</p>
          <h1>版本发布</h1>
          <p>创建发布草稿、记录 Artifact 与 Sparkle 签名、执行预检，并由管理员最终确认发布。</p>
        </div>
        <button
          className="primary-button"
          onClick={openCreateForm}
          type="button"
        >
          创建发布
        </button>
      </div>

      <section className="panel release-guard">
        <strong>发布护栏</strong>
        <span>
          AI 只能生成草稿、风险摘要和 appcast diff 说明。任何通道发布都必须由管理员输入
          PUBLISH 确认。
        </span>
        <span>{actionState}</span>
      </section>

      <ol aria-label="Release workflow" className="release-stepper">
        {releaseWorkflowSteps.map((step, index) => (
          <li className="release-step" key={step}>
            <span className="release-step-index">{index + 1}</span>
            <strong>{step}</strong>
          </li>
        ))}
      </ol>

      {error && !formOpen ? (
        <p className="form-error" role="alert">
          {error}
        </p>
      ) : null}

      {formOpen ? (
        <div
          className="connector-modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) {
              closeForm();
            }
          }}
        >
          <form
            aria-label={editingRelease ? "编辑发布草稿" : "创建发布草稿"}
            aria-modal="true"
            className="connector-modal connector-modal-resizable release-form-modal"
            onSubmit={(event) => void saveRelease(event)}
            role="dialog"
          >
          <header className="connector-modal-header">
            <div>
              <p className="eyebrow">Release Draft</p>
              <h2>{editingRelease ? "编辑发布草稿" : "创建发布草稿"}</h2>
              <p>保存草稿后需要重新完成预检，发布仍需管理员确认。</p>
            </div>
            <button
              aria-label={editingRelease ? "关闭编辑发布草稿" : "关闭创建发布草稿"}
              className="connector-modal-close"
              onClick={closeForm}
              title="关闭"
              type="button"
            >
              x
            </button>
          </header>
          <div className="connector-modal-body">
            {error ? <p className="form-error" role="alert">{error}</p> : null}
            <div className="form-grid">
            <label>
              <span>版本号</span>
              <input
                aria-label="版本号"
                disabled={Boolean(editingRelease)}
                onChange={(event) =>
                  setForm((current) => ({ ...current, version: event.target.value }))
                }
                required
                value={form.version}
              />
            </label>
            <label>
              <span>Build Number</span>
              <input
                aria-label="Build Number"
                disabled={Boolean(editingRelease)}
                onChange={(event) =>
                  setForm((current) => ({ ...current, buildNumber: event.target.value }))
                }
                required
                value={form.buildNumber}
              />
            </label>
            <label>
              <span>发布通道</span>
              <select
                aria-label="发布通道"
                disabled={Boolean(editingRelease)}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    channel: event.target.value as ReleaseInput["channel"]
                  }))
                }
                value={form.channel}
              >
                <option value="stable">Stable</option>
                <option value="beta">Beta</option>
                <option value="dev">Dev</option>
                <option value="internal">Internal</option>
              </select>
            </label>
            <label>
              <span>最低 macOS 版本</span>
              <input
                aria-label="最低 macOS 版本"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    minimumSystemVersion: event.target.value
                  }))
                }
                value={form.minimumSystemVersion}
              />
            </label>
            <label>
              <span>Artifact 名称</span>
              <input
                aria-label="Artifact 名称"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactName: event.target.value }))
                }
                required
                value={form.artifactName}
              />
            </label>
            <label>
              <span>Artifact URL</span>
              <input
                aria-label="Artifact URL"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactUrl: event.target.value }))
                }
                type="url"
                value={form.artifactUrl}
              />
            </label>
            <label>
              <span>Object Key</span>
              <input
                aria-label="Object Key"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactObjectKey: event.target.value }))
                }
                value={form.artifactObjectKey}
              />
            </label>
            <label>
              <span>Artifact 类型</span>
              <input
                aria-label="Artifact 类型"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactType: event.target.value }))
                }
                value={form.artifactType}
              />
            </label>
            <label>
              <span>Artifact 大小</span>
              <input
                aria-label="Artifact 大小"
                min="1"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactSize: event.target.value }))
                }
                type="number"
                value={form.artifactSize}
              />
            </label>
            <label>
              <span>Artifact SHA-256</span>
              <input
                aria-label="Artifact SHA-256"
                onChange={(event) =>
                  setForm((current) => ({ ...current, artifactSha256: event.target.value }))
                }
                value={form.artifactSha256}
              />
            </label>
            <div className="form-grid-wide inline-actions">
              <button
                className="secondary-button"
                disabled={busyId === "artifact-upload"}
                onClick={() => void generateArtifactUploadUrl()}
                type="button"
              >
                生成上传 URL
              </button>
              <span className="table-subtext">使用对象存储为当前 Artifact 生成 PUT 上传地址。</span>
            </div>
            <label className="form-grid-wide">
              <span>Sparkle EdDSA 签名</span>
              <input
                aria-label="Sparkle EdDSA 签名"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    sparkleEdDsaSignature: event.target.value
                  }))
                }
                value={form.sparkleEdDsaSignature}
              />
            </label>
            <label className="form-grid-wide">
              <span>发布说明</span>
              <textarea
                aria-label="发布说明"
                onChange={(event) =>
                  setForm((current) => ({ ...current, releaseNotes: event.target.value }))
                }
                value={form.releaseNotes}
              />
            </label>
            <label className="form-grid-wide">
              <span>AI 发布摘要</span>
              <textarea
                aria-label="AI 发布摘要"
                onChange={(event) =>
                  setForm((current) => ({ ...current, aiReleaseSummary: event.target.value }))
                }
                value={form.aiReleaseSummary}
              />
            </label>
            <label className="form-grid-wide">
              <span>AI 风险摘要</span>
              <textarea
                aria-label="AI 风险摘要"
                onChange={(event) =>
                  setForm((current) => ({ ...current, aiRiskSummary: event.target.value }))
                }
                value={form.aiRiskSummary}
              />
            </label>
            <label>
              <span>包签名验证状态</span>
              <select
                aria-label="包签名验证状态"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    packageSignatureStatus: event.target.value as ReleaseFormState["packageSignatureStatus"]
                  }))
                }
                value={form.packageSignatureStatus}
              >
                <option value="">未附加</option>
                <option value="passed">Passed</option>
                <option value="failed">Failed</option>
                <option value="not_available">Not available</option>
              </select>
            </label>
            <label>
              <span>包签名验证工具</span>
              <input
                aria-label="包签名验证工具"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    packageSignatureTool: event.target.value
                  }))
                }
                value={form.packageSignatureTool}
              />
            </label>
            <label>
              <span>包签名验证签名者</span>
              <input
                aria-label="包签名验证签名者"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    packageSignatureSigner: event.target.value
                  }))
                }
                value={form.packageSignatureSigner}
              />
            </label>
            <label>
              <span>包签名验证时间</span>
              <input
                aria-label="包签名验证时间"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    packageSignatureCheckedAt: event.target.value
                  }))
                }
                placeholder="2026-07-10T10:00:00.000Z"
                value={form.packageSignatureCheckedAt}
              />
            </label>
            <label className="form-grid-wide">
              <span>包签名验证摘要</span>
              <textarea
                aria-label="包签名验证摘要"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    packageSignatureSummary: event.target.value
                  }))
                }
                value={form.packageSignatureSummary}
              />
            </label>
            <label>
              <span>下载可达性状态</span>
              <select
                aria-label="下载可达性状态"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilityStatus: event.target.value as ReleaseFormState["downloadReachabilityStatus"]
                  }))
                }
                value={form.downloadReachabilityStatus}
              >
                <option value="">未附加</option>
                <option value="reachable">Reachable</option>
                <option value="unreachable">Unreachable</option>
                <option value="not_checked">Not checked</option>
              </select>
            </label>
            <label>
              <span>下载 HTTP 状态码</span>
              <input
                aria-label="下载 HTTP 状态码"
                min="100"
                max="599"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilityStatusCode: event.target.value
                  }))
                }
                type="number"
                value={form.downloadReachabilityStatusCode}
              />
            </label>
            <label>
              <span>下载 Content-Length</span>
              <input
                aria-label="下载 Content-Length"
                min="0"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilityContentLength: event.target.value
                  }))
                }
                type="number"
                value={form.downloadReachabilityContentLength}
              />
            </label>
            <label>
              <span>下载检查时间</span>
              <input
                aria-label="下载检查时间"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilityCheckedAt: event.target.value
                  }))
                }
                placeholder="2026-07-10T10:05:00.000Z"
                value={form.downloadReachabilityCheckedAt}
              />
            </label>
            <label className="form-grid-wide">
              <span>下载错误</span>
              <input
                aria-label="下载错误"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilityError: event.target.value
                  }))
                }
                value={form.downloadReachabilityError}
              />
            </label>
            <label className="form-grid-wide">
              <span>下载可达性摘要</span>
              <textarea
                aria-label="下载可达性摘要"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    downloadReachabilitySummary: event.target.value
                  }))
                }
                value={form.downloadReachabilitySummary}
              />
            </label>
            </div>
          </div>
          <footer className="connector-modal-actions form-actions">
            <button className="secondary-button" onClick={closeForm} type="button">
              取消
            </button>
            <button
              className="primary-button"
              disabled={busyId === "create" || busyId === "update"}
              type="submit"
            >
              {editingRelease ? "更新发布草稿" : "保存发布草稿"}
            </button>
          </footer>
          </form>
        </div>
      ) : null}

      {validation ? (
        <section className="panel">
          <div className="panel-header">
            <h2>最近一次预检</h2>
            <StatusBadge tone={validation.passed ? "green" : "red"}>
              {validation.passed ? "Passed" : "Failed"}
            </StatusBadge>
          </div>
          <div className="validation-list">
            {validation.checks.map((check) => (
              <div className="validation-row" key={check.key}>
                <StatusBadge tone={check.passed ? "green" : "red"}>
                  {check.passed ? "通过" : "失败"}
                </StatusBadge>
                <div>
                  <strong>{check.key}</strong>
                  <p>{check.message}</p>
                </div>
              </div>
            ))}
          </div>
        </section>
      ) : null}

      {appcastDiff ? (
        <section className="panel">
          <div className="panel-header">
            <div>
              <p className="eyebrow">Sparkle Preview</p>
              <h2>Appcast Diff</h2>
            </div>
            <StatusBadge tone="blue">{appcastDiff.channel}</StatusBadge>
          </div>
          <div className="validation-list">
            <div className="validation-row">
              <StatusBadge tone="green">Preview</StatusBadge>
              <div>
                <strong>{appcastDiff.addedItem.version}</strong>
                <p>
                  current items: {appcastDiff.currentItemCount}, preview items: {appcastDiff.previewItemCount}
                </p>
              </div>
            </div>
          </div>
          <pre className="feedback-diagnostics">{appcastDiff.previewXml}</pre>
        </section>
      ) : null}

      {artifactRelease ? (
        <section className="panel">
          <div className="panel-header">
            <div>
              <p className="eyebrow">Release Artifact</p>
              <h2>Artifact 记录</h2>
            </div>
            <StatusBadge tone="blue">{String(artifactRows.length)}</StatusBadge>
          </div>
          <div className="validation-list">
            {artifactRows.length > 0 ? (
              artifactRows.map((artifact) => (
                <div className="validation-row" key={artifact.id}>
                  <StatusBadge tone="blue">{artifact.contentType ?? "file"}</StatusBadge>
                  <div>
                    <strong>{artifact.fileName}</strong>
                    <p className="mono-text">{artifact.objectKey ?? artifact.url}</p>
                    <p>
                      {artifact.sizeBytes ? `${artifact.sizeBytes} bytes` : "size unknown"}
                      {artifact.sha256 ? ` · sha256: ${artifact.sha256}` : ""}
                    </p>
                  </div>
                </div>
              ))
            ) : (
              <div className="validation-row">
                <StatusBadge tone="orange">Empty</StatusBadge>
                <div>
                  <strong>{artifactRelease.version}</strong>
                  <p>暂无 Artifact 注册记录。</p>
                </div>
              </div>
            )}
          </div>
        </section>
      ) : null}

      {publicationRelease ? (
        <div className="connector-modal-backdrop" onMouseDown={(event) => {
          if (event.target === event.currentTarget) closePublicationStatus();
        }}>
          <section
            aria-label={`${publicationRelease.version} 同步状态`}
            aria-modal="true"
            className="connector-modal"
            role="dialog"
          >
            <header className="connector-modal-header">
              <div>
                <p className="connector-type">Release Publication</p>
                <h2>{publicationRelease.version} 同步状态</h2>
                <p>对象存储完成后才会更新 appcast 与官网公开目录；失败目标可由后台任务重试。</p>
              </div>
              <button
                aria-label={`关闭 ${publicationRelease.version} 同步状态`}
                className="connector-modal-close"
                onClick={closePublicationStatus}
                title="关闭"
                type="button"
              >
                x
              </button>
            </header>
            <div className="connector-modal-body">
              <div className="validation-list">
                {publicationRows.length > 0 ? publicationRows.map((publication) => (
                  <div className="validation-row" key={publication.id}>
                    <StatusBadge
                      tone={
                        publication.status === "succeeded"
                          ? "green"
                          : publication.status === "failed"
                            ? "red"
                            : publication.status === "running"
                              ? "blue"
                              : "orange"
                      }
                    >
                      {publication.status}
                    </StatusBadge>
                    <div>
                      <strong>{publication.target}</strong>
                      <p>尝试 {publication.attempts} 次</p>
                      {publication.objectKey ? <p className="mono-text">{publication.objectKey}</p> : null}
                      {publication.externalUrl ? <p className="mono-text">{publication.externalUrl}</p> : null}
                      {publication.lastError ? <p className="form-error">{publication.lastError}</p> : null}
                    </div>
                  </div>
                )) : (
                  <div className="validation-row">
                    <StatusBadge tone="orange">Empty</StatusBadge>
                    <div>
                      <strong>尚未创建同步目标</strong>
                      <p>只有通过人工确认发布的版本才会进入跨系统同步队列。</p>
                    </div>
                  </div>
                )}
              </div>
            </div>
            <footer className="connector-modal-actions form-actions">
              <button className="secondary-button" onClick={closePublicationStatus} type="button">关闭</button>
              <button
                className="secondary-button"
                disabled={
                  busyId === `retry-publication:${publicationRelease.id}` ||
                  !publicationRows.some((publication) => publication.status === "failed")
                }
                onClick={() => void retryFailedPublication(publicationRelease)}
                type="button"
              >
                重试失败项
              </button>
              <button
                className="primary-button"
                disabled={busyId === `publication:${publicationRelease.id}`}
                onClick={() => void loadPublicationStatus(publicationRelease)}
                type="button"
              >
                刷新状态
              </button>
            </footer>
          </section>
        </div>
      ) : null}

      <section className="panel">
        <div className="panel-header">
          <div>
            <p className="eyebrow">Sparkle Published</p>
            <h2>Appcast 快照</h2>
          </div>
          <StatusBadge tone="blue">{String(appcastEntries.length)}</StatusBadge>
        </div>
        <div className="validation-list">
          {appcastEntries.length > 0 ? (
            appcastEntries.map((entry) => (
              <div className="validation-row" key={entry.id}>
                <StatusBadge tone="blue">{entry.channelName}</StatusBadge>
                <div>
                  <strong className="mono-text">{entry.objectKey ?? "-"}</strong>
                  <p>
                    release: {entry.releaseId}
                    {entry.publishedAt ? ` · published: ${entry.publishedAt}` : ""}
                  </p>
                </div>
              </div>
            ))
          ) : (
            <div className="validation-row">
              <StatusBadge tone="orange">Empty</StatusBadge>
              <div>
                <strong>暂无已发布 appcast 快照</strong>
                <p>发布通过人工确认后会生成可审计的 Sparkle XML 快照。</p>
              </div>
            </div>
          )}
        </div>
      </section>

      <section className="panel">
        <DataTable
          columns={columns}
          emptyText="暂无发布版本"
          rows={rows}
          tableClassName="release-data-table"
        />
      </section>
    </div>
  );
}
