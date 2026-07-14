import { useEffect, useState, type FormEvent } from "react";
import {
  opsClient,
  type ChannelHistoryRecord,
  type ReleaseChannelInput,
  type ReleaseChannelRecord,
  type ReleaseChannelUpdateInput
} from "../api/client";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProductSelection } from "../product/ProductContext";

interface ChannelFormState {
  name: string;
  appcastUrl: string;
  currentReleaseId: string;
  allowedPlanIds: string;
  minimumUpgradableVersion: string;
  rolloutPercentage: string;
  autoDownloadAllowed: boolean;
  forceUpdatePrompt: boolean;
  status: "active" | "paused";
}

const emptyForm: ChannelFormState = {
  name: "",
  appcastUrl: "",
  currentReleaseId: "",
  allowedPlanIds: "",
  minimumUpgradableVersion: "",
  rolloutPercentage: "100",
  autoDownloadAllowed: false,
  forceUpdatePrompt: false,
  status: "active"
};

function splitList(value: string) {
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function formFromChannel(channel: ReleaseChannelRecord): ChannelFormState {
  return {
    name: channel.name,
    appcastUrl: channel.appcastUrl ?? "",
    currentReleaseId: channel.currentReleaseId ?? "",
    allowedPlanIds: channel.allowedPlanIds.join(", "),
    minimumUpgradableVersion: channel.minimumUpgradableVersion ?? "",
    rolloutPercentage: String(channel.rolloutPercentage),
    autoDownloadAllowed: channel.autoDownloadAllowed,
    forceUpdatePrompt: channel.forceUpdatePrompt,
    status: channel.status === "paused" ? "paused" : "active"
  };
}

function formatHistoryValue(value?: Record<string, unknown>) {
  if (!value) return "-";
  return Object.entries(value)
    .map(([key, item]) => `${key}: ${Array.isArray(item) ? item.join(", ") : String(item ?? "-")}`)
    .join(" · ");
}

export function ChannelsPage() {
  const { products, productId, setProductId } = useProductSelection();
  const [rows, setRows] = useState<ReleaseChannelRecord[]>([]);
  const [formMode, setFormMode] = useState<"create" | "edit" | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<ChannelFormState>(emptyForm);
  const [historyChannel, setHistoryChannel] = useState<ReleaseChannelRecord | null>(null);
  const [history, setHistory] = useState<ChannelHistoryRecord[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    setFormMode(null);
    setEditingId(null);
    setHistoryChannel(null);
    setHistory([]);
    setMessage("");
  }, [productId]);

  useEffect(() => {
    let mounted = true;
    setError("");
    void opsClient
      .channels(productId)
      .then((items) => {
        if (mounted) setRows(items);
      })
      .catch((nextError: unknown) => {
        if (mounted) setError(nextError instanceof Error ? nextError.message : "通道加载失败");
      });
    return () => {
      mounted = false;
    };
  }, [productId]);

  function replaceChannel(channel: ReleaseChannelRecord) {
    setRows((current) => [
      ...current.filter((candidate) => candidate.id !== channel.id),
      channel
    ].sort((left, right) => left.name.localeCompare(right.name)));
    if (historyChannel?.id === channel.id) {
      setHistoryChannel(channel);
    }
  }

  function startCreate() {
    setFormMode("create");
    setEditingId(null);
    setForm(emptyForm);
    setError("");
    setMessage("");
  }

  function startEdit(channel: ReleaseChannelRecord) {
    setFormMode("edit");
    setEditingId(channel.id);
    setForm(formFromChannel(channel));
    setError("");
    setMessage("");
  }

  function payloadFromForm(): ReleaseChannelInput {
    return {
      name: form.name.trim(),
      appcastUrl: form.appcastUrl.trim() || undefined,
      currentReleaseId: form.currentReleaseId.trim() || undefined,
      allowedPlanIds: splitList(form.allowedPlanIds),
      minimumUpgradableVersion: form.minimumUpgradableVersion.trim() || undefined,
      rolloutPercentage: Number(form.rolloutPercentage),
      autoDownloadAllowed: form.autoDownloadAllowed,
      forceUpdatePrompt: form.forceUpdatePrompt,
      status: form.status
    };
  }

  async function saveChannel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId(editingId ?? "create");
    setError("");
    setMessage("");
    try {
      const payload = payloadFromForm();
      const channel =
        formMode === "edit" && editingId
          ? await opsClient.updateChannel(
              productId,
              editingId,
              payload as ReleaseChannelUpdateInput
            )
          : await opsClient.createChannel(productId, payload);
      replaceChannel(channel);
      setFormMode(null);
      setEditingId(null);
      setMessage(formMode === "edit" ? "通道已更新。" : "通道已创建。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "通道保存失败");
    } finally {
      setBusyId(null);
    }
  }

  async function togglePause(channel: ReleaseChannelRecord) {
    const pause = channel.status !== "paused";
    const confirmation = pause ? "PAUSE" : "RESUME";
    const verb = pause ? "暂停" : "恢复";
    if (
      window.prompt(`请输入 ${confirmation}，${verb}通道 ${channel.name}。`) !==
      confirmation
    ) {
      return;
    }
    setBusyId(channel.id);
    setError("");
    try {
      replaceChannel(
        await opsClient.updateChannel(productId, channel.id, {
          status: pause ? "paused" : "active",
          confirmation
        })
      );
      setMessage(`${channel.name} 已${verb}。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : `通道${verb}失败`);
    } finally {
      setBusyId(null);
    }
  }

  async function showHistory(channel: ReleaseChannelRecord) {
    setBusyId(channel.id);
    setError("");
    try {
      setHistory(await opsClient.channelHistory(productId, channel.id));
      setHistoryChannel(channel);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "通道历史加载失败");
    } finally {
      setBusyId(null);
    }
  }

  async function rollback(entry: ChannelHistoryRecord) {
    if (!historyChannel) return;
    if (
      window.prompt(
        `请输入 ROLLBACK，将通道 ${historyChannel.name} 回滚到所选历史记录。`
      ) !== "ROLLBACK"
    ) {
      return;
    }
    setBusyId(historyChannel.id);
    setError("");
    try {
      replaceChannel(
        await opsClient.rollbackChannel(productId, historyChannel.id, entry.id)
      );
      setHistory(await opsClient.channelHistory(productId, historyChannel.id));
      setMessage(`${historyChannel.name} 已回滚。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "通道回滚失败");
    } finally {
      setBusyId(null);
    }
  }

  const columns: DataColumn<ReleaseChannelRecord>[] = [
    { key: "name", title: "通道", render: (row) => <strong>{row.name}</strong> },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge tone={row.status === "active" ? "green" : row.status === "paused" ? "orange" : "gray"}>
          {row.status}
        </StatusBadge>
      )
    },
    {
      key: "rollout",
      title: "Rollout",
      render: (row) => `${row.rolloutPercentage}%`
    },
    {
      key: "appcast",
      title: "Appcast",
      render: (row) => <span className="mono-text">{row.appcastUrl ?? "-"}</span>
    },
    {
      key: "currentRelease",
      title: "当前版本",
      render: (row) => <span className="mono-text">{row.currentReleaseId ?? "-"}</span>
    },
    {
      key: "policies",
      title: "策略",
      render: (row) =>
        `${row.autoDownloadAllowed ? "自动下载" : "手动下载"} / ${
          row.forceUpdatePrompt ? "强提示" : "普通提示"
        }`
    },
    {
      key: "plans",
      title: "套餐",
      render: (row) => row.allowedPlanIds.join(", ") || "全部"
    },
    {
      key: "actions",
      title: "操作",
      render: (row) => (
        <div className="inline-actions">
          <button
            aria-label={`编辑 ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id || row.status === "archived"}
            onClick={() => startEdit(row)}
            type="button"
          >
            编辑
          </button>
          <button
            aria-label={`${row.status === "paused" ? "恢复" : "暂停"} ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id || row.status === "archived"}
            onClick={() => void togglePause(row)}
            type="button"
          >
            {row.status === "paused" ? "恢复" : "暂停"}
          </button>
          <button
            aria-label={`历史 ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id}
            onClick={() => void showHistory(row)}
            type="button"
          >
            历史
          </button>
        </div>
      )
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Channels</p>
          <h1>分发渠道</h1>
          <p>管理 Appcast、灰度百分比、允许套餐、当前版本和更新提示策略。</p>
        </div>
        <button className="secondary-button" onClick={startCreate} type="button">
          新建通道
        </button>
      </div>

      <div className="configuration-toolbar">
        {products.length > 0 ? (
          <label className="product-switcher">
            <span>当前产品</span>
            <select
              aria-label="当前产品"
              onChange={(event) => {
                setProductId(event.target.value);
                setFormMode(null);
                setHistoryChannel(null);
              }}
              value={productId}
            >
              {products.map((product) => (
                <option key={product.id} value={product.id}>
                  {product.name} ({product.id})
                </option>
              ))}
            </select>
          </label>
        ) : null}
      </div>

      <section className="panel release-guard">
        <strong>发布护栏</strong>
        <span>Agent 只能提出建议；通道切换、灰度变更和 OTA 发布均由管理员确认。</span>
      </section>

      {error ? <p className="form-error">{error}</p> : null}
      {message ? <p className="action-message">{message}</p> : null}

      {formMode ? (
        <form className="panel product-form" onSubmit={(event) => void saveChannel(event)}>
          <div className="panel-header">
            <h2>{formMode === "create" ? "新建通道" : `编辑 ${form.name}`}</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>通道名称</span>
              <input
                aria-label="通道名称"
                onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))}
                pattern="[a-z0-9][a-z0-9_-]{1,63}"
                required
                value={form.name}
              />
            </label>
            <label>
              <span>Appcast URL</span>
              <input
                aria-label="Appcast URL"
                onChange={(event) => setForm((current) => ({ ...current, appcastUrl: event.target.value }))}
                placeholder="https://updates.example.com/appcast.xml"
                type="url"
                value={form.appcastUrl}
              />
            </label>
            <label>
              <span>灰度百分比</span>
              <input
                aria-label="灰度百分比"
                max="100"
                min="0"
                onChange={(event) =>
                  setForm((current) => ({ ...current, rolloutPercentage: event.target.value }))
                }
                required
                type="number"
                value={form.rolloutPercentage}
              />
            </label>
            <label>
              <span>当前 Release ID</span>
              <input
                onChange={(event) =>
                  setForm((current) => ({ ...current, currentReleaseId: event.target.value }))
                }
                value={form.currentReleaseId}
              />
            </label>
            <label>
              <span>允许套餐 ID</span>
              <input
                aria-label="允许套餐 ID"
                onChange={(event) =>
                  setForm((current) => ({ ...current, allowedPlanIds: event.target.value }))
                }
                placeholder="plan_free, plan_pro"
                value={form.allowedPlanIds}
              />
            </label>
            <label>
              <span>最低可升级版本</span>
              <input
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    minimumUpgradableVersion: event.target.value
                  }))
                }
                value={form.minimumUpgradableVersion}
              />
            </label>
            <label className="checkbox-field">
              <input
                checked={form.autoDownloadAllowed}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    autoDownloadAllowed: event.target.checked
                  }))
                }
                type="checkbox"
              />
              <span>允许自动下载</span>
            </label>
            <label className="checkbox-field">
              <input
                checked={form.forceUpdatePrompt}
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    forceUpdatePrompt: event.target.checked
                  }))
                }
                type="checkbox"
              />
              <span>强制更新提示</span>
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setFormMode(null)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busyId !== null} type="submit">
              保存通道
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <DataTable columns={columns} rows={rows} emptyText="暂无分发渠道" />
      </section>

      {historyChannel ? (
        <section className="panel channel-history-panel">
          <div className="panel-header">
            <div>
              <h2>{historyChannel.name} 历史</h2>
              <p>回滚会恢复所选记录的变更前状态，并产生新的审计事件。</p>
            </div>
            <button
              className="secondary-button"
              onClick={() => {
                setHistoryChannel(null);
                setHistory([]);
              }}
              type="button"
            >
              关闭
            </button>
          </div>
          {history.length === 0 ? (
            <div className="empty-state">暂无历史记录</div>
          ) : (
            <div className="channel-history-list">
              {history.map((entry) => (
                <article className="channel-history-item" key={entry.id}>
                  <div>
                    <strong>{entry.action}</strong>
                    <p className="table-subtext">{new Date(entry.createdAt).toLocaleString("zh-CN")}</p>
                    <p className="table-subtext">变更前：{formatHistoryValue(entry.beforeValue)}</p>
                    <p className="table-subtext">变更后：{formatHistoryValue(entry.afterValue)}</p>
                  </div>
                  {entry.beforeValue ? (
                    <button
                      aria-label={`回滚 ${entry.id}`}
                      className="secondary-button"
                      disabled={busyId === historyChannel.id}
                      onClick={() => void rollback(entry)}
                      type="button"
                    >
                      回滚
                    </button>
                  ) : null}
                </article>
              ))}
            </div>
          )}
        </section>
      ) : null}
    </div>
  );
}
