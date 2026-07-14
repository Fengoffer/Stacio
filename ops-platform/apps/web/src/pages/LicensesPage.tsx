import { useEffect, useState, type FormEvent } from "react";
import {
  demoModeEnabled,
  opsClient,
  type BatchLicenseInput,
  type LicenseCreationResult,
  type LicenseDetailRecord,
  type LicenseInput,
  type UpdateLicenseInput
} from "../api/client";
import { licenses } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type LicenseRow = (typeof licenses)[number];

interface LicenseFormState {
  customerName: string;
  customerEmail: string;
  username: string;
  plan: LicenseInput["plan"];
  seats: string;
  maxDevices: string;
  offlineGraceDays: string;
  expiresAt: string;
  entitlements: string;
  status: "active" | "trial";
}

interface BatchLicenseFormState {
  recipients: string;
  plan: BatchLicenseInput["plan"];
  seats: string;
  maxDevices: string;
  offlineGraceDays: string;
  expiresAt: string;
  entitlements: string;
  status: "active" | "trial";
}

interface LicenseEditFormState {
  plan: LicenseInput["plan"];
  seats: string;
  maxDevices: string;
  offlineGraceDays: string;
  expiresAt: string;
  entitlements: string;
}

interface IssuedLicenseEmailContext {
  licenseId: string;
  customerName: string;
  customerEmail: string;
  username?: string;
  plan: LicenseInput["plan"];
  expiresAt: string;
  licenseKey: string;
}

const emptyForm: LicenseFormState = {
  customerName: "",
  customerEmail: "",
  username: "",
  plan: "pro",
  seats: "1",
  maxDevices: "2",
  offlineGraceDays: "14",
  expiresAt: "",
  entitlements: "",
  status: "active"
};

const emptyBatchForm: BatchLicenseFormState = {
  recipients: "",
  plan: "team",
  seats: "1",
  maxDevices: "3",
  offlineGraceDays: "30",
  expiresAt: "",
  entitlements: "",
  status: "active"
};

const licensePlans: LicenseInput["plan"][] = ["free", "pro", "team", "internal"];

function splitList(value: string) {
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function normalizeLicensePlan(value: string): LicenseInput["plan"] {
  const normalized = value.trim().toLowerCase() as LicenseInput["plan"];
  return licensePlans.includes(normalized) ? normalized : "pro";
}

function parseDeviceSummary(value: string) {
  const [devicesPart, maxDevicesPart] = value.split("/");
  const devices = Number(devicesPart?.trim());
  const maxDevices = Number(maxDevicesPart?.trim());
  return {
    seats: Number.isFinite(devices) && devices > 0 ? String(devices) : "1",
    maxDevices: Number.isFinite(maxDevices) && maxDevices > 0 ? String(maxDevices) : "1"
  };
}

function toDateTimeLocal(value: string) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const localDate = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return localDate.toISOString().slice(0, 16);
}

function parseBatchRecipients(value: string): BatchLicenseInput["recipients"] {
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [customerName, customerEmail, username] = line
        .split(",")
        .map((field) => field.trim());
      if (!customerName || !customerEmail) {
        throw new Error("批量客户每行至少需要姓名和邮箱");
      }
      return {
        customerName,
        customerEmail,
        ...(username ? { username } : {})
      };
    });
}

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback;
}

function formatDateTime(value?: string) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(date);
}

function validationVersionLabel(log: LicenseDetailRecord["validationLogs"][number]) {
  const parts = [log.appVersion, log.buildNumber].filter(Boolean);
  return parts.length > 0 ? parts.join(" / ") : "-";
}

function activationIdentity(activation: LicenseDetailRecord["activations"][number]) {
  return activation.anonymousDeviceId ?? activation.machineFingerprintHash ?? "-";
}

function licenseRowFromDetail(detail: LicenseDetailRecord): LicenseRow {
  const maxDevices = detail.license.maxDevices ?? detail.license.seats;
  return {
    id: detail.license.id,
    customer: detail.license.customerName,
    email: detail.license.customerEmail,
    plan: detail.license.plan,
    status: detail.license.status,
    devices: `${detail.license.devices}/${maxDevices}`,
    expires: detail.license.expiresAt
  };
}

export function LicensesPage() {
  const { productId } = useProduct();
  const [rows, setRows] = useState<LicenseRow[]>(demoModeEnabled() ? licenses : []);
  const [formOpen, setFormOpen] = useState(false);
  const [batchOpen, setBatchOpen] = useState(false);
  const [form, setForm] = useState<LicenseFormState>(emptyForm);
  const [batchForm, setBatchForm] = useState<BatchLicenseFormState>(emptyBatchForm);
  const [editingLicense, setEditingLicense] = useState<LicenseRow | null>(null);
  const [editForm, setEditForm] = useState<LicenseEditFormState>({
    plan: "pro",
    seats: "1",
    maxDevices: "1",
    offlineGraceDays: "14",
    expiresAt: "",
    entitlements: ""
  });
  const [actionState, setActionState] = useState("就绪");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [oneTimeKey, setOneTimeKey] = useState("");
  const [batchResults, setBatchResults] = useState<LicenseCreationResult[]>([]);
  const [issuedLicenseEmail, setIssuedLicenseEmail] =
    useState<IssuedLicenseEmailContext | null>(null);
  const [selectedDetail, setSelectedDetail] = useState<LicenseDetailRecord | null>(null);
  const [detailBusyId, setDetailBusyId] = useState<string | null>(null);
  const [detailError, setDetailError] = useState("");

  async function reload() {
    setRows(await opsClient.licenses(productId));
  }

  useEffect(() => {
    let mounted = true;
    setSelectedDetail(null);
    setDetailError("");
    setEditingLicense(null);
    void opsClient
      .licenses(productId)
      .then((items) => {
        if (mounted) setRows(items);
      })
      .catch((nextError: unknown) => {
        if (mounted) setError(errorMessage(nextError, "License 列表加载失败"));
      });
    return () => {
      mounted = false;
    };
  }, [productId]);

  async function createLicense(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId("create");
    setError("");
    setOneTimeKey("");
    setBatchResults([]);
    setIssuedLicenseEmail(null);
    try {
      const expiresAt = new Date(form.expiresAt).toISOString();
      const result = await opsClient.createLicense(productId, {
        customerName: form.customerName.trim(),
        customerEmail: form.customerEmail.trim(),
        username: form.username.trim() || undefined,
        plan: form.plan,
        seats: Number(form.seats),
        maxDevices: Number(form.maxDevices),
        offlineGraceDays: Number(form.offlineGraceDays),
        expiresAt,
        entitlements: splitList(form.entitlements),
        status: form.status
      });
      setOneTimeKey(result.licenseKey);
      setIssuedLicenseEmail({
        licenseId: result.license.id,
        customerName: result.license.customerName,
        customerEmail: result.license.customerEmail,
        username: result.license.username,
        plan: result.license.plan,
        expiresAt: result.license.expiresAt,
        licenseKey: result.licenseKey
      });
      setActionState("License 已创建；完整密钥只会显示这一次");
      setFormOpen(false);
      setForm(emptyForm);
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "License 创建失败"));
    } finally {
      setBusyId(null);
    }
  }

  async function createBatchLicenses(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId("batch-create");
    setError("");
    setOneTimeKey("");
    setIssuedLicenseEmail(null);
    setBatchResults([]);
    try {
      const recipients = parseBatchRecipients(batchForm.recipients);
      if (recipients.length === 0) {
        throw new Error("请至少填写一位批量客户");
      }
      const results = await opsClient.batchCreateLicenses(productId, {
        recipients,
        plan: batchForm.plan,
        seats: Number(batchForm.seats),
        maxDevices: Number(batchForm.maxDevices),
        offlineGraceDays: Number(batchForm.offlineGraceDays),
        expiresAt: new Date(batchForm.expiresAt).toISOString(),
        entitlements: splitList(batchForm.entitlements),
        status: batchForm.status
      });
      setBatchResults(results);
      setActionState(`已批量创建 ${results.length} 张 License；完整密钥只会显示这一次`);
      setBatchOpen(false);
      setBatchForm(emptyBatchForm);
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "批量 License 创建失败"));
      setActionState("批量创建失败");
    } finally {
      setBusyId(null);
    }
  }

  function openLicenseEditor(row: LicenseRow) {
    const deviceSummary = parseDeviceSummary(row.devices);
    setEditingLicense(row);
    setEditForm({
      plan: normalizeLicensePlan(row.plan),
      seats: deviceSummary.seats,
      maxDevices: deviceSummary.maxDevices,
      offlineGraceDays: "14",
      expiresAt: toDateTimeLocal(row.expires),
      entitlements: ""
    });
    setFormOpen(false);
    setBatchOpen(false);
    setOneTimeKey("");
    setBatchResults([]);
    setIssuedLicenseEmail(null);
    setError("");
  }

  async function updateLicenseTerms(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editingLicense) return;
    setBusyId(`edit-${editingLicense.id}`);
    setError("");
    setActionState("正在更新授权条款");
    try {
      const payload: UpdateLicenseInput = {
        plan: editForm.plan,
        seats: Number(editForm.seats),
        maxDevices: Number(editForm.maxDevices),
        offlineGraceDays: Number(editForm.offlineGraceDays),
        expiresAt: new Date(editForm.expiresAt).toISOString(),
        entitlements: splitList(editForm.entitlements)
      };
      await opsClient.updateLicense(editingLicense.id, payload, productId);
      setEditingLicense(null);
      setActionState("授权条款已更新");
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "License 条款更新失败"));
      setActionState("条款更新失败");
    } finally {
      setBusyId(null);
    }
  }

  async function sendLicenseEmail() {
    if (!issuedLicenseEmail) {
      setActionState("没有可发送的 one-time License 邮件上下文");
      return;
    }
    const entered = window.prompt(
      `发送许可证邮件给 ${issuedLicenseEmail.customerEmail}？请输入 SEND 确认。`
    );
    if (entered !== "SEND") {
      setActionState("已取消邮件发送");
      return;
    }
    setBusyId("license-email");
    setError("");
    setActionState("正在排队发送许可证邮件");
    try {
      await opsClient.sendLicenseEmail(
        issuedLicenseEmail.licenseId,
        {
          licenseKey: issuedLicenseEmail.licenseKey,
          confirmation: "SEND"
        },
        productId
      );
      setActionState("许可证邮件已进入发送队列");
    } catch (nextError) {
      setError(errorMessage(nextError, "许可证邮件发送失败"));
      setActionState("邮件发送失败");
    } finally {
      setBusyId(null);
    }
  }

  async function sendBatchLicenseEmails() {
    if (batchResults.length === 0) {
      setActionState("没有可发送的批量 License 邮件上下文");
      return;
    }
    const entered = window.prompt(
      `将向 ${batchResults.length} 位客户发送许可证邮件。请输入 SEND 确认。`
    );
    if (entered !== "SEND") {
      setActionState("已取消批量邮件发送");
      return;
    }
    setBusyId("batch-license-email");
    setError("");
    setActionState("正在排队发送批量许可证邮件");
    try {
      const result = await opsClient.batchSendLicenseEmails(
        productId,
        batchResults.map((item) => ({
          licenseId: item.license.id,
          licenseKey: item.licenseKey
        })),
        "SEND"
      );
      setActionState(`批量许可证邮件已入队：成功 ${result.queuedCount}，跳过 ${result.skippedCount}`);
    } catch (nextError) {
      setError(errorMessage(nextError, "批量许可证邮件发送失败"));
      setActionState("批量邮件发送失败");
    } finally {
      setBusyId(null);
    }
  }

  async function resetActivations(row: LicenseRow) {
    const confirmation = "RESET";
    const entered = window.prompt(
      `重置 ${row.customer} 的设备激活记录？请输入 ${confirmation} 确认。`
    );
    if (entered !== confirmation) {
      setActionState("已取消操作");
      return;
    }
    setBusyId(row.id);
    setError("");
    setActionState("正在重置设备");
    try {
      await opsClient.resetLicenseActivations(row.id, confirmation, productId);
      setActionState("设备激活已重置");
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "设备激活重置失败"));
      setActionState("重置失败");
    } finally {
      setBusyId(null);
    }
  }

  async function updateStatus(
    row: LicenseRow,
    status: "active" | "suspended" | "revoked"
  ) {
    const confirmation =
      status === "suspended" ? "SUSPEND" : status === "revoked" ? "REVOKE" : undefined;
    if (confirmation) {
      const entered = window.prompt(
        `${status === "revoked" ? "撤销" : "暂停"} ${row.customer} 的 License？请输入 ${confirmation} 确认。`
      );
      if (entered !== confirmation) {
        setActionState("已取消操作");
        return;
      }
    }
    setBusyId(row.id);
    setError("");
    setActionState(
      status === "active"
        ? "正在恢复授权"
        : status === "suspended"
          ? "正在暂停授权"
          : "正在撤销授权"
    );
    try {
      await opsClient.updateLicense(
        row.id,
        {
          status,
          ...(confirmation ? { confirmation } : {})
        },
        productId
      );
      setActionState(
        status === "active"
          ? "授权已恢复"
          : status === "suspended"
            ? "授权已暂停"
            : "授权已撤销"
      );
      await reload();
    } catch (nextError) {
      setError(errorMessage(nextError, "License 状态更新失败"));
      setActionState("操作失败");
    } finally {
      setBusyId(null);
    }
  }

  async function openLicenseDetail(row: LicenseRow) {
    setDetailBusyId(row.id);
    setDetailError("");
    setActionState("正在加载 License 详情");
    try {
      const detail = await opsClient.licenseDetail(row.id, productId);
      setSelectedDetail(detail);
      setActionState("License 详情已加载");
    } catch (nextError) {
      setDetailError(errorMessage(nextError, "License 详情加载失败"));
      setActionState("详情加载失败");
    } finally {
      setDetailBusyId(null);
    }
  }

  const columns: DataColumn<LicenseRow>[] = [
    {
      key: "customer",
      title: "客户",
      render: (row) => (
        <div>
          <strong>{row.customer}</strong>
          <p className="table-subtext">{row.email}</p>
        </div>
      )
    },
    { key: "plan", title: "套餐", render: (row) => row.plan },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge
          tone={
            row.status === "Active"
              ? "green"
              : row.status === "Revoked"
                ? "red"
                : "orange"
          }
        >
          {row.status}
        </StatusBadge>
      )
    },
    { key: "devices", title: "设备", render: (row) => row.devices },
    { key: "expires", title: "到期", render: (row) => row.expires },
    {
      key: "actions",
      title: "操作",
      render: (row) => {
        const suspended = row.status.toLowerCase().includes("suspended");
        const revoked = row.status.toLowerCase().includes("revoked");
        return (
          <div className="inline-actions">
            <button
              aria-label={`查看详情 ${row.customer}`}
              className="secondary-button"
              disabled={detailBusyId === row.id}
              onClick={() => void openLicenseDetail(row)}
              type="button"
            >
              详情
            </button>
            <button
              aria-label={`编辑授权 ${row.customer}`}
              className="secondary-button"
              disabled={busyId === `edit-${row.id}` || revoked}
              onClick={() => openLicenseEditor(row)}
              type="button"
            >
              编辑
            </button>
            <button
              aria-label={`重置设备 ${row.customer}`}
              className="secondary-button"
              disabled={busyId === row.id || revoked}
              onClick={() => void resetActivations(row)}
              type="button"
            >
              重置设备
            </button>
            <button
              aria-label={`${suspended ? "恢复" : "暂停"} ${row.customer}`}
              className="secondary-button"
              disabled={busyId === row.id || revoked}
              onClick={() => void updateStatus(row, suspended ? "active" : "suspended")}
              type="button"
            >
              {suspended ? "恢复" : "暂停"}
            </button>
            <button
              aria-label={`撤销 ${row.customer}`}
              className="danger-button"
              disabled={busyId === row.id || revoked}
              onClick={() => void updateStatus(row, "revoked")}
              type="button"
            >
              撤销
            </button>
          </div>
        );
      }
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">License</p>
          <h1>许可证</h1>
          <p>按用户名和邮箱发放授权，管理设备、离线宽限、Entitlements 与授权生命周期。</p>
        </div>
        <div className="inline-actions">
          <button
            className="secondary-button"
            onClick={() => {
              setBatchOpen(true);
              setFormOpen(false);
              setEditingLicense(null);
              setError("");
              setOneTimeKey("");
              setBatchResults([]);
              setIssuedLicenseEmail(null);
            }}
            type="button"
          >
            批量生成
          </button>
          <button
            className="primary-button"
            onClick={() => {
              setFormOpen(true);
              setBatchOpen(false);
              setEditingLicense(null);
              setError("");
              setOneTimeKey("");
              setBatchResults([]);
              setIssuedLicenseEmail(null);
            }}
            type="button"
          >
            生成许可证
          </button>
        </div>
      </div>

        <section className="panel release-guard">
          <strong>授权护栏</strong>
          <span>
            设备指纹只作为激活和风险信号。重置、暂停和撤销必须人工输入确认词，AI 不得直接执行。
            {actionState}
          </span>
        </section>

      {error ? (
        <p className="form-error" role="alert">
          {error}
        </p>
      ) : null}

      {detailError ? (
        <p className="form-error" role="alert">
          {detailError}
        </p>
      ) : null}

      {selectedDetail ? (
        <section className="panel license-detail-panel" role="region" aria-label="License 详情">
          {(() => {
            const detailRow = licenseRowFromDetail(selectedDetail);
            const detailSuspended = detailRow.status.toLowerCase().includes("suspended");
            const detailRevoked = detailRow.status.toLowerCase().includes("revoked");
            return (
              <>
          <div className="panel-header license-detail-heading">
            <div>
              <p className="eyebrow">License Detail</p>
              <h2>License 详情</h2>
              <p>
                {selectedDetail.license.customerName} · {selectedDetail.license.keyPrefix ?? selectedDetail.license.id}
              </p>
            </div>
            <button
              className="secondary-button"
              onClick={() => setSelectedDetail(null)}
              type="button"
            >
              关闭
            </button>
          </div>

          <div className="license-detail-section">
            <h3>客户资料</h3>
            <dl className="detail-list license-detail-summary">
              <div>
                <dt>客户名称</dt>
                <dd>{selectedDetail.customer?.name ?? selectedDetail.license.customerName}</dd>
              </div>
              <div>
                <dt>客户邮箱</dt>
                <dd>{selectedDetail.customer?.email ?? selectedDetail.license.customerEmail}</dd>
              </div>
              <div>
                <dt>客户状态</dt>
                <dd>{selectedDetail.customer?.status ?? "-"}</dd>
              </div>
              <div>
                <dt>风险标记</dt>
                <dd>{selectedDetail.customer?.riskFlag ? "需要关注" : "正常"}</dd>
              </div>
              <div>
                <dt>用户名</dt>
                <dd>{selectedDetail.license.username ?? "-"}</dd>
              </div>
            </dl>
          </div>

          <dl className="detail-list license-detail-summary">
            <div>
              <dt>License ID</dt>
              <dd>{selectedDetail.license.keyPrefix ?? selectedDetail.license.id}</dd>
            </div>
            <div>
              <dt>套餐 / 状态</dt>
              <dd>
                {selectedDetail.license.plan} / {selectedDetail.license.status}
              </dd>
            </div>
            <div>
              <dt>设备</dt>
              <dd>
                {selectedDetail.license.devices}/{selectedDetail.license.maxDevices ?? selectedDetail.license.seats}
              </dd>
            </div>
            <div>
              <dt>到期时间</dt>
              <dd>{formatDateTime(selectedDetail.license.expiresAt)}</dd>
            </div>
            <div>
              <dt>Entitlements</dt>
              <dd>{selectedDetail.license.entitlements?.join(", ") || "-"}</dd>
            </div>
            <div>
              <dt>离线宽限</dt>
              <dd>{selectedDetail.license.offlineGraceDays ?? 14} 天</dd>
            </div>
          </dl>

          <div className="license-detail-section">
            <h3>授权操作</h3>
            <div className="inline-actions">
              <button
                aria-label={`编辑详情授权 ${detailRow.customer}`}
                className="secondary-button"
                disabled={busyId === `edit-${detailRow.id}` || detailRevoked}
                onClick={() => openLicenseEditor(detailRow)}
                type="button"
              >
                编辑授权
              </button>
              <button
                aria-label={`重置详情设备 ${detailRow.customer}`}
                className="secondary-button"
                disabled={busyId === detailRow.id || detailRevoked}
                onClick={() => void resetActivations(detailRow)}
                type="button"
              >
                重置设备
              </button>
              <button
                aria-label={`${detailSuspended ? "恢复" : "暂停"}详情 ${detailRow.customer}`}
                className="secondary-button"
                disabled={busyId === detailRow.id || detailRevoked}
                onClick={() => void updateStatus(detailRow, detailSuspended ? "active" : "suspended")}
                type="button"
              >
                {detailSuspended ? "恢复授权" : "暂停授权"}
              </button>
              <button
                aria-label={`撤销详情 ${detailRow.customer}`}
                className="danger-button"
                disabled={busyId === detailRow.id || detailRevoked}
                onClick={() => void updateStatus(detailRow, "revoked")}
                type="button"
              >
                撤销授权
              </button>
            </div>
          </div>

          <div className="license-detail-section">
            <h3>激活设备</h3>
            {selectedDetail.activations.length > 0 ? (
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>设备标识</th>
                      <th>首次激活</th>
                      <th>最近验证</th>
                      <th>状态</th>
                    </tr>
                  </thead>
                  <tbody>
                    {selectedDetail.activations.map((activation) => (
                      <tr key={activation.id}>
                        <td className="mono-text">{activationIdentity(activation)}</td>
                        <td>{formatDateTime(activation.firstSeenAt)}</td>
                        <td>{formatDateTime(activation.lastSeenAt)}</td>
                        <td>{activation.resetAt ? "已重置" : "有效"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty-state">暂无激活设备</div>
            )}
          </div>

          <div className="license-detail-section">
            <h3>验证历史</h3>
            {selectedDetail.validationLogs.length > 0 ? (
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>结果</th>
                      <th>版本</th>
                      <th>设备</th>
                      <th>原因</th>
                      <th>时间</th>
                    </tr>
                  </thead>
                  <tbody>
                    {selectedDetail.validationLogs.map((log) => (
                      <tr key={log.id}>
                        <td>
                          <StatusBadge tone={log.result === "valid" ? "green" : "red"}>
                            {log.result}
                          </StatusBadge>
                        </td>
                        <td>{validationVersionLabel(log)}</td>
                        <td className="mono-text">{log.anonymousDeviceId ?? log.machineFingerprintHash ?? "-"}</td>
                        <td>{log.reason ?? "-"}</td>
                        <td>{formatDateTime(log.createdAt)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty-state">暂无验证历史</div>
            )}
          </div>

          <div className="license-detail-section">
            <h3>审计记录</h3>
            {selectedDetail.auditLogs.length > 0 ? (
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>动作</th>
                      <th>目标</th>
                      <th>时间</th>
                    </tr>
                  </thead>
                  <tbody>
                    {selectedDetail.auditLogs.map((log) => (
                      <tr key={log.id}>
                        <td>{log.action}</td>
                        <td>{log.targetId ? `${log.targetType} / ${log.targetId}` : log.targetType}</td>
                        <td>{formatDateTime(log.createdAt)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty-state">暂无审计记录</div>
            )}
          </div>
              </>
            );
          })()}
        </section>
      ) : null}

      {oneTimeKey ? (
        <section className="panel one-time-secret" aria-live="polite">
          <div>
            <p className="eyebrow">One-time reveal</p>
            <h2>License Key</h2>
            <p>完整密钥只会完整显示这一次。离开页面或创建下一张 License 后无法再次读取。</p>
          </div>
          <code>{oneTimeKey}</code>
          <button
            className="secondary-button"
            onClick={() => void navigator.clipboard?.writeText(oneTimeKey)}
            type="button"
          >
            复制密钥
          </button>
          <button
            className="secondary-button"
            disabled={!issuedLicenseEmail || busyId === "license-email"}
            onClick={() => void sendLicenseEmail()}
            type="button"
          >
            发送许可证邮件
          </button>
        </section>
      ) : null}

      {batchResults.length > 0 ? (
        <section className="panel one-time-secret" aria-live="polite">
          <div>
            <p className="eyebrow">Batch one-time reveal</p>
            <h2>批量 License Keys</h2>
            <p>这些完整密钥只会完整显示这一次。请在离开页面前完成安全交付。</p>
          </div>
          <div className="secret-list">
            {batchResults.map((item) => (
              <div className="secret-list-row" key={item.license.id}>
                <span>{item.license.customerEmail}</span>
                <code>{item.licenseKey}</code>
              </div>
            ))}
          </div>
          <button
            className="secondary-button"
            disabled={busyId === "batch-license-email"}
            onClick={() => void sendBatchLicenseEmails()}
            type="button"
          >
            发送全部许可证邮件
          </button>
        </section>
      ) : null}

      {editingLicense ? (
        <form
          aria-label="编辑 License 授权"
          className="panel product-form"
          onSubmit={(event) => void updateLicenseTerms(event)}
        >
          <div className="panel-header">
            <div>
              <p className="eyebrow">Commercial Terms</p>
              <h2>编辑授权</h2>
              <p>
                {editingLicense.customer} · {editingLicense.email}
              </p>
            </div>
          </div>
          <div className="form-grid">
            <label>
              <span>授权套餐</span>
              <select
                aria-label="授权套餐"
                onChange={(event) =>
                  setEditForm((current) => ({
                    ...current,
                    plan: event.target.value as LicenseInput["plan"]
                  }))
                }
                value={editForm.plan}
              >
                <option value="free">Free</option>
                <option value="pro">Pro</option>
                <option value="team">Team</option>
                <option value="internal">Internal</option>
              </select>
            </label>
            <label>
              <span>授权席位数</span>
              <input
                aria-label="授权席位数"
                min="1"
                onChange={(event) =>
                  setEditForm((current) => ({ ...current, seats: event.target.value }))
                }
                required
                type="number"
                value={editForm.seats}
              />
            </label>
            <label>
              <span>授权最大设备数</span>
              <input
                aria-label="授权最大设备数"
                min="1"
                onChange={(event) =>
                  setEditForm((current) => ({ ...current, maxDevices: event.target.value }))
                }
                required
                type="number"
                value={editForm.maxDevices}
              />
            </label>
            <label>
              <span>授权离线宽限天数</span>
              <input
                aria-label="授权离线宽限天数"
                max="365"
                min="1"
                onChange={(event) =>
                  setEditForm((current) => ({
                    ...current,
                    offlineGraceDays: event.target.value
                  }))
                }
                required
                type="number"
                value={editForm.offlineGraceDays}
              />
            </label>
            <label>
              <span>授权到期时间</span>
              <input
                aria-label="授权到期时间"
                onChange={(event) =>
                  setEditForm((current) => ({ ...current, expiresAt: event.target.value }))
                }
                required
                type="datetime-local"
                value={editForm.expiresAt}
              />
            </label>
            <label className="form-grid-wide">
              <span>授权 Entitlements</span>
              <input
                aria-label="授权 Entitlements"
                onChange={(event) =>
                  setEditForm((current) => ({ ...current, entitlements: event.target.value }))
                }
                placeholder="internal_features, beta_channel"
                value={editForm.entitlements}
              />
            </label>
          </div>
          <div className="form-actions">
            <button
              className="secondary-button"
              onClick={() => setEditingLicense(null)}
              type="button"
            >
              取消
            </button>
            <button
              className="primary-button"
              disabled={busyId === `edit-${editingLicense.id}`}
              type="submit"
            >
              保存授权变更
            </button>
          </div>
        </form>
      ) : null}

      {formOpen ? (
        <form className="panel product-form" onSubmit={(event) => void createLicense(event)}>
          <div className="panel-header">
            <div>
              <p className="eyebrow">Issue License</p>
              <h2>生成许可证</h2>
            </div>
          </div>
          <div className="form-grid">
            <label>
              <span>客户名称</span>
              <input
                aria-label="客户名称"
                onChange={(event) =>
                  setForm((current) => ({ ...current, customerName: event.target.value }))
                }
                required
                value={form.customerName}
              />
            </label>
            <label>
              <span>客户邮箱</span>
              <input
                aria-label="客户邮箱"
                onChange={(event) =>
                  setForm((current) => ({ ...current, customerEmail: event.target.value }))
                }
                required
                type="email"
                value={form.customerEmail}
              />
            </label>
            <label>
              <span>用户名</span>
              <input
                aria-label="用户名"
                onChange={(event) =>
                  setForm((current) => ({ ...current, username: event.target.value }))
                }
                value={form.username}
              />
            </label>
            <label>
              <span>套餐</span>
              <select
                aria-label="套餐"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    plan: event.target.value as LicenseInput["plan"]
                  }))
                }
                value={form.plan}
              >
                <option value="free">Free</option>
                <option value="pro">Pro</option>
                <option value="team">Team</option>
                <option value="internal">Internal</option>
              </select>
            </label>
            <label>
              <span>席位数</span>
              <input
                aria-label="席位数"
                min="1"
                onChange={(event) =>
                  setForm((current) => ({ ...current, seats: event.target.value }))
                }
                required
                type="number"
                value={form.seats}
              />
            </label>
            <label>
              <span>最大设备数</span>
              <input
                aria-label="最大设备数"
                min="1"
                onChange={(event) =>
                  setForm((current) => ({ ...current, maxDevices: event.target.value }))
                }
                required
                type="number"
                value={form.maxDevices}
              />
            </label>
            <label>
              <span>离线宽限天数</span>
              <input
                aria-label="离线宽限天数"
                max="365"
                min="1"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    offlineGraceDays: event.target.value
                  }))
                }
                required
                type="number"
                value={form.offlineGraceDays}
              />
            </label>
            <label>
              <span>到期时间</span>
              <input
                aria-label="到期时间"
                onChange={(event) =>
                  setForm((current) => ({ ...current, expiresAt: event.target.value }))
                }
                required
                type="datetime-local"
                value={form.expiresAt}
              />
            </label>
            <label>
              <span>初始状态</span>
              <select
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    status: event.target.value as LicenseFormState["status"]
                  }))
                }
                value={form.status}
              >
                <option value="active">Active</option>
                <option value="trial">Trial</option>
              </select>
            </label>
            <label className="form-grid-wide">
              <span>Entitlements</span>
              <input
                aria-label="Entitlements"
                onChange={(event) =>
                  setForm((current) => ({ ...current, entitlements: event.target.value }))
                }
                placeholder="pro_features, beta_channel"
                value={form.entitlements}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setFormOpen(false)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busyId === "create"} type="submit">
              创建并生成密钥
            </button>
          </div>
        </form>
      ) : null}

      {batchOpen ? (
        <form className="panel product-form" onSubmit={(event) => void createBatchLicenses(event)}>
          <div className="panel-header">
            <div>
              <p className="eyebrow">Batch Issue</p>
              <h2>批量生成许可证</h2>
            </div>
          </div>
          <div className="form-grid">
            <label className="form-grid-wide">
              <span>批量客户</span>
              <textarea
                aria-label="批量客户"
                onChange={(event) =>
                  setBatchForm((current) => ({ ...current, recipients: event.target.value }))
                }
                placeholder="Team One,team-one@example.com,team-one"
                required
                rows={6}
                value={batchForm.recipients}
              />
            </label>
            <label>
              <span>批量套餐</span>
              <select
                aria-label="批量套餐"
                onChange={(event) =>
                  setBatchForm((current) => ({
                    ...current,
                    plan: event.target.value as BatchLicenseInput["plan"]
                  }))
                }
                value={batchForm.plan}
              >
                <option value="free">Free</option>
                <option value="pro">Pro</option>
                <option value="team">Team</option>
                <option value="internal">Internal</option>
              </select>
            </label>
            <label>
              <span>批量席位数</span>
              <input
                aria-label="批量席位数"
                min="1"
                onChange={(event) =>
                  setBatchForm((current) => ({ ...current, seats: event.target.value }))
                }
                required
                type="number"
                value={batchForm.seats}
              />
            </label>
            <label>
              <span>批量最大设备数</span>
              <input
                aria-label="批量最大设备数"
                min="1"
                onChange={(event) =>
                  setBatchForm((current) => ({ ...current, maxDevices: event.target.value }))
                }
                required
                type="number"
                value={batchForm.maxDevices}
              />
            </label>
            <label>
              <span>批量离线宽限天数</span>
              <input
                aria-label="批量离线宽限天数"
                max="365"
                min="1"
                onChange={(event) =>
                  setBatchForm((current) => ({
                    ...current,
                    offlineGraceDays: event.target.value
                  }))
                }
                required
                type="number"
                value={batchForm.offlineGraceDays}
              />
            </label>
            <label>
              <span>批量到期时间</span>
              <input
                aria-label="批量到期时间"
                onChange={(event) =>
                  setBatchForm((current) => ({ ...current, expiresAt: event.target.value }))
                }
                required
                type="datetime-local"
                value={batchForm.expiresAt}
              />
            </label>
            <label>
              <span>批量初始状态</span>
              <select
                onChange={(event) =>
                  setBatchForm((current) => ({
                    ...current,
                    status: event.target.value as BatchLicenseFormState["status"]
                  }))
                }
                value={batchForm.status}
              >
                <option value="active">Active</option>
                <option value="trial">Trial</option>
              </select>
            </label>
            <label className="form-grid-wide">
              <span>批量 Entitlements</span>
              <input
                aria-label="批量 Entitlements"
                onChange={(event) =>
                  setBatchForm((current) => ({ ...current, entitlements: event.target.value }))
                }
                placeholder="team_features, beta_channel"
                value={batchForm.entitlements}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setBatchOpen(false)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busyId === "batch-create"} type="submit">
              批量创建许可证
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <DataTable columns={columns} rows={rows} emptyText="暂无许可证" />
      </section>
    </div>
  );
}
