import { useEffect, useState, type FormEvent } from "react";
import {
  demoModeEnabled,
  opsClient,
  type GitHubIssueCommentResult
} from "../api/client";
import { githubIssues, githubSyncRuns } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type GitHubIssueRow = (typeof githubIssues)[number];
type GitHubSyncRunRow = {
  id: string;
  trigger: string;
  status: string;
  fetched: number;
  changed: number;
  feedbackCreated: number;
  error?: string;
  finishedAt: string;
};
type ReplyPanelState = {
  issue: GitHubIssueRow;
  result?: GitHubIssueCommentResult;
};
type LabelPanelState = {
  issue: GitHubIssueRow;
};

function syncRunTone(status: string) {
  const normalized = status.toLowerCase();
  if (normalized === "success") return "green";
  if (normalized === "failed") return "red";
  return "orange";
}

const syncColumns: DataColumn<GitHubSyncRunRow>[] = [
  { key: "trigger", title: "触发", render: (row) => row.trigger },
  { key: "status", title: "状态", render: (row) => <StatusBadge tone={syncRunTone(row.status)}>{row.status}</StatusBadge> },
  { key: "fetched", title: "读取", render: (row) => String(row.fetched) },
  { key: "changed", title: "变更", render: (row) => String(row.changed) },
  { key: "feedbackCreated", title: "转反馈", render: (row) => String(row.feedbackCreated) },
  { key: "error", title: "最后错误", render: (row) => row.error ?? "-" },
  { key: "finishedAt", title: "完成", render: (row) => row.finishedAt }
];

export function GitHubIssuesPage() {
  const { activeProduct, productId } = useProduct();
  const [rows, setRows] = useState<GitHubIssueRow[]>(demoModeEnabled() ? githubIssues : []);
  const [syncRows, setSyncRows] = useState<GitHubSyncRunRow[]>(demoModeEnabled() ? githubSyncRuns : []);
  const [syncState, setSyncState] = useState("就绪");
  const [replyPanel, setReplyPanel] = useState<ReplyPanelState | null>(null);
  const [replyBody, setReplyBody] = useState("");
  const [replyState, setReplyState] = useState("等待人工确认");
  const [replyError, setReplyError] = useState("");
  const [labelPanel, setLabelPanel] = useState<LabelPanelState | null>(null);
  const [labelInput, setLabelInput] = useState("");
  const [labelState, setLabelState] = useState("等待人工确认");
  const [labelError, setLabelError] = useState("");
  const [loadError, setLoadError] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const openCount = rows.filter((row) => row.state.toLowerCase() !== "closed").length;
  const latestSync = syncRows[0];
  const lastSync = latestSync?.finishedAt ?? "尚未同步";
  const latestSyncStatus = latestSync?.status ?? (activeProduct?.githubOwner && activeProduct.githubRepository ? "已配置" : "未配置");
  const latestSyncMessage = latestSync?.error ? `最后错误：${latestSync.error}` : syncState;

  const reload = () => {
    setLoadError("");
    void Promise.all([
      opsClient.githubIssues(productId),
      opsClient.githubSyncRuns(productId)
    ]).then(([items, runs]) => {
      setRows(items);
      setSyncRows(runs);
      setLoadError("");
    }).catch((error: unknown) => {
      setLoadError(error instanceof Error ? error.message : "GitHub Issues 加载失败");
    });
  };

  useEffect(() => {
    reload();
  }, [productId]);

  async function runGitHubPull() {
    setSyncState("同步任务入队中");
    const result = await opsClient.pullGitHubIssues(productId);
    setSyncState(result ? "同步任务已入队" : "需要配置 GitHub 或队列");
    reload();
  }

  function startReply(issue: GitHubIssueRow) {
    setReplyPanel({ issue });
    setReplyBody("");
    setReplyState("等待人工确认");
    setReplyError("");
  }

  function startLabels(issue: GitHubIssueRow) {
    setLabelPanel({ issue });
    setLabelInput(issue.labels.join(", "));
    setLabelState("等待人工确认");
    setLabelError("");
  }

  function splitLabels(value: string) {
    return [...new Set(value.split(",").map((label) => label.trim()).filter(Boolean))];
  }

  async function submitLabels(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!labelPanel) return;
    const labels = splitLabels(labelInput);
    const confirmation = window.prompt(
      `将在 GitHub Issue #${labelPanel.issue.number} 更新公开标签。请输入 APPLY_LABELS 确认。`
    );
    if (confirmation !== "APPLY_LABELS") {
      setLabelState("已取消标签更新");
      return;
    }
    setBusyId(`labels:${labelPanel.issue.id}`);
    setLabelError("");
    try {
      await opsClient.updateGitHubIssue(productId, labelPanel.issue.id, {
        labels,
        confirmation: "APPLY_LABELS"
      });
      setLabelState("GitHub 标签已更新");
      setLabelPanel(null);
      reload();
    } catch (error) {
      setLabelError(error instanceof Error ? error.message : "GitHub 标签更新失败");
    } finally {
      setBusyId(null);
    }
  }

  async function closeIssue(issue: GitHubIssueRow) {
    const confirmation = window.prompt(
      `将关闭 GitHub Issue #${issue.number}。请输入 CLOSE 确认。`
    );
    if (confirmation !== "CLOSE") {
      setSyncState("已取消关闭 Issue");
      return;
    }
    setBusyId(`close:${issue.id}`);
    try {
      await opsClient.updateGitHubIssue(productId, issue.id, {
        state: "closed",
        confirmation: "CLOSE"
      });
      setSyncState("GitHub Issue 已关闭");
      reload();
    } catch (error) {
      setSyncState(error instanceof Error ? error.message : "GitHub Issue 关闭失败");
    } finally {
      setBusyId(null);
    }
  }

  async function submitReply(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!replyPanel || !replyBody.trim()) {
      return;
    }
    const confirmation = window.prompt(
      `将在 GitHub Issue #${replyPanel.issue.number} 发布公开回复。请输入 POST 确认。`
    );
    if (confirmation !== "POST") {
      setReplyState("已取消 GitHub 回复");
      return;
    }
    setBusyId(replyPanel.issue.id);
    setReplyError("");
    try {
      const result = await opsClient.commentGitHubIssue(productId, replyPanel.issue.id, {
        body: replyBody.trim(),
        confirmation: "POST"
      });
      setReplyPanel({ issue: replyPanel.issue, result });
      setReplyState("GitHub 回复已发布");
      setReplyBody("");
      reload();
    } catch (error) {
      setReplyError(error instanceof Error ? error.message : "GitHub 回复发布失败");
    } finally {
      setBusyId(null);
    }
  }

  const issueColumns: DataColumn<GitHubIssueRow>[] = [
    {
      key: "number",
      title: "编号",
      render: (row) => (
        <a href={row.url} rel="noreferrer" target="_blank">
          #{row.number}
        </a>
      )
    },
    {
      key: "title",
      title: "标题",
      render: (row) => (
        <div>
          <strong>{row.title}</strong>
          <div className="label-list">
            {row.labels.map((label) => (
              <StatusBadge key={label} tone={label.includes("bug") || label.includes("p1") ? "red" : "blue"}>
                {label}
              </StatusBadge>
            ))}
          </div>
        </div>
      )
    },
    { key: "state", title: "状态", render: (row) => <StatusBadge tone={row.state.toLowerCase() === "closed" ? "green" : "orange"}>{row.state}</StatusBadge> },
    { key: "author", title: "提交人", render: (row) => row.author },
    { key: "comments", title: "评论", render: (row) => String(row.comments) },
    { key: "linkedFeedback", title: "反馈单", render: (row) => row.linkedFeedback },
    { key: "updatedAt", title: "更新", render: (row) => row.updatedAt },
    {
      key: "actions",
      title: "操作",
      render: (row) => (
        <div className="inline-actions">
          <button
            aria-label={`回复 #${row.number}`}
            className="secondary-button"
            disabled={busyId === row.id}
            onClick={() => startReply(row)}
            type="button"
          >
            回复
          </button>
          <button
            aria-label={`编辑标签 #${row.number}`}
            className="secondary-button"
            disabled={busyId === `labels:${row.id}`}
            onClick={() => startLabels(row)}
            type="button"
          >
            标签
          </button>
          <button
            aria-label={`关闭 #${row.number}`}
            className="danger-button"
            disabled={row.state.toLowerCase() === "closed" || busyId === `close:${row.id}`}
            onClick={() => void closeIssue(row)}
            type="button"
          >
            关闭
          </button>
        </div>
      )
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">GitHub</p>
          <h1>GitHub 问题</h1>
          <p>同步仓库 Issues，并自动映射到统一反馈收件箱。</p>
        </div>
        <div className="inline-actions">
          <a className="secondary-button" href="/connectors?type=github">
            配置 GitHub
          </a>
          <button className="primary-button" onClick={runGitHubPull} type="button">
            同步入队
          </button>
        </div>
      </div>
      {loadError ? <div className="error-banner" role="alert">{loadError}</div> : null}

      <div className="summary-grid summary-grid-three">
        <section className="panel metric-panel">
          <span>连接状态</span>
          <strong>{latestSyncStatus}</strong>
          <p>{latestSyncMessage}</p>
        </section>
        <section className="panel metric-panel">
          <span>Open Issues</span>
          <strong>{openCount}</strong>
          <p>共 {rows.length} 个问题</p>
        </section>
        <section className="panel metric-panel">
          <span>最后同步</span>
          <strong>{lastSync}</strong>
          <p>只读同步入队执行，回复写回后续人工确认。</p>
        </section>
      </div>

      <section className="panel">
        <div className="panel-header">
          <h2>Issues</h2>
          <StatusBadge tone="blue">
            {activeProduct?.githubOwner && activeProduct.githubRepository
              ? `${activeProduct.githubOwner}/${activeProduct.githubRepository}`
              : productId}
          </StatusBadge>
        </div>
        <DataTable columns={issueColumns} rows={rows} emptyText="暂无 GitHub Issues" />
      </section>

      {replyPanel ? (
        <form className="panel product-form" onSubmit={(event) => void submitReply(event)}>
          <div className="panel-header">
            <div>
              <h2>GitHub 回复</h2>
              <p className="table-subtext">#{replyPanel.issue.number} {replyPanel.issue.title}</p>
            </div>
            <StatusBadge tone={replyPanel.result ? "green" : "orange"}>{replyState}</StatusBadge>
          </div>
          {replyError ? (
            <p className="form-error" role="alert">
              {replyError}
            </p>
          ) : null}
          <label className="form-grid-wide">
            <span>GitHub 回复内容</span>
            <textarea
              aria-label="GitHub 回复内容"
              onChange={(event) => setReplyBody(event.target.value)}
              required
              rows={5}
              value={replyBody}
            />
          </label>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setReplyPanel(null)} type="button">
              取消
            </button>
            <button
              className="primary-button"
              disabled={!replyBody.trim() || busyId === replyPanel.issue.id}
              type="submit"
            >
              发布 GitHub 回复
            </button>
          </div>
          {replyPanel.result ? (
            <p className="action-message">
              <a href={replyPanel.result.url} rel="noreferrer" target="_blank">
                查看 GitHub 评论
              </a>
            </p>
          ) : null}
        </form>
      ) : null}

      {labelPanel ? (
        <form className="panel product-form" onSubmit={(event) => void submitLabels(event)}>
          <div className="panel-header">
            <div>
              <h2>GitHub 标签</h2>
              <p className="table-subtext">#{labelPanel.issue.number} {labelPanel.issue.title}</p>
            </div>
            <StatusBadge tone="orange">{labelState}</StatusBadge>
          </div>
          {labelError ? (
            <p className="form-error" role="alert">
              {labelError}
            </p>
          ) : null}
          <label className="form-grid-wide">
            <span>GitHub Labels</span>
            <input
              aria-label="GitHub Labels"
              onChange={(event) => setLabelInput(event.target.value)}
              placeholder="bug, priority:p0"
              value={labelInput}
            />
          </label>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setLabelPanel(null)} type="button">
              取消
            </button>
            <button
              className="primary-button"
              disabled={busyId === `labels:${labelPanel.issue.id}`}
              type="submit"
            >
              应用 GitHub 标签
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <div className="panel-header">
          <h2>同步记录</h2>
        </div>
        <DataTable columns={syncColumns} rows={syncRows} emptyText="暂无同步记录" />
      </section>
    </div>
  );
}
