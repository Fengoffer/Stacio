import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import {
  opsClient,
  type ConnectorConfigurationInput,
  type ConnectorRecord,
  type ConnectorType
} from "../api/client";
import { StatusBadge } from "../components/StatusBadge";
import { useProductSelection } from "../product/ProductContext";

interface ConnectorDefinition {
  type: ConnectorType;
  name: string;
  description: string;
}

type ConnectorForm = Record<string, string | boolean>;

const definitions: ConnectorDefinition[] = [
  {
    type: "github",
    name: "GitHub Issues",
    description: "同步仓库 Issues，并为统一反馈处理提供来源。"
  },
  {
    type: "smtp",
    name: "SMTP",
    description: "发送客户回复、反馈通知、License 和更新邮件。"
  },
  {
    type: "object_storage",
    name: "Object Storage",
    description: "保存安装包、反馈附件和其他产品资产。"
  },
  {
    type: "agent_api",
    name: "Agent API",
    description: "向 Codex、Claude 等 Agent 提供受控接口访问。"
  },
  {
    type: "webhook",
    name: "Webhook",
    description: "向外部系统发送受控事件通知，用于后续自动化集成。"
  }
];

const defaultForms: Record<ConnectorType, ConnectorForm> = {
  github: {
    owner: "",
    repository: "",
    apiBaseUrl: "https://api.github.com",
    state: "all",
    token: ""
  },
  smtp: {
    host: "smtp.feishu.cn",
    port: "465",
    secure: true,
    user: "",
    from: "",
    replyTo: "",
    password: ""
  },
  object_storage: {
    endpoint: "",
    region: "auto",
    bucket: "",
    forcePathStyle: true,
    publicBaseUrl: "",
    objectPrefix: "",
    accessKeyId: "",
    secretAccessKey: "",
    sessionToken: ""
  },
  agent_api: {
    baseUrl: "",
    healthPath: "/health",
    headerName: "Authorization",
    apiKey: ""
  },
  webhook: {
    url: "",
    eventTypes: "feedback.created, license.revoked",
    signingHeader: "X-Stacio-Signature",
    signingSecret: ""
  }
};

function toneForStatus(status: string) {
  const normalized = status.toLowerCase();
  if (normalized === "configured") return "green";
  if (normalized === "error") return "red";
  if (normalized === "disabled") return "gray";
  return "orange";
}

function statusLabel(status: string) {
  const labels: Record<string, string> = {
    configured: "已配置",
    unconfigured: "未配置",
    error: "连接异常",
    disabled: "已断开"
  };
  return labels[status.toLowerCase()] ?? status;
}

function displayDate(value?: string) {
  if (!value) return "尚未成功检测";
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function formFromConnector(type: ConnectorType, connector?: ConnectorRecord) {
  const form = {
    ...defaultForms[type]
  };
  for (const [key, value] of Object.entries(connector?.config ?? {})) {
    if (typeof value === "string" || typeof value === "boolean" || typeof value === "number") {
      form[key] = typeof value === "number" ? String(value) : value;
    }
  }
  return form;
}

function optional(value: string) {
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function splitList(value: string) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function payloadFor(type: ConnectorType, form: ConnectorForm): ConnectorConfigurationInput {
  const text = (key: string) => String(form[key] ?? "");
  switch (type) {
    case "github": {
      const token = optional(text("token"));
      return {
        config: {
          owner: text("owner").trim(),
          repository: text("repository").trim(),
          apiBaseUrl: text("apiBaseUrl").trim(),
          state: text("state")
        },
        ...(token ? { secrets: { token } } : {})
      };
    }
    case "smtp": {
      const password = optional(text("password"));
      return {
        config: {
          host: text("host").trim(),
          port: Number(text("port")),
          secure: form.secure === true,
          user: optional(text("user")),
          from: text("from").trim(),
          replyTo: optional(text("replyTo"))
        },
        ...(password ? { secrets: { password } } : {})
      };
    }
    case "object_storage": {
      const accessKeyId = optional(text("accessKeyId"));
      const secretAccessKey = optional(text("secretAccessKey"));
      const sessionToken = optional(text("sessionToken"));
      return {
        config: {
          endpoint: optional(text("endpoint")),
          region: text("region").trim(),
          bucket: text("bucket").trim(),
          forcePathStyle: form.forcePathStyle === true,
          publicBaseUrl: optional(text("publicBaseUrl")),
          objectPrefix: optional(text("objectPrefix"))
        },
        ...(accessKeyId && secretAccessKey
          ? {
              secrets: {
                accessKeyId,
                secretAccessKey,
                ...(sessionToken ? { sessionToken } : {})
              }
            }
          : {})
      };
    }
    case "agent_api": {
      const apiKey = optional(text("apiKey"));
      return {
        config: {
          baseUrl: text("baseUrl").trim(),
          healthPath: optional(text("healthPath")),
          headerName: optional(text("headerName"))
        },
        ...(apiKey ? { secrets: { apiKey } } : {})
      };
    }
    case "webhook": {
      const signingSecret = optional(text("signingSecret"));
      return {
        config: {
          url: text("url").trim(),
          eventTypes: splitList(text("eventTypes")),
          signingHeader: optional(text("signingHeader")) ?? "X-Stacio-Signature"
        },
        ...(signingSecret ? { secrets: { signingSecret } } : {})
      };
    }
  }
}

function connectorTypeFromLocation(): ConnectorType | null {
  if (typeof window === "undefined") {
    return null;
  }
  const value = new URLSearchParams(window.location.search).get("type");
  return definitions.some((definition) => definition.type === value)
    ? value as ConnectorType
    : null;
}

function auditLogHref(type: ConnectorType) {
  return `/audit-logs?targetType=connector&targetId=${encodeURIComponent(type)}`;
}

function TextField({
  label,
  field,
  form,
  onChange,
  required = false,
  type = "text",
  placeholder
}: {
  label: string;
  field: string;
  form: ConnectorForm;
  onChange: (field: string, value: string | boolean) => void;
  required?: boolean;
  type?: string;
  placeholder?: string;
}) {
  return (
    <label>
      <span>{label}</span>
      <input
        aria-label={label}
        onChange={(event) => onChange(field, event.target.value)}
        placeholder={placeholder}
        required={required}
        type={type}
        value={String(form[field] ?? "")}
      />
    </label>
  );
}

function ConnectorFields({
  type,
  form,
  onChange,
  hasSecrets
}: {
  type: ConnectorType;
  form: ConnectorForm;
  onChange: (field: string, value: string | boolean) => void;
  hasSecrets: boolean;
}) {
  const secretPlaceholder = hasSecrets ? "留空以保留现有密钥" : "请输入密钥";
  if (type === "github") {
    return (
      <>
        <TextField label="GitHub Owner" field="owner" form={form} onChange={onChange} required />
        <TextField label="Repository" field="repository" form={form} onChange={onChange} required />
        <TextField label="GitHub API Base URL" field="apiBaseUrl" form={form} onChange={onChange} required type="url" />
        <label>
          <span>Issue 同步范围</span>
          <select
            aria-label="Issue 同步范围"
            onChange={(event) => onChange("state", event.target.value)}
            value={String(form.state)}
          >
            <option value="all">全部</option>
            <option value="open">仅打开</option>
            <option value="closed">仅关闭</option>
          </select>
        </label>
        <TextField label="GitHub Token" field="token" form={form} onChange={onChange} placeholder={secretPlaceholder} type="password" />
      </>
    );
  }
  if (type === "smtp") {
    return (
      <>
        <TextField label="SMTP Host" field="host" form={form} onChange={onChange} required />
        <TextField label="SMTP Port" field="port" form={form} onChange={onChange} required type="number" />
        <TextField label="SMTP 用户名" field="user" form={form} onChange={onChange} />
        <TextField label="发件地址" field="from" form={form} onChange={onChange} required />
        <TextField label="回复地址" field="replyTo" form={form} onChange={onChange} />
        <TextField label="SMTP 密码" field="password" form={form} onChange={onChange} placeholder={secretPlaceholder} type="password" />
        <label className="checkbox-field">
          <input
            checked={form.secure === true}
            onChange={(event) => onChange("secure", event.target.checked)}
            type="checkbox"
          />
          <span>使用 TLS 安全连接</span>
        </label>
      </>
    );
  }
  if (type === "object_storage") {
    return (
      <>
        <TextField label="S3 Endpoint" field="endpoint" form={form} onChange={onChange} type="url" />
        <TextField label="Region" field="region" form={form} onChange={onChange} required />
        <TextField label="Bucket" field="bucket" form={form} onChange={onChange} required />
        <TextField label="公开访问 Base URL" field="publicBaseUrl" form={form} onChange={onChange} type="url" />
        <TextField label="对象前缀" field="objectPrefix" form={form} onChange={onChange} />
        <TextField label="Access Key ID" field="accessKeyId" form={form} onChange={onChange} placeholder={secretPlaceholder} />
        <TextField label="Secret Access Key" field="secretAccessKey" form={form} onChange={onChange} placeholder={secretPlaceholder} type="password" />
        <TextField label="Session Token" field="sessionToken" form={form} onChange={onChange} placeholder="可选" type="password" />
        <label className="checkbox-field">
          <input
            checked={form.forcePathStyle === true}
            onChange={(event) => onChange("forcePathStyle", event.target.checked)}
            type="checkbox"
          />
          <span>使用 Path-style 地址</span>
        </label>
      </>
    );
  }
  if (type === "agent_api") {
    return (
      <>
        <TextField label="Agent API Base URL" field="baseUrl" form={form} onChange={onChange} required type="url" />
        <TextField label="健康检查路径" field="healthPath" form={form} onChange={onChange} />
        <TextField label="认证 Header" field="headerName" form={form} onChange={onChange} />
        <TextField label="Agent API Key" field="apiKey" form={form} onChange={onChange} placeholder={secretPlaceholder} type="password" />
      </>
    );
  }
  return (
    <>
      <TextField label="Webhook URL" field="url" form={form} onChange={onChange} required type="url" />
      <TextField label="事件类型" field="eventTypes" form={form} onChange={onChange} required />
      <TextField label="签名 Header" field="signingHeader" form={form} onChange={onChange} />
      <TextField label="签名密钥" field="signingSecret" form={form} onChange={onChange} placeholder={secretPlaceholder} type="password" />
    </>
  );
}

export function ConnectorsPage() {
  const { products, productId, setProductId } = useProductSelection();
  const [connectors, setConnectors] = useState<ConnectorRecord[]>([]);
  const [connectorsLoaded, setConnectorsLoaded] = useState(false);
  const [editingType, setEditingType] = useState<ConnectorType | null>(null);
  const [form, setForm] = useState<ConnectorForm>(defaultForms.github);
  const [busyType, setBusyType] = useState<ConnectorType | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [queryConnectorType] = useState(connectorTypeFromLocation);
  const queryHandled = useRef(false);

  const connectorMap = useMemo(
    () => new Map(connectors.map((connector) => [connector.type, connector])),
    [connectors]
  );

  useEffect(() => {
    setEditingType(null);
    setMessage("");
  }, [productId]);

  useEffect(() => {
    let mounted = true;
    setError("");
    setConnectorsLoaded(false);
    void opsClient.connectors(productId).then((items) => {
      if (mounted) setConnectors(items);
    }).catch((nextError: unknown) => {
      if (mounted) setError(nextError instanceof Error ? nextError.message : "连接器加载失败");
    }).finally(() => {
      if (mounted) setConnectorsLoaded(true);
    });
    return () => {
      mounted = false;
    };
  }, [productId]);

  useEffect(() => {
    if (!connectorsLoaded || !queryConnectorType || queryHandled.current) {
      return;
    }
    queryHandled.current = true;
    setEditingType(queryConnectorType);
    setForm(formFromConnector(queryConnectorType, connectorMap.get(queryConnectorType)));
    setError("");
    setMessage("");
  }, [connectorMap, connectorsLoaded, queryConnectorType]);

  useEffect(() => {
    if (!editingType) {
      return;
    }
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setEditingType(null);
        setError("");
      }
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [editingType]);

  function replaceConnector(next: ConnectorRecord) {
    setConnectors((current) => [
      ...current.filter((item) => item.type !== next.type),
      next
    ]);
  }

  function startConfigure(type: ConnectorType) {
    queryHandled.current = true;
    setEditingType(type);
    setForm(formFromConnector(type, connectorMap.get(type)));
    setError("");
    setMessage("");
  }

  function closeConfigure() {
    setEditingType(null);
    setError("");
  }

  function updateField(field: string, value: string | boolean) {
    setForm((current) => ({
      ...current,
      [field]: value
    }));
  }

  async function saveConnector(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editingType) return;
    setBusyType(editingType);
    setError("");
    setMessage("");
    try {
      const updated = await opsClient.configureConnector(
        productId,
        editingType,
        payloadFor(editingType, form)
      );
      replaceConnector(updated);
      setEditingType(null);
      setMessage(`${updated.name} 配置已保存，建议立即执行连接检测。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "连接器保存失败");
    } finally {
      setBusyType(null);
    }
  }

  async function testConnection(definition: ConnectorDefinition) {
    setBusyType(definition.type);
    setError("");
    setMessage("");
    try {
      const result = await opsClient.testConnector(productId, definition.type);
      replaceConnector(result.connector);
      setMessage(result.result.message);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "连接检测失败");
      try {
        setConnectors(await opsClient.connectors(productId));
      } catch {
        // Preserve the original connection-test error.
      }
    } finally {
      setBusyType(null);
    }
  }

  async function disconnect(definition: ConnectorDefinition) {
    const confirmation = window.prompt(
      `请输入 DISCONNECT 以断开 ${definition.name}。保存的密钥会被立即清除。`
    );
    if (confirmation !== "DISCONNECT") return;
    setBusyType(definition.type);
    setError("");
    setMessage("");
    try {
      const updated = await opsClient.disconnectConnector(productId, definition.type);
      replaceConnector(updated);
      setMessage(`${definition.name} 已断开，保存的密钥已清除。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "断开连接失败");
    } finally {
      setBusyType(null);
    }
  }

  const editingDefinition = editingType
    ? definitions.find((definition) => definition.type === editingType)
    : undefined;

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Connectors</p>
          <h1>连接器</h1>
          <p>集中管理 GitHub、SMTP、对象存储和 Agent API，密钥只以加密形式保存。</p>
        </div>
      </div>

      {products.length > 0 ? (
        <label className="product-switcher connector-product-switcher">
          <span>当前产品</span>
          <select
            aria-label="当前产品"
            onChange={(event) => {
              setProductId(event.target.value);
              setEditingType(null);
              setMessage("");
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

      {!editingType && error ? <p className="form-error">{error}</p> : null}
      {message ? <p className="action-message">{message}</p> : null}

      <div className="connector-grid">
        {definitions.map((definition) => {
          const connector = connectorMap.get(definition.type);
          const busy = busyType === definition.type;
          return (
            <section className="panel connector-card" key={definition.type}>
              <div className="connector-card-header">
                <div>
                  <p className="connector-type">{definition.type}</p>
                  <h2>{definition.name}</h2>
                </div>
                <StatusBadge tone={toneForStatus(connector?.status ?? "unconfigured")}>
                  {statusLabel(connector?.status ?? "unconfigured")}
                </StatusBadge>
              </div>
              <p className="connector-description">{definition.description}</p>
              <dl className="connector-meta">
                <div>
                  <dt>凭据</dt>
                  <dd>{connector?.hasSecrets ? "已加密保存" : "尚未保存"}</dd>
                </div>
                <div>
                  <dt>最近成功</dt>
                  <dd>{displayDate(connector?.lastSuccessAt)}</dd>
                </div>
              </dl>
              {connector?.lastError ? (
                <p className="connector-error">{connector.lastError}</p>
              ) : null}
              <div className="connector-actions">
                <button
                  aria-label={`配置 ${definition.name}`}
                  className="secondary-button"
                  disabled={busy}
                  onClick={() => startConfigure(definition.type)}
                  type="button"
                >
                  配置
                </button>
                <button
                  aria-label={`检测 ${definition.name}`}
                  className="secondary-button"
                  disabled={busy || !connector}
                  onClick={() => void testConnection(definition)}
                  type="button"
                >
                  检测连接
                </button>
                <button
                  aria-label={`断开 ${definition.name}`}
                  className="danger-button"
                  disabled={busy || !connector?.hasSecrets}
                  onClick={() => void disconnect(definition)}
                  type="button"
                >
                  断开
                </button>
                <a
                  aria-label={`查看 ${definition.name} 审计日志`}
                  className="secondary-button"
                  href={auditLogHref(definition.type)}
                >
                  审计日志
                </a>
              </div>
            </section>
          );
        })}
      </div>

      {editingType && editingDefinition ? (
        <div className="connector-modal-backdrop" onMouseDown={(event) => {
          if (event.target === event.currentTarget) {
            closeConfigure();
          }
        }}>
          <form
            aria-label={`配置 ${editingDefinition.name}`}
            aria-modal="true"
            className="connector-modal connector-modal-resizable"
            onSubmit={(event) => void saveConnector(event)}
            role="dialog"
          >
            <header className="connector-modal-header">
              <div>
                <p className="connector-type">{editingType}</p>
                <h2>配置 {editingDefinition.name}</h2>
                <p>密钥留空时保留现有凭据；填写后将替换为新的加密凭据。</p>
              </div>
              <button
                aria-label={`关闭配置 ${editingDefinition.name}`}
                className="connector-modal-close"
                onClick={closeConfigure}
                title="关闭"
                type="button"
              >
                x
              </button>
            </header>
            <div className="connector-modal-body">
              {error ? <p className="form-error">{error}</p> : null}
              <div className="form-grid">
                <ConnectorFields
                  form={form}
                  hasSecrets={connectorMap.get(editingType)?.hasSecrets ?? false}
                  onChange={updateField}
                  type={editingType}
                />
              </div>
            </div>
            <footer className="connector-modal-actions form-actions">
              <button className="secondary-button" onClick={closeConfigure} type="button">
                取消
              </button>
              <button className="primary-button" disabled={busyType === editingType} type="submit">
                保存连接器
              </button>
            </footer>
          </form>
        </div>
      ) : null}
    </div>
  );
}
