import type { FeedbackItem, LicenseItem, NotificationTemplateItem, Product, ReleaseItem } from "./types.js";

const now = "2026-07-09T12:00:00.000Z";

export const requiredNotificationTemplateTypes = [
  "admin_new_feedback",
  "admin_p0_p1_bug_alert",
  "admin_daily_feedback_digest",
  "admin_github_sync_failure",
  "admin_ota_publish_success",
  "admin_ota_publish_failure",
  "admin_license_anomaly",
  "customer_feedback_received",
  "customer_feedback_reply",
  "customer_feedback_resolved",
  "customer_license_issued",
  "customer_license_expiring",
  "customer_license_suspended",
  "customer_license_revoked"
] as const;

const defaultTemplateCopy: Record<(typeof requiredNotificationTemplateTypes)[number], { subject: string; html: string; text: string }> = {
  admin_new_feedback: {
    subject: "Stacio new feedback: {{feedbackTitle}}",
    html: "<p>New Stacio feedback from {{contactEmail}}: {{feedbackTitle}}</p>",
    text: "New Stacio feedback from {{contactEmail}}: {{feedbackTitle}}"
  },
  admin_p0_p1_bug_alert: {
    subject: "Stacio urgent feedback alert: {{feedbackTitle}}",
    html: "<p>{{priority}} Stacio feedback requires attention: {{feedbackTitle}}</p>",
    text: "{{priority}} Stacio feedback requires attention: {{feedbackTitle}}"
  },
  admin_daily_feedback_digest: {
    subject: "Stacio daily feedback digest",
    html: "<p>Stacio feedback summary: {{summary}}</p>",
    text: "Stacio feedback summary: {{summary}}"
  },
  admin_github_sync_failure: {
    subject: "Stacio GitHub sync failed",
    html: "<p>GitHub sync failed for Stacio: {{error}}</p>",
    text: "GitHub sync failed for Stacio: {{error}}"
  },
  admin_ota_publish_success: {
    subject: "Stacio OTA publish succeeded: {{version}}",
    html: "<p>Stacio {{channel}} release {{version}} was published.</p>",
    text: "Stacio {{channel}} release {{version}} was published."
  },
  admin_ota_publish_failure: {
    subject: "Stacio OTA publish failed: {{version}}",
    html: "<p>Stacio {{channel}} release {{version}} failed: {{error}}</p>",
    text: "Stacio {{channel}} release {{version}} failed: {{error}}"
  },
  admin_license_anomaly: {
    subject: "Stacio license anomaly: {{licenseId}}",
    html: "<p>Stacio license {{licenseId}} needs review: {{reason}}</p>",
    text: "Stacio license {{licenseId}} needs review: {{reason}}"
  },
  customer_feedback_received: {
    subject: "Stacio received your feedback",
    html: "<p>Thanks for your Stacio feedback. We received: {{feedbackTitle}}</p>",
    text: "Thanks for your Stacio feedback. We received: {{feedbackTitle}}"
  },
  customer_feedback_reply: {
    subject: "Stacio feedback update: {{feedbackTitle}}",
    html: "<p>{{reply}}</p><p>Thanks for helping improve Stacio.</p>",
    text: "{{reply}}\n\nThanks for helping improve Stacio."
  },
  customer_feedback_resolved: {
    subject: "Stacio feedback resolved: {{feedbackTitle}}",
    html: "<p>Your Stacio feedback was marked resolved: {{resolution}}</p>",
    text: "Your Stacio feedback was marked resolved: {{resolution}}"
  },
  customer_license_issued: {
    subject: "Your Stacio license is ready",
    html: "<p>Your Stacio {{plan}} license is ready. License key: {{licenseKey}}</p>",
    text: "Your Stacio {{plan}} license is ready. License key: {{licenseKey}}"
  },
  customer_license_expiring: {
    subject: "Your Stacio license expires soon",
    html: "<p>Your Stacio license expires on {{expiresAt}}.</p>",
    text: "Your Stacio license expires on {{expiresAt}}."
  },
  customer_license_suspended: {
    subject: "Your Stacio license was suspended",
    html: "<p>Your Stacio license was suspended: {{reason}}</p>",
    text: "Your Stacio license was suspended: {{reason}}"
  },
  customer_license_revoked: {
    subject: "Your Stacio license was revoked",
    html: "<p>Your Stacio license was revoked: {{reason}}</p>",
    text: "Your Stacio license was revoked: {{reason}}"
  }
};

export const seedNotificationTemplates: NotificationTemplateItem[] = requiredNotificationTemplateTypes.map((type) => ({
  id: `tmpl_stacio_${type}`,
  productId: "stacio",
  type,
  subjectTemplate: defaultTemplateCopy[type].subject,
  htmlTemplate: defaultTemplateCopy[type].html,
  textTemplate: defaultTemplateCopy[type].text,
  status: "active",
  createdAt: now,
  updatedAt: now
}));

export const seedProducts: Product[] = [
  {
    id: "stacio",
    name: "Stacio",
    platform: "macOS",
    bundleId: "com.stacio.Stacio",
    currentStableVersion: "0.13.1-Beta",
    currentBetaVersion: "0.13.2-Beta",
    supportEmail: "support@stacio.dev",
    licensePolicy: {
      defaultOfflineGraceDays: 14,
      deviceFingerprintMode: "risk_signal"
    },
    dataRetentionPolicy: {
      feedbackRetentionDays: 730,
      diagnosticsRetentionDays: 90,
      auditLogRetentionDays: 1095,
      inactiveCustomerRetentionDays: 730
    },
    emailBrand: {
      name: "Stacio",
      accentColor: "#0070C0"
    },
    objectStoragePrefix: "products/stacio",
    status: "active"
  }
];

export const seedFeedback: FeedbackItem[] = [
  {
    id: "fb_001",
    productId: "stacio",
    title: "远端编辑器保存后偶发失败",
    description: "重连远端主机后，编辑器保存动作偶尔提示失败，需要重新打开文件。",
    type: "bug",
    status: "new",
    priority: "P1",
    source: "app",
    contactEmail: "ops-user@example.com",
    appVersion: "0.13.2-Beta",
    buildNumber: "12",
    osVersion: "macOS 15.5",
    anonymousDeviceId: "device_seed_001",
    aiSummary: "疑似远端文件编辑保存流程在 SSH 重连后没有刷新远端 revision。",
    createdAt: now,
    updatedAt: now
  },
  {
    id: "fb_002",
    productId: "stacio",
    title: "希望设备看板支持自定义刷新频率",
    description: "当前默认刷新频率适合排障，但平时监控时希望降低频率。",
    type: "feature",
    status: "triaged",
    priority: "P2",
    source: "github",
    contactEmail: "github-user@example.com",
    appVersion: "0.13.1-Beta",
    buildNumber: "10",
    osVersion: "macOS 14.6",
    aiSummary: "需求与设备看板设置相关，可合并到 metrics settings。",
    createdAt: now,
    updatedAt: now
  }
];

export const seedReleases: ReleaseItem[] = [
  {
    id: "rel_001",
    productId: "stacio",
    channel: "stable",
    version: "0.13.1-Beta",
    buildNumber: "10",
    status: "published",
    artifactName: "Stacio-0.13.1-Beta.dmg",
    publishedAt: "2026-07-08T10:00:00.000Z",
    createdAt: "2026-07-08T09:30:00.000Z"
  },
  {
    id: "rel_002",
    productId: "stacio",
    channel: "beta",
    version: "0.13.2-Beta",
    buildNumber: "12",
    status: "ready",
    artifactName: "Stacio-0.13.2-Beta.dmg",
    createdAt: now
  }
];

export const seedLicenses: LicenseItem[] = [
  {
    id: "lic_001",
    productId: "stacio",
    customerName: "Internal Tester",
    customerEmail: "tester@example.com",
    plan: "internal",
    status: "active",
    seats: 5,
    devices: 3,
    expiresAt: "2027-07-09T00:00:00.000Z",
    createdAt: now
  },
  {
    id: "lic_002",
    productId: "stacio",
    customerName: "Pro User",
    customerEmail: "pro@example.com",
    plan: "pro",
    status: "trial",
    seats: 1,
    devices: 1,
    expiresAt: "2026-08-09T00:00:00.000Z",
    createdAt: now
  }
];
