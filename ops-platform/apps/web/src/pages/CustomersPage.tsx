import { useEffect, useMemo, useState, type FormEvent } from "react";
import {
  opsClient,
  type CustomerDetailRecord,
  type CustomerInput,
  type CustomerRecord,
  type LicenseInput,
  type NotificationInput,
  type NotificationRecord
} from "../api/client";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProductSelection } from "../product/ProductContext";

interface CustomerFormState {
  email: string;
  name: string;
  company: string;
  status: string;
}

interface CustomerLicenseFormState {
  plan: LicenseInput["plan"];
  seats: string;
  maxDevices: string;
  offlineGraceDays: string;
  expiresAt: string;
  entitlements: string;
  status: "active" | "trial";
}

interface CustomerEmailFormState {
  type: string;
  priority: NonNullable<NotificationInput["priority"]>;
  payload: string;
}

const emptyForm: CustomerFormState = {
  email: "",
  name: "",
  company: "",
  status: "active"
};

const emptyLicenseForm: CustomerLicenseFormState = {
  plan: "pro",
  seats: "1",
  maxDevices: "2",
  offlineGraceDays: "14",
  expiresAt: "",
  entitlements: "pro_features",
  status: "active"
};

const emptyEmailForm: CustomerEmailFormState = {
  type: "customer_feedback_reply",
  priority: "normal",
  payload: "{}"
};

function splitList(value: string) {
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function toneForStatus(status: string) {
  if (status === "active") return "green";
  if (status === "blocked") return "red";
  if (status === "merged" || status === "archived") return "gray";
  return "orange";
}

function formatDate(value?: string) {
  if (!value) return "-";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).format(new Date(value));
}

export function CustomersPage() {
  const { products, productId, setProductId } = useProductSelection();
  const [customers, setCustomers] = useState<CustomerRecord[]>([]);
  const [formMode, setFormMode] = useState<"create" | "edit" | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<CustomerFormState>(emptyForm);
  const [detail, setDetail] = useState<CustomerDetailRecord | null>(null);
  const [noteBody, setNoteBody] = useState("");
  const [licenseFormOpen, setLicenseFormOpen] = useState(false);
  const [licenseForm, setLicenseForm] = useState<CustomerLicenseFormState>(emptyLicenseForm);
  const [customerLicenseKey, setCustomerLicenseKey] = useState("");
  const [emailFormOpen, setEmailFormOpen] = useState(false);
  const [emailForm, setEmailForm] = useState<CustomerEmailFormState>(emptyEmailForm);
  const [customerEmailNotification, setCustomerEmailNotification] =
    useState<NotificationRecord | null>(null);
  const [mergeTargetId, setMergeTargetId] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const activeCustomers = useMemo(
    () => customers.filter((customer) => customer.status !== "merged"),
    [customers]
  );

  async function loadCustomers(nextProductId = productId) {
    const items = await opsClient.customers(nextProductId);
    setCustomers(items);
    if (
      mergeTargetId &&
      !items.some((customer) => customer.id === mergeTargetId && customer.status !== "merged")
    ) {
      setMergeTargetId("");
    }
  }

  useEffect(() => {
    setDetail(null);
    setFormMode(null);
    setEditingId(null);
    setMergeTargetId("");
    setNoteBody("");
    setLicenseFormOpen(false);
    setLicenseForm(emptyLicenseForm);
    setCustomerLicenseKey("");
    setEmailFormOpen(false);
    setEmailForm(emptyEmailForm);
    setCustomerEmailNotification(null);
    setMessage("");
  }, [productId]);

  useEffect(() => {
    let mounted = true;
    setError("");
    void opsClient.customers(productId).then((items) => {
      if (mounted) setCustomers(items);
    }).catch((nextError: unknown) => {
      if (mounted) setError(nextError instanceof Error ? nextError.message : "客户加载失败");
    });
    return () => {
      mounted = false;
    };
  }, [productId]);

  function startCreate() {
    setFormMode("create");
    setEditingId(null);
    setForm(emptyForm);
    setError("");
    setMessage("");
  }

  function startEdit(customer: CustomerRecord) {
    setFormMode("edit");
    setEditingId(customer.id);
    setForm({
      email: customer.email,
      name: customer.name,
      company: customer.company ?? "",
      status: customer.status
    });
    setError("");
    setMessage("");
  }

  function replaceCustomer(next: CustomerRecord) {
    setCustomers((current) => [
      ...current.filter((customer) => customer.id !== next.id),
      next
    ]);
    if (detail?.customer.id === next.id) {
      setDetail((current) => current ? { ...current, customer: next } : current);
    }
  }

  async function saveCustomer(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId(editingId ?? "create");
    setError("");
    setMessage("");
    const input: CustomerInput = {
      email: form.email.trim(),
      name: form.name.trim(),
      company: form.company.trim() || undefined,
      status: form.status
    };
    try {
      const customer = formMode === "edit" && editingId
        ? await opsClient.updateCustomer(productId, editingId, input)
        : await opsClient.createCustomer(productId, input);
      replaceCustomer(customer);
      setFormMode(null);
      setEditingId(null);
      setMessage(formMode === "edit" ? "客户资料已更新。" : "客户已创建。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户保存失败");
    } finally {
      setBusyId(null);
    }
  }

  async function toggleRisk(customer: CustomerRecord) {
    setBusyId(customer.id);
    setError("");
    try {
      const updated = await opsClient.updateCustomer(productId, customer.id, {
        riskFlag: !customer.riskFlag
      });
      replaceCustomer(updated);
      setMessage(updated.riskFlag ? "客户已标记为风险。" : "客户风险标记已取消。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "风险状态更新失败");
    } finally {
      setBusyId(null);
    }
  }

  async function showDetail(customer: CustomerRecord) {
    setBusyId(customer.id);
    setError("");
    try {
      setDetail(await opsClient.customerDetail(productId, customer.id));
      setNoteBody("");
      setLicenseFormOpen(false);
      setLicenseForm(emptyLicenseForm);
      setCustomerLicenseKey("");
      setEmailFormOpen(false);
      setEmailForm(emptyEmailForm);
      setCustomerEmailNotification(null);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户详情加载失败");
    } finally {
      setBusyId(null);
    }
  }

  async function addNote() {
    if (!detail || !noteBody.trim()) return;
    setBusyId(detail.customer.id);
    setError("");
    try {
      const note = await opsClient.addCustomerNote(
        productId,
        detail.customer.id,
        noteBody.trim()
      );
      setDetail((current) => current ? { ...current, notes: [note, ...current.notes] } : current);
      setNoteBody("");
      setMessage("内部备注已添加。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "备注添加失败");
    } finally {
      setBusyId(null);
    }
  }

  async function mergeCustomer(source: CustomerRecord) {
    if (!mergeTargetId || mergeTargetId === source.id) {
      setError("请选择其他客户作为合并目标。");
      return;
    }
    const confirmation = window.prompt(
      `请输入 MERGE，将 ${source.name} 合并到所选客户。此操作会迁移关联记录。`
    );
    if (confirmation !== "MERGE") return;
    setBusyId(source.id);
    setError("");
    try {
      const result = await opsClient.mergeCustomer(
        productId,
        source.id,
        mergeTargetId
      );
      setCustomers((current) =>
        current.map((customer) => {
          if (customer.id === result.source.id) return result.source;
          if (customer.id === result.target.id) return result.target;
          return customer;
        })
      );
      if (detail?.customer.id === source.id) {
        setDetail(await opsClient.customerDetail(productId, result.target.id));
      }
      setMessage(`${source.name} 已合并到 ${result.target.name}。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户合并失败");
    } finally {
      setBusyId(null);
    }
  }

  async function issueCustomerLicense(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!detail) return;
    setBusyId(detail.customer.id);
    setError("");
    setMessage("");
    setCustomerLicenseKey("");
    try {
      const result = await opsClient.createLicense(productId, {
        customerName: detail.customer.name,
        customerEmail: detail.customer.email,
        username: detail.customer.name,
        plan: licenseForm.plan,
        seats: Number(licenseForm.seats),
        maxDevices: Number(licenseForm.maxDevices),
        offlineGraceDays: Number(licenseForm.offlineGraceDays),
        expiresAt: new Date(licenseForm.expiresAt).toISOString(),
        entitlements: splitList(licenseForm.entitlements),
        status: licenseForm.status
      });
      setDetail((current) =>
        current
          ? {
              ...current,
              licenses: [
                {
                  id: result.license.id,
                  plan: result.license.plan,
                  status: result.license.status,
                  devices: result.license.devices,
                  expiresAt: result.license.expiresAt
                },
                ...current.licenses
              ]
            }
          : current
      );
      setCustomerLicenseKey(result.licenseKey);
      setLicenseFormOpen(false);
      setLicenseForm(emptyLicenseForm);
      setMessage("客户 License 已创建；完整密钥只会显示这一次。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户 License 创建失败");
    } finally {
      setBusyId(null);
    }
  }

  async function sendCustomerEmail(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!detail) return;
    setBusyId(detail.customer.id);
    setError("");
    setMessage("");
    setCustomerEmailNotification(null);
    try {
      let payload: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(emailForm.payload);
        if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
          throw new Error("Payload 必须是 JSON 对象");
        }
        payload = parsed as Record<string, unknown>;
      } catch (parseError) {
        throw new Error(parseError instanceof Error ? parseError.message : "Payload JSON 无效");
      }

      const notification = await opsClient.createNotification(productId, {
        type: emailForm.type.trim(),
        recipient: detail.customer.email,
        priority: emailForm.priority,
        status: "queued",
        payload: {
          customer: {
            id: detail.customer.id,
            name: detail.customer.name,
            email: detail.customer.email
          },
          ...payload
        }
      });
      setCustomerEmailNotification(notification);
      setDetail((current) =>
        current
          ? {
              ...current,
              notifications: [
                {
                  id: notification.id,
                  type: notification.type,
                  status: notification.status,
                  createdAt: notification.createdAt,
                  deliveries: []
                },
                ...current.notifications
              ]
            }
          : current
      );

      const confirmation = window.prompt(
        `将向 ${detail.customer.email} 发送客户可见邮件。请输入 SEND 确认。`
      );
      if (confirmation !== "SEND") {
        setMessage("客户邮件已创建，真实发送已取消。");
        return;
      }
      await opsClient.sendNotification(notification.id, false, "queue", productId);
      setMessage("客户邮件发送任务已入队。");
      setEmailFormOpen(false);
      setEmailForm(emptyEmailForm);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "客户邮件创建或发送失败");
    } finally {
      setBusyId(null);
    }
  }

  const columns: DataColumn<CustomerRecord>[] = [
    {
      key: "name",
      title: "客户",
      render: (row) => (
        <div>
          <strong>{row.name}</strong>
          <p className="table-subtext">{row.email}</p>
          {row.mergedIntoId ? <p className="table-subtext">已合并至 {row.mergedIntoId}</p> : null}
        </div>
      )
    },
    { key: "company", title: "公司", render: (row) => row.company ?? "-" },
    {
      key: "status",
      title: "状态",
      render: (row) => <StatusBadge tone={toneForStatus(row.status)}>{row.status}</StatusBadge>
    },
    {
      key: "risk",
      title: "风险",
      render: (row) => <StatusBadge tone={row.riskFlag ? "red" : "green"}>{row.riskFlag ? "Risk" : "Normal"}</StatusBadge>
    },
    { key: "createdAt", title: "创建", render: (row) => formatDate(row.createdAt) },
    {
      key: "actions",
      title: "操作",
      render: (row) => (
        <div className="inline-actions customer-row-actions">
          <button
            aria-label={`查看 ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id}
            onClick={() => void showDetail(row)}
            type="button"
          >
            查看
          </button>
          <button
            aria-label={`编辑 ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id || row.status === "merged"}
            onClick={() => startEdit(row)}
            type="button"
          >
            编辑
          </button>
          <button
            aria-label={`${row.riskFlag ? "取消风险" : "标记风险"} ${row.name}`}
            className="secondary-button"
            disabled={busyId === row.id || row.status === "merged"}
            onClick={() => void toggleRisk(row)}
            type="button"
          >
            {row.riskFlag ? "取消风险" : "标记风险"}
          </button>
          <button
            aria-label={`合并 ${row.name}`}
            className="danger-button"
            disabled={busyId === row.id || row.status === "merged" || !mergeTargetId || mergeTargetId === row.id}
            onClick={() => void mergeCustomer(row)}
            type="button"
          >
            合并
          </button>
        </div>
      )
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Customers</p>
          <h1>客户管理</h1>
          <p>统一查看客户资料、授权、设备、反馈、邮件与审计历史。</p>
        </div>
        <button className="primary-button" onClick={startCreate} type="button">
          新建客户
        </button>
      </div>

      <div className="customer-toolbar">
        {products.length > 0 ? (
          <label className="product-switcher">
            <span>当前产品</span>
            <select
              aria-label="当前产品"
              onChange={(event) => {
                setProductId(event.target.value);
                setDetail(null);
                setFormMode(null);
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
        <label className="customer-merge-target">
          <span>合并到客户</span>
          <select
            aria-label="合并到客户"
            onChange={(event) => setMergeTargetId(event.target.value)}
            value={mergeTargetId}
          >
            <option value="">请选择目标客户</option>
            {activeCustomers.map((customer) => (
              <option key={customer.id} value={customer.id}>
                {customer.name} ({customer.email})
              </option>
            ))}
          </select>
        </label>
      </div>

      {error ? <p className="form-error">{error}</p> : null}
      {message ? <p className="action-message">{message}</p> : null}

      {formMode ? (
        <form className="panel product-form" onSubmit={(event) => void saveCustomer(event)}>
          <div className="panel-header">
            <h2>{formMode === "create" ? "新建客户" : "编辑客户"}</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>客户邮箱</span>
              <input
                aria-label="客户邮箱"
                onChange={(event) => setForm((current) => ({ ...current, email: event.target.value }))}
                required
                type="email"
                value={form.email}
              />
            </label>
            <label>
              <span>客户名称</span>
              <input
                aria-label="客户名称"
                onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))}
                required
                value={form.name}
              />
            </label>
            <label>
              <span>公司</span>
              <input
                onChange={(event) => setForm((current) => ({ ...current, company: event.target.value }))}
                value={form.company}
              />
            </label>
            <label>
              <span>状态</span>
              <select
                onChange={(event) => setForm((current) => ({ ...current, status: event.target.value }))}
                value={form.status}
              >
                <option value="active">Active</option>
                <option value="trial">Trial</option>
                <option value="blocked">Blocked</option>
                <option value="archived">Archived</option>
              </select>
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setFormMode(null)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busyId !== null} type="submit">
              保存客户
            </button>
          </div>
        </form>
      ) : null}

      <div className="customer-workspace">
        <section className="panel customer-table-panel">
          <DataTable columns={columns} rows={customers} emptyText="暂无客户" />
        </section>

        {detail ? (
          <aside className="panel customer-detail-panel">
            <div className="customer-detail-heading">
              <div>
                <p className="eyebrow">Customer Detail</p>
                <h2>{detail.customer.name}</h2>
                <p>{detail.customer.email}</p>
              </div>
              <StatusBadge tone={detail.customer.riskFlag ? "red" : "green"}>
                {detail.customer.riskFlag ? "Risk" : "Normal"}
              </StatusBadge>
            </div>

            <div className="customer-kpi-grid">
              <div><span>许可证</span><strong>{detail.licenses.length}</strong></div>
              <div><span>设备</span><strong>{detail.activationCount}</strong></div>
              <div><span>反馈</span><strong>{detail.feedback.length}</strong></div>
              <div><span>邮件</span><strong>{detail.notifications.length}</strong></div>
            </div>

            <div className="customer-detail-actions">
              <button
                className="secondary-button"
                onClick={() => {
                  setLicenseFormOpen((current) => !current);
                  setCustomerLicenseKey("");
                }}
                type="button"
              >
                分配 License
              </button>
              <button
                className="secondary-button"
                onClick={() => {
                  setEmailFormOpen((current) => !current);
                  setCustomerEmailNotification(null);
                }}
                type="button"
              >
                发送邮件
              </button>
            </div>

            {customerEmailNotification ? (
              <section className="customer-detail-section customer-email-result" aria-live="polite">
                <p className="eyebrow">Email</p>
                <h3>客户邮件已创建</h3>
                <p>
                  <strong>{customerEmailNotification.id}</strong> · {customerEmailNotification.type} · {customerEmailNotification.status}
                </p>
              </section>
            ) : null}

            {emailFormOpen ? (
              <form className="customer-detail-section customer-email-form" onSubmit={(event) => void sendCustomerEmail(event)}>
                <h3>给客户发送邮件</h3>
                <div className="form-grid customer-email-grid">
                  <label>
                    <span>邮件类型</span>
                    <input
                      aria-label="客户邮件类型"
                      onChange={(event) =>
                        setEmailForm((current) => ({ ...current, type: event.target.value }))
                      }
                      required
                      value={emailForm.type}
                    />
                  </label>
                  <label>
                    <span>优先级</span>
                    <select
                      aria-label="客户邮件优先级"
                      onChange={(event) =>
                        setEmailForm((current) => ({
                          ...current,
                          priority: event.target.value as CustomerEmailFormState["priority"]
                        }))
                      }
                      value={emailForm.priority}
                    >
                      <option value="low">Low</option>
                      <option value="normal">Normal</option>
                      <option value="high">High</option>
                      <option value="urgent">Urgent</option>
                    </select>
                  </label>
                  <label className="form-grid-wide">
                    <span>Payload JSON</span>
                    <textarea
                      aria-label="客户邮件 Payload JSON"
                      onChange={(event) =>
                        setEmailForm((current) => ({ ...current, payload: event.target.value }))
                      }
                      rows={5}
                      value={emailForm.payload}
                    />
                  </label>
                </div>
                <div className="form-actions">
                  <button className="secondary-button" onClick={() => setEmailFormOpen(false)} type="button">
                    取消
                  </button>
                  <button className="primary-button" disabled={busyId === detail.customer.id} type="submit">
                    创建并发送客户邮件
                  </button>
                </div>
              </form>
            ) : null}

            {customerLicenseKey ? (
              <section className="customer-detail-section one-time-secret customer-license-secret" aria-live="polite">
                <div>
                  <p className="eyebrow">One-time reveal</p>
                  <h3>客户 License Key</h3>
                  <p>完整密钥只会完整显示这一次，请立即完成安全交付。</p>
                </div>
                <code>{customerLicenseKey}</code>
              </section>
            ) : null}

            {licenseFormOpen ? (
              <form className="customer-detail-section customer-license-form" onSubmit={(event) => void issueCustomerLicense(event)}>
                <h3>给客户发放 License</h3>
                <div className="form-grid customer-license-grid">
                  <label>
                    <span>套餐</span>
                    <select
                      aria-label="客户 License 套餐"
                      onChange={(event) =>
                        setLicenseForm((current) => ({
                          ...current,
                          plan: event.target.value as LicenseInput["plan"]
                        }))
                      }
                      value={licenseForm.plan}
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
                      aria-label="客户 License 席位数"
                      min="1"
                      onChange={(event) =>
                        setLicenseForm((current) => ({ ...current, seats: event.target.value }))
                      }
                      required
                      type="number"
                      value={licenseForm.seats}
                    />
                  </label>
                  <label>
                    <span>最大设备数</span>
                    <input
                      aria-label="客户 License 最大设备数"
                      min="1"
                      onChange={(event) =>
                        setLicenseForm((current) => ({ ...current, maxDevices: event.target.value }))
                      }
                      required
                      type="number"
                      value={licenseForm.maxDevices}
                    />
                  </label>
                  <label>
                    <span>离线宽限天数</span>
                    <input
                      aria-label="客户 License 离线宽限天数"
                      max="365"
                      min="1"
                      onChange={(event) =>
                        setLicenseForm((current) => ({ ...current, offlineGraceDays: event.target.value }))
                      }
                      required
                      type="number"
                      value={licenseForm.offlineGraceDays}
                    />
                  </label>
                  <label>
                    <span>到期时间</span>
                    <input
                      aria-label="客户 License 到期时间"
                      onChange={(event) =>
                        setLicenseForm((current) => ({ ...current, expiresAt: event.target.value }))
                      }
                      required
                      type="datetime-local"
                      value={licenseForm.expiresAt}
                    />
                  </label>
                  <label>
                    <span>初始状态</span>
                    <select
                      aria-label="客户 License 初始状态"
                      onChange={(event) =>
                        setLicenseForm((current) => ({
                          ...current,
                          status: event.target.value as CustomerLicenseFormState["status"]
                        }))
                      }
                      value={licenseForm.status}
                    >
                      <option value="active">Active</option>
                      <option value="trial">Trial</option>
                    </select>
                  </label>
                  <label className="form-grid-wide">
                    <span>Entitlements</span>
                    <input
                      aria-label="客户 License Entitlements"
                      onChange={(event) =>
                        setLicenseForm((current) => ({ ...current, entitlements: event.target.value }))
                      }
                      placeholder="pro_features, beta_channel"
                      value={licenseForm.entitlements}
                    />
                  </label>
                </div>
                <div className="form-actions">
                  <button className="secondary-button" onClick={() => setLicenseFormOpen(false)} type="button">
                    取消
                  </button>
                  <button className="primary-button" disabled={busyId === detail.customer.id} type="submit">
                    创建客户 License
                  </button>
                </div>
              </form>
            ) : null}

            <section className="customer-detail-section">
              <h3>许可证</h3>
              {detail.licenses.length > 0 ? (
                <ul className="signal-list">
                  {detail.licenses.map((license) => (
                    <li key={license.id}>
                      <strong>{license.id}</strong> · {license.plan} · {license.status} · {license.devices} 台设备 · {formatDate(license.expiresAt)}
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="empty-state">暂无许可证</p>
              )}
            </section>

            <section className="customer-detail-section">
              <h3>设备</h3>
              {detail.activations.length > 0 ? (
                <ul className="signal-list">
                  {detail.activations.map((activation) => (
                    <li key={activation.id}>
                      <code>{activation.anonymousDeviceId ?? "-"}</code> · <code>{activation.machineFingerprintHash ?? "-"}</code> · License {activation.licenseId} · 最近 {formatDate(activation.lastSeenAt)}
                      {activation.resetAt ? ` · 已重置 ${formatDate(activation.resetAt)}` : ""}
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="empty-state">暂无设备记录</p>
              )}
            </section>

            <section className="customer-detail-section">
              <h3>内部备注</h3>
              <textarea
                aria-label="内部备注"
                onChange={(event) => setNoteBody(event.target.value)}
                placeholder="记录客户背景、风险原因或跟进信息"
                value={noteBody}
              />
              <button
                className="primary-button"
                disabled={!noteBody.trim() || busyId === detail.customer.id}
                onClick={() => void addNote()}
                type="button"
              >
                添加备注
              </button>
              <div className="customer-note-list">
                {detail.notes.map((note) => (
                  <article key={note.id}>
                    <p>{note.body}</p>
                    <time>{formatDate(note.createdAt)}</time>
                  </article>
                ))}
                {detail.notes.length === 0 ? <p className="empty-state">暂无内部备注</p> : null}
              </div>
            </section>

            <section className="customer-detail-section">
              <h3>邮件历史</h3>
              {detail.notifications.length > 0 ? (
                <ul className="signal-list">
                  {detail.notifications.map((item) => {
                    const deliveries = item.deliveries ?? [];
                    return (
                      <li key={item.id}>
                        <strong>{item.id}</strong> · {item.type} · {item.status} · {formatDate(item.createdAt)}
                        {deliveries.length > 0 ? (
                          <div className="customer-email-deliveries">
                            {deliveries.map((delivery) => (
                              <p key={delivery.id}>
                                尝试 {delivery.attempt} · {delivery.provider} · {delivery.status} · {formatDate(delivery.sentAt ?? delivery.createdAt)}
                                {delivery.providerMessageId ? ` · Provider ID: ${delivery.providerMessageId}` : ""}
                                {delivery.error ? ` · 错误：${delivery.error}` : ""}
                              </p>
                            ))}
                          </div>
                        ) : (
                          <span className="customer-email-delivery-empty">暂无投递记录</span>
                        )}
                      </li>
                    );
                  })}
                </ul>
              ) : (
                <p className="empty-state">暂无邮件历史</p>
              )}
            </section>

            <section className="customer-detail-section">
              <h3>客户审计事件</h3>
              {detail.auditLogs.length > 0 ? (
                <ul className="signal-list customer-audit-list">
                  {detail.auditLogs.map((item) => (
                    <li key={item.id}>
                      <strong>{item.action}</strong> · {item.actorType ?? "system"}
                      {item.actorId ? ` (${item.actorId})` : ""} · {item.targetType ?? "customer"} {item.targetId ?? detail.customer.id} · {formatDate(item.createdAt)}
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="empty-state">暂无审计事件</p>
              )}
            </section>

            <section className="customer-detail-section">
              <h3>最近活动</h3>
              <ul className="signal-list">
                {detail.feedback.slice(0, 3).map((item) => (
                  <li key={item.id}>反馈: {item.title} ({item.status})</li>
                ))}
                {detail.notifications.slice(0, 3).map((item) => (
                  <li key={item.id}>邮件: {item.type} ({item.status})</li>
                ))}
              </ul>
            </section>
          </aside>
        ) : null}
      </div>
    </div>
  );
}
