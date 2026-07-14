import { useEffect, useMemo, useState, type FormEvent } from "react";
import { demoModeEnabled, opsClient, type AiAnalysisRecord } from "../api/client";
import { aiAnalyses, aiProposedActions } from "../api/mockData";
import { KpiCard } from "../components/KpiCard";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type AiAnalysisRow = AiAnalysisRecord;
type ProposedActionRow = (typeof aiProposedActions)[number];

function confidencePercent(value: string) {
  const numeric = Number.parseFloat(value);
  if (Number.isNaN(numeric)) {
    return 0;
  }
  return numeric <= 1 ? Math.round(numeric * 100) : Math.round(numeric);
}

function toneForClassification(value: string) {
  const normalized = value.toLowerCase();
  if (normalized.includes("bug") || normalized.includes("risk")) return "red";
  if (normalized.includes("release")) return "orange";
  if (normalized.includes("feature")) return "blue";
  return "gray";
}

export function AiAnalysisPage() {
  const { productId } = useProduct();
  const [rows, setRows] = useState<AiAnalysisRow[]>(demoModeEnabled() ? aiAnalyses : []);
  const [actions, setActions] = useState<ProposedActionRow[]>(demoModeEnabled() ? aiProposedActions : []);
  const [reviewingId, setReviewingId] = useState<string | null>(null);
  const [reviewingActionId, setReviewingActionId] = useState<string | null>(null);
  const [executingActionId, setExecutingActionId] = useState<string | null>(null);
  const [editing, setEditing] = useState<AiAnalysisRow | null>(null);
  const [editSummary, setEditSummary] = useState("");
  const [editClassification, setEditClassification] = useState("");
  const [error, setError] = useState("");

  async function reload() {
    const [items, proposedActions] = await Promise.all([
      opsClient.aiAnalysis(productId),
      opsClient.proposedActions(productId)
    ]);
    setRows(items);
    setActions(proposedActions);
  }

  useEffect(() => {
    let isMounted = true;
    setError("");
    void Promise.all([
      opsClient.aiAnalysis(productId),
      opsClient.proposedActions(productId)
    ]).then(([items, proposedActions]) => {
      if (isMounted) {
        setRows(items);
        setActions(proposedActions);
        setError("");
      }
    }).catch((nextError: unknown) => {
      if (isMounted) {
        setError(nextError instanceof Error ? nextError.message : "AI 分析加载失败");
      }
    });
    return () => {
      isMounted = false;
    };
  }, [productId]);

  const stats = useMemo(() => {
    const pending = rows.filter((row) => row.adoptionState.toLowerCase().includes("pending")).length;
    const accepted = rows.filter((row) => row.adoptionState.toLowerCase().includes("accepted")).length;
    const confidence = rows.map((row) => confidencePercent(row.confidence)).filter((value) => value > 0);
    const average = confidence.length
      ? Math.round(confidence.reduce((total, value) => total + value, 0) / confidence.length)
      : 0;
    return { pending, accepted, average };
  }, [rows]);

  const pendingActions = useMemo(
    () => actions.filter((action) => action.status.toLowerCase().includes("pending")).length,
    [actions]
  );

  async function reviewAnalysis(id: string, adoptionState: "accepted" | "ignored") {
    setReviewingId(id);
    setError("");
    try {
      await opsClient.reviewAiAnalysis(id, adoptionState, productId);
      await reload();
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "AI 分析处理失败");
    } finally {
      setReviewingId(null);
    }
  }

  async function reviewProposedAction(
    id: string,
    status: "accepted" | "rejected" | "dismissed"
  ) {
    setReviewingActionId(id);
    setError("");
    try {
      await opsClient.reviewProposedAction(id, status, productId);
      await reload();
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "建议动作处理失败");
    } finally {
      setReviewingActionId(null);
    }
  }

  async function executeProposedAction(id: string) {
    setExecutingActionId(id);
    setError("");
    try {
      await opsClient.executeProposedAction(id, productId);
      await reload();
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "建议动作执行失败");
    } finally {
      setExecutingActionId(null);
    }
  }

  function startEditing(row: AiAnalysisRow) {
    setEditing(row);
    setEditSummary(row.summary);
    setEditClassification(row.classification);
    setError("");
  }

  async function saveEditedAnalysis(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editing) return;
    setReviewingId(editing.id);
    setError("");
    try {
      await opsClient.reviewAiAnalysis(
        editing.id,
        "edited_accepted",
        productId,
        {
          summary: editSummary.trim(),
          classification: editClassification.trim()
        }
      );
      setEditing(null);
      await reload();
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "AI 分析保存失败");
    } finally {
      setReviewingId(null);
    }
  }

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Agent</p>
          <h1>AI 分析中心</h1>
          <p>集中查看 Codex、Claude 等 Agent 写入的分析、摘要、分类和风险建议。</p>
        </div>
        <a className="secondary-button" href="/connectors?type=agent_api">
          配置 Agent API
        </a>
      </div>

      {error ? (
        <p className="form-error" role="alert">
          {error}
        </p>
      ) : null}

      {editing ? (
        <form className="panel product-form" onSubmit={(event) => void saveEditedAnalysis(event)}>
          <div className="panel-header">
            <div>
              <p className="eyebrow">Human Review</p>
              <h2>编辑分析结果</h2>
              <p>{editing.target}</p>
            </div>
          </div>
          <div className="form-grid">
            <label className="form-grid-wide">
              <span>摘要</span>
              <textarea
                aria-label="编辑摘要"
                onChange={(event) => setEditSummary(event.target.value)}
                required
                value={editSummary}
              />
            </label>
            <label>
              <span>分类</span>
              <input
                aria-label="编辑分类"
                onChange={(event) => setEditClassification(event.target.value)}
                required
                value={editClassification}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setEditing(null)} type="button">
              取消
            </button>
            <button
              className="primary-button"
              disabled={reviewingId === editing.id}
              type="submit"
            >
              保存并采纳
            </button>
          </div>
        </form>
      ) : null}

      <div className="kpi-grid">
        <KpiCard label="分析结果" value={String(rows.length)} detail="已写入后台" tone="blue" />
        <KpiCard label="待采纳" value={String(stats.pending)} detail="需要人工处理" tone="orange" />
        <KpiCard label="建议动作" value={String(pendingActions)} detail="等待人工确认" tone="orange" />
        <KpiCard label="已采纳" value={String(stats.accepted)} detail="进入业务流程" tone="green" />
      </div>

      <div className="content-grid">
        <section className="panel">
          <div className="panel-header">
            <h2>分析队列</h2>
            <StatusBadge tone="orange">{`${stats.pending} Pending`}</StatusBadge>
          </div>
          <div className="analysis-list">
            {rows.map((row: AiAnalysisRow) => {
              const percent = confidencePercent(row.confidence);
              const inputReferencesPreview = row.inputReferencesPreview ?? "-";
              const outputBodyPreview = row.outputBodyPreview ?? "-";
              return (
                <article className="analysis-item" key={row.id}>
                  <div className="analysis-title-row">
                    <div>
                      <strong>{row.target}</strong>
                      <p className="table-subtext">
                        {row.agent} / {row.model} / {row.analysisType}
                      </p>
                    </div>
                    <div className="inline-actions">
                      <StatusBadge tone={toneForClassification(row.classification)}>{row.classification}</StatusBadge>
                      <StatusBadge tone={row.adoptionState.toLowerCase().includes("accepted") ? "green" : "orange"}>
                        {row.adoptionState}
                      </StatusBadge>
                    </div>
                  </div>
                  <p className="analysis-summary">{row.summary}</p>
                  {inputReferencesPreview !== "-" || outputBodyPreview !== "-" ? (
                    <dl className="analysis-context-grid">
                      {inputReferencesPreview !== "-" ? (
                        <div>
                          <dt>输入依据</dt>
                          <dd>{inputReferencesPreview}</dd>
                        </div>
                      ) : null}
                      {outputBodyPreview !== "-" ? (
                        <div>
                          <dt>输出详情</dt>
                          <dd>{outputBodyPreview}</dd>
                        </div>
                      ) : null}
                    </dl>
                  ) : null}
                  <div className="confidence-row">
                    <span>置信度</span>
                    <div className="progress-track">
                      <div className="progress-fill" style={{ width: `${Math.max(percent, 8)}%` }} />
                    </div>
                    <strong>{percent > 0 ? `${percent}%` : "-"}</strong>
                  </div>
                  <div className="analysis-actions">
                    <button
                      aria-label={`采纳分析 ${row.target}`}
                      className="primary-button"
                      disabled={row.adoptionState.toLowerCase().includes("accepted") || reviewingId === row.id}
                      onClick={() => void reviewAnalysis(row.id, "accepted")}
                      type="button"
                    >
                      {reviewingId === row.id ? "处理中" : "采纳"}
                    </button>
                    <button
                      aria-label={`编辑 ${row.target}`}
                      className="secondary-button"
                      disabled={reviewingId === row.id}
                      onClick={() => startEditing(row)}
                      type="button"
                    >
                      编辑
                    </button>
                    <button
                      aria-label={`忽略分析 ${row.target}`}
                      className="secondary-button"
                      disabled={row.adoptionState.toLowerCase().includes("ignored") || reviewingId === row.id}
                      onClick={() => void reviewAnalysis(row.id, "ignored")}
                      type="button"
                    >
                      忽略
                    </button>
                  </div>
                </article>
              );
            })}
          </div>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>建议动作</h2>
            <StatusBadge tone="orange">{`${pendingActions} Pending`}</StatusBadge>
          </div>
          <div className="analysis-list">
            {actions.map((action) => {
              const actionStatus = action.status.toLowerCase();
              const actionAccepted = actionStatus.includes("accepted");
              const actionExecuted = actionStatus.includes("executed");
              const actionBusy = reviewingActionId === action.id || executingActionId === action.id;
              return (
                <article className="analysis-item" key={action.id}>
                  <div className="analysis-title-row">
                    <div>
                      <strong>{action.actionType}</strong>
                      <p className="table-subtext">
                        {action.target} / {action.agent} / {action.model}
                      </p>
                    </div>
                    <StatusBadge tone={actionAccepted || actionExecuted ? "green" : "orange"}>
                      {action.status}
                    </StatusBadge>
                  </div>
                  <p className="analysis-summary">{action.rationale}</p>
                  <p className="table-subtext">{action.payloadPreview}</p>
                  <div className="analysis-actions">
                    {actionAccepted ? (
                      <button
                        aria-label={`执行建议 ${action.actionType}`}
                        className="primary-button"
                        disabled={executingActionId === action.id}
                        onClick={() => void executeProposedAction(action.id)}
                        type="button"
                      >
                        {executingActionId === action.id ? "执行中" : "执行建议"}
                      </button>
                    ) : null}
                    <button
                      aria-label={`采纳建议 ${action.actionType}`}
                      className="primary-button"
                      disabled={actionAccepted || actionExecuted || actionBusy}
                      onClick={() => void reviewProposedAction(action.id, "accepted")}
                      type="button"
                    >
                      {reviewingActionId === action.id ? "处理中" : "采纳建议"}
                    </button>
                    <button
                      className="secondary-button"
                      disabled={actionStatus.includes("rejected") || actionExecuted || actionBusy}
                      onClick={() => void reviewProposedAction(action.id, "rejected")}
                      type="button"
                    >
                      拒绝
                    </button>
                    <button
                      className="secondary-button"
                      disabled={actionStatus.includes("dismissed") || actionExecuted || actionBusy}
                      onClick={() => void reviewProposedAction(action.id, "dismissed")}
                      type="button"
                    >
                      忽略
                    </button>
                  </div>
                </article>
              );
            })}
          </div>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>Agent API 护栏</h2>
          </div>
          <ul className="signal-list">
            <li>允许读取待分析反馈、GitHub Issues 和发布草稿。</li>
            <li>允许写入摘要、分类、风险说明和草稿建议。</li>
            <li>发布 OTA、客户可见邮件、GitHub 公开回复、许可证变更永远需要人工确认。</li>
          </ul>
        </section>
      </div>
    </div>
  );
}
