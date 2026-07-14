import { useEffect, useState, type FormEvent } from "react";
import { demoModeEnabled, opsClient, type AuditLogFilters } from "../api/client";
import { auditLogs } from "../api/mockData";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type AuditLogRow = (typeof auditLogs)[number];
type AuditFilter = "all" | "login" | "permission" | "release" | "license" | "system";

interface AuditFilterForm {
  search: string;
  actorType: AuditLogFilters["actorType"];
  actorId: string;
  action: string;
  targetType: string;
  targetId: string;
  ipAddress: string;
  createdFrom: string;
  createdTo: string;
}

const emptyAuditFilters: AuditFilterForm = {
  search: "",
  actorType: "",
  actorId: "",
  action: "",
  targetType: "",
  targetId: "",
  ipAddress: "",
  createdFrom: "",
  createdTo: ""
};

function dateInputValue(value: string) {
  return value.includes("T") ? value.slice(0, 10) : value;
}

function auditFiltersFromLocation(): AuditFilterForm {
  if (typeof window === "undefined") {
    return emptyAuditFilters;
  }
  const parameters = new URLSearchParams(window.location.search);
  const actorType = parameters.get("actorType");
  return {
    search: parameters.get("search") ?? "",
    actorType: ["user", "agent", "system", "public"].includes(actorType ?? "")
      ? actorType as AuditFilterForm["actorType"]
      : "",
    actorId: parameters.get("actorId") ?? "",
    action: parameters.get("action") ?? "",
    targetType: parameters.get("targetType") ?? "",
    targetId: parameters.get("targetId") ?? "",
    ipAddress: parameters.get("ipAddress") ?? "",
    createdFrom: dateInputValue(parameters.get("createdFrom") ?? ""),
    createdTo: dateInputValue(parameters.get("createdTo") ?? "")
  };
}

function toneForAction(action: string) {
  if (action.includes("publish") || action.includes("release")) return "green";
  if (action.includes("license") || action.includes("permission")) return "orange";
  if (action.includes("agent") || action.includes("github")) return "blue";
  return "gray";
}

const columns: DataColumn<AuditLogRow>[] = [
  { key: "time", title: "时间", render: (row) => row.time },
  {
    key: "actor",
    title: "操作者",
    render: (row) => (
      <div>
        <strong>{row.actor}</strong>
        <p className="table-subtext">{row.actorType}</p>
      </div>
    )
  },
  { key: "action", title: "操作", render: (row) => <StatusBadge tone={toneForAction(row.action)}>{row.action}</StatusBadge> },
  {
    key: "target",
    title: "对象",
    render: (row) => (
      <div>
        <strong>{row.target}</strong>
        <p className="table-subtext">{row.detail}</p>
      </div>
    )
  },
  { key: "ip", title: "IP", render: (row) => row.ip }
];

export function AuditLogsPage() {
  const { productId } = useProduct();
  const [rows, setRows] = useState<AuditLogRow[]>(demoModeEnabled() ? auditLogs : []);
  const [filter, setFilter] = useState<AuditFilter>("all");
  const [auditFilters, setAuditFilters] = useState<AuditFilterForm>(auditFiltersFromLocation);
  const [initialAuditFilters] = useState<AuditFilterForm>(auditFiltersFromLocation);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  function buildFilters(form: AuditFilterForm): AuditLogFilters {
    const filters: AuditLogFilters = {};
    for (const key of ["search", "actorId", "action", "targetType", "targetId", "ipAddress"] as const) {
      const value = form[key].trim();
      if (value) {
        filters[key] = value;
      }
    }
    if (form.actorType) {
      filters.actorType = form.actorType;
    }
    if (form.createdFrom) {
      filters.createdFrom = new Date(`${form.createdFrom}T00:00:00.000Z`).toISOString();
    }
    if (form.createdTo) {
      filters.createdTo = new Date(`${form.createdTo}T23:59:59.999Z`).toISOString();
    }
    return filters;
  }

  async function loadRows(nextFilters: AuditLogFilters = {}) {
    setLoading(true);
    setError("");
    try {
      setRows(await opsClient.auditLogs(productId, nextFilters));
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "审计日志加载失败");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    let isMounted = true;
    const initialRequestFilters = buildFilters(initialAuditFilters);
    const request = Object.keys(initialRequestFilters).length > 0
      ? opsClient.auditLogs(productId, initialRequestFilters)
      : opsClient.auditLogs(productId);
    void request.then((items) => {
      if (isMounted) {
        setRows(items);
      }
    }).catch((nextError: unknown) => {
      if (isMounted) {
        setError(nextError instanceof Error ? nextError.message : "审计日志加载失败");
      }
    });
    return () => {
      isMounted = false;
    };
  }, [initialAuditFilters, productId]);

  function updateAuditFilter<K extends keyof AuditFilterForm>(key: K, value: AuditFilterForm[K]) {
    setAuditFilters((current) => ({
      ...current,
      [key]: value
    }));
  }

  function applyAuditFilters(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadRows(buildFilters(auditFilters));
  }

  function resetAuditFilters() {
    setAuditFilters(emptyAuditFilters);
    void loadRows({});
  }

  const filteredRows = rows.filter((row) => {
    const action = row.action.toLowerCase();
    switch (filter) {
      case "login":
        return action.includes("login") || action.includes("auth");
      case "permission":
        return action.includes("permission") || action.includes("role") || action.includes("api_key");
      case "release":
        return action.includes("release") || action.includes("channel");
      case "license":
        return action.includes("license");
      case "system":
        return ["agent", "github", "connector", "notification", "settings", "system"].some(
          (value) => action.includes(value)
        );
      default:
        return true;
    }
  });

  function exportLogs() {
    const escape = (value: string) => `"${value.replaceAll('"', '""')}"`;
    const csv = [
      ["time", "actor", "actorType", "action", "target", "detail", "ip"],
      ...filteredRows.map((row) => [
        row.time,
        row.actor,
        row.actorType,
        row.action,
        row.target,
        row.detail,
        row.ip
      ])
    ]
      .map((line) => line.map((value) => escape(String(value))).join(","))
      .join("\n");
    const blob = new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${productId}-audit-logs.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Audit</p>
          <h1>审计日志</h1>
          <p>记录登录、权限、发布、许可证、GitHub 同步和 Agent 写入等关键动作。</p>
        </div>
        <button className="secondary-button" onClick={exportLogs} type="button">
          导出 CSV
        </button>
      </div>

      <div className="filter-row">
        {([
          ["all", "全部"],
          ["login", "登录"],
          ["permission", "权限"],
          ["release", "发布"],
          ["license", "许可证"],
          ["system", "系统"]
        ] as const).map(([value, label]) => (
          <button
            aria-pressed={filter === value}
            className="filter-button"
            key={value}
            onClick={() => setFilter(value)}
            type="button"
          >
            {label}
          </button>
        ))}
      </div>

      <section className="panel">
        <form className="form-grid" onSubmit={applyAuditFilters}>
          <label className="field-wide">
            <span>搜索审计日志</span>
            <input
              aria-label="搜索审计日志"
              onChange={(event) => updateAuditFilter("search", event.target.value)}
              placeholder="版本号、target、metadata、IP..."
              value={auditFilters.search}
            />
          </label>
          <label>
            <span>操作者类型</span>
            <select
              aria-label="操作者类型"
              onChange={(event) => updateAuditFilter("actorType", event.target.value as AuditFilterForm["actorType"])}
              value={auditFilters.actorType}
            >
              <option value="">全部</option>
              <option value="user">User</option>
              <option value="agent">Agent</option>
              <option value="system">System</option>
              <option value="public">Public</option>
            </select>
          </label>
          <label>
            <span>操作者 ID</span>
            <input
              aria-label="操作者 ID"
              onChange={(event) => updateAuditFilter("actorId", event.target.value)}
              placeholder="usr_..."
              value={auditFilters.actorId}
            />
          </label>
          <label>
            <span>操作类型</span>
            <input
              aria-label="操作类型"
              onChange={(event) => updateAuditFilter("action", event.target.value)}
              placeholder="release.publish"
              value={auditFilters.action}
            />
          </label>
          <label>
            <span>目标类型</span>
            <input
              aria-label="目标类型"
              onChange={(event) => updateAuditFilter("targetType", event.target.value)}
              placeholder="release"
              value={auditFilters.targetType}
            />
          </label>
          <label>
            <span>目标 ID</span>
            <input
              aria-label="目标 ID"
              onChange={(event) => updateAuditFilter("targetId", event.target.value)}
              placeholder="rel_..."
              value={auditFilters.targetId}
            />
          </label>
          <label>
            <span>IP 地址</span>
            <input
              aria-label="IP 地址"
              onChange={(event) => updateAuditFilter("ipAddress", event.target.value)}
              placeholder="203.0.113.10"
              value={auditFilters.ipAddress}
            />
          </label>
          <label>
            <span>开始时间</span>
            <input
              aria-label="开始时间"
              onChange={(event) => updateAuditFilter("createdFrom", event.target.value)}
              type="date"
              value={auditFilters.createdFrom}
            />
          </label>
          <label>
            <span>结束时间</span>
            <input
              aria-label="结束时间"
              onChange={(event) => updateAuditFilter("createdTo", event.target.value)}
              type="date"
              value={auditFilters.createdTo}
            />
          </label>
          <div className="inline-actions field-wide">
            <button className="primary-button" disabled={loading} type="submit">
              应用筛选
            </button>
            <button className="secondary-button" disabled={loading} onClick={resetAuditFilters} type="button">
              重置
            </button>
          </div>
        </form>
        {error ? <p className="error-text">{error}</p> : null}
      </section>

      <section className="panel">
        <div className="panel-header">
          <h2>事件明细</h2>
          <StatusBadge tone="blue">{`${filteredRows.length} Events`}</StatusBadge>
        </div>
        <DataTable columns={columns} rows={filteredRows} emptyText="暂无审计日志" />
      </section>
    </div>
  );
}
