import { useEffect, useMemo, useState, type FormEvent } from "react";
import {
  demoModeEnabled,
  opsClient,
  type NotificationDeliveryRecord,
  type NotificationInput,
  type NotificationPolicyInput,
  type NotificationPolicyRecord,
  type NotificationRecord,
  type NotificationTemplateRecord
} from "../api/client";
import { notificationTemplates, notifications } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

interface TemplateFormState {
  type: string;
  subjectTemplate: string;
  htmlTemplate: string;
  textTemplate: string;
  status: "active" | "disabled";
}

interface NotificationFormState {
  type: string;
  recipient: string;
  priority: NonNullable<NotificationInput["priority"]>;
  payload: string;
}

type TemplatePreviewState = { subject: string; html: string; text?: string };
type DeliveryPanelState = {
  notification: NotificationRecord;
  rows: NotificationDeliveryRecord[];
};
type NotificationPolicyFormState = NotificationPolicyInput;

const emptyTemplateForm: TemplateFormState = {
  type: "",
  subjectTemplate: "",
  htmlTemplate: "",
  textTemplate: "",
  status: "active"
};

const emptyNotificationForm: NotificationFormState = {
  type: "",
  recipient: "",
  priority: "normal",
  payload: "{}"
};

const defaultPolicyForm: NotificationPolicyFormState = {
  quietHoursEnabled: false,
  quietHoursStart: "22:00",
  quietHoursEnd: "08:00",
  quietHoursTimeZone: "Asia/Shanghai"
};

function templateFormFromRecord(template: NotificationTemplateRecord): TemplateFormState {
  return {
    type: template.type,
    subjectTemplate: template.subject,
    htmlTemplate: template.htmlTemplate,
    textTemplate: template.textTemplate ?? "",
    status: template.status.toLowerCase().includes("disabled") ? "disabled" : "active"
  };
}

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback;
}

function policyFormFromRecord(policy: NotificationPolicyRecord): NotificationPolicyFormState {
  return {
    quietHoursEnabled: policy.quietHoursEnabled,
    quietHoursStart: policy.quietHoursStart,
    quietHoursEnd: policy.quietHoursEnd,
    quietHoursTimeZone: policy.quietHoursTimeZone
  };
}

function notificationStatusTone(status: string) {
  const normalized = status.toLowerCase();
  if (normalized.includes("sent")) return "green";
  if (normalized.includes("fail")) return "red";
  if (normalized.includes("draft")) return "gray";
  return "orange";
}

export function NotificationsPage() {
  const { productId } = useProduct();
  const demoMode = demoModeEnabled();
  const [templates, setTemplates] = useState<NotificationTemplateRecord[]>(
    demoMode ? notificationTemplates : []
  );
  const [queue, setQueue] = useState<NotificationRecord[]>(
    demoMode ? notifications : []
  );
  const [selectedType, setSelectedType] = useState(
    demoMode ? notificationTemplates[0]?.type ?? "" : ""
  );
  const [templateForm, setTemplateForm] = useState<TemplateFormState>(() =>
    demoMode && notificationTemplates[0]
      ? templateFormFromRecord(notificationTemplates[0])
      : emptyTemplateForm
  );
  const [notificationForm, setNotificationForm] =
    useState<NotificationFormState>(emptyNotificationForm);
  const [policyForm, setPolicyForm] =
    useState<NotificationPolicyFormState>(defaultPolicyForm);
  const [digestRecipient, setDigestRecipient] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [preview, setPreview] = useState<TemplatePreviewState>({
    subject: "",
    html: "",
    text: ""
  });
  const [deliveryPanel, setDeliveryPanel] = useState<DeliveryPanelState | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [message, setMessage] = useState("未执行发送");
  const [error, setError] = useState("");

  async function reloadQueue() {
    setQueue(await opsClient.notifications(productId));
  }

  async function reloadTemplates(preferredType?: string) {
    const items = await opsClient.notificationTemplates(productId);
    setTemplates(items);
    const next =
      items.find((template) => template.type === preferredType) ??
      items[0];
    if (next) {
      setSelectedType(next.type);
      setTemplateForm(templateFormFromRecord(next));
    }
  }

  useEffect(() => {
    let mounted = true;
    void Promise.all([
      opsClient.notificationTemplates(productId),
      opsClient.notifications(productId),
      opsClient.notificationPolicy(productId)
    ])
      .then(([templateRows, notificationRows, notificationPolicy]) => {
        if (!mounted) return;
        setTemplates(templateRows);
        setQueue(notificationRows);
        setPolicyForm(policyFormFromRecord(notificationPolicy));
        const first = templateRows[0];
        if (first) {
          setSelectedType(first.type);
          setTemplateForm(templateFormFromRecord(first));
        }
      })
      .catch((nextError: unknown) => {
        if (mounted) {
          setError(errorMessage(nextError, "通知中心加载失败"));
        }
      });
    return () => {
      mounted = false;
    };
  }, [productId]);

  const queuedCount = useMemo(
    () => queue.filter((item) => item.status.toLowerCase().includes("queued")).length,
    [queue]
  );

  function selectTemplate(type: string) {
    setSelectedType(type);
    const selected = templates.find((template) => template.type === type);
    if (selected) {
      setTemplateForm(templateFormFromRecord(selected));
    }
    setError("");
    setMessage("");
  }

  async function saveTemplate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!templateForm.type.trim()) {
      setError("请填写模板类型");
      return;
    }
    setBusyId("template");
    setError("");
    try {
      const saved = await opsClient.upsertNotificationTemplate(
        productId,
        templateForm.type.trim(),
        {
          subjectTemplate: templateForm.subjectTemplate.trim(),
          htmlTemplate: templateForm.htmlTemplate,
          textTemplate: templateForm.textTemplate || undefined,
          status: templateForm.status
        }
      );
      setMessage(`模板 ${saved.type} 已保存`);
      await reloadTemplates(saved.type);
    } catch (nextError) {
      setError(errorMessage(nextError, "邮件模板保存失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function previewCurrentTemplate() {
    setBusyId("preview");
    setError("");
    try {
      const rendered = await opsClient.previewTemplate({
        productId,
        subjectTemplate: templateForm.subjectTemplate,
        htmlTemplate: templateForm.htmlTemplate,
        textTemplate: templateForm.textTemplate || undefined,
        payload: {
          feedback: { title: "登录崩溃" },
          reply: { body: "问题已经修复。" },
          license: { plan: "Pro" },
          release: { version: "0.14.0" }
        }
      });
      setPreview(rendered);
      setMessage("模板预览已刷新");
    } catch (nextError) {
      setError(errorMessage(nextError, "模板预览失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function createNotification(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId("create");
    setError("");
    try {
      let payload: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(notificationForm.payload);
        if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
          throw new Error("Payload 必须是 JSON 对象");
        }
        payload = parsed as Record<string, unknown>;
      } catch (parseError) {
        throw new Error(
          parseError instanceof Error ? parseError.message : "Payload JSON 无效"
        );
      }
      await opsClient.createNotification(productId, {
        type: notificationForm.type.trim(),
        recipient: notificationForm.recipient.trim(),
        payload,
        priority: notificationForm.priority,
        status: "queued"
      });
      setMessage("通知已加入队列");
      setCreateOpen(false);
      setNotificationForm(emptyNotificationForm);
      await reloadQueue();
    } catch (nextError) {
      setError(errorMessage(nextError, "通知创建失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function createDailyFeedbackDigest() {
    const recipient = digestRecipient.trim();
    if (!recipient) {
      setError("请填写日报收件邮箱");
      return;
    }
    setBusyId("digest");
    setError("");
    try {
      const created = await opsClient.createDailyFeedbackDigest(productId, {
        recipient
      });
      setQueue((current) => [created, ...current.filter((item) => item.id !== created.id)]);
      setMessage("反馈日报已加入队列");
    } catch (nextError) {
      setError(errorMessage(nextError, "反馈日报创建失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function createLicenseExpiringReminders() {
    setBusyId("license-expiring");
    setError("");
    try {
      const result = await opsClient.createLicenseExpiringReminders(productId, {
        days: 30
      });
      setQueue((current) => [
        ...result.created,
        ...current.filter((item) => !result.created.some((created) => created.id === item.id))
      ]);
      setMessage(`License 到期提醒已加入队列：新增 ${result.createdCount}，跳过 ${result.skippedCount}`);
    } catch (nextError) {
      setError(errorMessage(nextError, "License 到期提醒创建失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function saveNotificationPolicy() {
    setBusyId("policy");
    setError("");
    try {
      const saved = await opsClient.updateNotificationPolicy(productId, policyForm);
      setPolicyForm(policyFormFromRecord(saved));
      setMessage("静默策略已保存");
    } catch (nextError) {
      setError(errorMessage(nextError, "静默策略保存失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function sendNotification(row: NotificationRecord, dryRun: boolean) {
    if (!dryRun) {
      const confirmation = window.prompt(
        `将向 ${row.recipient} 发送客户可见邮件。请输入 SEND 确认。`
      );
      if (confirmation !== "SEND") {
        setMessage("已取消发送");
        return;
      }
    }
    setBusyId(row.id);
    setError("");
    setMessage(dryRun ? "Dry-run 任务入队中" : "真实发送任务入队中");
    try {
      await opsClient.sendNotification(row.id, dryRun, "queue", productId);
      setMessage(dryRun ? "Dry-run 任务已入队" : "发送任务已入队");
      await reloadQueue();
    } catch (nextError) {
      setError(errorMessage(nextError, dryRun ? "Dry-run 失败" : "邮件发送失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function loadDeliveryHistory(row: NotificationRecord) {
    setBusyId(`deliveries:${row.id}`);
    setError("");
    try {
      const rows = await opsClient.notificationDeliveries(productId, row.id);
      setDeliveryPanel({ notification: row, rows });
      setMessage(`已载入 ${row.recipient} 的投递历史`);
    } catch (nextError) {
      setError(errorMessage(nextError, "投递历史加载失败"));
    } finally {
      setBusyId(null);
    }
  }

  const templateColumns: DataColumn<NotificationTemplateRecord>[] = [
    {
      key: "type",
      title: "类型",
      render: (row) => (
        <button
          className="table-link-button"
          onClick={() => selectTemplate(row.type)}
          type="button"
        >
          {row.type}
        </button>
      )
    },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge
          tone={row.status.toLowerCase().includes("active") ? "green" : "gray"}
        >
          {row.status}
        </StatusBadge>
      )
    },
    { key: "updatedAt", title: "更新", render: (row) => row.updatedAt }
  ];

  const notificationColumns: DataColumn<NotificationRecord>[] = [
    {
      key: "recipient",
      title: "收件人",
      render: (row) => (
        <div>
          <strong>{row.recipient}</strong>
          <p className="table-subtext">{row.summary}</p>
        </div>
      )
    },
    { key: "type", title: "类型", render: (row) => row.type },
    {
      key: "priority",
      title: "优先级",
      render: (row) => (
        <StatusBadge
          tone={row.priority.toLowerCase().includes("high") ? "orange" : "blue"}
        >
          {row.priority}
        </StatusBadge>
      )
    },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge tone={notificationStatusTone(row.status)}>
          {row.status}
        </StatusBadge>
      )
    },
    { key: "createdAt", title: "创建", render: (row) => row.createdAt },
    {
      key: "actions",
      title: "操作",
      render: (row) => (
        <div className="inline-actions">
          <button
            aria-label={`Dry-run ${row.recipient}`}
            className="secondary-button"
            disabled={busyId === row.id}
            onClick={() => void sendNotification(row, true)}
            type="button"
          >
            Dry-run
          </button>
          <button
            aria-label={`${row.status.toLowerCase().includes("fail") ? "重试" : "发送"} ${row.recipient}`}
            className="primary-button"
            disabled={busyId === row.id}
            onClick={() => void sendNotification(row, false)}
            type="button"
          >
            {row.status.toLowerCase().includes("fail") ? "重试" : "发送"}
          </button>
          <button
            aria-label={`投递历史 ${row.recipient}`}
            className="secondary-button"
            disabled={busyId === `deliveries:${row.id}`}
            onClick={() => void loadDeliveryHistory(row)}
            type="button"
          >
            历史
          </button>
        </div>
      )
    }
  ];

  const deliveryColumns: DataColumn<NotificationDeliveryRecord>[] = [
    {
      key: "attempt",
      title: "尝试",
      render: (row) => `Attempt ${row.attempt}`
    },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge
          tone={
            row.status.toLowerCase().includes("sent")
              ? "green"
              : row.status.toLowerCase().includes("fail")
                ? "red"
                : "blue"
          }
        >
          {row.status}
        </StatusBadge>
      )
    },
    { key: "provider", title: "Provider", render: (row) => row.provider },
    {
      key: "providerMessageId",
      title: "消息 ID",
      render: (row) => row.providerMessageId ?? "-"
    },
    {
      key: "sentAt",
      title: "发送时间",
      render: (row) => row.sentAt ?? row.createdAt
    },
    {
      key: "error",
      title: "错误",
      render: (row) => row.error ?? "-"
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">SMTP</p>
          <h1>通知中心</h1>
          <p>维护品牌邮件模板，创建通知队列，并对客户可见邮件执行人工确认。</p>
        </div>
        <div className="inline-actions">
          <button
            className="secondary-button"
            onClick={() => setCreateOpen(true)}
            type="button"
          >
            创建通知
          </button>
          <button
            className="primary-button"
            disabled={busyId === "preview" || !templateForm.type}
            onClick={() => void previewCurrentTemplate()}
            type="button"
          >
            预览当前模板
          </button>
        </div>
      </div>

      <section className="panel release-guard">
        <strong>发送护栏</strong>
        <span>
          Dry-run 可直接入队；任何客户可见邮件都必须由管理员输入 SEND 确认。
        </span>
        {message ? <span role="status">{message}</span> : null}
      </section>

      <section className="panel release-guard">
        <strong>反馈日报</strong>
        <label className="feedback-search">
          <span>日报收件邮箱</span>
          <input
            aria-label="日报收件邮箱"
            onChange={(event) => setDigestRecipient(event.target.value)}
            placeholder="ops@example.com"
            type="email"
            value={digestRecipient}
          />
        </label>
        <button
          className="secondary-button"
          disabled={busyId === "digest"}
          onClick={() => void createDailyFeedbackDigest()}
          type="button"
        >
          生成反馈日报
        </button>
      </section>

      <section className="panel release-guard">
        <strong>License 到期提醒</strong>
        <span>未来 30 天</span>
        <button
          className="secondary-button"
          disabled={busyId === "license-expiring"}
          onClick={() => void createLicenseExpiringReminders()}
          type="button"
        >
          生成 License 到期提醒
        </button>
      </section>

      <section className="panel release-guard">
        <strong>静默时间</strong>
        <span>{policyForm.quietHoursEnabled ? `${policyForm.quietHoursStart} - ${policyForm.quietHoursEnd}` : "未启用"}</span>
        <label className="checkbox-row">
          <input
            aria-label="启用静默时间"
            checked={policyForm.quietHoursEnabled}
            onChange={(event) =>
              setPolicyForm((current) => ({
                ...current,
                quietHoursEnabled: event.target.checked
              }))
            }
            type="checkbox"
          />
          <span>启用</span>
        </label>
        <label className="feedback-search">
          <span>静默开始</span>
          <input
            aria-label="静默开始"
            onChange={(event) =>
              setPolicyForm((current) => ({
                ...current,
                quietHoursStart: event.target.value
              }))
            }
            type="time"
            value={policyForm.quietHoursStart}
          />
        </label>
        <label className="feedback-search">
          <span>静默结束</span>
          <input
            aria-label="静默结束"
            onChange={(event) =>
              setPolicyForm((current) => ({
                ...current,
                quietHoursEnd: event.target.value
              }))
            }
            type="time"
            value={policyForm.quietHoursEnd}
          />
        </label>
        <label className="feedback-search">
          <span>时区</span>
          <input
            aria-label="静默时区"
            onChange={(event) =>
              setPolicyForm((current) => ({
                ...current,
                quietHoursTimeZone: event.target.value
              }))
            }
            value={policyForm.quietHoursTimeZone}
          />
        </label>
        <button
          className="secondary-button"
          disabled={busyId === "policy"}
          onClick={() => void saveNotificationPolicy()}
          type="button"
        >
          保存静默策略
        </button>
      </section>

      {error ? (
        <p className="form-error" role="alert">
          {error}
        </p>
      ) : null}

      <div className="summary-grid summary-grid-three">
        <section className="panel metric-panel">
          <span>模板</span>
          <strong>{templates.length}</strong>
          <p>支持 HTML 与纯文本版本</p>
        </section>
        <section className="panel metric-panel">
          <span>待发送</span>
          <strong>{queuedCount}</strong>
          <p>队列发送由 Worker 执行</p>
        </section>
        <section className="panel metric-panel">
          <span>邮件服务</span>
          <strong>Feishu SMTP</strong>
          <p>凭据在 Connectors 中配置</p>
        </section>
      </div>

      <div className="content-grid">
        <section className="panel">
          <div className="panel-header">
            <h2>邮件模板</h2>
            <select
              aria-label="选择邮件模板"
              className="select-control"
              onChange={(event) => selectTemplate(event.target.value)}
              value={selectedType}
            >
              {templates.map((template) => (
                <option key={template.id} value={template.type}>
                  {template.type} 模板
                </option>
              ))}
            </select>
          </div>
          <DataTable
            columns={templateColumns}
            rows={templates}
            emptyText="暂无邮件模板"
          />
        </section>

        <form className="panel product-form" onSubmit={(event) => void saveTemplate(event)}>
          <div className="panel-header">
            <h2>模板编辑</h2>
            <StatusBadge tone={templateForm.status === "active" ? "green" : "gray"}>
              {templateForm.status}
            </StatusBadge>
          </div>
          <div className="form-grid">
            <label>
              <span>模板类型</span>
              <input
                aria-label="模板类型"
                onChange={(event) =>
                  setTemplateForm((current) => ({ ...current, type: event.target.value }))
                }
                required
                value={templateForm.type}
              />
            </label>
            <label>
              <span>模板状态</span>
              <select
                aria-label="模板状态"
                onChange={(event) =>
                  setTemplateForm((current) => ({
                    ...current,
                    status: event.target.value as TemplateFormState["status"]
                  }))
                }
                value={templateForm.status}
              >
                <option value="active">Active</option>
                <option value="disabled">Disabled</option>
              </select>
            </label>
            <label className="form-grid-wide">
              <span>邮件主题模板</span>
              <input
                aria-label="邮件主题模板"
                onChange={(event) =>
                  setTemplateForm((current) => ({
                    ...current,
                    subjectTemplate: event.target.value
                  }))
                }
                required
                value={templateForm.subjectTemplate}
              />
            </label>
            <label className="form-grid-wide">
              <span>HTML 模板</span>
              <textarea
                aria-label="HTML 模板"
                onChange={(event) =>
                  setTemplateForm((current) => ({
                    ...current,
                    htmlTemplate: event.target.value
                  }))
                }
                required
                rows={8}
                value={templateForm.htmlTemplate}
              />
            </label>
            <label className="form-grid-wide">
              <span>纯文本模板</span>
              <textarea
                aria-label="纯文本模板"
                onChange={(event) =>
                  setTemplateForm((current) => ({
                    ...current,
                    textTemplate: event.target.value
                  }))
                }
                rows={5}
                value={templateForm.textTemplate}
              />
            </label>
          </div>
          <div className="form-actions">
            <button
              className="primary-button"
              disabled={busyId === "template"}
              type="submit"
            >
              保存邮件模板
            </button>
          </div>
        </form>
      </div>

      {preview.subject || preview.html || preview.text ? (
        <section className="panel">
          <div className="panel-header">
            <h2>模板预览</h2>
            <StatusBadge tone="blue">Rendered</StatusBadge>
          </div>
          <div className="template-preview">
            <strong>{preview.subject}</strong>
            <pre>{preview.text || preview.html}</pre>
          </div>
        </section>
      ) : null}

      {createOpen ? (
        <form className="panel product-form" onSubmit={(event) => void createNotification(event)}>
          <div className="panel-header">
            <h2>创建通知</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>通知类型</span>
              <input
                aria-label="通知类型"
                list="notification-template-types"
                onChange={(event) =>
                  setNotificationForm((current) => ({
                    ...current,
                    type: event.target.value
                  }))
                }
                required
                value={notificationForm.type}
              />
              <datalist id="notification-template-types">
                {templates.map((template) => (
                  <option key={template.id} value={template.type} />
                ))}
              </datalist>
            </label>
            <label>
              <span>收件邮箱</span>
              <input
                aria-label="收件邮箱"
                onChange={(event) =>
                  setNotificationForm((current) => ({
                    ...current,
                    recipient: event.target.value
                  }))
                }
                required
                type="email"
                value={notificationForm.recipient}
              />
            </label>
            <label>
              <span>通知优先级</span>
              <select
                aria-label="通知优先级"
                onChange={(event) =>
                  setNotificationForm((current) => ({
                    ...current,
                    priority: event.target.value as NotificationFormState["priority"]
                  }))
                }
                value={notificationForm.priority}
              >
                <option value="low">Low</option>
                <option value="normal">Normal</option>
                <option value="high">High</option>
                <option value="urgent">Urgent</option>
              </select>
            </label>
            <label className="form-grid-wide">
              <span>通知 Payload JSON</span>
              <textarea
                aria-label="通知 Payload JSON"
                onChange={(event) =>
                  setNotificationForm((current) => ({
                    ...current,
                    payload: event.target.value
                  }))
                }
                required
                rows={8}
                value={notificationForm.payload}
              />
            </label>
          </div>
          <div className="form-actions">
            <button
              className="secondary-button"
              onClick={() => setCreateOpen(false)}
              type="button"
            >
              取消
            </button>
            <button
              className="primary-button"
              disabled={busyId === "create"}
              type="submit"
            >
              加入通知队列
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <div className="panel-header">
          <h2>通知队列</h2>
          <StatusBadge tone="orange">{`${queuedCount} Queued`}</StatusBadge>
        </div>
        <DataTable
          columns={notificationColumns}
          rows={queue}
          emptyText="暂无通知"
        />
      </section>

      {deliveryPanel ? (
        <section className="panel">
          <div className="panel-header">
            <div>
              <h2>投递历史</h2>
              <p className="table-subtext">{deliveryPanel.notification.recipient}</p>
            </div>
            <StatusBadge tone="blue">{`${deliveryPanel.rows.length} Attempts`}</StatusBadge>
          </div>
          <DataTable
            columns={deliveryColumns}
            rows={deliveryPanel.rows}
            emptyText="暂无投递记录"
          />
        </section>
      ) : null}
    </div>
  );
}
