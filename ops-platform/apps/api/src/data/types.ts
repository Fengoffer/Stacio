export type FeedbackStatus =
  | "new"
  | "triaged"
  | "in_progress"
  | "waiting_for_user"
  | "resolved"
  | "closed"
  | "duplicate";

export type FeedbackPriority = "P0" | "P1" | "P2" | "P3";

export type FeedbackType =
  | "bug"
  | "feature"
  | "question"
  | "crash"
  | "update_issue"
  | "license_issue"
  | "billing_issue"
  | "other";

export type FeedbackSource = "app" | "github" | "admin";

export interface Product {
  id: string;
  name: string;
  platform: string;
  bundleId: string;
  iconUrl?: string;
  description?: string;
  currentStableVersion: string;
  currentBetaVersion: string;
  supportEmail: string;
  githubOwner?: string;
  githubRepository?: string;
  updateBaseUrl?: string;
  appcastBaseUrl?: string;
  licensePolicy: Record<string, unknown>;
  dataRetentionPolicy: Record<string, unknown>;
  emailBrand: Record<string, unknown>;
  objectStoragePrefix?: string;
  status: "active" | "archived";
  createdAt?: string;
  updatedAt?: string;
}

export interface ReleaseChannelItem {
  id: string;
  productId: string;
  name: "stable" | "beta" | "dev" | "internal" | string;
  appcastUrl?: string;
  currentReleaseId?: string;
  allowedPlanIds: string[];
  minimumUpgradableVersion?: string;
  rolloutPercentage: number;
  autoDownloadAllowed: boolean;
  forceUpdatePrompt: boolean;
  status: "active" | "paused" | "archived" | string;
  createdAt: string;
  updatedAt: string;
}

export type ReleasePublicationTarget = "object_storage" | "appcast" | "github" | "website_catalog";
export type ReleasePublicationStatus = "queued" | "running" | "succeeded" | "failed" | "skipped";

export interface ReleasePublicationItem {
  id: string;
  productId: string;
  releaseId: string;
  target: ReleasePublicationTarget;
  status: ReleasePublicationStatus;
  attempts: number;
  objectKey?: string;
  externalUrl?: string;
  lastError?: string;
  metadata: Record<string, unknown>;
  startedAt?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export type WebsiteEventType =
  | "page_view"
  | "download_requested"
  | "download_redirected"
  | "github_release_clicked"
  | "github_asset_clicked";

export interface WebsiteEventItem {
  eventId: string;
  productId: string;
  type: WebsiteEventType;
  path: string;
  referrer?: string;
  visitorHash: string;
  sessionHash?: string;
  releaseId?: string;
  platform?: string;
  architecture?: string;
  ipAddress: string;
  ipHash: string;
  browserName: string;
  browserVersion?: string;
  operatingSystem: string;
  deviceType: "desktop" | "mobile" | "tablet" | "unknown";
  occurredAt: string;
}

export interface WebsiteAnalyticsSummary {
  overview: {
    pageViews: number;
    uniqueVisitors: number;
    downloadRequests: number;
    uniqueDownloaders: number;
  };
  browsers: Array<{ name: string; count: number }>;
  operatingSystems: Array<{ name: string; count: number }>;
  devices: Array<{ name: string; count: number }>;
  recentEvents: WebsiteEventItem[];
}

export interface CustomerItem {
  id: string;
  productId: string;
  email: string;
  name: string;
  company?: string;
  status: "active" | "trial" | "blocked" | "archived" | "merged" | string;
  notes?: string;
  riskFlag: boolean;
  mergedIntoId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface CustomerNoteItem {
  id: string;
  customerId: string;
  authorId?: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}

export type CustomerNotificationItem = NotificationItem & {
  deliveries: NotificationDeliveryItem[];
};

export interface CustomerDetail {
  customer: CustomerItem;
  licenses: LicenseItem[];
  activations: LicenseActivationItem[];
  feedback: FeedbackItem[];
  notifications: CustomerNotificationItem[];
  notes: CustomerNoteItem[];
  activationCount: number;
  auditLogs: AuditLogItem[];
}

export interface PlanItem {
  id: string;
  productId: string;
  name: string;
  description?: string;
  maxDevices: number;
  maxSeats: number;
  trialDays: number;
  offlineGraceDays: number;
  allowedChannels: string[];
  supportedVersionRange?: string;
  paymentProvider?: string;
  providerPlanId?: string;
  priceMinor?: number;
  currency?: string;
  billingInterval?: string;
  couponSupport?: boolean;
  subscriptionSupport?: boolean;
  entitlements: string[];
  status: "active" | "disabled" | "archived" | string;
  createdAt: string;
  updatedAt: string;
}

export interface ConnectorItem {
  id: string;
  productId?: string;
  type: "github" | "smtp" | "object_storage" | "agent_api" | string;
  name: string;
  config: Record<string, unknown>;
  hasSecrets: boolean;
  status: "configured" | "unconfigured" | "error" | "disabled" | string;
  lastSuccessAt?: string;
  lastError?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface SettingsSummary {
  productId: string;
  persistence: "postgres" | "memory";
  smtpConfigured: boolean;
  objectStorageConfigured: boolean;
  redisConfigured: boolean;
  bootstrapOwnerConfigured: boolean;
  roleCount: number;
  userCount: number;
  apiKeyCount: number;
  policy: {
    otaRequiresManualConfirmation: true;
    agentDangerousActionsBlocked: true;
    licenseOfflineGraceDays: number;
  };
}

export interface AgentApiKeyItem {
  id: string;
  ownerType: "agent";
  ownerId: string;
  name: string;
  keyPrefix: string;
  productIds: string[];
  scopes: string[];
  expiresAt?: string;
  lastUsedAt?: string;
  status: "active" | "disabled" | string;
  createdAt: string;
  updatedAt: string;
}

export interface FeedbackItem {
  id: string;
  productId: string;
  customerId?: string;
  title: string;
  description: string;
  type: FeedbackType;
  status: FeedbackStatus;
  priority: FeedbackPriority;
  source: FeedbackSource;
  contactEmail?: string;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  licenseState?: string;
  licenseKeyHash?: string;
  anonymousDeviceId?: string;
  diagnosticsSummary?: Record<string, unknown>;
  aiSummary?: string;
  aiClassification?: string;
  aiSuggestedPriority?: FeedbackPriority;
  assignedUserId?: string;
  duplicateOfId?: string;
  relatedReleaseId?: string;
  deletedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface FeedbackCommentItem {
  id: string;
  feedbackId: string;
  authorType: "user" | "agent" | "system" | "customer";
  authorId?: string;
  visibility: "internal" | "public";
  body: string;
  deliveryId?: string;
  notificationId?: string;
  deliveryStatus?: "draft" | "queued" | "sent" | "failed" | "not_applicable";
  createdAt: string;
  updatedAt: string;
}

export interface FeedbackAttachmentItem {
  id: string;
  feedbackId: string;
  objectKey: string;
  fileName: string;
  contentType: string;
  sizeBytes: number;
  sha256?: string;
  redactedAt?: string;
  deletedAt?: string;
  createdAt: string;
}

export interface GitHubIssueItem {
  id: string;
  productId: string;
  githubIssueId: string;
  number: number;
  title: string;
  body?: string;
  labels: string[];
  author?: string;
  state: "open" | "closed";
  commentsCount: number;
  url: string;
  linkedFeedbackId?: string;
  githubCreatedAt?: string;
  githubUpdatedAt?: string;
  githubClosedAt?: string;
  syncedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface GitHubSyncRunItem {
  id: string;
  productId: string;
  trigger: "manual" | "scheduled" | "webhook";
  status: "success" | "failed" | "partial";
  fetchedCount: number;
  changedCount: number;
  error?: string;
  startedAt: string;
  finishedAt?: string;
  createdAt: string;
}

export interface AiAnalysisResultItem {
  id: string;
  productId: string;
  targetType: "feedback" | "release" | "github_issue";
  targetId: string;
  agentIdentity: string;
  provider?: string;
  model?: string;
  analysisType: string;
  inputReferences: Record<string, unknown>;
  outputBody: Record<string, unknown>;
  confidence?: string;
  adoptionState: "pending" | "accepted" | "edited_accepted" | "ignored" | "superseded";
  createdAt: string;
  updatedAt: string;
}

export interface AiProposedActionItem {
  id: string;
  analysisId: string;
  productId: string;
  targetType: AiAnalysisResultItem["targetType"];
  targetId: string;
  actionType: string;
  payload: Record<string, unknown>;
  status: "pending" | "accepted" | "rejected" | "dismissed" | "superseded" | string;
  reviewedBy?: string;
  reviewedAt?: string;
  createdAt: string;
  updatedAt: string;
  analysis: AiAnalysisResultItem;
}

export interface AgentRequestItem {
  id: string;
  productId: string;
  targetType: "feedback" | "release" | "github_issue";
  targetId: string;
  requestType: "summary" | "reply_draft" | "release_notes" | "release_risk" | string;
  agentHint?: string;
  prompt: string;
  status: "queued" | "in_progress" | "completed" | "cancelled" | "failed" | string;
  requestedBy?: string;
  metadata: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

export interface NotificationTemplateItem {
  id: string;
  productId: string;
  type: string;
  subjectTemplate: string;
  htmlTemplate: string;
  textTemplate?: string;
  status: "active" | "disabled";
  createdAt: string;
  updatedAt: string;
}

export interface NotificationItem {
  id: string;
  productId: string;
  customerId?: string;
  type: string;
  recipient: string;
  payload: Record<string, unknown>;
  priority: "low" | "normal" | "high" | "urgent";
  status: "queued" | "sent" | "failed" | "draft";
  scheduledAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface NotificationPolicyItem {
  productId: string;
  quietHoursEnabled: boolean;
  quietHoursStart: string;
  quietHoursEnd: string;
  quietHoursTimeZone: string;
  createdAt: string;
  updatedAt: string;
}

export interface NotificationDeliveryItem {
  id: string;
  notificationId: string;
  provider: string;
  attempt: number;
  status: "sent" | "failed" | "dry_run";
  providerMessageId?: string;
  error?: string;
  sentAt?: string;
  createdAt: string;
}

export interface ReleaseItem {
  id: string;
  productId: string;
  channel: "stable" | "beta" | "dev" | "internal";
  version: string;
  buildNumber: string;
  status: "draft" | "validating" | "ready" | "published" | "paused" | "withdrawn" | "failed";
  artifactName: string;
  artifactUrl?: string;
  artifactType?: string;
  artifactSize?: number;
  minimumSystemVersion?: string;
  sparkleEdDsaSignature?: string;
  releaseNotes?: string;
  aiReleaseSummary?: string;
  aiRiskSummary?: string;
  preflightEvidence?: Record<string, unknown>;
  createdBy?: string;
  publishedBy?: string;
  publishedAt?: string;
  createdAt: string;
}

export interface AppcastEntryItem {
  id: string;
  productId: string;
  channelId: string;
  channelName: string;
  releaseId: string;
  xml: string;
  objectKey?: string;
  publishedAt?: string;
  createdAt: string;
}

export interface ReleaseArtifactItem {
  id: string;
  productId: string;
  releaseId: string;
  objectKey?: string;
  url: string;
  fileName: string;
  contentType?: string;
  sizeBytes?: number;
  sha256?: string;
  signatureEvidence: Record<string, unknown>;
  createdAt: string;
}

export interface LicenseItem {
  id: string;
  productId: string;
  customerId?: string;
  customerName: string;
  customerEmail: string;
  username?: string;
  plan: "free" | "pro" | "team" | "internal";
  status: "active" | "trial" | "expired" | "suspended" | "revoked";
  seats: number;
  devices: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  keyPrefix?: string;
  expiresAt: string;
  createdAt: string;
}

export interface LicenseActivationItem {
  id: string;
  licenseId: string;
  anonymousDeviceId?: string;
  machineFingerprintHash?: string;
  firstSeenAt: string;
  lastSeenAt: string;
  resetAt?: string;
  riskSignals: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

export interface LicenseValidationLogItem {
  id: string;
  licenseId?: string;
  productId: string;
  keyPrefix?: string;
  email?: string;
  anonymousDeviceId?: string;
  machineFingerprintHash?: string;
  result: "valid" | "invalid" | string;
  reason?: string;
  appVersion?: string;
  buildNumber?: string;
  ipAddress?: string;
  createdAt: string;
}

export interface LicenseDetail {
  license: LicenseItem;
  customer?: CustomerItem;
  activations: LicenseActivationItem[];
  validationLogs: LicenseValidationLogItem[];
  auditLogs: AuditLogItem[];
}

export interface DashboardSummary {
  productId: string;
  currentStableVersion: string;
  currentBetaVersion: string;
  todayFeedbackCount: number;
  unhandledFeedbackCount: number;
  p0p1BugCount: number;
  activeLicenseCount: number;
  expiringLicenseCount: number;
  latestReleaseStatus: string;
  githubSyncStatus: string;
  aiPendingSuggestionCount: number;
  licenseValidationErrorCount: number;
  emailDeliveryStatus: {
    queued: number;
    sent: number;
    failed: number;
    dryRun: number;
  };
  recentAuditEvents: AuditLogItem[];
}

export interface AuditLogItem {
  id: string;
  actorType: "user" | "agent" | "system" | "public";
  actorId?: string;
  action: string;
  targetType: string;
  targetId?: string;
  productId?: string;
  beforeValue?: Record<string, unknown>;
  afterValue?: Record<string, unknown>;
  ipAddress?: string;
  userAgent?: string;
  metadata: Record<string, unknown>;
  createdAt: string;
}
