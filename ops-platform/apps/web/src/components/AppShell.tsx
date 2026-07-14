import {
  BadgeDollarSign,
  Bell,
  Box,
  ChartNoAxesCombined,
  GitPullRequest,
  KeyRound,
  LayoutDashboard,
  MessageCircleMore,
  PlugZap,
  ScrollText,
  Search,
  SendHorizontal,
  Settings2,
  Sparkles,
  Tags,
  UserRound,
  UsersRound,
  type LucideIcon
} from "lucide-react";
import type { ReactNode } from "react";
import { useProduct } from "../product/ProductContext";

interface NavItem {
  href: string;
  label: string;
  icon: LucideIcon;
}

const navItems: NavItem[] = [
  { href: "/", label: "工作台", icon: LayoutDashboard },
  { href: "/products", label: "产品管理", icon: Box },
  { href: "/feedback", label: "用户反馈", icon: MessageCircleMore },
  { href: "/github-issues", label: "GitHub 问题", icon: GitPullRequest },
  { href: "/ai-analysis", label: "AI 分析", icon: Sparkles },
  { href: "/releases", label: "版本发布", icon: Tags },
  { href: "/channels", label: "分发渠道", icon: SendHorizontal },
  { href: "/licenses", label: "许可证", icon: KeyRound },
  { href: "/customers", label: "客户管理", icon: UsersRound },
  { href: "/plans", label: "订阅计划", icon: BadgeDollarSign },
  { href: "/notifications", label: "通知中心", icon: Bell },
  { href: "/connectors", label: "连接器", icon: PlugZap },
  { href: "/website-analytics", label: "官网数据", icon: ChartNoAxesCombined },
  { href: "/audit-logs", label: "审计日志", icon: ScrollText }
];

interface AppShellProps {
  activePath: string;
  title: string;
  children: ReactNode;
  onLogout: () => void;
}

export function AppShell({ activePath, title, children, onLogout }: AppShellProps) {
  const { activeProduct, error, loading, productId, products, setProductId } = useProduct();

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand-row">
          <img src="/assets/stacio-logo.png" alt="Stacio" />
          <span>Stacio Ops</span>
        </div>
        <nav aria-label="Main sidebar navigation" className="nav-list">
          {navItems.map((item) => (
            <a key={item.href} href={item.href} className={activePath === item.href ? "nav-item nav-item-active" : "nav-item"}>
              <item.icon aria-hidden="true" className="nav-icon" size={17} strokeWidth={1.8} />
              <span>{item.label}</span>
            </a>
          ))}
          <div className="nav-spacer" />
          <a href="/settings" className={activePath === "/settings" ? "nav-item nav-item-active" : "nav-item nav-item-muted"}>
            <Settings2 aria-hidden="true" className="nav-icon" size={17} strokeWidth={1.8} />
            <span>系统设置</span>
          </a>
        </nav>
      </aside>

      <section className="main-panel">
        <header className="topbar">
          <div className="breadcrumb">
            <span>{activeProduct?.name ?? productId}</span>
            <span>/</span>
            <span>{title}</span>
          </div>
          <label className="search-box">
            <Search aria-hidden="true" size={16} strokeWidth={1.8} />
            <input aria-label="搜索后台" placeholder="反馈、版本、License..." />
          </label>
          <select
            aria-label="当前产品"
            className="product-selector"
            disabled={loading}
            onChange={(event) => setProductId(event.target.value)}
            title={error}
            value={productId}
          >
            {products.length === 0 ? (
              <option value={productId}>{loading ? "加载产品..." : productId}</option>
            ) : null}
            {products.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} · {item.platform}
              </option>
            ))}
          </select>
          <a aria-label="我的账号" className="account-button" href="/account" title="我的账号">
            <UserRound aria-hidden="true" size={17} strokeWidth={1.8} />
          </a>
          <button className="logout-button" onClick={onLogout} type="button">
            退出
          </button>
        </header>
        {children}
      </section>
    </main>
  );
}
