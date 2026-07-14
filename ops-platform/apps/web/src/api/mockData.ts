export const product = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  supportEmail: "support@stacio.dev",
  currentStableVersion: "0.13.1-Beta",
  currentBetaVersion: "0.13.2-Beta",
  status: "active"
};

export const dashboard = {
  productId: "stacio",
  currentStableVersion: "0.13.1-Beta",
  currentBetaVersion: "0.13.2-Beta",
  todayFeedbackCount: 18,
  unhandledFeedbackCount: 7,
  p0p1BugCount: 2,
  activeLicenseCount: 126,
  expiringLicenseCount: 9,
  latestReleaseStatus: "ready",
  githubSyncStatus: "healthy",
  aiPendingSuggestionCount: 6,
  licenseValidationErrorCount: 3,
  emailDeliveryStatus: {
    queued: 4,
    sent: 18,
    failed: 1,
    dryRun: 2
  },
  recentAuditEvents: [
    {
      id: "audit_001",
      actorType: "user",
      actorId: "usr_bootstrap_owner",
      action: "github.sync",
      targetType: "github_sync_run",
      targetId: "ghrun_001",
      productId: "stacio",
      metadata: {
        changed: 2
      },
      createdAt: "2026-07-10T10:20:00.000Z"
    },
    {
      id: "audit_002",
      actorType: "agent",
      actorId: "codex",
      action: "agent.analysis_written",
      targetType: "feedback",
      targetId: "fb_001",
      productId: "stacio",
      metadata: {
        analysisType: "triage"
      },
      createdAt: "2026-07-10T10:10:00.000Z"
    }
  ]
};

export const feedbackItems = [
  {
    id: "fb_001",
    title: "远端编辑器保存后偶发失败",
    type: "Bug",
    status: "New",
    priority: "P1",
    source: "App",
    version: "0.13.2-Beta",
    user: "ops-user@example.com",
    aiSummary: "SSH 重连后可能未刷新远端文件 revision。",
    updatedAt: "10 分钟前"
  },
  {
    id: "fb_002",
    title: "希望设备看板支持自定义刷新频率",
    type: "Feature",
    status: "Triaged",
    priority: "P2",
    source: "GitHub",
    version: "0.13.1-Beta",
    user: "github-user",
    aiSummary: "可合并到 metrics settings。",
    updatedAt: "38 分钟前"
  },
  {
    id: "fb_003",
    title: "License 离线授权文案需要更清楚",
    type: "License",
    status: "Waiting",
    priority: "P2",
    source: "Email",
    version: "0.13.1-Beta",
    user: "pro@example.com",
    aiSummary: "客户需要明确 14 天离线宽限逻辑。",
    updatedAt: "1 小时前"
  }
];

export const releases = [
  {
    id: "rel_002",
    version: "0.13.2-Beta",
    build: "12",
    channel: "beta",
    status: "Ready",
    artifact: "Stacio-0.13.2-Beta.dmg",
    aiReleaseSummary: "Beta 修复集中在远端文件保存和设备指标刷新。",
    aiRiskSummary: "需确认 Sparkle 签名和最低系统版本。",
    checks: "12/12",
    updatedAt: "刚刚"
  },
  {
    id: "rel_001",
    version: "0.13.1-Beta",
    build: "10",
    channel: "stable",
    status: "Published",
    artifact: "Stacio-0.13.1-Beta.dmg",
    aiReleaseSummary: "已发布的稳定 Beta 构建。",
    aiRiskSummary: "",
    checks: "12/12",
    updatedAt: "昨天"
  }
];

export const licenses = [
  {
    id: "lic_001",
    customer: "Internal Tester",
    email: "tester@example.com",
    plan: "Internal",
    status: "Active",
    devices: "3/5",
    expires: "2027-07-09"
  },
  {
    id: "lic_002",
    customer: "Pro User",
    email: "pro@example.com",
    plan: "Pro",
    status: "Trial",
    devices: "1/2",
    expires: "2026-08-09"
  }
];

export const githubIssues = [
  {
    id: "ghi_001",
    number: 42,
    title: "远端编辑器保存后偶发失败",
    labels: ["bug", "priority:p1"],
    author: "ops-user",
    state: "open",
    comments: 4,
    linkedFeedback: "fb_001",
    url: "https://github.com/stacio-app/desktop/issues/42",
    updatedAt: "10 分钟前"
  },
  {
    id: "ghi_002",
    number: 38,
    title: "希望设备看板支持自定义刷新频率",
    labels: ["enhancement", "metrics"],
    author: "github-user",
    state: "open",
    comments: 2,
    linkedFeedback: "fb_002",
    url: "https://github.com/stacio-app/desktop/issues/38",
    updatedAt: "38 分钟前"
  }
];

export const githubSyncRuns = [
  {
    id: "ghrun_001",
    trigger: "manual",
    status: "success",
    fetched: 2,
    changed: 2,
    feedbackCreated: 2,
    error: undefined,
    finishedAt: "10 分钟前"
  }
];

export const aiAnalyses = [
  {
    id: "ai_001",
    target: "feedback / fb_001",
    agent: "codex",
    model: "gpt-5",
    analysisType: "triage",
    summary: "疑似 SSH 重连后远端 revision 未刷新，建议作为 P1 bug 处理。",
    classification: "bug",
    inputReferencesPreview: "feedbackId: fb_001, source: app",
    outputBodyPreview: "summary: 疑似 SSH 重连后远端 revision 未刷新，classification: bug",
    confidence: "0.91",
    adoptionState: "pending",
    createdAt: "10 分钟前"
  },
  {
    id: "ai_002",
    target: "release / rel_002",
    agent: "claude",
    model: "sonnet",
    analysisType: "release_risk",
    summary: "Beta 发布风险较低，但建议在发布说明中强调远端编辑器修复范围。",
    classification: "release",
    inputReferencesPreview: "releaseId: rel_002, channel: beta",
    outputBodyPreview: "riskSummary: Beta 发布风险较低, classification: release",
    confidence: "0.86",
    adoptionState: "accepted",
    createdAt: "昨天"
  }
];

export const aiProposedActions = [
  {
    id: "act_001",
    actionType: "feedback.update_status",
    target: "feedback / fb_001",
    payloadPreview: "status: in_progress, priority: P1",
    rationale: "保存失败影响远端编辑器核心链路，建议进入处理状态。",
    agent: "codex",
    model: "gpt-5",
    status: "pending",
    createdAt: "刚刚"
  }
];

export const notificationTemplates = [
  {
    id: "tmpl_feedback_reply",
    type: "feedback_reply",
    subject: "Stacio 已收到你的反馈: {{feedback.title}}",
    status: "active",
    updatedAt: "昨天",
    htmlTemplate: "<h1>{{brand.name}}</h1><p>{{reply.body}}</p>",
    textTemplate: "{{reply.body}}"
  },
  {
    id: "tmpl_customer_license_issued",
    type: "customer_license_issued",
    subject: "你的 Stacio 许可证已开通",
    status: "active",
    updatedAt: "昨天",
    htmlTemplate: "<h1>欢迎使用 Stacio</h1><p>{{license.plan}}</p>",
    textTemplate: "欢迎使用 Stacio {{license.plan}}"
  }
];

export const notifications = [
  {
    id: "ntf_001",
    type: "feedback_reply",
    recipient: "ops-user@example.com",
    summary: "反馈回复邮件等待发送",
    status: "queued",
    priority: "high",
    createdAt: "10 分钟前"
  },
  {
    id: "ntf_002",
    type: "customer_license_issued",
    recipient: "pro@example.com",
    summary: "Pro 许可证开通通知已发送",
    status: "sent",
    priority: "normal",
    createdAt: "昨天"
  }
];

export const auditLogs = [
  {
    id: "audit_001",
    time: "刚刚",
    actor: "usr_bootstrap_owner",
    actorType: "user",
    action: "github.sync",
    target: "github_sync_run / ghrun_001",
    detail: "changed: 2",
    ip: "127.0.0.1"
  },
  {
    id: "audit_002",
    time: "10 分钟前",
    actor: "codex",
    actorType: "agent",
    action: "agent.analysis_written",
    target: "feedback / fb_001",
    detail: "analysisType: triage",
    ip: "-"
  }
];

export const releaseChannels = [
  {
    id: "channel_stacio_stable",
    name: "stable",
    status: "active",
    rollout: "100%",
    appcast: "/updates/stacio/stable/appcast.xml",
    autoDownload: "No",
    forcePrompt: "No",
    plans: "Free, Pro, Team, Internal"
  },
  {
    id: "channel_stacio_beta",
    name: "beta",
    status: "active",
    rollout: "100%",
    appcast: "/updates/stacio/beta/appcast.xml",
    autoDownload: "No",
    forcePrompt: "No",
    plans: "Pro, Team, Internal"
  },
  {
    id: "channel_stacio_internal",
    name: "internal",
    status: "active",
    rollout: "100%",
    appcast: "/updates/stacio/internal/appcast.xml",
    autoDownload: "No",
    forcePrompt: "No",
    plans: "Internal"
  }
];

export const customers = [
  {
    id: "cust_internal_tester",
    name: "Internal Tester",
    email: "tester@example.com",
    company: "Stacio",
    status: "active",
    risk: "Normal",
    createdAt: "2026-07-09"
  },
  {
    id: "cust_pro_user",
    name: "Pro User",
    email: "pro@example.com",
    company: "-",
    status: "active",
    risk: "Normal",
    createdAt: "2026-07-09"
  }
];

export const plans = [
  {
    id: "plan_free",
    name: "Free",
    status: "active",
    devices: "1",
    seats: "1",
    trial: "0 天",
    offlineGrace: "14 天",
    channels: "stable"
  },
  {
    id: "plan_pro",
    name: "Pro",
    status: "active",
    devices: "2",
    seats: "1",
    trial: "14 天",
    offlineGrace: "14 天",
    channels: "stable, beta"
  },
  {
    id: "plan_team",
    name: "Team",
    status: "active",
    devices: "20",
    seats: "10",
    trial: "14 天",
    offlineGrace: "30 天",
    channels: "stable, beta"
  }
];

export const connectors = [
  {
    id: "conn_github",
    type: "github",
    name: "GitHub Issues",
    status: "unconfigured",
    detail: "read_only_sync",
    lastSuccess: "-"
  },
  {
    id: "conn_smtp",
    type: "smtp",
    name: "Feishu SMTP",
    status: "unconfigured",
    detail: "smtp",
    lastSuccess: "-"
  },
  {
    id: "conn_object_storage",
    type: "object_storage",
    name: "Object Storage",
    status: "unconfigured",
    detail: "products/stacio",
    lastSuccess: "-"
  },
  {
    id: "conn_agent_api",
    type: "agent_api",
    name: "Agent API",
    status: "unconfigured",
    detail: "dangerousActions=blocked",
    lastSuccess: "-"
  },
  {
    id: "conn_webhook",
    type: "webhook",
    name: "Webhook",
    status: "unconfigured",
    detail: "outbound-events",
    lastSuccess: "-"
  }
];

export const settingsSummary = {
  productId: "stacio",
  persistence: "memory",
  smtpConfigured: false,
  objectStorageConfigured: false,
  redisConfigured: false,
  bootstrapOwnerConfigured: false,
  roleCount: 5,
  userCount: 1,
  apiKeyCount: 0,
  policy: {
    otaRequiresManualConfirmation: true,
    agentDangerousActionsBlocked: true,
    licenseOfflineGraceDays: 14
  }
};
