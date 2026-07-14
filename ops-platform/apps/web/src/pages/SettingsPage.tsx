import { useEffect, useState, type FormEvent } from "react";
import {
  demoModeEnabled,
  opsClient,
  type AgentApiKeyRecord,
  type AdminRoleRecord,
  type AdminUserRecord
} from "../api/client";
import { settingsSummary } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { KpiCard } from "../components/KpiCard";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

function yesNo(value: boolean) {
  return value ? "已配置" : "未配置";
}

const emptyUserForm = {
  email: "",
  name: "",
  password: "",
  role: "",
  productIds: ""
};

const emptyPersistedAgentKeyForm = {
  name: "",
  productIds: "",
  scopes: "feedback:read, actions:propose",
  expiresAt: ""
};

const agentScopeTemplates = {
  feedback_triage: [
    "feedback:read",
    "feedback:write_analysis",
    "feedback:write_draft",
    "issues:read",
    "actions:propose"
  ],
  release_draft: ["releases:read", "releases:write_draft", "actions:propose"],
  support_read: ["customers:read", "licenses:read", "notifications:write_draft"],
  full_agent: [
    "feedback:read",
    "feedback:write_analysis",
    "feedback:write_draft",
    "issues:read",
    "customers:read",
    "licenses:read",
    "notifications:write_draft",
    "actions:propose",
    "releases:read",
    "releases:write_draft"
  ]
} as const;

type AgentScopeTemplate = keyof typeof agentScopeTemplates;

function defaultAgentForm(productId: string) {
  return {
    id: `codex-${productId}-triage`,
    name: "Codex feedback triage",
    productIds: productId,
    scopeTemplate: "feedback_triage" as AgentScopeTemplate,
    expiresAt: "2099-01-01T00:00:00.000Z"
  };
}

function splitProductIds(value: string) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function splitScopes(value: string) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function isDisabledStatus(status: string) {
  return status.toLowerCase().includes("disabled");
}

function generateAgentSecret() {
  const bytes = new Uint8Array(24);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256);
    }
  }
  return `agent_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export function SettingsPage() {
  const { productId } = useProduct();
  const [refreshing, setRefreshing] = useState(false);
  const [message, setMessage] = useState("");
  const [createUserOpen, setCreateUserOpen] = useState(false);
  const [agentKeyOpen, setAgentKeyOpen] = useState(false);
  const [createAgentKeyOpen, setCreateAgentKeyOpen] = useState(false);
  const [userBusyId, setUserBusyId] = useState<string | null>(null);
  const [agentKeyBusyId, setAgentKeyBusyId] = useState<string | null>(null);
  const [roles, setRoles] = useState<AdminRoleRecord[]>([]);
  const [users, setUsers] = useState<AdminUserRecord[]>([]);
  const [agentKeys, setAgentKeys] = useState<AgentApiKeyRecord[]>([]);
  const [userForm, setUserForm] = useState(emptyUserForm);
  const [persistedAgentKeyForm, setPersistedAgentKeyForm] = useState(() => ({
    ...emptyPersistedAgentKeyForm,
    name: "Codex feedback triage",
    productIds: productId
  }));
  const [createdAgentKey, setCreatedAgentKey] = useState("");
  const [agentForm, setAgentForm] = useState(() => defaultAgentForm(productId));
  const [agentConfigJson, setAgentConfigJson] = useState("");
  const [error, setError] = useState("");
  const [summary, setSummary] = useState(
    demoModeEnabled()
      ? settingsSummary
      : {
          ...settingsSummary,
          persistence: "-",
          smtpConfigured: false,
          objectStorageConfigured: false,
          redisConfigured: false,
          bootstrapOwnerConfigured: false,
          roleCount: 0,
          userCount: 0,
          apiKeyCount: 0
        }
  );

  useEffect(() => {
    let isMounted = true;
    setError("");
    void Promise.all([
      opsClient.settingsSummary(productId),
      opsClient.adminRoles(),
      opsClient.adminUsers(),
      opsClient.agentApiKeys()
    ])
      .then(([nextSummary, nextRoles, nextUsers, nextAgentKeys]) => {
        if (isMounted) {
          setSummary(nextSummary);
          setRoles(nextRoles);
          setUsers(nextUsers);
          setAgentKeys(nextAgentKeys);
          setUserForm((current) => ({
            ...current,
            role: current.role || nextRoles.find((role) => role.name !== "agent")?.name || nextRoles[0]?.name || ""
          }));
          setError("");
        }
      })
      .catch((nextError: unknown) => {
        if (isMounted) {
          setError(nextError instanceof Error ? nextError.message : "系统设置加载失败");
        }
      });
    return () => {
      isMounted = false;
    };
  }, [productId]);

  async function reloadUsers() {
    setUsers(await opsClient.adminUsers());
  }

  async function reloadAgentKeys() {
    setAgentKeys(await opsClient.agentApiKeys());
  }

  async function refreshSummary() {
    setRefreshing(true);
    setMessage("");
    setError("");
    try {
      const [nextSummary, nextRoles, nextUsers, nextAgentKeys] = await Promise.all([
        opsClient.settingsSummary(productId),
        opsClient.adminRoles(),
        opsClient.adminUsers(),
        opsClient.agentApiKeys()
      ]);
      setSummary(nextSummary);
      setRoles(nextRoles);
      setUsers(nextUsers);
      setAgentKeys(nextAgentKeys);
      setMessage("状态已刷新");
    } catch (error) {
      setError(error instanceof Error ? error.message : "状态刷新失败");
    } finally {
      setRefreshing(false);
    }
  }

  async function createAdminUser(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setUserBusyId("create");
    setMessage("");
    try {
      await opsClient.createAdminUser({
        email: userForm.email.trim(),
        name: userForm.name.trim(),
        password: userForm.password,
        role: userForm.role,
        productIds: splitProductIds(userForm.productIds)
      });
      setMessage("后台用户已创建");
      setCreateUserOpen(false);
      setUserForm((current) => ({ ...emptyUserForm, role: current.role }));
      await reloadUsers();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "后台用户创建失败");
    } finally {
      setUserBusyId(null);
    }
  }

  async function disableAdminUser(user: AdminUserRecord) {
    const confirmation = window.prompt(`将停用 ${user.email}。请输入 DISABLE 确认。`);
    if (confirmation !== "DISABLE") {
      setMessage("已取消停用用户");
      return;
    }
    setUserBusyId(user.id);
    setMessage("");
    try {
      await opsClient.updateAdminUser(user.id, {
        status: "disabled",
        confirmation: "DISABLE"
      });
      setMessage("后台用户已停用");
      await reloadUsers();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "后台用户停用失败");
    } finally {
      setUserBusyId(null);
    }
  }

  async function enableAdminUser(user: AdminUserRecord) {
    const confirmation = window.prompt(`将启用 ${user.email}。请输入 ENABLE 确认。`);
    if (confirmation !== "ENABLE") {
      setMessage("已取消启用用户");
      return;
    }
    setUserBusyId(user.id);
    setMessage("");
    try {
      await opsClient.updateAdminUser(user.id, {
        status: "active",
        confirmation: "ENABLE"
      });
      setMessage("后台用户已启用");
      await reloadUsers();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "后台用户启用失败");
    } finally {
      setUserBusyId(null);
    }
  }

  async function createPersistedAgentKey(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setAgentKeyBusyId("create");
    setMessage("");
    setCreatedAgentKey("");
    try {
      const key = await opsClient.createAgentApiKey({
        name: persistedAgentKeyForm.name.trim(),
        productIds: splitProductIds(persistedAgentKeyForm.productIds),
        scopes: splitScopes(persistedAgentKeyForm.scopes),
        ...(persistedAgentKeyForm.expiresAt.trim() ? { expiresAt: persistedAgentKeyForm.expiresAt.trim() } : {})
      });
      setCreatedAgentKey(key.oneTimeKey ?? "");
      setMessage("Agent Key 已创建，明文只显示一次");
      setCreateAgentKeyOpen(false);
      setPersistedAgentKeyForm((current) => ({
        ...emptyPersistedAgentKeyForm,
        name: current.name,
        productIds: current.productIds
      }));
      await reloadAgentKeys();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Agent Key 创建失败");
    } finally {
      setAgentKeyBusyId(null);
    }
  }

  async function disableAgentApiKey(key: AgentApiKeyRecord) {
    const confirmation = window.prompt(`将停用 Agent Key ${key.name}。请输入 DISABLE 确认。`);
    if (confirmation !== "DISABLE") {
      setMessage("已取消停用 Agent Key");
      return;
    }
    setAgentKeyBusyId(key.id);
    setMessage("");
    try {
      await opsClient.updateAgentApiKey(key.id, {
        status: "disabled",
        confirmation: "DISABLE"
      });
      setMessage("Agent Key 已停用");
      await reloadAgentKeys();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Agent Key 停用失败");
    } finally {
      setAgentKeyBusyId(null);
    }
  }

  async function enableAgentApiKey(key: AgentApiKeyRecord) {
    const confirmation = window.prompt(`将启用 Agent Key ${key.name}。请输入 ENABLE 确认。`);
    if (confirmation !== "ENABLE") {
      setMessage("已取消启用 Agent Key");
      return;
    }
    setAgentKeyBusyId(key.id);
    setMessage("");
    try {
      await opsClient.updateAgentApiKey(key.id, {
        status: "active",
        confirmation: "ENABLE"
      });
      setMessage("Agent Key 已启用");
      await reloadAgentKeys();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Agent Key 启用失败");
    } finally {
      setAgentKeyBusyId(null);
    }
  }

  async function rotateAgentApiKey(key: AgentApiKeyRecord) {
    const confirmation = window.prompt(`将轮换 Agent Key ${key.name}。请输入 ROTATE 确认。`);
    if (confirmation !== "ROTATE") {
      setMessage("已取消轮换 Agent Key");
      return;
    }
    setAgentKeyBusyId(key.id);
    setMessage("");
    setCreatedAgentKey("");
    try {
      const rotated = await opsClient.rotateAgentApiKey(key.id, {
        confirmation: "ROTATE"
      });
      setCreatedAgentKey(rotated.oneTimeKey ?? "");
      setMessage("Agent Key 已轮换，明文只显示一次");
      await reloadAgentKeys();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Agent Key 轮换失败");
    } finally {
      setAgentKeyBusyId(null);
    }
  }

  function generateAgentConfig(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const config = {
      id: agentForm.id.trim(),
      key: generateAgentSecret(),
      name: agentForm.name.trim(),
      productIds: splitProductIds(agentForm.productIds),
      scopes: [...agentScopeTemplates[agentForm.scopeTemplate]],
      ...(agentForm.expiresAt.trim() ? { expiresAt: agentForm.expiresAt.trim() } : {})
    };
    setAgentConfigJson(JSON.stringify([config], null, 2));
    setMessage("Agent Key 配置已生成");
  }

  const userColumns: DataColumn<AdminUserRecord>[] = [
    {
      key: "email",
      title: "用户",
      render: (row) => (
        <div>
          <strong>{row.email}</strong>
          <p className="table-subtext">{row.name}</p>
        </div>
      )
    },
    { key: "role", title: "角色", render: (row) => row.role },
    { key: "productScope", title: "产品范围", render: (row) => row.productScope },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge tone={row.status.toLowerCase().includes("active") ? "green" : "gray"}>
          {row.status}
        </StatusBadge>
      )
    },
    { key: "createdAt", title: "创建", render: (row) => row.createdAt },
    {
      key: "actions",
      title: "操作",
      render: (row) => {
        if (isDisabledStatus(row.status)) {
          return (
            <button
              aria-label={`启用 ${row.email}`}
              className="secondary-button"
              disabled={userBusyId === row.id}
              onClick={() => void enableAdminUser(row)}
              type="button"
            >
              启用
            </button>
          );
        }
        return (
          <button
            aria-label={`停用 ${row.email}`}
            className="danger-button"
            disabled={userBusyId === row.id}
            onClick={() => void disableAdminUser(row)}
            type="button"
          >
            停用
          </button>
        );
      }
    }
  ];

  const roleColumns: DataColumn<AdminRoleRecord>[] = [
    {
      key: "name",
      title: "角色",
      render: (row) => (
        <div>
          <strong>{row.name}</strong>
          <p className="table-subtext">{row.description ?? "-"}</p>
        </div>
      )
    },
    {
      key: "permissions",
      title: "权限",
      render: (row) => row.permissions.join(", ") || "-"
    }
  ];

  const agentKeyColumns: DataColumn<AgentApiKeyRecord>[] = [
    {
      key: "name",
      title: "名称",
      render: (row) => (
        <div>
          <strong>{row.name}</strong>
          <p className="table-subtext">{row.keyPrefix}</p>
        </div>
      )
    },
    { key: "productScope", title: "产品范围", render: (row) => row.productScope },
    { key: "scopeSummary", title: "Scopes", render: (row) => row.scopeSummary },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge tone={row.status.toLowerCase().includes("active") ? "green" : "gray"}>
          {row.status}
        </StatusBadge>
      )
    },
    { key: "createdAt", title: "创建", render: (row) => row.createdAt },
    {
      key: "actions",
      title: "操作",
      render: (row) => {
        if (isDisabledStatus(row.status)) {
          return (
            <button
              aria-label={`启用 Agent Key ${row.name}`}
              className="secondary-button"
              disabled={agentKeyBusyId === row.id}
              onClick={() => void enableAgentApiKey(row)}
              type="button"
            >
              启用
            </button>
          );
        }
        return (
          <div className="inline-actions">
            <button
              aria-label={`轮换 Agent Key ${row.name}`}
              className="secondary-button"
              disabled={agentKeyBusyId === row.id}
              onClick={() => void rotateAgentApiKey(row)}
              type="button"
            >
              轮换
            </button>
            <button
              aria-label={`停用 Agent Key ${row.name}`}
              className="danger-button"
              disabled={agentKeyBusyId === row.id}
              onClick={() => void disableAgentApiKey(row)}
              type="button"
            >
              停用
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
          <p className="eyebrow">Settings</p>
          <h1>系统设置</h1>
          <p>查看部署持久化、外部服务和后台安全策略状态。</p>
        </div>
        <div className="inline-actions">
          <button
            className="secondary-button"
            onClick={() => setCreateAgentKeyOpen(true)}
            type="button"
          >
            新建 Agent Key
          </button>
          <button
            className="secondary-button"
            onClick={() => setAgentKeyOpen(true)}
            type="button"
          >
            生成 Agent Key 配置
          </button>
          <button
            className="secondary-button"
            onClick={() => setCreateUserOpen(true)}
            type="button"
          >
            新建后台用户
          </button>
          <button
            className="secondary-button"
            disabled={refreshing}
            onClick={() => void refreshSummary()}
            type="button"
          >
            {refreshing ? "刷新中" : "刷新状态"}
          </button>
        </div>
      </div>

      {message ? <p className="action-message">{message}</p> : null}
      {error ? <div className="error-banner" role="alert">{error}</div> : null}
      {createdAgentKey ? (
        <p className="action-message">
          {createdAgentKey}
        </p>
      ) : null}

      <div className="kpi-grid">
        <KpiCard label="持久化" value={summary.persistence} detail="Docker production uses PostgreSQL" tone="blue" />
        <KpiCard label="角色" value={summary.roleCount} detail={`${summary.userCount} users`} tone="green" />
        <KpiCard label="API Keys" value={summary.apiKeyCount} detail="Scoped access keys" tone="orange" />
        <KpiCard label="离线授权" value={`${summary.policy.licenseOfflineGraceDays} 天`} detail="默认宽限期" tone="blue" />
      </div>

      <div className="content-grid">
        <section className="panel">
          <div className="panel-header">
            <h2>外部服务</h2>
          </div>
          <dl className="detail-list">
            <div>
              <dt>SMTP</dt>
              <dd>
                <StatusBadge tone={summary.smtpConfigured ? "green" : "orange"}>{yesNo(summary.smtpConfigured)}</StatusBadge>
              </dd>
            </div>
            <div>
              <dt>对象存储</dt>
              <dd>
                <StatusBadge tone={summary.objectStorageConfigured ? "green" : "orange"}>{yesNo(summary.objectStorageConfigured)}</StatusBadge>
              </dd>
            </div>
            <div>
              <dt>Redis</dt>
              <dd>
                <StatusBadge tone={summary.redisConfigured ? "green" : "orange"}>{yesNo(summary.redisConfigured)}</StatusBadge>
              </dd>
            </div>
            <div>
              <dt>Bootstrap Owner</dt>
              <dd>
                <StatusBadge tone={summary.bootstrapOwnerConfigured ? "green" : "orange"}>
                  {yesNo(summary.bootstrapOwnerConfigured)}
                </StatusBadge>
              </dd>
            </div>
          </dl>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>安全策略</h2>
          </div>
          <dl className="detail-list">
            <div>
              <dt>OTA 发布</dt>
              <dd>{summary.policy.otaRequiresManualConfirmation ? "永远人工确认" : "未启用确认"}</dd>
            </div>
            <div>
              <dt>Agent 高风险动作</dt>
              <dd>{summary.policy.agentDangerousActionsBlocked ? "已阻止" : "未阻止"}</dd>
            </div>
            <div>
              <dt>Product ID</dt>
              <dd>{summary.productId}</dd>
            </div>
          </dl>
        </section>
      </div>

      {createUserOpen ? (
        <form className="panel product-form" onSubmit={(event) => void createAdminUser(event)}>
          <div className="panel-header">
            <h2>新建后台用户</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>用户邮箱</span>
              <input
                aria-label="用户邮箱"
                onChange={(event) => setUserForm((current) => ({ ...current, email: event.target.value }))}
                required
                type="email"
                value={userForm.email}
              />
            </label>
            <label>
              <span>用户姓名</span>
              <input
                aria-label="用户姓名"
                onChange={(event) => setUserForm((current) => ({ ...current, name: event.target.value }))}
                required
                value={userForm.name}
              />
            </label>
            <label>
              <span>初始密码</span>
              <input
                aria-label="初始密码"
                onChange={(event) => setUserForm((current) => ({ ...current, password: event.target.value }))}
                required
                type="password"
                value={userForm.password}
              />
            </label>
            <label>
              <span>用户角色</span>
              <select
                aria-label="用户角色"
                onChange={(event) => setUserForm((current) => ({ ...current, role: event.target.value }))}
                required
                value={userForm.role}
              >
                {roles
                  .filter((role) => role.name !== "agent")
                  .map((role) => (
                    <option key={role.id} value={role.name}>
                      {role.name}
                    </option>
                  ))}
              </select>
            </label>
            <label className="form-grid-wide">
              <span>产品范围</span>
              <input
                aria-label="产品范围"
                onChange={(event) => setUserForm((current) => ({ ...current, productIds: event.target.value }))}
                value={userForm.productIds}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setCreateUserOpen(false)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={userBusyId === "create"} type="submit">
              创建后台用户
            </button>
          </div>
        </form>
      ) : null}

      {agentKeyOpen ? (
        <form className="panel product-form" onSubmit={(event) => generateAgentConfig(event)}>
          <div className="panel-header">
            <h2>Agent API Key 配置</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>Agent Key ID</span>
              <input
                aria-label="Agent Key ID"
                onChange={(event) => setAgentForm((current) => ({ ...current, id: event.target.value }))}
                required
                value={agentForm.id}
              />
            </label>
            <label>
              <span>Agent Key 名称</span>
              <input
                aria-label="Agent Key 名称"
                onChange={(event) => setAgentForm((current) => ({ ...current, name: event.target.value }))}
                required
                value={agentForm.name}
              />
            </label>
            <label>
              <span>Agent 产品范围</span>
              <input
                aria-label="Agent 产品范围"
                onChange={(event) => setAgentForm((current) => ({ ...current, productIds: event.target.value }))}
                value={agentForm.productIds}
              />
            </label>
            <label>
              <span>Agent Scope 模板</span>
              <select
                aria-label="Agent Scope 模板"
                onChange={(event) => setAgentForm((current) => ({
                  ...current,
                  scopeTemplate: event.target.value as AgentScopeTemplate
                }))}
                value={agentForm.scopeTemplate}
              >
                <option value="feedback_triage">Feedback triage</option>
                <option value="release_draft">Release draft</option>
                <option value="support_read">Support read</option>
                <option value="full_agent">Full agent</option>
              </select>
            </label>
            <label className="form-grid-wide">
              <span>Agent 过期时间</span>
              <input
                aria-label="Agent 过期时间"
                onChange={(event) => setAgentForm((current) => ({ ...current, expiresAt: event.target.value }))}
                value={agentForm.expiresAt}
              />
            </label>
            <label className="form-grid-wide">
              <span>AGENT_API_KEYS_JSON</span>
              <textarea
                aria-label="AGENT_API_KEYS_JSON"
                readOnly
                value={agentConfigJson}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setAgentKeyOpen(false)} type="button">
              关闭
            </button>
            <button className="primary-button" type="submit">
              生成配置
            </button>
          </div>
        </form>
      ) : null}

      {createAgentKeyOpen ? (
        <form className="panel product-form" onSubmit={(event) => void createPersistedAgentKey(event)}>
          <div className="panel-header">
            <h2>新建 Agent Key</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>后台 Agent Key 名称</span>
              <input
                aria-label="后台 Agent Key 名称"
                onChange={(event) => setPersistedAgentKeyForm((current) => ({ ...current, name: event.target.value }))}
                required
                value={persistedAgentKeyForm.name}
              />
            </label>
            <label>
              <span>后台 Agent 产品范围</span>
              <input
                aria-label="后台 Agent 产品范围"
                onChange={(event) => setPersistedAgentKeyForm((current) => ({ ...current, productIds: event.target.value }))}
                value={persistedAgentKeyForm.productIds}
              />
            </label>
            <label className="form-grid-wide">
              <span>后台 Agent Scopes</span>
              <input
                aria-label="后台 Agent Scopes"
                onChange={(event) => setPersistedAgentKeyForm((current) => ({ ...current, scopes: event.target.value }))}
                required
                value={persistedAgentKeyForm.scopes}
              />
            </label>
            <label className="form-grid-wide">
              <span>后台 Agent 过期时间</span>
              <input
                aria-label="后台 Agent 过期时间"
                onChange={(event) => setPersistedAgentKeyForm((current) => ({ ...current, expiresAt: event.target.value }))}
                value={persistedAgentKeyForm.expiresAt}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setCreateAgentKeyOpen(false)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={agentKeyBusyId === "create"} type="submit">
              创建 Agent Key
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <div className="panel-header">
          <h2>角色权限</h2>
          <StatusBadge tone="blue">{`${roles.length} Roles`}</StatusBadge>
        </div>
        <DataTable columns={roleColumns} rows={roles} emptyText="暂无角色权限" />
      </section>

      <section className="panel">
        <div className="panel-header">
          <h2>后台用户</h2>
          <StatusBadge tone="blue">{`${users.length} Users`}</StatusBadge>
        </div>
        <DataTable columns={userColumns} rows={users} emptyText="暂无后台用户" />
      </section>

      <section className="panel">
        <div className="panel-header">
          <h2>Agent API Keys</h2>
          <StatusBadge tone="blue">{`${agentKeys.length} Keys`}</StatusBadge>
        </div>
        <DataTable columns={agentKeyColumns} rows={agentKeys} emptyText="暂无 Agent Key" />
      </section>
    </div>
  );
}
