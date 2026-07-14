import { useEffect, useMemo, useState, type FormEvent } from "react";
import { demoModeEnabled, opsClient, type ProductInput } from "../api/client";
import { product as demoProduct } from "../api/mockData";
import { KpiCard } from "../components/KpiCard";
import { StatusBadge } from "../components/StatusBadge";

type ProductRecord = Awaited<ReturnType<typeof opsClient.products>>[number];
type FormMode = "create" | "edit" | null;

interface ProductFormState {
  id: string;
  name: string;
  platform: string;
  bundleId: string;
  supportEmail: string;
  currentStableVersion: string;
  currentBetaVersion: string;
  description: string;
  iconUrl: string;
  githubOwner: string;
  githubRepository: string;
  updateBaseUrl: string;
  appcastBaseUrl: string;
  objectStoragePrefix: string;
  brandName: string;
  accentColor: string;
  emailLogoUrl: string;
  senderName: string;
  replyToEmail: string;
  supportUrl: string;
  footerText: string;
  legalText: string;
  offlineGraceDays: string;
  feedbackRetentionDays: string;
  diagnosticsRetentionDays: string;
  auditLogRetentionDays: string;
  inactiveCustomerRetentionDays: string;
}

const emptyForm: ProductFormState = {
  id: "",
  name: "",
  platform: "",
  bundleId: "",
  supportEmail: "",
  currentStableVersion: "",
  currentBetaVersion: "",
  description: "",
  iconUrl: "",
  githubOwner: "",
  githubRepository: "",
  updateBaseUrl: "",
  appcastBaseUrl: "",
  objectStoragePrefix: "",
  brandName: "",
  accentColor: "#0070C0",
  emailLogoUrl: "",
  senderName: "",
  replyToEmail: "",
  supportUrl: "",
  footerText: "",
  legalText: "",
  offlineGraceDays: "14",
  feedbackRetentionDays: "730",
  diagnosticsRetentionDays: "90",
  auditLogRetentionDays: "1095",
  inactiveCustomerRetentionDays: "730"
};

function valueFromRecord(record: Record<string, unknown>, keys: string[], fallback = "") {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" || typeof value === "number") {
      return String(value);
    }
  }
  return fallback;
}

function formFromProduct(item: ProductRecord): ProductFormState {
  return {
    id: item.id,
    name: item.name,
    platform: item.platform,
    bundleId: item.bundleId,
    supportEmail: item.supportEmail,
    currentStableVersion: item.currentStableVersion,
    currentBetaVersion: item.currentBetaVersion,
    description: item.description,
    iconUrl: item.iconUrl,
    githubOwner: item.githubOwner,
    githubRepository: item.githubRepository,
    updateBaseUrl: item.updateBaseUrl,
    appcastBaseUrl: item.appcastBaseUrl,
    objectStoragePrefix: item.objectStoragePrefix,
    brandName: valueFromRecord(item.emailBrand, ["name", "senderName"], item.name),
    accentColor: valueFromRecord(item.emailBrand, ["accentColor", "brandColor"], "#0070C0"),
    emailLogoUrl: valueFromRecord(item.emailBrand, ["logoUrl", "logo", "imageUrl"], item.iconUrl),
    senderName: valueFromRecord(item.emailBrand, ["senderName", "fromName"], item.name),
    replyToEmail: valueFromRecord(item.emailBrand, ["replyToEmail", "replyTo"], item.supportEmail),
    supportUrl: valueFromRecord(item.emailBrand, ["supportUrl", "supportURL"], ""),
    footerText: valueFromRecord(item.emailBrand, ["footerText", "footer"], ""),
    legalText: valueFromRecord(item.emailBrand, ["legalText", "legal"], ""),
    offlineGraceDays: valueFromRecord(item.licensePolicy, ["defaultOfflineGraceDays", "offlineGraceDays"], "14"),
    feedbackRetentionDays: valueFromRecord(item.dataRetentionPolicy, ["feedbackRetentionDays"], "730"),
    diagnosticsRetentionDays: valueFromRecord(item.dataRetentionPolicy, ["diagnosticsRetentionDays"], "90"),
    auditLogRetentionDays: valueFromRecord(item.dataRetentionPolicy, ["auditLogRetentionDays"], "1095"),
    inactiveCustomerRetentionDays: valueFromRecord(item.dataRetentionPolicy, ["inactiveCustomerRetentionDays"], "730")
  };
}

function toProductInput(form: ProductFormState): ProductInput {
  const brandName = form.brandName.trim() || form.name.trim();
  return {
    id: form.id.trim(),
    name: form.name.trim(),
    platform: form.platform.trim(),
    bundleId: form.bundleId.trim(),
    supportEmail: form.supportEmail.trim(),
    description: form.description.trim() || undefined,
    iconUrl: form.iconUrl.trim() || undefined,
    githubOwner: form.githubOwner.trim() || undefined,
    githubRepository: form.githubRepository.trim() || undefined,
    currentStableVersion: form.currentStableVersion.trim() || undefined,
    currentBetaVersion: form.currentBetaVersion.trim() || undefined,
    updateBaseUrl: form.updateBaseUrl.trim() || undefined,
    appcastBaseUrl: form.appcastBaseUrl.trim() || undefined,
    objectStoragePrefix: form.objectStoragePrefix.trim() || undefined,
    emailBrand: {
      name: brandName,
      accentColor: form.accentColor.trim() || "#0070C0",
      logoUrl: form.emailLogoUrl.trim() || form.iconUrl.trim() || undefined,
      senderName: form.senderName.trim() || brandName,
      replyToEmail: form.replyToEmail.trim() || form.supportEmail.trim(),
      supportUrl: form.supportUrl.trim() || undefined,
      footerText: form.footerText.trim() || undefined,
      legalText: form.legalText.trim() || undefined
    },
    licensePolicy: {
      defaultOfflineGraceDays: Number(form.offlineGraceDays) || 14,
      deviceFingerprintMode: "risk_signal"
    },
    dataRetentionPolicy: {
      feedbackRetentionDays: Number(form.feedbackRetentionDays) || 730,
      diagnosticsRetentionDays: Number(form.diagnosticsRetentionDays) || 90,
      auditLogRetentionDays: Number(form.auditLogRetentionDays) || 1095,
      inactiveCustomerRetentionDays: Number(form.inactiveCustomerRetentionDays) || 730
    }
  };
}

function normalizeProduct(item: Partial<ProductRecord>): ProductRecord {
  return {
    id: item.id ?? "",
    name: item.name ?? "",
    platform: item.platform ?? "",
    bundleId: item.bundleId ?? "",
    iconUrl: item.iconUrl ?? "",
    description: item.description ?? "",
    currentStableVersion: item.currentStableVersion ?? "",
    currentBetaVersion: item.currentBetaVersion ?? "",
    supportEmail: item.supportEmail ?? "",
    githubOwner: item.githubOwner ?? "",
    githubRepository: item.githubRepository ?? "",
    updateBaseUrl: item.updateBaseUrl ?? "",
    appcastBaseUrl: item.appcastBaseUrl ?? "",
    licensePolicy: item.licensePolicy ?? {},
    dataRetentionPolicy: item.dataRetentionPolicy ?? {},
    emailBrand: item.emailBrand ?? {},
    objectStoragePrefix: item.objectStoragePrefix ?? "",
    status: item.status ?? "active",
    createdAt: item.createdAt,
    updatedAt: item.updatedAt
  };
}

export function ProductsPage() {
  const [items, setItems] = useState<ProductRecord[]>(
    demoModeEnabled()
      ? [
          normalizeProduct({
            ...demoProduct,
            objectStoragePrefix: "products/stacio"
          })
        ]
      : []
  );
  const [selectedId, setSelectedId] = useState("stacio");
  const [mode, setMode] = useState<FormMode>(null);
  const [form, setForm] = useState<ProductFormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [revealedKey, setRevealedKey] = useState("");

  const selected = useMemo(
    () => items.find((item) => item.id === selectedId) ?? items[0],
    [items, selectedId]
  );

  useEffect(() => {
    let isMounted = true;
    void opsClient
      .products()
      .then((nextItems) => {
        if (!isMounted) return;
        setItems(nextItems);
        if (nextItems.length > 0 && !nextItems.some((item) => item.id === selectedId)) {
          setSelectedId(nextItems[0].id);
        }
      })
      .catch((nextError: unknown) => {
        if (isMounted) {
          setError(nextError instanceof Error ? nextError.message : "产品加载失败");
        }
      });
    return () => {
      isMounted = false;
    };
  }, []);

  function startCreate() {
    setMode("create");
    setForm(emptyForm);
    setError("");
    setMessage("");
    setRevealedKey("");
  }

  function startEdit() {
    if (!selected) return;
    setMode("edit");
    setForm(formFromProduct(selected));
    setError("");
    setMessage("");
    setRevealedKey("");
  }

  function updateField(field: keyof ProductFormState, value: string) {
    setForm((current) => ({
      ...current,
      [field]: value
    }));
  }

  async function saveProduct(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const input = toProductInput(form);
      if (mode === "create") {
        const result = await opsClient.createProduct(input);
        const created = normalizeProduct(result.product);
        setItems((current) => [...current.filter((item) => item.id !== created.id), created]);
        setSelectedId(created.id);
        setRevealedKey(result.feedbackApiKey);
        setMessage("产品已创建。Feedback API Key 只显示这一次，请立即保存。");
      } else if (selected) {
        const { id: _id, ...update } = input;
        const updated = normalizeProduct(await opsClient.updateProduct(selected.id, update));
        setItems((current) => current.map((item) => (item.id === selected.id ? updated : item)));
        setMessage("产品配置已保存。");
      }
      setMode(null);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "产品保存失败");
    } finally {
      setBusy(false);
    }
  }

  async function rotateKey() {
    if (!selected) return;
    const confirmation = window.prompt("请输入 ROTATE 以确认轮换 Feedback API Key。旧 Key 会立即失效。");
    if (confirmation !== "ROTATE") return;
    setBusy(true);
    setError("");
    try {
      const result = await opsClient.rotateFeedbackApiKey(selected.id);
      setRevealedKey(result.feedbackApiKey);
      setMessage("Feedback API Key 已轮换，只显示这一次，请立即保存并更新客户端配置。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Key 轮换失败");
    } finally {
      setBusy(false);
    }
  }

  async function archiveProduct() {
    if (!selected) return;
    const confirmation = window.prompt("请输入 ARCHIVE 以确认归档产品。归档后公开反馈将停止接入。");
    if (confirmation !== "ARCHIVE") return;
    setBusy(true);
    setError("");
    try {
      await opsClient.archiveProduct(selected.id);
      setItems((current) =>
        current.map((item) => (item.id === selected.id ? { ...item, status: "archived" } : item))
      );
      setMessage("产品已归档。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "产品归档失败");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Products</p>
          <h1>产品管理</h1>
          <p>管理多产品标识、品牌、GitHub、更新地址和公开反馈接入凭据。</p>
        </div>
        <div className="heading-actions">
          <button className="secondary-button" onClick={startCreate} type="button">
            新建产品
          </button>
          <button className="secondary-button" disabled={!selected} onClick={startEdit} type="button">
            编辑产品
          </button>
        </div>
      </div>

      {items.length > 1 ? (
        <label className="product-switcher">
          <span>当前产品</span>
          <select
            aria-label="当前产品"
            onChange={(event) => {
              setSelectedId(event.target.value);
              setMode(null);
              setMessage("");
              setRevealedKey("");
            }}
            value={selected?.id ?? ""}
          >
            {items.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} ({item.id})
              </option>
            ))}
          </select>
        </label>
      ) : null}

      {error ? <p className="form-error">{error}</p> : null}
      {message ? <p className="action-message">{message}</p> : null}
      {revealedKey ? (
        <section className="panel key-reveal" aria-live="polite">
          <div>
            <strong>Feedback API Key</strong>
            <p>该密钥只显示这一次，后台仅保存哈希。</p>
          </div>
          <code>{revealedKey}</code>
        </section>
      ) : null}

      {mode ? (
        <form className="panel product-form" onSubmit={(event) => void saveProduct(event)}>
          <div className="panel-header">
            <div>
              <h2>{mode === "create" ? "新建产品" : "编辑产品"}</h2>
              <p>所有配置均按产品隔离，可复用于后续桌面软件。</p>
            </div>
          </div>
          <div className="form-grid">
            <label>
              <span>Product ID</span>
              <input
                disabled={mode === "edit"}
                onChange={(event) => updateField("id", event.target.value)}
                pattern="[a-z0-9][a-z0-9_-]*"
                required
                value={form.id}
              />
            </label>
            <label>
              <span>产品名称</span>
              <input onChange={(event) => updateField("name", event.target.value)} required value={form.name} />
            </label>
            <label>
              <span>平台</span>
              <input onChange={(event) => updateField("platform", event.target.value)} required value={form.platform} />
            </label>
            <label>
              <span>Bundle ID</span>
              <input onChange={(event) => updateField("bundleId", event.target.value)} required value={form.bundleId} />
            </label>
            <label>
              <span>支持邮箱</span>
              <input
                onChange={(event) => updateField("supportEmail", event.target.value)}
                required
                type="email"
                value={form.supportEmail}
              />
            </label>
            <label>
              <span>产品图标 URL</span>
              <input onChange={(event) => updateField("iconUrl", event.target.value)} type="url" value={form.iconUrl} />
            </label>
            <label className="field-wide">
              <span>产品描述</span>
              <textarea onChange={(event) => updateField("description", event.target.value)} value={form.description} />
            </label>
            <label>
              <span>GitHub Owner</span>
              <input onChange={(event) => updateField("githubOwner", event.target.value)} value={form.githubOwner} />
            </label>
            <label>
              <span>GitHub Repository</span>
              <input
                onChange={(event) => updateField("githubRepository", event.target.value)}
                value={form.githubRepository}
              />
            </label>
            <label>
              <span>当前 Stable 版本</span>
              <input
                onChange={(event) => updateField("currentStableVersion", event.target.value)}
                value={form.currentStableVersion}
              />
            </label>
            <label>
              <span>当前 Beta 版本</span>
              <input
                onChange={(event) => updateField("currentBetaVersion", event.target.value)}
                value={form.currentBetaVersion}
              />
            </label>
            <label>
              <span>Update Base URL</span>
              <input
                onChange={(event) => updateField("updateBaseUrl", event.target.value)}
                type="url"
                value={form.updateBaseUrl}
              />
            </label>
            <label>
              <span>Appcast Base URL</span>
              <input
                onChange={(event) => updateField("appcastBaseUrl", event.target.value)}
                type="url"
                value={form.appcastBaseUrl}
              />
            </label>
            <label>
              <span>对象存储前缀</span>
              <input
                onChange={(event) => updateField("objectStoragePrefix", event.target.value)}
                value={form.objectStoragePrefix}
              />
            </label>
            <label>
              <span>邮件品牌名称</span>
              <input onChange={(event) => updateField("brandName", event.target.value)} value={form.brandName} />
            </label>
            <label>
              <span>品牌强调色</span>
              <input onChange={(event) => updateField("accentColor", event.target.value)} value={form.accentColor} />
            </label>
            <label>
              <span>邮件 Logo URL</span>
              <input
                onChange={(event) => updateField("emailLogoUrl", event.target.value)}
                type="url"
                value={form.emailLogoUrl}
              />
            </label>
            <label>
              <span>邮件发件人名称</span>
              <input onChange={(event) => updateField("senderName", event.target.value)} value={form.senderName} />
            </label>
            <label>
              <span>邮件 Reply-To</span>
              <input
                onChange={(event) => updateField("replyToEmail", event.target.value)}
                type="email"
                value={form.replyToEmail}
              />
            </label>
            <label>
              <span>邮件支持 URL</span>
              <input
                onChange={(event) => updateField("supportUrl", event.target.value)}
                type="url"
                value={form.supportUrl}
              />
            </label>
            <label className="field-wide">
              <span>邮件 Footer 文案</span>
              <textarea onChange={(event) => updateField("footerText", event.target.value)} value={form.footerText} />
            </label>
            <label className="field-wide">
              <span>邮件 Legal 文案</span>
              <textarea onChange={(event) => updateField("legalText", event.target.value)} value={form.legalText} />
            </label>
            <label>
              <span>默认离线宽限期（天）</span>
              <input
                min="1"
                onChange={(event) => updateField("offlineGraceDays", event.target.value)}
                type="number"
                value={form.offlineGraceDays}
              />
            </label>
            <label>
              <span>反馈保留天数</span>
              <input
                min="1"
                onChange={(event) => updateField("feedbackRetentionDays", event.target.value)}
                type="number"
                value={form.feedbackRetentionDays}
              />
            </label>
            <label>
              <span>诊断摘要保留天数</span>
              <input
                min="1"
                onChange={(event) => updateField("diagnosticsRetentionDays", event.target.value)}
                type="number"
                value={form.diagnosticsRetentionDays}
              />
            </label>
            <label>
              <span>审计日志保留天数</span>
              <input
                min="1"
                onChange={(event) => updateField("auditLogRetentionDays", event.target.value)}
                type="number"
                value={form.auditLogRetentionDays}
              />
            </label>
            <label>
              <span>非活跃客户保留天数</span>
              <input
                min="1"
                onChange={(event) => updateField("inactiveCustomerRetentionDays", event.target.value)}
                type="number"
                value={form.inactiveCustomerRetentionDays}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setMode(null)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busy} type="submit">
              {mode === "create" ? "创建产品" : "保存产品"}
            </button>
          </div>
        </form>
      ) : null}

      {selected ? (
        <>
          <div className="kpi-grid">
            <KpiCard label="当前 Stable" value={selected.currentStableVersion || "-"} detail="Sparkle stable channel" tone="green" />
            <KpiCard label="当前 Beta" value={selected.currentBetaVersion || "-"} detail="Beta channel" tone="blue" />
            <KpiCard label="平台" value={selected.platform} detail={selected.bundleId} tone="orange" />
            <KpiCard label="状态" value={selected.status} detail={selected.supportEmail} tone="blue" />
          </div>

          <section className="panel detail-panel">
            <div className="panel-header">
              <h2>产品资料</h2>
              <StatusBadge tone={selected.status === "active" ? "green" : "orange"}>{selected.status}</StatusBadge>
            </div>
            <dl className="detail-list">
              <div>
                <dt>Product ID</dt>
                <dd>{selected.id}</dd>
              </div>
              <div>
                <dt>Name</dt>
                <dd>{selected.name}</dd>
              </div>
              <div>
                <dt>Bundle ID</dt>
                <dd>{selected.bundleId}</dd>
              </div>
              <div>
                <dt>Support Email</dt>
                <dd>{selected.supportEmail}</dd>
              </div>
              <div>
                <dt>GitHub</dt>
                <dd>{selected.githubOwner && selected.githubRepository ? `${selected.githubOwner}/${selected.githubRepository}` : "-"}</dd>
              </div>
              <div>
                <dt>Appcast</dt>
                <dd>{selected.appcastBaseUrl || "-"}</dd>
              </div>
              <div>
                <dt>Storage Prefix</dt>
                <dd>{selected.objectStoragePrefix || "-"}</dd>
              </div>
              <div>
                <dt>Email Brand</dt>
                <dd>{valueFromRecord(selected.emailBrand, ["name", "senderName"], selected.name)}</dd>
              </div>
              <div>
                <dt>Email Sender</dt>
                <dd>{valueFromRecord(selected.emailBrand, ["senderName", "fromName"], selected.name)}</dd>
              </div>
              <div>
                <dt>Reply-To</dt>
                <dd>{valueFromRecord(selected.emailBrand, ["replyToEmail", "replyTo"], selected.supportEmail)}</dd>
              </div>
              <div>
                <dt>Email Support URL</dt>
                <dd>{valueFromRecord(selected.emailBrand, ["supportUrl", "supportURL"], "-")}</dd>
              </div>
              <div>
                <dt>Email Footer</dt>
                <dd>{valueFromRecord(selected.emailBrand, ["footerText", "footer"], "-")}</dd>
              </div>
              <div>
                <dt>Feedback Retention</dt>
                <dd>{valueFromRecord(selected.dataRetentionPolicy, ["feedbackRetentionDays"], "730")} 天</dd>
              </div>
              <div>
                <dt>Diagnostics Retention</dt>
                <dd>{valueFromRecord(selected.dataRetentionPolicy, ["diagnosticsRetentionDays"], "90")} 天</dd>
              </div>
              <div>
                <dt>Audit Retention</dt>
                <dd>{valueFromRecord(selected.dataRetentionPolicy, ["auditLogRetentionDays"], "1095")} 天</dd>
              </div>
              <div>
                <dt>Inactive Customer Retention</dt>
                <dd>{valueFromRecord(selected.dataRetentionPolicy, ["inactiveCustomerRetentionDays"], "730")} 天</dd>
              </div>
            </dl>
          </section>

          <section className="panel danger-panel">
            <div>
              <h2>安全与生命周期</h2>
              <p>Feedback Key 轮换后旧客户端需更新配置；归档会停止公开反馈接入。</p>
            </div>
            <div className="heading-actions">
              <button className="secondary-button" disabled={busy} onClick={() => void rotateKey()} type="button">
                轮换 Feedback Key
              </button>
              <button className="danger-button" disabled={busy || selected.status === "archived"} onClick={() => void archiveProduct()} type="button">
                归档产品
              </button>
            </div>
          </section>
        </>
      ) : (
        <section className="panel empty-state">
          <h2>暂无产品</h2>
          <p>创建第一个产品后即可配置反馈、发布、License 和品牌邮件。</p>
        </section>
      )}
    </div>
  );
}
