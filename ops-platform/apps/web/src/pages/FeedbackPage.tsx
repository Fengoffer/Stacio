import { useEffect, useMemo, useState } from "react";
import {
  opsClient,
  type AgentRequestRecord,
  type AiAnalysisRecord,
  type FeedbackCommentRecord,
  type FeedbackDetailRecord,
  type FeedbackQuery,
  type FeedbackRecord
} from "../api/client";
import { StatusBadge } from "../components/StatusBadge";
import { useProductSelection } from "../product/ProductContext";

const priorities = ["P0", "P1", "P2", "P3"];
const statuses = ["new", "triaged", "in_progress", "waiting_for_user", "resolved", "closed", "duplicate"];
const feedbackTypes = ["bug", "feature", "question", "crash", "update_issue", "license_issue", "billing_issue", "other"];
const licenseStates = ["licensed", "trial", "unlicensed", "expired", "invalid", "suspended", "revoked", "unknown"];

function formatDateTime(value?: string) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function humanize(value?: string) {
  return value
    ? value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ")
    : "-";
}

function priorityTone(priority: string) {
  if (priority === "P0" || priority === "P1") return "red";
  return priority === "P2" ? "orange" : "gray";
}

function statusTone(status: string) {
  if (status === "resolved" || status === "closed") return "green";
  if (status === "waiting_for_user") return "orange";
  if (status === "duplicate") return "gray";
  return "blue";
}

function sourceTone(source: string) {
  if (source === "github") return "gray";
  return source === "admin" ? "orange" : "blue";
}

function commentLabel(comment: FeedbackCommentRecord) {
  if (comment.visibility === "internal") return "内部备注";
  return comment.authorType === "customer" ? "客户消息" : "公开回复";
}

function outputString(analysis: AiAnalysisRecord, key: string) {
  const value = analysis.outputBody?.[key];
  return typeof value === "string" ? value : undefined;
}

export function FeedbackPage() {
  const { products, productId, setProductId } = useProductSelection();
  const [rows, setRows] = useState<FeedbackRecord[]>([]);
  const [detail, setDetail] = useState<FeedbackDetailRecord | null>(null);
  const [agentAnalyses, setAgentAnalyses] = useState<AiAnalysisRecord[]>([]);
  const [agentRequests, setAgentRequests] = useState<AgentRequestRecord[]>([]);
  const [githubIssues, setGitHubIssues] = useState<Awaited<ReturnType<typeof opsClient.githubIssues>>>([]);
  const [releases, setReleases] = useState<Awaited<ReturnType<typeof opsClient.releases>>>([]);
  const [search, setSearch] = useState("");
  const [priority, setPriority] = useState("");
  const [status, setStatus] = useState("");
  const [type, setType] = useState("");
  const [source, setSource] = useState("");
  const [version, setVersion] = useState("");
  const [licenseState, setLicenseState] = useState("");
  const [createdFrom, setCreatedFrom] = useState("");
  const [createdTo, setCreatedTo] = useState("");
  const [sort, setSort] = useState<NonNullable<FeedbackQuery["sort"]>>("newest");
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [batchStatus, setBatchStatus] = useState("");
  const [batchPriority, setBatchPriority] = useState("");
  const [batchAssignee, setBatchAssignee] = useState("");
  const [internalNote, setInternalNote] = useState("");
  const [customerReply, setCustomerReply] = useState("");
  const [githubIssueId, setGitHubIssueId] = useState("");
  const [duplicateOfId, setDuplicateOfId] = useState("");
  const [relatedReleaseId, setRelatedReleaseId] = useState("");
  const [assignedUserId, setAssignedUserId] = useState("");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const query = useMemo<FeedbackQuery>(() => ({
    search: search.trim() || undefined,
    priority: priority || undefined,
    status: status || undefined,
    type: type || undefined,
    source: source || undefined,
    version: version.trim() || undefined,
    licenseState: licenseState || undefined,
    createdFrom: createdFrom || undefined,
    createdTo: createdTo || undefined,
    sort
  }), [createdFrom, createdTo, licenseState, priority, search, sort, source, status, type, version]);

  const stats = useMemo(() => {
    const weekAgo = Date.now() - 7 * 86_400_000;
    return {
      total: rows.length,
      weekly: rows.filter((item) => new Date(item.createdAt).getTime() >= weekAgo).length,
      resolved: rows.filter((item) => ["resolved", "closed"].includes(item.status)).length,
      critical: rows.filter((item) => ["P0", "P1"].includes(item.priority)).length
    };
  }, [rows]);

  const availableGitHubIssues = useMemo(() => {
    const linkedIds = new Set(detail?.linkedGitHubIssues.map((issue) => issue.id) ?? []);
    return githubIssues.filter((issue) => issue.linkedFeedback === "-" && !linkedIds.has(issue.id));
  }, [detail, githubIssues]);
  const duplicateTargets = useMemo(() => (
    detail ? rows.filter((item) => item.id !== detail.id) : []
  ), [detail, rows]);
  const auditEvents = detail?.auditEvents ?? [];
  const feedbackAgentAnalyses = useMemo(() => {
    if (!detail) return [];
    return agentAnalyses.filter((item) => {
      if (item.targetType || item.targetId) {
        return item.targetType === "feedback" && item.targetId === detail.id;
      }
      return item.target === `feedback / ${detail.id}`;
    });
  }, [agentAnalyses, detail]);
  const feedbackAgentRequests = useMemo(() => {
    if (!detail) return [];
    return agentRequests.filter((item) => item.targetType === "feedback" && item.targetId === detail.id);
  }, [agentRequests, detail]);

  async function loadRows(nextProductId = productId, nextQuery = query) {
    const items = await opsClient.feedback(nextProductId, nextQuery);
    setRows(items);
    if (detail && !items.some((item) => item.id === detail.id)) setDetail(null);
  }

  async function loadGitHubIssues(nextProductId = productId) {
    setGitHubIssues(await opsClient.githubIssues(nextProductId));
  }

  useEffect(() => {
    setDetail(null);
    setAgentAnalyses([]);
    setAgentRequests([]);
    setSelectedIds([]);
    setBatchStatus("");
    setBatchPriority("");
    setBatchAssignee("");
    setInternalNote("");
    setCustomerReply("");
    setGitHubIssueId("");
    setDuplicateOfId("");
    setRelatedReleaseId("");
    setAssignedUserId("");
    setMessage("");
  }, [productId]);

  useEffect(() => {
    let mounted = true;
    setError("");
    void Promise.all([
      opsClient.feedback(productId, query),
      opsClient.githubIssues(productId),
      opsClient.releases(productId)
    ]).then(([feedbackRows, issueRows, releaseRows]) => {
      if (!mounted) return;
      setRows(feedbackRows);
      setGitHubIssues(issueRows);
      setReleases(releaseRows);
    }).catch((nextError: unknown) => {
      if (mounted) setError(nextError instanceof Error ? nextError.message : "反馈加载失败");
    });
    return () => {
      mounted = false;
    };
  }, [productId, query]);

  async function showDetail(item: FeedbackRecord) {
    setBusy(`detail:${item.id}`);
    setError("");
    setMessage("");
    setAgentAnalyses([]);
    setAgentRequests([]);
    try {
      const [nextDetail, analyses, requests] = await Promise.all([
        opsClient.feedbackDetail(productId, item.id),
        opsClient.aiAnalysis(productId, {
          targetType: "feedback",
          targetId: item.id
        }),
        opsClient.feedbackAgentRequests(productId, item.id)
      ]);
      setDetail(nextDetail);
      setAgentAnalyses(analyses);
      setAgentRequests(requests);
      setInternalNote("");
      setCustomerReply("");
      setGitHubIssueId("");
      setDuplicateOfId("");
      setRelatedReleaseId(nextDetail.relatedReleaseId ?? "");
      setAssignedUserId(nextDetail.assignedUserId ?? "");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "反馈详情加载失败");
    } finally {
      setBusy("");
    }
  }

  function replaceFeedback(next: FeedbackRecord) {
    setRows((current) => current.map((item) => item.id === next.id ? next : item));
    setDetail((current) => current?.id === next.id ? { ...current, ...next } : current);
  }

  function toggleSelected(id: string, selected: boolean) {
    setSelectedIds((current) =>
      selected ? [...new Set([...current, id])] : current.filter((item) => item !== id)
    );
  }

  async function applyBatchUpdate() {
    if (selectedIds.length === 0) return;
    const changes: { status?: string; priority?: string; assignedUserId?: string } = {};
    if (batchStatus) changes.status = batchStatus;
    if (batchPriority) changes.priority = batchPriority;
    const assignee = batchAssignee.trim();
    if (assignee) changes.assignedUserId = assignee;
    if (Object.keys(changes).length === 0) {
      setMessage("请选择要批量更新的字段。");
      return;
    }
    setBusy("batch");
    setError("");
    try {
      const updated = await opsClient.batchUpdateFeedback(productId, selectedIds, changes);
      setRows((current) => current.map((item) => updated.find((next) => next.id === item.id) ?? item));
      setDetail((current) => {
        if (!current) return current;
        const next = updated.find((item) => item.id === current.id);
        return next ? { ...current, ...next } : current;
      });
      setSelectedIds([]);
      setMessage(`${updated.length} 条反馈已批量更新。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "批量更新失败");
    } finally {
      setBusy("");
    }
  }

  async function updateFeedback(input: {
    status?: string;
    priority?: string;
    assignedUserId?: string | null;
    duplicateOfId?: string;
    relatedReleaseId?: string | null;
  }) {
    if (!detail) return;
    setBusy("update");
    setError("");
    try {
      replaceFeedback(await opsClient.updateFeedback(productId, detail.id, input));
      setMessage("反馈状态已更新。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "反馈更新失败");
    } finally {
      setBusy("");
    }
  }

  async function assignOwner() {
    if (!detail) return;
    const assignee = assignedUserId.trim();
    if (!assignee) return;
    setBusy("assign");
    setError("");
    try {
      replaceFeedback(await opsClient.updateFeedback(productId, detail.id, {
        assignedUserId: assignee
      }));
      setMessage("负责人已指派。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "负责人指派失败");
    } finally {
      setBusy("");
    }
  }

  async function markDuplicate() {
    if (!detail || !duplicateOfId) return;
    if (window.prompt("请输入 DUPLICATE 确认将当前反馈标记为重复。") !== "DUPLICATE") return;
    setBusy("duplicate");
    setError("");
    try {
      replaceFeedback(await opsClient.updateFeedback(productId, detail.id, {
        status: "duplicate",
        duplicateOfId
      }));
      setMessage("反馈已标记为重复。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "标记重复失败");
    } finally {
      setBusy("");
    }
  }

  async function linkRelatedRelease() {
    if (!detail || !relatedReleaseId) return;
    setBusy("release-link");
    setError("");
    try {
      replaceFeedback(await opsClient.updateFeedback(productId, detail.id, {
        relatedReleaseId
      }));
      setMessage("反馈已关联发布版本。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "关联发布失败");
    } finally {
      setBusy("");
    }
  }

  async function addInternalNote() {
    if (!detail || !internalNote.trim()) return;
    setBusy("note");
    setError("");
    try {
      const comment = await opsClient.addFeedbackComment(productId, detail.id, {
        visibility: "internal",
        body: internalNote.trim()
      });
      setDetail((current) => current ? { ...current, comments: [...current.comments, comment] } : current);
      setInternalNote("");
      setMessage("内部备注已添加。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "内部备注添加失败");
    } finally {
      setBusy("");
    }
  }

  async function sendCustomerReply() {
    if (!detail || !customerReply.trim()) return;
    if (window.prompt(`回复将发送到 ${detail.contactEmail ?? "客户邮箱"}。请输入 SEND 确认发送。`) !== "SEND") return;
    setBusy("reply");
    setError("");
    try {
      const result = await opsClient.sendFeedbackReply(productId, detail.id, customerReply.trim());
      setDetail((current) => current ? { ...current, comments: [...current.comments, result.comment] } : current);
      setCustomerReply("");
      setMessage("客户回复已进入发送队列。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户回复发送失败");
    } finally {
      setBusy("");
    }
  }

  async function acceptAgentAnalysis(analysis: AiAnalysisRecord) {
    if (!detail) return;
    setBusy(`ai-review:${analysis.id}`);
    setError("");
    try {
      await opsClient.reviewAiAnalysis(analysis.id, "accepted", productId);
      setAgentAnalyses((current) => current.map((item) =>
        item.id === analysis.id ? { ...item, adoptionState: "Accepted" } : item
      ));
      setDetail((current) => current ? {
        ...current,
        aiSummary: outputString(analysis, "summary") ?? analysis.summary ?? current.aiSummary,
        aiClassification: outputString(analysis, "classification") ?? analysis.classification ?? current.aiClassification,
        aiSuggestedPriority: outputString(analysis, "suggestedPriority") ?? current.aiSuggestedPriority
      } : current);
      setMessage("AI 摘要已采纳，客户邮件仍需人工确认发送。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "AI 摘要采纳失败");
    } finally {
      setBusy("");
    }
  }

  function useAgentReplyDraft(analysis: AiAnalysisRecord) {
    if (!analysis.replyDraft) return;
    setCustomerReply(analysis.replyDraft);
    setMessage("回复草稿已填入客户回复，发送前仍需人工确认。");
  }

  async function queueAgentRequest(requestType: "summary" | "reply_draft") {
    if (!detail) return;
    const prompt = requestType === "summary"
      ? "请总结这条反馈，提取影响版本、可能分类、建议优先级和下一步处理建议。"
      : "请基于当前反馈起草一封客户可见回复，只生成草稿，不要发送邮件。";
    setBusy(`agent-request:${requestType}`);
    setError("");
    try {
      const request = await opsClient.createFeedbackAgentRequest(productId, detail.id, {
        requestType,
        agentHint: requestType === "summary" ? "codex" : "claude",
        prompt
      });
      setAgentRequests((current) => [request, ...current.filter((item) => item.id !== request.id)]);
      setMessage(`Agent 请求已排队：${request.requestType}`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Agent 请求创建失败");
    } finally {
      setBusy("");
    }
  }

  async function linkGitHubIssue() {
    if (!detail || !githubIssueId) return;
    setBusy("github-link");
    setError("");
    try {
      const linked = await opsClient.linkFeedbackGitHubIssue(productId, detail.id, githubIssueId);
      setDetail((current) => current ? {
        ...current,
        linkedGitHubIssues: [...current.linkedGitHubIssues, linked]
      } : current);
      setGitHubIssueId("");
      await loadGitHubIssues();
      setMessage(`已关联 GitHub Issue #${linked.number}。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "GitHub Issue 关联失败");
    } finally {
      setBusy("");
    }
  }

  async function unlinkGitHubIssue(issueId: string) {
    if (!detail || window.prompt("请输入 UNLINK 确认解除 GitHub Issue 关联。") !== "UNLINK") return;
    setBusy(`github-unlink:${issueId}`);
    setError("");
    try {
      await opsClient.unlinkFeedbackGitHubIssue(productId, detail.id, issueId);
      setDetail((current) => current ? {
        ...current,
        linkedGitHubIssues: current.linkedGitHubIssues.filter((issue) => issue.id !== issueId)
      } : current);
      await loadGitHubIssues();
      setMessage("GitHub Issue 关联已解除。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "解除关联失败");
    } finally {
      setBusy("");
    }
  }

  async function redactAttachment(attachmentId: string) {
    if (!detail || window.prompt("请输入 REDACT 确认脱敏附件。") !== "REDACT") return;
    setBusy(`attachment-redact:${attachmentId}`);
    setError("");
    try {
      const attachment = await opsClient.redactFeedbackAttachment(productId, detail.id, attachmentId);
      setDetail((current) => current ? {
        ...current,
        attachments: current.attachments.map((item) => item.id === attachment.id ? attachment : item)
      } : current);
      setMessage("附件已脱敏。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "附件脱敏失败");
    } finally {
      setBusy("");
    }
  }

  async function deleteAttachment(attachmentId: string) {
    if (!detail || window.prompt("请输入 DELETE 确认删除附件记录。") !== "DELETE") return;
    setBusy(`attachment-delete:${attachmentId}`);
    setError("");
    try {
      await opsClient.deleteFeedbackAttachment(productId, detail.id, attachmentId);
      setDetail((current) => current ? {
        ...current,
        attachments: current.attachments.filter((item) => item.id !== attachmentId)
      } : current);
      setMessage("附件记录已删除。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "附件删除失败");
    } finally {
      setBusy("");
    }
  }

  async function redactFeedback() {
    if (!detail || window.prompt("请输入 REDACT 确认脱敏描述、邮箱与诊断信息。") !== "REDACT") return;
    setBusy("redact");
    setError("");
    try {
      replaceFeedback(await opsClient.redactFeedback(productId, detail.id, [
        "description",
        "contactEmail",
        "diagnosticsSummary"
      ]));
      setMessage("反馈中的敏感字段已脱敏。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "反馈脱敏失败");
    } finally {
      setBusy("");
    }
  }

  async function deleteFeedback() {
    if (!detail || window.prompt("请输入 DELETE 确认删除反馈。") !== "DELETE") return;
    setBusy("delete");
    setError("");
    try {
      await opsClient.deleteFeedback(productId, detail.id);
      setRows((current) => current.filter((item) => item.id !== detail.id));
      setDetail(null);
      setMessage("反馈已删除。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "反馈删除失败");
    } finally {
      setBusy("");
    }
  }

  async function syncGitHub() {
    setBusy("github-sync");
    setError("");
    try {
      await opsClient.pullGitHubIssues(productId);
      await loadGitHubIssues();
      setMessage("GitHub 同步任务已进入队列。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "GitHub 同步失败");
    } finally {
      setBusy("");
    }
  }

  function exportFeedback() {
    const values = rows.map((item) => [
      item.id,
      item.title,
      item.type,
      item.status,
      item.priority,
      item.source,
      item.contactEmail ?? "",
      item.appVersion ?? "",
      item.updatedAt
    ]);
    const csv = [
      ["id", "title", "type", "status", "priority", "source", "email", "version", "updatedAt"],
      ...values
    ].map((row) => row.map((value) => `"${String(value).replaceAll("\"", "\"\"")}"`).join(",")).join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `${productId}-feedback.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  return (
    <div className="page">
      <div className="page-heading feedback-page-heading">
        <div>
          <p className="eyebrow">Inbox</p>
          <h1>用户反馈</h1>
          <p>统一处理 App 提交、GitHub Issues 和管理员录入的需求与 Bug。</p>
        </div>
        <div className="inline-actions">
          <button className="secondary-button" onClick={exportFeedback} type="button">导出当前结果</button>
          <button className="primary-button" disabled={busy === "github-sync"} onClick={() => void syncGitHub()} type="button">
            同步 GitHub
          </button>
        </div>
      </div>

      {error ? <div className="error-banner" role="alert">{error}</div> : null}
      {message ? <div className="success-banner" role="status">{message}</div> : null}

      <div className="feedback-toolbar">
        <label className="product-switcher">
          <span>当前产品</span>
          <select aria-label="当前产品" onChange={(event) => {
            setProductId(event.target.value);
            setDetail(null);
          }} value={productId}>
            {products.length === 0 ? <option value={productId}>{productId}</option> : null}
            {products.map((item) => <option key={item.id} value={item.id}>{item.name} ({item.id})</option>)}
          </select>
        </label>
        <label className="feedback-search">
          <span>搜索</span>
          <input aria-label="搜索反馈" onChange={(event) => setSearch(event.target.value)} placeholder="标题、内容、邮箱、版本、GitHub Issue 或 ID" type="search" value={search} />
        </label>
        <label><span>优先级</span><select aria-label="筛选优先级" onChange={(event) => setPriority(event.target.value)} value={priority}>
          <option value="">全部</option>{priorities.map((item) => <option key={item} value={item}>{item}</option>)}
        </select></label>
        <label><span>状态</span><select aria-label="筛选状态" onChange={(event) => setStatus(event.target.value)} value={status}>
          <option value="">全部</option>{statuses.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}
        </select></label>
        <label><span>类型</span><select aria-label="筛选类型" onChange={(event) => setType(event.target.value)} value={type}>
          <option value="">全部</option>{feedbackTypes.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}
        </select></label>
        <label><span>来源</span><select aria-label="筛选来源" onChange={(event) => setSource(event.target.value)} value={source}>
          <option value="">全部</option><option value="app">App</option><option value="github">GitHub</option><option value="admin">Admin</option>
        </select></label>
        <label><span>版本</span><input aria-label="筛选版本" onChange={(event) => setVersion(event.target.value)} placeholder="0.13.2-Beta" value={version} /></label>
        <label><span>License</span><select aria-label="筛选 License" onChange={(event) => setLicenseState(event.target.value)} value={licenseState}>
          <option value="">全部</option>{licenseStates.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}
        </select></label>
        <label><span>开始日期</span><input aria-label="开始日期" onChange={(event) => setCreatedFrom(event.target.value)} type="date" value={createdFrom} /></label>
        <label><span>结束日期</span><input aria-label="结束日期" onChange={(event) => setCreatedTo(event.target.value)} type="date" value={createdTo} /></label>
        <label><span>排序</span><select aria-label="反馈排序" onChange={(event) => setSort(event.target.value as NonNullable<FeedbackQuery["sort"]>)} value={sort}>
          <option value="newest">最新</option><option value="priority">优先级</option><option value="last_activity">最后活动</option><option value="version">影响版本</option>
        </select></label>
      </div>

      <div className="feedback-stats" aria-label="反馈统计">
        <div><span>总反馈</span><strong>{stats.total}</strong></div>
        <div><span>本周新增</span><strong>{stats.weekly}</strong></div>
        <div><span>已解决</span><strong>{stats.resolved}</strong></div>
        <div><span>P0 / P1</span><strong>{stats.critical}</strong></div>
      </div>

      <div className="feedback-workspace">
        <section className="feedback-list-panel" aria-label="反馈列表">
          <div className="feedback-list-header">
            <strong>{rows.length} 条反馈</strong>
            <button className="secondary-button" onClick={() => void loadRows()} type="button">刷新</button>
          </div>
          <div className="feedback-batch-bar">
            <span>{selectedIds.length} 条已选择</span>
            <label><span>批量状态</span><select aria-label="批量状态" onChange={(event) => setBatchStatus(event.target.value)} value={batchStatus}>
              <option value="">不变</option>{statuses.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}
            </select></label>
            <label><span>批量优先级</span><select aria-label="批量优先级" onChange={(event) => setBatchPriority(event.target.value)} value={batchPriority}>
              <option value="">不变</option>{priorities.map((item) => <option key={item} value={item}>{item}</option>)}
            </select></label>
            <label><span>批量指派人</span><input aria-label="批量指派人" onChange={(event) => setBatchAssignee(event.target.value)} placeholder="用户 ID" value={batchAssignee} /></label>
            <button className="secondary-button" disabled={selectedIds.length === 0 || busy === "batch"} onClick={() => void applyBatchUpdate()} type="button">应用批量更新</button>
          </div>
          <div className="feedback-list">
            {rows.length === 0 ? <div className="empty-state">暂无符合筛选条件的反馈。</div> : rows.map((item) => (
              <div className="feedback-list-row" key={item.id}>
                <label className="feedback-row-select">
                  <input
                    aria-label={`选择反馈 ${item.title}`}
                    checked={selectedIds.includes(item.id)}
                    onChange={(event) => toggleSelected(item.id, event.target.checked)}
                    type="checkbox"
                  />
                </label>
                <button
                  aria-label={`查看反馈 ${item.title}`}
                  className={`feedback-list-item${detail?.id === item.id ? " active" : ""}`}
                  disabled={busy === `detail:${item.id}`}
                  onClick={() => void showDetail(item)}
                  type="button"
                >
                  <div className="feedback-list-title">
                    <strong>{item.title}</strong>
                    <StatusBadge tone={priorityTone(item.priority)}>{item.priority}</StatusBadge>
                  </div>
                  <p>{item.aiSummary ?? item.description}</p>
                  <div className="feedback-list-meta">
                    <StatusBadge tone={statusTone(item.status)}>{humanize(item.status)}</StatusBadge>
                    <StatusBadge tone={sourceTone(item.source)}>{humanize(item.source)}</StatusBadge>
                    <span>{item.appVersion ?? "未知版本"}</span>
                    <time>{formatDateTime(item.updatedAt)}</time>
                  </div>
                </button>
              </div>
            ))}
          </div>
        </section>

        {detail ? (
          <aside className="feedback-detail-panel" aria-label="反馈详情">
            <div className="feedback-detail-heading">
              <div>
                <p className="eyebrow">{detail.id}</p>
                <h2>{detail.title}</h2>
                <div className="feedback-badge-row">
                  <StatusBadge tone={priorityTone(detail.priority)}>{detail.priority}</StatusBadge>
                  <StatusBadge tone={statusTone(detail.status)}>{humanize(detail.status)}</StatusBadge>
                  <StatusBadge tone={sourceTone(detail.source)}>{humanize(detail.source)}</StatusBadge>
                </div>
              </div>
              <button aria-label="关闭反馈详情" className="secondary-button" onClick={() => setDetail(null)} type="button">关闭</button>
            </div>

            <section className="feedback-detail-section feedback-triage-controls">
              <label><span>状态</span><select aria-label="反馈状态" disabled={busy === "update"} onChange={(event) => void updateFeedback({ status: event.target.value })} value={detail.status}>
                {statuses.map((item) => <option key={item} value={item}>{humanize(item)}</option>)}
              </select></label>
              <label><span>优先级</span><select aria-label="反馈优先级" disabled={busy === "update"} onChange={(event) => void updateFeedback({ priority: event.target.value })} value={detail.priority}>
                {priorities.map((item) => <option key={item} value={item}>{item}</option>)}
              </select></label>
            </section>

            <section className="feedback-detail-section">
              <h3>负责人</h3>
              <div className="feedback-link-controls">
                <input aria-label="指派负责人" onChange={(event) => setAssignedUserId(event.target.value)} placeholder="用户 ID" value={assignedUserId} />
                <button className="secondary-button" disabled={!assignedUserId.trim() || busy === "assign"} onClick={() => void assignOwner()} type="button">指派</button>
              </div>
            </section>

            <section className="feedback-detail-section">
              <h3>重复反馈</h3>
              <div className="feedback-link-controls">
                <select aria-label="重复目标" onChange={(event) => setDuplicateOfId(event.target.value)} value={duplicateOfId}>
                  <option value="">选择原始反馈</option>
                  {duplicateTargets.map((item) => <option key={item.id} value={item.id}>{item.title} ({item.id})</option>)}
                </select>
                <button className="secondary-button" disabled={!duplicateOfId || busy === "duplicate"} onClick={() => void markDuplicate()} type="button">标记为重复</button>
              </div>
            </section>

            <section className="feedback-detail-section">
              <h3>关联发布</h3>
              <div className="feedback-link-controls">
                <select aria-label="关联发布版本" onChange={(event) => setRelatedReleaseId(event.target.value)} value={relatedReleaseId}>
                  <option value="">选择发布版本</option>
                  {releases.map((release) => <option key={release.id} value={release.id}>{release.version} · {release.channel}</option>)}
                </select>
                <button className="secondary-button" disabled={!relatedReleaseId || busy === "release-link"} onClick={() => void linkRelatedRelease()} type="button">关联发布</button>
              </div>
            </section>

            <section className="feedback-detail-section">
              <h3>用户描述</h3>
              <p className="feedback-description">{detail.description}</p>
              <dl className="feedback-metadata">
                <div><dt>联系邮箱</dt><dd>{detail.contactEmail ?? "-"}</dd></div>
                <div><dt>App 版本</dt><dd>{detail.appVersion ?? "-"}</dd></div>
                <div><dt>Build</dt><dd>{detail.buildNumber ?? "-"}</dd></div>
                <div><dt>系统</dt><dd>{detail.osVersion ?? "-"}</dd></div>
                <div><dt>License</dt><dd>{detail.licenseState ?? "-"}</dd></div>
                <div><dt>负责人</dt><dd>{detail.assignedUserId ?? "-"}</dd></div>
                <div><dt>创建时间</dt><dd>{formatDateTime(detail.createdAt)}</dd></div>
              </dl>
            </section>

            <section className="feedback-detail-section">
              <h3>AI 分析</h3>
              <p>{detail.aiSummary ?? "尚未生成 AI 摘要。"}</p>
              <div className="feedback-ai-meta">
                <span>分类：{detail.aiClassification ?? "-"}</span>
                <span>建议优先级：{detail.aiSuggestedPriority ?? "-"}</span>
              </div>
              <div className="inline-actions">
                <button
                  className="secondary-button"
                  disabled={busy === "agent-request:summary"}
                  onClick={() => void queueAgentRequest("summary")}
                  type="button"
                >
                  请求 Agent 摘要
                </button>
                <button
                  className="secondary-button"
                  disabled={busy === "agent-request:reply_draft"}
                  onClick={() => void queueAgentRequest("reply_draft")}
                  type="button"
                >
                  请求 Agent 回复草稿
                </button>
              </div>
              {feedbackAgentRequests.length > 0 ? (
                <div className="feedback-thread">
                  {feedbackAgentRequests.map((request) => (
                    <article className="internal" key={request.id}>
                      <header>
                        <strong>Agent 请求</strong>
                        <span>{request.status}</span>
                      </header>
                      <p>{request.requestType} · {request.agentHint ?? "any agent"}</p>
                      <small>{request.prompt}</small>
                    </article>
                  ))}
                </div>
              ) : null}
              {feedbackAgentAnalyses.length > 0 ? (
                <div className="feedback-thread">
                  {feedbackAgentAnalyses.map((analysis) => (
                    <article className="internal" key={analysis.id}>
                      <header>
                        <strong>{analysis.agent}</strong>
                        <span>{analysis.analysisType}</span>
                      </header>
                      <p>{analysis.replyDraft ?? analysis.summary}</p>
                      <small>
                        {analysis.model} · 置信度 {analysis.confidence} · {analysis.adoptionState}
                      </small>
                      {analysis.replyDraft ? (
                        <button
                          className="secondary-button"
                          onClick={() => useAgentReplyDraft(analysis)}
                          type="button"
                        >
                          使用回复草稿 {analysis.agent}
                        </button>
                      ) : (
                        <button
                          className="secondary-button"
                          disabled={busy === `ai-review:${analysis.id}`}
                          onClick={() => void acceptAgentAnalysis(analysis)}
                          type="button"
                        >
                          采纳 AI 摘要 {analysis.agent}
                        </button>
                      )}
                    </article>
                  ))}
                </div>
              ) : null}
            </section>

            <section className="feedback-detail-section">
              <h3>诊断信息</h3>
              <pre className="feedback-diagnostics">{JSON.stringify(detail.diagnosticsSummary ?? {}, null, 2)}</pre>
            </section>

            <section className="feedback-detail-section">
              <h3>附件</h3>
              {detail.attachments.length === 0 ? <p className="muted-copy">没有附件。</p> : (
                <div className="feedback-attachment-list">{detail.attachments.map((attachment) => (
                  <div key={attachment.id}>
                    <div><strong>{attachment.fileName}</strong><span>{attachment.contentType} · {attachment.sizeBytes} bytes</span></div>
                    <div className="inline-actions">
                      <button className="secondary-button" disabled={busy === `attachment-redact:${attachment.id}`} onClick={() => void redactAttachment(attachment.id)} type="button">脱敏</button>
                      <button className="danger-button" disabled={busy === `attachment-delete:${attachment.id}`} onClick={() => void deleteAttachment(attachment.id)} type="button">删除</button>
                    </div>
                  </div>
                ))}</div>
              )}
            </section>

            <section className="feedback-detail-section">
              <h3>GitHub Issue</h3>
              {detail.linkedGitHubIssues.length === 0 ? <p className="muted-copy">尚未关联 GitHub Issue。</p> : (
                <div className="feedback-github-list">{detail.linkedGitHubIssues.map((issue) => (
                  <div key={issue.id}>
                    <a href={issue.url} rel="noreferrer" target="_blank">#{issue.number} {issue.title}</a>
                    <button className="danger-button" disabled={busy === `github-unlink:${issue.id}`} onClick={() => void unlinkGitHubIssue(issue.id)} type="button">解除关联</button>
                  </div>
                ))}</div>
              )}
              <div className="feedback-link-controls">
                <select aria-label="关联 GitHub Issue" onChange={(event) => setGitHubIssueId(event.target.value)} value={githubIssueId}>
                  <option value="">选择未关联 Issue</option>
                  {availableGitHubIssues.map((issue) => <option key={issue.id} value={issue.id}>#{issue.number} {issue.title}</option>)}
                </select>
                <button className="secondary-button" disabled={!githubIssueId || busy === "github-link"} onClick={() => void linkGitHubIssue()} type="button">关联 Issue</button>
              </div>
            </section>

            <section className="feedback-detail-section">
              <h3>处理记录</h3>
              {detail.comments.length === 0 ? <p className="muted-copy">暂无备注或公开回复。</p> : (
                <div className="feedback-thread">{detail.comments.map((comment) => (
                  <article className={comment.visibility} key={comment.id}>
                    <header><strong>{commentLabel(comment)}</strong><span>{formatDateTime(comment.createdAt)}</span></header>
                    <p>{comment.body}</p>
                    {comment.deliveryStatus ? <small>投递状态：{humanize(comment.deliveryStatus)}</small> : null}
                  </article>
                ))}</div>
              )}
            </section>

            <section className="feedback-detail-section">
              <h3>审计轨迹</h3>
              {auditEvents.length === 0 ? <p className="muted-copy">暂无审计事件。</p> : (
                <div className="feedback-thread">{auditEvents.map((event) => (
                  <article className="internal" key={event.id}>
                    <header><strong>{event.action}</strong><span>{formatDateTime(event.createdAt)}</span></header>
                    <p>{event.actorId ?? event.actorType}</p>
                    <small>{event.targetType}{event.targetId ? ` / ${event.targetId}` : ""}</small>
                  </article>
                ))}</div>
              )}
            </section>

            <section className="feedback-detail-section">
              <h3>内部备注</h3>
              <textarea aria-label="内部备注" onChange={(event) => setInternalNote(event.target.value)} placeholder="仅管理后台可见" rows={3} value={internalNote} />
              <button className="secondary-button" disabled={!internalNote.trim() || busy === "note"} onClick={() => void addInternalNote()} type="button">添加内部备注</button>
            </section>

            <section className="feedback-detail-section">
              <h3>客户回复</h3>
              <textarea aria-label="客户回复" disabled={!detail.contactEmail} onChange={(event) => setCustomerReply(event.target.value)} placeholder={detail.contactEmail ? `回复至 ${detail.contactEmail}` : "反馈未提供有效邮箱"} rows={4} value={customerReply} />
              <button className="primary-button" disabled={!detail.contactEmail || !customerReply.trim() || busy === "reply"} onClick={() => void sendCustomerReply()} type="button">确认并发送回复</button>
            </section>

            <section className="feedback-detail-section feedback-danger-zone">
              <h3>敏感操作</h3>
              <p>脱敏和删除均需要人工输入确认词，并写入审计日志。</p>
              <div className="inline-actions">
                <button className="secondary-button" disabled={busy === "redact"} onClick={() => void redactFeedback()} type="button">脱敏敏感字段</button>
                <button className="danger-button" disabled={busy === "delete"} onClick={() => void deleteFeedback()} type="button">删除反馈</button>
              </div>
            </section>
          </aside>
        ) : (
          <aside className="feedback-detail-empty">
            <strong>选择一条反馈开始处理</strong>
            <p>查看诊断、调整优先级、添加备注、回复客户或关联 GitHub Issue。</p>
          </aside>
        )}
      </div>
    </div>
  );
}
