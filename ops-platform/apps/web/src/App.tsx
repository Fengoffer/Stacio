import { useState } from "react";
import { getAuthToken, opsClient } from "./api/client";
import { AppShell } from "./components/AppShell";
import { AiAnalysisPage } from "./pages/AiAnalysisPage";
import { AccountPage } from "./pages/AccountPage";
import { AuditLogsPage } from "./pages/AuditLogsPage";
import { ChannelsPage } from "./pages/ChannelsPage";
import { ConnectorsPage } from "./pages/ConnectorsPage";
import { CustomersPage } from "./pages/CustomersPage";
import { DashboardPage } from "./pages/DashboardPage";
import { FeedbackPage } from "./pages/FeedbackPage";
import { GitHubIssuesPage } from "./pages/GitHubIssuesPage";
import { LicensesPage } from "./pages/LicensesPage";
import { LoginPage } from "./pages/LoginPage";
import { NotificationsPage } from "./pages/NotificationsPage";
import { PlansPage } from "./pages/PlansPage";
import { ProductsPage } from "./pages/ProductsPage";
import { ReleasesPage } from "./pages/ReleasesPage";
import { SettingsPage } from "./pages/SettingsPage";
import { WebsiteAnalyticsPage } from "./pages/WebsiteAnalyticsPage";
import { ProductProvider } from "./product/ProductContext";

function currentPath() {
  if (typeof window === "undefined") {
    return "/";
  }
  return window.location.pathname === "" ? "/" : window.location.pathname;
}

function pageFor(path: string, onReauthenticationRequired: () => void) {
  switch (path) {
    case "/":
      return { title: "工作台", content: <DashboardPage /> };
    case "/feedback":
      return { title: "用户反馈", content: <FeedbackPage /> };
    case "/releases":
      return { title: "版本发布", content: <ReleasesPage /> };
    case "/licenses":
      return { title: "许可证", content: <LicensesPage /> };
    case "/products":
      return { title: "产品管理", content: <ProductsPage /> };
    case "/github-issues":
      return { title: "GitHub 问题", content: <GitHubIssuesPage /> };
    case "/ai-analysis":
      return { title: "AI 分析", content: <AiAnalysisPage /> };
    case "/channels":
      return { title: "分发渠道", content: <ChannelsPage /> };
    case "/customers":
      return { title: "客户管理", content: <CustomersPage /> };
    case "/plans":
      return { title: "订阅计划", content: <PlansPage /> };
    case "/notifications":
      return { title: "通知中心", content: <NotificationsPage /> };
    case "/connectors":
      return { title: "连接器", content: <ConnectorsPage /> };
    case "/website-analytics":
      return { title: "官网数据", content: <WebsiteAnalyticsPage /> };
    case "/audit-logs":
      return { title: "审计日志", content: <AuditLogsPage /> };
    case "/account":
      return { title: "我的账号", content: <AccountPage onReauthenticationRequired={onReauthenticationRequired} /> };
    case "/settings":
      return { title: "系统设置", content: <SettingsPage /> };
    default:
      return { title: "工作台", content: <DashboardPage /> };
  }
}

export function App() {
  const [token, setToken] = useState(() => getAuthToken());
  const path = currentPath();
  const logout = () => {
    void opsClient.logout();
    setToken(null);
  };
  const page = pageFor(path, logout);

  if (!token) {
    return <LoginPage onLogin={() => setToken(getAuthToken())} />;
  }

  return (
    <ProductProvider>
      <AppShell
        activePath={path}
        title={page.title}
        onLogout={logout}
      >
        {page.content}
      </AppShell>
    </ProductProvider>
  );
}
