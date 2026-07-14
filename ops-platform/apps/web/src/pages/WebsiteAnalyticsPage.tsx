import { useEffect, useMemo, useState } from "react";
import {
  type GitHubDownloadMetricsRecord,
  type WebsiteAnalyticsRecord,
  type WebsiteAnalyticsRange,
  opsClient
} from "../api/client";
import { DataTable, type DataColumn } from "../components/DataTable";
import { KpiCard } from "../components/KpiCard";
import { useProductSelection } from "../product/ProductContext";

const emptyAnalytics: WebsiteAnalyticsRecord = {
  overview: {
    pageViews: 0,
    uniqueVisitors: 0,
    downloadRequests: 0,
    uniqueDownloaders: 0
  },
  browsers: [],
  operatingSystems: [],
  devices: [],
  recentEvents: []
};

const emptyGitHubMetrics: GitHubDownloadMetricsRecord = {
  fetchedAt: new Date(0).toISOString(),
  sourceArchiveDetailAvailable: false,
  releases: []
};

const analyticsRangeOptions: Array<{ value: WebsiteAnalyticsRange; label: string }> = [
  { value: "24h", label: "24 小时" },
  { value: "7d", label: "7 天" },
  { value: "30d", label: "30 天" },
  { value: "90d", label: "90 天" },
  { value: "180d", label: "180 天" },
  { value: "1y", label: "1 年" },
  { value: "all", label: "全部时间" }
];

function eventLabel(type: string) {
  const labels: Record<string, string> = {
    page_view: "页面访问",
    download_requested: "下载点击",
    download_redirected: "下载跳转",
    github_release_clicked: "GitHub Release",
    github_asset_clicked: "GitHub Asset"
  };
  return labels[type] ?? type;
}

function displayTime(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(new Date(value));
}

function DimensionList({ title, items }: { title: string; items: Array<{ name: string; count: number }> }) {
  return (
    <section className="panel analytics-dimension-panel">
      <div className="panel-header">
        <h2>{title}</h2>
      </div>
      {items.length > 0 ? (
        <ul className="analytics-dimension-list">
          {items.slice(0, 8).map((item) => (
            <li key={item.name}>
              <span>{item.name}</span>
              <strong>{item.count}</strong>
            </li>
          ))}
        </ul>
      ) : (
        <p className="empty-copy">暂无数据</p>
      )}
    </section>
  );
}

export function WebsiteAnalyticsPage() {
  const { productId } = useProductSelection();
  const [range, setRange] = useState<WebsiteAnalyticsRange>("24h");
  const [analytics, setAnalytics] = useState<WebsiteAnalyticsRecord>(emptyAnalytics);
  const [githubMetrics, setGitHubMetrics] = useState<GitHubDownloadMetricsRecord>(emptyGitHubMetrics);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    async function load() {
      try {
        const result = await opsClient.websiteAnalytics(productId, range);
        if (active) {
          setAnalytics(result);
          setError("");
        }
      } catch (caught) {
        if (active) {
          setError(caught instanceof Error ? caught.message : "官网数据加载失败");
        }
      }
    }
    void load();
    const timer = window.setInterval(() => void load(), 15_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [productId, range]);

  useEffect(() => {
    let active = true;
    void opsClient.githubDownloadMetrics(productId).then((result) => {
      if (active) setGitHubMetrics(result);
    }).catch(() => {
      if (active) setGitHubMetrics(emptyGitHubMetrics);
    });
    return () => {
      active = false;
    };
  }, [productId]);

  const columns = useMemo<DataColumn<WebsiteAnalyticsRecord["recentEvents"][number]>[]>(
    () => [
      { key: "occurredAt", title: "时间", render: (event) => displayTime(event.occurredAt) },
      { key: "type", title: "事件", render: (event) => eventLabel(event.type) },
      { key: "path", title: "页面 / 下载", render: (event) => event.path },
      { key: "client", title: "客户端", render: (event) => `${event.browserName} · ${event.operatingSystem}` },
      { key: "device", title: "设备", render: (event) => `${event.deviceType}${event.architecture ? ` · ${event.architecture}` : ""}` },
      { key: "ip", title: "IP", render: (event) => event.ipAddress }
    ],
    []
  );

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Website Analytics</p>
          <h1>官网数据</h1>
          <p>实时汇总官网访问、下载发起与客户端环境，IP 仅展示匿名网段。</p>
        </div>
        <label className="product-switcher analytics-range-picker">
          <span>统计范围</span>
          <select aria-label="统计范围" onChange={(event) => setRange(event.target.value as WebsiteAnalyticsRange)} value={range}>
            {analyticsRangeOptions.map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </label>
      </div>
      {error ? <div className="error-banner" role="alert">{error}</div> : null}

      <div className="kpi-grid analytics-kpi-grid">
        <KpiCard label="页面访问" value={analytics.overview.pageViews} detail="指定时间范围内 page view" tone="blue" />
        <KpiCard label="独立访客" value={analytics.overview.uniqueVisitors} detail="匿名访客哈希去重" tone="green" />
        <KpiCard label="官网下载安装" value={analytics.overview.downloadRequests} detail="受控下载跳转与点击" tone="orange" />
        <KpiCard label="独立下载者" value={analytics.overview.uniqueDownloaders} detail="匿名访客哈希去重" tone="blue" />
      </div>

      <div className="analytics-dimension-grid">
        <DimensionList title="浏览器" items={analytics.browsers} />
        <DimensionList title="操作系统" items={analytics.operatingSystems} />
        <DimensionList title="设备类型" items={analytics.devices} />
      </div>

      <section className="panel">
        <div className="panel-header">
          <div>
            <h2>最近官网事件</h2>
            <p>下载完成情况以对象存储/CDN 访问日志为准。</p>
          </div>
        </div>
        <DataTable columns={columns} emptyText="当前范围内暂无官网事件" rows={analytics.recentEvents} />
      </section>

      <section className="panel github-distribution-panel">
        <div className="panel-header">
          <div>
            <h2>GitHub 分发</h2>
            <p>GitHub 官方仅提供 Release Asset 聚合下载次数，数据更新时间：{displayTime(githubMetrics.fetchedAt)}</p>
          </div>
        </div>
        {githubMetrics.releases.length > 0 ? (
          <div className="validation-list">
            {githubMetrics.releases.flatMap((release) => release.assets.map((asset) => (
              <div className="validation-row" key={`${release.tagName}:${asset.id}`}>
                <div>
                  <strong>{asset.name}</strong>
                  <p>{release.tagName} · GitHub Asset 下载 {asset.downloadCount}</p>
                </div>
              </div>
            )))}
          </div>
        ) : (
          <p className="empty-copy">GitHub Release 指标暂不可用，请检查 GitHub 连接器配置。</p>
        )}
        {!githubMetrics.sourceArchiveDetailAvailable ? (
          <p className="table-subtext">GitHub 不提供源码包的单次下载明细或访客设备信息。</p>
        ) : null}
      </section>
    </div>
  );
}
