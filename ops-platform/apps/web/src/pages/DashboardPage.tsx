import { useEffect, useState } from "react";
import { demoModeEnabled, opsClient } from "../api/client";
import { dashboard } from "../api/mockData";
import { KpiCard } from "../components/KpiCard";
import { StatusBadge } from "../components/StatusBadge";
import { useProduct } from "../product/ProductContext";

type DashboardAuditEvent = (typeof dashboard.recentAuditEvents)[number];

function auditTarget(event: DashboardAuditEvent) {
  return event.targetId ? `${event.targetType} / ${event.targetId}` : event.targetType;
}

function formatAuditTime(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

export function DashboardPage() {
  const { productId } = useProduct();
  const [error, setError] = useState("");
  const [summary, setSummary] = useState(
    demoModeEnabled()
      ? dashboard
      : {
          ...dashboard,
          currentStableVersion: "-",
          currentBetaVersion: "-",
          todayFeedbackCount: 0,
          unhandledFeedbackCount: 0,
          p0p1BugCount: 0,
          activeLicenseCount: 0,
          expiringLicenseCount: 0,
          latestReleaseStatus: "-",
          githubSyncStatus: "-",
          aiPendingSuggestionCount: 0,
          licenseValidationErrorCount: 0,
          emailDeliveryStatus: {
            queued: 0,
            sent: 0,
            failed: 0,
            dryRun: 0
          },
          recentAuditEvents: []
        }
  );

  useEffect(() => {
    let isMounted = true;
    setError("");
    void opsClient.dashboard(productId).then((data) => {
      if (isMounted) {
        setSummary(data);
        setError("");
      }
    }).catch((nextError: unknown) => {
      if (isMounted) {
        setError(nextError instanceof Error ? nextError.message : "Dashboard 加载失败");
      }
    });
    return () => {
      isMounted = false;
    };
  }, [productId]);

  const deliveryMetrics = [
    { label: "Queued", value: summary.emailDeliveryStatus.queued },
    { label: "Sent", value: summary.emailDeliveryStatus.sent },
    { label: "Failed", value: summary.emailDeliveryStatus.failed },
    { label: "Dry Run", value: summary.emailDeliveryStatus.dryRun }
  ];
  const deliveryTone = summary.emailDeliveryStatus.failed > 0
    ? "red"
    : summary.emailDeliveryStatus.queued > 0
      ? "orange"
      : "green";

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Product Ops</p>
          <h1>工作台</h1>
          <p>统一查看反馈、发布、授权和 AI 待确认动作。</p>
        </div>
        <a className="primary-button" href="/releases?create=1">
          新建发布草稿
        </a>
      </div>
      {error ? <div className="error-banner" role="alert">{error}</div> : null}

      <div className="kpi-grid">
        <KpiCard label="今日反馈" value={summary.todayFeedbackCount} detail="今日 App 与 GitHub 新增" tone="blue" />
        <KpiCard label="未处理反馈" value={summary.unhandledFeedbackCount} detail="含 App 与 GitHub 来源" tone="blue" />
        <KpiCard label="P0/P1 Bug" value={summary.p0p1BugCount} detail="需要实时邮件通知" tone="red" />
        <KpiCard label="Active License" value={summary.activeLicenseCount} detail={`${summary.expiringLicenseCount} 个即将过期`} tone="green" />
        <KpiCard label="License 验证错误" value={summary.licenseValidationErrorCount} detail="最近失败校验需要排查" tone="red" />
        <KpiCard label="AI 待确认" value={summary.aiPendingSuggestionCount} detail="草稿和建议均需人工采纳" tone="orange" />
      </div>

      <div className="content-grid">
        <section className="panel">
          <div className="panel-header">
            <h2>发布状态</h2>
            <StatusBadge tone="blue">Manual Confirm</StatusBadge>
          </div>
          <div className="release-status">
            <div>
              <span>Stable</span>
              <strong>{summary.currentStableVersion}</strong>
            </div>
            <div>
              <span>Beta</span>
              <strong>{summary.currentBetaVersion}</strong>
            </div>
            <div>
              <span>Latest Draft</span>
              <strong>{summary.latestReleaseStatus}</strong>
            </div>
          </div>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>系统信号</h2>
            <StatusBadge tone="green">Healthy</StatusBadge>
          </div>
          <ul className="signal-list">
            <li>GitHub Issues 同步状态：{summary.githubSyncStatus}</li>
            <li>邮件失败：{summary.emailDeliveryStatus.failed}</li>
            <li>License 验证错误：{summary.licenseValidationErrorCount}</li>
          </ul>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>邮件投递</h2>
            <StatusBadge tone={deliveryTone}>SMTP</StatusBadge>
          </div>
          <div className="delivery-status-list">
            {deliveryMetrics.map((item) => (
              <div key={item.label}>
                <span>{item.label}</span>
                <strong>{item.value}</strong>
              </div>
            ))}
          </div>
        </section>

        <section className="panel">
          <div className="panel-header">
            <h2>最近审计</h2>
            <StatusBadge tone="gray">Latest</StatusBadge>
          </div>
          {summary.recentAuditEvents.length > 0 ? (
            <ul className="audit-mini-list">
              {summary.recentAuditEvents.map((event) => (
                <li key={event.id}>
                  <div>
                    <strong>{event.action}</strong>
                    <span>{auditTarget(event)}</span>
                  </div>
                  <time>{formatAuditTime(event.createdAt)}</time>
                </li>
              ))}
            </ul>
          ) : (
            <p className="empty-copy">暂无审计事件</p>
          )}
        </section>
      </div>
    </div>
  );
}
