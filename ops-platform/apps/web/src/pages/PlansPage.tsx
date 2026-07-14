import { useEffect, useState, type FormEvent } from "react";
import {
  opsClient,
  type PlanInput,
  type PlanRecord,
  type PlanUpdateInput
} from "../api/client";
import { DataTable, type DataColumn } from "../components/DataTable";
import { StatusBadge } from "../components/StatusBadge";
import { useProductSelection } from "../product/ProductContext";

interface PlanFormState {
  id: string;
  name: string;
  description: string;
  maxDevices: string;
  maxSeats: string;
  trialDays: string;
  offlineGraceDays: string;
  allowedChannels: string;
  supportedVersionRange: string;
  entitlements: string;
  paymentProvider: string;
  providerPlanId: string;
  priceMinor: string;
  currency: string;
  billingInterval: "" | "month" | "year" | "one_time";
  couponSupport: boolean;
  subscriptionSupport: boolean;
  status: "active" | "disabled";
}

const emptyForm: PlanFormState = {
  id: "",
  name: "",
  description: "",
  maxDevices: "1",
  maxSeats: "1",
  trialDays: "0",
  offlineGraceDays: "14",
  allowedChannels: "stable",
  supportedVersionRange: "",
  entitlements: "",
  paymentProvider: "",
  providerPlanId: "",
  priceMinor: "",
  currency: "",
  billingInterval: "",
  couponSupport: false,
  subscriptionSupport: false,
  status: "active"
};

function splitList(value: string) {
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function formFromPlan(plan: PlanRecord): PlanFormState {
  return {
    id: plan.id,
    name: plan.name,
    description: plan.description ?? "",
    maxDevices: String(plan.maxDevices),
    maxSeats: String(plan.maxSeats),
    trialDays: String(plan.trialDays),
    offlineGraceDays: String(plan.offlineGraceDays),
    allowedChannels: plan.allowedChannels.join(", "),
    supportedVersionRange: plan.supportedVersionRange ?? "",
    entitlements: plan.entitlements.join(", "),
    paymentProvider: plan.paymentProvider ?? "",
    providerPlanId: plan.providerPlanId ?? "",
    priceMinor: plan.priceMinor === undefined ? "" : String(plan.priceMinor),
    currency: plan.currency ?? "",
    billingInterval:
      plan.billingInterval === "month" ||
      plan.billingInterval === "year" ||
      plan.billingInterval === "one_time"
        ? plan.billingInterval
        : "",
    couponSupport: plan.couponSupport ?? false,
    subscriptionSupport: plan.subscriptionSupport ?? false,
    status: plan.status === "disabled" ? "disabled" : "active"
  };
}

export function PlansPage() {
  const { products, productId, setProductId } = useProductSelection();
  const [rows, setRows] = useState<PlanRecord[]>([]);
  const [formMode, setFormMode] = useState<"create" | "edit" | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<PlanFormState>(emptyForm);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    setFormMode(null);
    setEditingId(null);
    setMessage("");
  }, [productId]);

  useEffect(() => {
    let mounted = true;
    setError("");
    void opsClient
      .plans(productId)
      .then((items) => {
        if (mounted) setRows(items);
      })
      .catch((nextError: unknown) => {
        if (mounted) setError(nextError instanceof Error ? nextError.message : "套餐加载失败");
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

  function startEdit(plan: PlanRecord) {
    setFormMode("edit");
    setEditingId(plan.id);
    setForm(formFromPlan(plan));
    setError("");
    setMessage("");
  }

  function replacePlan(plan: PlanRecord) {
    setRows((current) => [
      ...current.filter((candidate) => candidate.id !== plan.id),
      plan
    ].sort((left, right) => left.name.localeCompare(right.name)));
  }

  function payloadFromForm(): PlanInput {
    return {
      id: form.id.trim(),
      name: form.name.trim(),
      description: form.description.trim() || undefined,
      maxDevices: Number(form.maxDevices),
      maxSeats: Number(form.maxSeats),
      trialDays: Number(form.trialDays),
      offlineGraceDays: Number(form.offlineGraceDays),
      allowedChannels: splitList(form.allowedChannels),
      supportedVersionRange: form.supportedVersionRange.trim() || undefined,
      entitlements: splitList(form.entitlements),
      paymentProvider: form.paymentProvider.trim() || undefined,
      providerPlanId: form.providerPlanId.trim() || undefined,
      priceMinor: form.priceMinor ? Number(form.priceMinor) : undefined,
      currency: form.currency.trim() || undefined,
      billingInterval: form.billingInterval || undefined,
      couponSupport: form.couponSupport,
      subscriptionSupport: form.subscriptionSupport,
      status: form.status
    };
  }

  async function savePlan(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusyId(editingId ?? "create");
    setError("");
    setMessage("");
    try {
      const payload = payloadFromForm();
      const plan =
        formMode === "edit" && editingId
          ? await opsClient.updatePlan(
              productId,
              editingId,
              (({ id: _id, ...update }) => update)(payload) as PlanUpdateInput
            )
          : await opsClient.createPlan(productId, payload);
      replacePlan(plan);
      setFormMode(null);
      setEditingId(null);
      setMessage(formMode === "edit" ? "套餐已更新。" : "套餐已创建。");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "套餐保存失败");
    } finally {
      setBusyId(null);
    }
  }

  async function archivePlan(plan: PlanRecord) {
    const confirmation = window.prompt(
      `请输入 ARCHIVE，归档套餐 ${plan.name}。现有 License 不会被自动删除。`
    );
    if (confirmation !== "ARCHIVE") return;
    setBusyId(plan.id);
    setError("");
    try {
      replacePlan(await opsClient.archivePlan(productId, plan.id));
      setMessage(`${plan.name} 已归档。`);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "套餐归档失败");
    } finally {
      setBusyId(null);
    }
  }

  const columns: DataColumn<PlanRecord>[] = [
    {
      key: "name",
      title: "套餐",
      render: (row) => (
        <div>
          <strong>{row.name}</strong>
          <p className="table-subtext mono-text">{row.id}</p>
        </div>
      )
    },
    {
      key: "status",
      title: "状态",
      render: (row) => (
        <StatusBadge tone={row.status === "active" ? "green" : "gray"}>
          {row.status}
        </StatusBadge>
      )
    },
    { key: "devices", title: "设备", render: (row) => row.maxDevices },
    { key: "seats", title: "席位", render: (row) => row.maxSeats },
    { key: "trial", title: "试用", render: (row) => `${row.trialDays} 天` },
    {
      key: "offlineGrace",
      title: "离线授权",
      render: (row) => `${row.offlineGraceDays} 天`
    },
    {
      key: "channels",
      title: "渠道",
      render: (row) => row.allowedChannels.join(", ") || "-"
    },
    {
      key: "entitlements",
      title: "Entitlements",
      render: (row) => row.entitlements.join(", ") || "-"
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
            aria-label={`归档 ${row.name}`}
            className="danger-button"
            disabled={busyId === row.id || row.status === "archived"}
            onClick={() => void archivePlan(row)}
            type="button"
          >
            归档
          </button>
        </div>
      )
    }
  ];

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Plans</p>
          <h1>订阅计划</h1>
          <p>定义 License 配额、离线宽限期、发布渠道与功能权益。</p>
        </div>
        <button className="secondary-button" onClick={startCreate} type="button">
          新建套餐
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
        <strong>License 策略</strong>
        <span>设备指纹只用于激活和风险判断；归档套餐不会自动撤销已签发 License。</span>
      </section>

      {error ? <p className="form-error">{error}</p> : null}
      {message ? <p className="action-message">{message}</p> : null}

      {formMode ? (
        <form className="panel product-form" onSubmit={(event) => void savePlan(event)}>
          <div className="panel-header">
            <h2>{formMode === "create" ? "新建套餐" : `编辑 ${form.name}`}</h2>
          </div>
          <div className="form-grid">
            <label>
              <span>套餐 ID</span>
              <input
                aria-label="套餐 ID"
                disabled={formMode === "edit"}
                onChange={(event) => setForm((current) => ({ ...current, id: event.target.value }))}
                pattern="[a-z0-9][a-z0-9_-]{2,63}"
                required
                value={form.id}
              />
            </label>
            <label>
              <span>套餐名称</span>
              <input
                aria-label="套餐名称"
                onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))}
                required
                value={form.name}
              />
            </label>
            <label>
              <span>最大设备数</span>
              <input
                aria-label="最大设备数"
                min="1"
                onChange={(event) => setForm((current) => ({ ...current, maxDevices: event.target.value }))}
                required
                type="number"
                value={form.maxDevices}
              />
            </label>
            <label>
              <span>最大席位</span>
              <input
                aria-label="最大席位"
                min="1"
                onChange={(event) => setForm((current) => ({ ...current, maxSeats: event.target.value }))}
                required
                type="number"
                value={form.maxSeats}
              />
            </label>
            <label>
              <span>试用天数</span>
              <input
                aria-label="试用天数"
                min="0"
                onChange={(event) => setForm((current) => ({ ...current, trialDays: event.target.value }))}
                required
                type="number"
                value={form.trialDays}
              />
            </label>
            <label>
              <span>离线宽限天数</span>
              <input
                aria-label="离线宽限天数"
                min="1"
                onChange={(event) => setForm((current) => ({ ...current, offlineGraceDays: event.target.value }))}
                required
                type="number"
                value={form.offlineGraceDays}
              />
            </label>
            <label>
              <span>可用渠道</span>
              <input
                aria-label="可用渠道"
                onChange={(event) => setForm((current) => ({ ...current, allowedChannels: event.target.value }))}
                placeholder="stable, beta"
                required
                value={form.allowedChannels}
              />
            </label>
            <label>
              <span>Entitlements</span>
              <input
                aria-label="Entitlements"
                onChange={(event) => setForm((current) => ({ ...current, entitlements: event.target.value }))}
                placeholder="pro_features, beta_channel"
                value={form.entitlements}
              />
            </label>
            <label>
              <span>支持版本范围</span>
              <input
                onChange={(event) => setForm((current) => ({ ...current, supportedVersionRange: event.target.value }))}
                placeholder=">=0.13.0"
                value={form.supportedVersionRange}
              />
            </label>
            <label>
              <span>支付提供方</span>
              <input
                aria-label="支付提供方"
                onChange={(event) => setForm((current) => ({ ...current, paymentProvider: event.target.value }))}
                placeholder="stripe, paddle, manual"
                value={form.paymentProvider}
              />
            </label>
            <label>
              <span>Provider Plan ID</span>
              <input
                aria-label="Provider Plan ID"
                onChange={(event) => setForm((current) => ({ ...current, providerPlanId: event.target.value }))}
                placeholder="price_pro_monthly"
                value={form.providerPlanId}
              />
            </label>
            <label>
              <span>价格（最小货币单位）</span>
              <input
                aria-label="价格（最小货币单位）"
                min="0"
                onChange={(event) => setForm((current) => ({ ...current, priceMinor: event.target.value }))}
                type="number"
                value={form.priceMinor}
              />
            </label>
            <label>
              <span>币种</span>
              <input
                aria-label="币种"
                onChange={(event) => setForm((current) => ({ ...current, currency: event.target.value.toUpperCase() }))}
                placeholder="CNY"
                value={form.currency}
              />
            </label>
            <label>
              <span>计费周期</span>
              <select
                aria-label="计费周期"
                onChange={(event) =>
                  setForm((current) => ({
                    ...current,
                    billingInterval: event.target.value as PlanFormState["billingInterval"]
                  }))
                }
                value={form.billingInterval}
              >
                <option value="">未配置</option>
                <option value="month">月付</option>
                <option value="year">年付</option>
                <option value="one_time">一次性</option>
              </select>
            </label>
            <label>
              <span>支持优惠券</span>
              <input
                aria-label="支持优惠券"
                checked={form.couponSupport}
                onChange={(event) =>
                  setForm((current) => ({ ...current, couponSupport: event.target.checked }))
                }
                type="checkbox"
              />
            </label>
            <label>
              <span>支持订阅</span>
              <input
                aria-label="支持订阅"
                checked={form.subscriptionSupport}
                onChange={(event) =>
                  setForm((current) => ({ ...current, subscriptionSupport: event.target.checked }))
                }
                type="checkbox"
              />
            </label>
            <label className="form-grid-wide">
              <span>描述</span>
              <textarea
                onChange={(event) => setForm((current) => ({ ...current, description: event.target.value }))}
                value={form.description}
              />
            </label>
          </div>
          <div className="form-actions">
            <button className="secondary-button" onClick={() => setFormMode(null)} type="button">
              取消
            </button>
            <button className="primary-button" disabled={busyId !== null} type="submit">
              保存套餐
            </button>
          </div>
        </form>
      ) : null}

      <section className="panel">
        <DataTable columns={columns} rows={rows} emptyText="暂无套餐" />
      </section>
    </div>
  );
}
