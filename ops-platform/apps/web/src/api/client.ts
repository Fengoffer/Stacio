import {
  aiAnalyses,
  aiProposedActions,
  auditLogs,
  connectors,
  customers,
  dashboard,
  feedbackItems,
  githubIssues,
  githubSyncRuns,
  licenses,
  notificationTemplates,
  notifications,
  plans,
  product,
  releaseChannels,
  releases,
  settingsSummary
} from "./mockData";

const apiBase = import.meta.env.VITE_API_BASE_URL ?? "/api/v1";
const tokenStorageKey = "stacio.ops.authToken";
const refreshTokenStorageKey = "stacio.ops.refreshToken";

export interface CurrentUserRecord {
  id: string;
  email: string;
  name: string;
  roles: string[];
  permissions: string[];
  productIds: string[];
}

export interface LoginResult {
  token: string;
  refreshToken?: string;
  user: CurrentUserRecord;
}

export interface UpdateCurrentUserInput {
  name: string;
  email: string;
  currentPassword: string;
  newPassword?: string;
}

export interface UpdateCurrentUserResult {
  user: CurrentUserRecord;
  reauthenticationRequired: boolean;
}

const demoCurrentUser: CurrentUserRecord = {
  id: "usr_demo_owner",
  email: "owner@stacio.local",
  name: "Stacio Owner",
  roles: ["owner"],
  permissions: ["*"],
  productIds: []
};

export interface AdminRoleRecord {
  id: string;
  name: string;
  description?: string;
  permissions: string[];
}

interface ApiAdminUserItem {
  id: string;
  email: string;
  name: string;
  status: string;
  roles: string[];
  permissions: string[];
  productIds: string[];
  lastLoginAt?: string;
  createdAt?: string;
  updatedAt?: string;
}

interface ApiAgentApiKeyItem {
  id: string;
  name: string;
  key?: string;
  keyPrefix: string;
  productIds: string[];
  scopes: string[];
  expiresAt?: string;
  lastUsedAt?: string;
  status: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface AdminUserRecord {
  id: string;
  email: string;
  name: string;
  status: string;
  roles: string[];
  permissions: string[];
  productIds: string[];
  role: string;
  productScope: string;
  lastLoginAt?: string;
  createdAt: string;
}

export interface AgentApiKeyRecord {
  id: string;
  name: string;
  oneTimeKey?: string;
  keyPrefix: string;
  productIds: string[];
  productScope: string;
  scopes: string[];
  scopeSummary: string;
  expiresAt?: string;
  lastUsedAt?: string;
  status: string;
  createdAt: string;
}

export interface CreateAdminUserInput {
  email: string;
  name: string;
  password: string;
  role: string;
  productIds: string[];
}

export interface CreateAgentApiKeyInput {
  name: string;
  productIds: string[];
  scopes: string[];
  expiresAt?: string;
}

export interface UpdateAdminUserInput {
  name?: string;
  password?: string;
  status?: "active" | "disabled";
  role?: string;
  productIds?: string[];
  confirmation?: "DISABLE" | "ENABLE";
}

export interface UpdateAgentApiKeyInput {
  status: "active" | "disabled";
  confirmation: "DISABLE" | "ENABLE";
}

export interface RotateAgentApiKeyInput {
  confirmation: "ROTATE";
}

export function getAuthToken() {
  if (typeof window === "undefined") {
    return null;
  }
  return window.localStorage.getItem(tokenStorageKey);
}

export function setAuthToken(token: string | null) {
  if (typeof window === "undefined") {
    return;
  }
  if (token) {
    window.localStorage.setItem(tokenStorageKey, token);
  } else {
    window.localStorage.removeItem(tokenStorageKey);
  }
}

export function getRefreshToken() {
  if (typeof window === "undefined") {
    return null;
  }
  return window.localStorage.getItem(refreshTokenStorageKey);
}

export function setRefreshToken(token: string | null) {
  if (typeof window === "undefined") {
    return;
  }
  if (token) {
    window.localStorage.setItem(refreshTokenStorageKey, token);
  } else {
    window.localStorage.removeItem(refreshTokenStorageKey);
  }
}

function authHeaders(): Record<string, string> {
  const token = getAuthToken();
  return token
    ? {
        Authorization: `Bearer ${token}`
      }
    : {};
}

function normalizeHeaders(headers: HeadersInit | undefined): Record<string, string> {
  if (!headers) {
    return {};
  }
  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }
  if (Array.isArray(headers)) {
    return Object.fromEntries(headers);
  }
  return headers;
}

function accessTokenFrom(data: Record<string, unknown>) {
  return data.token ?? data.accessToken ?? data.access_token;
}

function refreshTokenFrom(data: Record<string, unknown>) {
  return data.refreshToken ?? data.refresh_token;
}

async function fetchApi(path: string, options: RequestInit): Promise<Response> {
  return fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...authHeaders(),
      ...normalizeHeaders(options.headers)
    }
  });
}

export async function refreshSession() {
  const refreshToken = getRefreshToken();
  if (!refreshToken) {
    setAuthToken(null);
    return null;
  }

  const response = await fetch(`${apiBase}/auth/refresh`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ refreshToken })
  });
  const body = await response.json();
  if (!response.ok || !body.ok) {
    setAuthToken(null);
    setRefreshToken(null);
    return null;
  }

  const data = body.data as Record<string, unknown>;
  const token = accessTokenFrom(data);
  const nextRefreshToken = refreshTokenFrom(data);
  if (typeof token !== "string") {
    setAuthToken(null);
    setRefreshToken(null);
    return null;
  }

  setAuthToken(token);
  setRefreshToken(typeof nextRefreshToken === "string" ? nextRefreshToken : refreshToken);
  return token;
}

function mapAdminUser(item: ApiAdminUserItem): AdminUserRecord {
  return {
    id: item.id,
    email: item.email,
    name: item.name,
    status: humanize(item.status),
    roles: item.roles,
    permissions: item.permissions,
    productIds: item.productIds,
    role: item.roles[0] ?? "-",
    productScope: item.productIds.length > 0 ? item.productIds.join(", ") : "All products",
    lastLoginAt: item.lastLoginAt ? formatDate(item.lastLoginAt) : undefined,
    createdAt: formatDate(item.createdAt)
  };
}

function mapAgentApiKey(item: ApiAgentApiKeyItem): AgentApiKeyRecord {
  return {
    id: item.id,
    name: item.name,
    oneTimeKey: item.key,
    keyPrefix: item.keyPrefix,
    productIds: item.productIds,
    productScope: item.productIds.length > 0 ? item.productIds.join(", ") : "All products",
    scopes: item.scopes,
    scopeSummary: item.scopes.join(", "),
    expiresAt: item.expiresAt ? formatDate(item.expiresAt) : undefined,
    lastUsedAt: item.lastUsedAt ? formatDate(item.lastUsedAt) : undefined,
    status: humanize(item.status),
    createdAt: formatDate(item.createdAt)
  };
}

async function requestJson<T>(path: string, options: RequestInit, fallback: T): Promise<T> {
  try {
    let response = await fetchApi(path, options);
    if (response.status === 401 && getRefreshToken()) {
      const refreshedToken = await refreshSession();
      if (refreshedToken) {
        response = await fetchApi(path, options);
      }
    }
    if (!response.ok) {
      let message = `API request failed with status ${response.status}`;
      try {
        const body = await response.json();
        message = body.error?.message ?? message;
      } catch {
        // Keep status-derived error.
      }
      throw new Error(message);
    }
    const body = await response.json();
    return body.data ?? fallback;
  } catch (error) {
    if (demoModeEnabled()) {
      return fallback;
    }
    throw error;
  }
}

async function fetchJson<T>(path: string, fallback: T): Promise<T> {
  return requestJson(path, { method: "GET" }, fallback);
}

const defaultListPageSize = 100;

function withDefaultListPageSize(path: string) {
  const [pathname, queryString] = path.split("?");
  const parameters = new URLSearchParams(queryString);
  if (!parameters.has("page_size")) {
    parameters.set("page_size", String(defaultListPageSize));
  }
  return `${pathname}?${parameters.toString()}`;
}

async function fetchListJson<T>(path: string, fallback: T): Promise<T> {
  return fetchJson(withDefaultListPageSize(path), fallback);
}

export function demoModeEnabled() {
  return import.meta.env.VITE_DEMO_MODE === "true" || (import.meta.env.MODE === "test" && import.meta.env.VITE_STRICT_API !== "true");
}

export interface FeedbackRecord {
  id: string;
  productId: string;
  customerId?: string;
  title: string;
  description: string;
  type: string;
  priority: string;
  status: string;
  source: string;
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
  aiSuggestedPriority?: string;
  assignedUserId?: string;
  duplicateOfId?: string;
  relatedReleaseId?: string;
  deletedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface FeedbackCommentRecord {
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

export interface FeedbackAttachmentRecord {
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

export interface PresignedUploadRecord {
  objectKey: string;
  bucket?: string;
  uploadUrl: string;
  method?: "PUT";
  headers?: Record<string, string>;
  expiresInSeconds?: number;
  publicUrl?: string;
  dryRun?: boolean;
}

export interface PresignReleaseArtifactInput {
  fileName: string;
  contentType: string;
  sizeBytes: number;
  refId?: string;
}

export interface LinkedGitHubIssueRecord {
  id: string;
  productId: string;
  githubIssueId: string;
  number: number;
  title: string;
  body?: string;
  labels: string[];
  author?: string;
  state: string;
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

export interface FeedbackAuditEventRecord {
  id: string;
  actorType: string;
  actorId?: string;
  action: string;
  targetType: string;
  targetId?: string;
  metadata?: Record<string, unknown>;
  createdAt: string;
}

export interface FeedbackDetailRecord extends FeedbackRecord {
  comments: FeedbackCommentRecord[];
  attachments: FeedbackAttachmentRecord[];
  linkedGitHubIssues: LinkedGitHubIssueRecord[];
  auditEvents: FeedbackAuditEventRecord[];
}

export interface FeedbackQuery {
  search?: string;
  type?: string;
  status?: string;
  priority?: string;
  source?: string;
  version?: string;
  licenseState?: string;
  createdFrom?: string;
  createdTo?: string;
  sort?: "newest" | "priority" | "last_activity" | "version";
}

export interface FeedbackUpdateInput {
  status?: string;
  priority?: string;
  assignedUserId?: string | null;
  duplicateOfId?: string | null;
  relatedReleaseId?: string | null;
  aiSummary?: string | null;
  aiClassification?: string | null;
  aiSuggestedPriority?: string | null;
}

export type FeedbackRedactionField =
  | "title"
  | "description"
  | "contactEmail"
  | "diagnosticsSummary"
  | "appVersion"
  | "buildNumber"
  | "osVersion"
  | "licenseState"
  | "licenseKeyHash"
  | "anonymousDeviceId";

export interface ReleaseRecord {
  id: string;
  productId: string;
  version: string;
  buildNumber: string;
  channel: "stable" | "beta" | "dev" | "internal";
  status: string;
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

export interface ReleaseInput {
  channel: "stable" | "beta" | "dev" | "internal";
  version: string;
  buildNumber: string;
  minimumSystemVersion?: string;
  artifactName: string;
  artifactUrl?: string;
  artifactObjectKey?: string;
  artifactType?: string;
  artifactSize?: number;
  artifactSha256?: string;
  sparkleEdDsaSignature?: string;
  releaseNotes?: string;
  aiReleaseSummary?: string;
  aiRiskSummary?: string;
  packageSignatureEvidence?: {
    status: "passed" | "failed" | "not_available";
    tool?: string;
    checkedAt?: string;
    signer?: string;
    summary?: string;
  };
  downloadReachabilityEvidence?: {
    status: "reachable" | "unreachable" | "not_checked";
    checkedAt?: string;
    statusCode?: number;
    contentLength?: number;
    error?: string;
    summary?: string;
  };
}

export interface ReleaseDraftUpdateInput {
  minimumSystemVersion?: string;
  artifactName?: string;
  artifactUrl?: string;
  artifactObjectKey?: string;
  artifactType?: string;
  artifactSize?: number;
  artifactSha256?: string;
  sparkleEdDsaSignature?: string;
  releaseNotes?: string;
  aiReleaseSummary?: string;
  aiRiskSummary?: string;
  packageSignatureEvidence?: ReleaseInput["packageSignatureEvidence"];
  downloadReachabilityEvidence?: ReleaseInput["downloadReachabilityEvidence"];
}

export interface ReleaseListRecord {
  id: string;
  version: string;
  build: string;
  channel: string;
  status: string;
  artifact: string;
  artifactName?: string;
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
  checks: string;
  updatedAt: string;
}

export interface ReleaseValidationResult {
  release?: ReleaseRecord;
  passed: boolean;
  checks: Array<{
    key: string;
    passed: boolean;
    message: string;
  }>;
}

export interface ReleaseDownloadCheckResult {
  release: ReleaseRecord;
  downloadReachabilityEvidence: NonNullable<ReleaseInput["downloadReachabilityEvidence"]>;
}

export interface ReleaseAppcastDiff {
  releaseId: string;
  channel: string;
  addedItem: {
    version: string;
    buildNumber: string;
    artifactUrl?: string;
    artifactName?: string;
  };
  currentItemCount: number;
  previewItemCount: number;
  currentXml: string;
  previewXml: string;
}

export interface AppcastEntryRecord {
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

export interface WebsiteAnalyticsRecord {
  overview: {
    pageViews: number;
    uniqueVisitors: number;
    downloadRequests: number;
    uniqueDownloaders: number;
  };
  browsers: Array<{ name: string; count: number }>;
  operatingSystems: Array<{ name: string; count: number }>;
  devices: Array<{ name: string; count: number }>;
  recentEvents: Array<{
    eventId: string;
    productId: string;
    type: string;
    path: string;
    releaseId?: string;
    platform?: string;
    architecture?: string;
    ipAddress: string;
    browserName: string;
    browserVersion?: string;
    operatingSystem: string;
    deviceType: string;
    occurredAt: string;
  }>;
}

export type WebsiteAnalyticsRange = "24h" | "7d" | "30d" | "90d" | "180d" | "1y" | "all";

export interface GitHubDownloadMetricsRecord {
  fetchedAt: string;
  sourceArchiveDetailAvailable: boolean;
  releases: Array<{
    tagName: string;
    name?: string;
    releaseUrl: string;
    publishedAt?: string;
    sourceZipUrl?: string;
    sourceTarUrl?: string;
    assets: Array<{
      id: number;
      name: string;
      sizeBytes: number;
      downloadCount: number;
      downloadUrl: string;
    }>;
  }>;
}

export interface ReleaseArtifactRecord {
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

export interface ReleasePublicationRecord {
  id: string;
  productId: string;
  releaseId: string;
  target: "object_storage" | "appcast" | "github" | "website_catalog";
  status: "queued" | "running" | "succeeded" | "failed" | "skipped";
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

type ReleaseLifecycleAction = "pause" | "resume" | "withdraw";

const releaseLifecycleConfirmations: Record<ReleaseLifecycleAction, string> = {
  pause: "PAUSE",
  resume: "RESUME",
  withdraw: "WITHDRAW"
};

export interface LicenseRecord {
  id: string;
  productId: string;
  customerId?: string;
  customerName: string;
  customerEmail: string;
  username?: string;
  plan: "free" | "pro" | "team" | "internal";
  status: string;
  seats: number;
  devices: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  keyPrefix?: string;
  expiresAt: string;
  createdAt: string;
  updatedAt?: string;
}

export interface LicenseInput {
  customerName: string;
  customerEmail: string;
  username?: string;
  plan: "free" | "pro" | "team" | "internal";
  seats?: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  expiresAt: string;
  status?: "active" | "trial" | "expired" | "suspended" | "revoked";
}

export interface LicenseCreationResult {
  license: LicenseRecord;
  licenseKey: string;
  revealPolicy: "one_time";
}

export interface LicenseEmailInput {
  licenseKey: string;
  confirmation: "SEND";
  dryRun?: boolean;
}

export interface LicenseEmailResult {
  notification: NotificationRecord;
  job?: {
    id?: string;
    name: string;
    payload?: unknown;
    delayMs?: number;
    scheduledFor?: string;
  };
}

export interface BatchLicenseEmailInput {
  licenseId: string;
  licenseKey: string;
}

export interface BatchLicenseEmailResult {
  requestedCount: number;
  queuedCount: number;
  skippedCount: number;
  queued: Array<{
    licenseId: string;
    recipient: string;
    notification: NotificationRecord;
    job?: LicenseEmailResult["job"];
  }>;
  skipped: Array<{
    licenseId: string;
    recipient?: string;
    reason: string;
  }>;
}

export interface BatchLicenseInput extends Omit<LicenseInput, "customerName" | "customerEmail" | "username"> {
  recipients: Array<{
    customerName: string;
    customerEmail: string;
    username?: string;
  }>;
}

interface BatchLicenseCreationResponse {
  items: LicenseCreationResult[];
}

export interface UpdateLicenseInput {
  plan?: "free" | "pro" | "team" | "internal";
  status?: "active" | "trial" | "expired" | "suspended" | "revoked";
  seats?: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  expiresAt?: string;
  confirmation?: string;
}

interface ApiGitHubIssueItem {
  id: string;
  number: number;
  title: string;
  labels: string[];
  author?: string;
  state: string;
  commentsCount: number;
  url: string;
  linkedFeedbackId?: string;
  githubUpdatedAt?: string;
  syncedAt?: string;
  updatedAt?: string;
}

interface ApiGitHubSyncRunItem {
  id: string;
  trigger: string;
  status: string;
  fetchedCount: number;
  changedCount: number;
  feedbackCreatedCount?: number;
  error?: string | null;
  finishedAt?: string;
  createdAt?: string;
}

export interface GitHubIssueCommentInput {
  body: string;
  confirmation: "POST";
}

export interface GitHubIssueCommentResult {
  commentId: string;
  url: string;
  body: string;
}

export interface GitHubIssueUpdateInput {
  labels?: string[];
  state?: "open" | "closed";
  confirmation: "APPLY_LABELS" | "CLOSE" | "REOPEN";
}

interface ApiAiAnalysisItem {
  id: string;
  targetType: string;
  targetId: string;
  agentIdentity: string;
  provider?: string;
  model?: string;
  analysisType: string;
  inputReferences?: Record<string, unknown>;
  outputBody: Record<string, unknown>;
  confidence?: string;
  adoptionState: string;
  createdAt?: string;
}

interface ApiAgentRequestItem {
  id: string;
  productId: string;
  targetType: string;
  targetId: string;
  requestType: string;
  agentHint?: string;
  prompt: string;
  status: string;
  requestedBy?: string;
  metadata?: Record<string, unknown>;
  createdAt?: string;
  updatedAt?: string;
}

export interface AiAnalysisRecord {
  id: string;
  target: string;
  targetType?: string;
  targetId?: string;
  agent: string;
  model: string;
  analysisType: string;
  summary: string;
  classification: string;
  replyDraft?: string;
  outputBody?: Record<string, unknown>;
  inputReferencesPreview?: string;
  outputBodyPreview?: string;
  confidence: string;
  adoptionState: string;
  createdAt: string;
}

export interface AiAnalysisQuery {
  targetType?: string;
  targetId?: string;
}

export interface AgentRequestRecord {
  id: string;
  productId: string;
  targetType: string;
  targetId: string;
  requestType: string;
  agentHint?: string;
  prompt: string;
  status: string;
  requestedBy?: string;
  metadata?: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

export interface CreateAgentRequestInput {
  requestType: "summary" | "reply_draft" | "release_notes" | "release_risk";
  agentHint?: string;
  prompt: string;
}

interface ApiProposedActionItem {
  id: string;
  actionType: string;
  payload: Record<string, unknown>;
  status: string;
  targetType: string;
  targetId: string;
  reviewedBy?: string;
  reviewedAt?: string;
  createdAt?: string;
  analysis?: {
    agentIdentity?: string;
    provider?: string;
    model?: string;
    outputBody?: Record<string, unknown>;
  };
}

export interface NotificationTemplateRecord {
  id: string;
  type: string;
  subject: string;
  status: string;
  updatedAt: string;
  htmlTemplate: string;
  textTemplate?: string;
}

export interface NotificationTemplateInput {
  subjectTemplate: string;
  htmlTemplate: string;
  textTemplate?: string;
  status?: "active" | "disabled";
}

interface ApiNotificationTemplateItem {
  id: string;
  type: string;
  subjectTemplate: string;
  htmlTemplate: string;
  textTemplate?: string;
  status: string;
  updatedAt?: string;
}

export interface NotificationRecord {
  id: string;
  type: string;
  recipient: string;
  summary: string;
  status: string;
  priority: string;
  createdAt: string;
}

export interface NotificationDeliveryRecord {
  id: string;
  notificationId: string;
  provider: string;
  attempt: number;
  status: string;
  providerMessageId?: string;
  error?: string;
  sentAt?: string;
  createdAt: string;
}

export interface NotificationPolicyRecord {
  productId: string;
  quietHoursEnabled: boolean;
  quietHoursStart: string;
  quietHoursEnd: string;
  quietHoursTimeZone: string;
  updatedAt?: string;
}

export interface NotificationPolicyInput {
  quietHoursEnabled: boolean;
  quietHoursStart: string;
  quietHoursEnd: string;
  quietHoursTimeZone: string;
}

export interface NotificationInput {
  type: string;
  recipient: string;
  payload: Record<string, unknown>;
  priority?: "low" | "normal" | "high" | "urgent";
  status?: "queued" | "sent" | "failed" | "draft";
  scheduledAt?: string;
}

export interface LicenseExpiringReminderInput {
  days?: number;
  referenceDate?: string;
}

export interface LicenseExpiringReminderResult {
  scannedCount: number;
  createdCount: number;
  skippedCount: number;
  window: {
    referenceDate: string;
    days: number;
    cutoffDate: string;
  };
  created: NotificationRecord[];
  skipped: Array<{
    licenseId: string;
    recipient: string;
    reason: string;
    notificationId?: string;
  }>;
}

interface ApiNotificationItem {
  id: string;
  type: string;
  recipient: string;
  payload: Record<string, unknown>;
  priority: string;
  status: string;
  createdAt?: string;
}

interface ApiLicenseEmailResult {
  notification: ApiNotificationItem;
  job?: LicenseEmailResult["job"];
}

interface ApiBatchLicenseEmailResult {
  requestedCount: number;
  queuedCount: number;
  skippedCount: number;
  queued: Array<{
    licenseId: string;
    recipient: string;
    notification: ApiNotificationItem;
    job?: LicenseEmailResult["job"];
  }>;
  skipped: BatchLicenseEmailResult["skipped"];
}

interface ApiLicenseExpiringReminderResult {
  scannedCount: number;
  createdCount: number;
  skippedCount: number;
  window: {
    referenceDate: string;
    days: number;
    cutoffDate: string;
  };
  created: ApiNotificationItem[];
  skipped: Array<{
    licenseId: string;
    recipient: string;
    reason: string;
    notificationId?: string;
  }>;
}

interface ApiNotificationDeliveryItem {
  id: string;
  notificationId: string;
  provider: string;
  attempt: number;
  status: string;
  providerMessageId?: string;
  error?: string;
  sentAt?: string;
  createdAt?: string;
}

interface ApiAuditLogItem {
  id: string;
  actorType: string;
  actorId?: string;
  action: string;
  targetType: string;
  targetId?: string;
  afterValue?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  ipAddress?: string;
  createdAt?: string;
}

export interface AuditLogFilters {
  search?: string;
  actorType?: "user" | "agent" | "system" | "public" | "";
  actorId?: string;
  action?: string;
  targetType?: string;
  targetId?: string;
  ipAddress?: string;
  createdFrom?: string;
  createdTo?: string;
}

interface ApiProductItem {
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
  status: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface ProductInput {
  id: string;
  name: string;
  platform: string;
  bundleId: string;
  iconUrl?: string;
  description?: string;
  supportEmail: string;
  currentStableVersion?: string;
  currentBetaVersion?: string;
  githubOwner?: string;
  githubRepository?: string;
  updateBaseUrl?: string;
  appcastBaseUrl?: string;
  licensePolicy?: Record<string, unknown>;
  dataRetentionPolicy?: Record<string, unknown>;
  emailBrand?: Record<string, unknown>;
  objectStoragePrefix?: string;
}

function demoFeedbackRecords(): FeedbackRecord[] {
  return feedbackItems.map((item, index) => ({
    id: item.id,
    productId: "stacio",
    title: item.title,
    description: item.aiSummary,
    type: item.type.toLowerCase().includes("bug") ? "bug" : "feature",
    priority: item.priority,
    status: item.status.toLowerCase().replaceAll(" ", "_"),
    source: item.source.toLowerCase(),
    contactEmail: item.user === "-" ? undefined : item.user,
    appVersion: item.version === "-" ? undefined : item.version,
    aiSummary: item.aiSummary,
    createdAt: new Date(Date.now() - (index + 1) * 86_400_000).toISOString(),
    updatedAt: new Date().toISOString()
  }));
}

export type ProductUpdateInput = Partial<Omit<ProductInput, "id">> & {
  status?: "active" | "archived";
};

export interface ReleaseChannelRecord {
  id: string;
  productId: string;
  name: string;
  status: string;
  appcastUrl?: string;
  currentReleaseId?: string;
  minimumUpgradableVersion?: string;
  rolloutPercentage: number;
  autoDownloadAllowed: boolean;
  forceUpdatePrompt: boolean;
  allowedPlanIds: string[];
  createdAt: string;
  updatedAt: string;
}

export interface ReleaseChannelInput {
  name: string;
  appcastUrl?: string;
  currentReleaseId?: string;
  allowedPlanIds: string[];
  minimumUpgradableVersion?: string;
  rolloutPercentage: number;
  autoDownloadAllowed: boolean;
  forceUpdatePrompt: boolean;
  status?: "active" | "paused";
}

export type ReleaseChannelUpdateInput = Partial<ReleaseChannelInput> & {
  appcastUrl?: string | null;
  currentReleaseId?: string | null;
  minimumUpgradableVersion?: string | null;
  status?: "active" | "paused" | "archived";
  confirmation?: string;
};

export interface ChannelHistoryRecord {
  id: string;
  actorType?: string;
  actorId?: string;
  action: string;
  targetType: string;
  targetId?: string;
  beforeValue?: Record<string, unknown>;
  afterValue?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  createdAt: string;
}

export interface CustomerRecord {
  id: string;
  productId: string;
  name: string;
  email: string;
  company?: string;
  status: string;
  riskFlag: boolean;
  mergedIntoId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface CustomerInput {
  email: string;
  name: string;
  company?: string;
  status?: string;
  riskFlag?: boolean;
}

export interface CustomerNoteRecord {
  id: string;
  customerId: string;
  authorId?: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}

export interface CustomerDetailRecord {
  customer: CustomerRecord;
  licenses: Array<{
    id: string;
    plan: string;
    status: string;
    devices: number;
    expiresAt: string;
  }>;
  activations: LicenseActivationRecord[];
  feedback: Array<{
    id: string;
    title: string;
    status: string;
    priority: string;
  }>;
  notifications: Array<{
    id: string;
    type: string;
    status: string;
    createdAt: string;
    deliveries: NotificationDeliveryRecord[];
  }>;
  notes: CustomerNoteRecord[];
  activationCount: number;
  auditLogs: Array<{
    id: string;
    actorType?: string;
    actorId?: string;
    action: string;
    targetType?: string;
    targetId?: string;
    createdAt: string;
  }>;
}

export interface LicenseActivationRecord {
  id: string;
  licenseId: string;
  anonymousDeviceId?: string;
  machineFingerprintHash?: string;
  firstSeenAt: string;
  lastSeenAt: string;
  riskSignals?: Record<string, unknown>;
  resetAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface LicenseValidationLogRecord {
  id: string;
  licenseId?: string;
  productId: string;
  keyPrefix?: string;
  email?: string;
  anonymousDeviceId?: string;
  machineFingerprintHash?: string;
  result: string;
  reason?: string;
  appVersion?: string;
  buildNumber?: string;
  ipAddress?: string;
  createdAt: string;
}

export interface LicenseDetailRecord {
  license: LicenseRecord;
  customer?: CustomerRecord;
  activations: LicenseActivationRecord[];
  validationLogs: LicenseValidationLogRecord[];
  auditLogs: ChannelHistoryRecord[];
}

interface ApiCustomerItem extends CustomerRecord {}

export interface PlanRecord {
  id: string;
  productId: string;
  name: string;
  description?: string;
  status: string;
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
  createdAt: string;
  updatedAt: string;
}

export interface PlanInput {
  id: string;
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
  billingInterval?: "month" | "year" | "one_time";
  couponSupport?: boolean;
  subscriptionSupport?: boolean;
  entitlements?: string[];
  status?: "active" | "disabled";
}

export type PlanUpdateInput = Partial<Omit<PlanInput, "id">>;

export type ConnectorType = "github" | "smtp" | "object_storage" | "agent_api" | "webhook";

export interface ConnectorRecord {
  id: string;
  productId?: string;
  type: ConnectorType;
  name: string;
  status: string;
  config: Record<string, unknown>;
  hasSecrets: boolean;
  lastSuccessAt?: string;
  lastError?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ConnectorConfigurationInput {
  config: Record<string, unknown>;
  secrets?: Record<string, string>;
}

interface ApiConnectorItem extends ConnectorRecord {}

interface ApiSettingsSummary {
  productId: string;
  persistence: string;
  smtpConfigured: boolean;
  objectStorageConfigured: boolean;
  redisConfigured: boolean;
  bootstrapOwnerConfigured: boolean;
  roleCount: number;
  userCount: number;
  apiKeyCount: number;
  policy: {
    otaRequiresManualConfirmation: boolean;
    agentDangerousActionsBlocked: boolean;
    licenseOfflineGraceDays: number;
  };
}

interface TemplatePreview {
  subject: string;
  html: string;
  text?: string;
}

function humanize(value: string) {
  return value
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function formatDate(value?: string) {
  if (!value) {
    return "刚刚";
  }
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).format(new Date(value));
}

function releaseCheckSummary(preflightEvidence?: Record<string, unknown>) {
  const checks = preflightEvidence?.checks;
  if (!Array.isArray(checks) || checks.length === 0) {
    return "待校验";
  }
  const passedCount = checks.filter(
    (check): check is { passed: true } =>
      typeof check === "object" &&
      check !== null &&
      "passed" in check &&
      (check as { passed?: unknown }).passed === true
  ).length;
  return `${passedCount}/${checks.length}`;
}

function safeIsoDate(value?: string) {
  const date = value ? new Date(value) : new Date();
  return Number.isNaN(date.getTime()) ? new Date().toISOString() : date.toISOString();
}

function normalizeLicensePlan(value?: string): LicenseRecord["plan"] {
  const plan = value?.toLowerCase();
  return plan === "free" || plan === "pro" || plan === "team" || plan === "internal"
    ? plan
    : "pro";
}

function fallbackLicenseDetail(productId: string, licenseId: string): LicenseDetailRecord {
  const mockLicense = licenses.find((item) => item.id === licenseId) ?? licenses[0];
  const [devices = 0, seats = 1] = (mockLicense?.devices ?? "0/1")
    .split("/")
    .map((part) => Number(part.trim()));
  const customerName = mockLicense?.customer ?? "Demo Customer";
  const customerEmail = mockLicense?.email ?? "demo@example.com";
  const timestamp = new Date().toISOString();
  const expiresAt = safeIsoDate(mockLicense?.expires);

  return {
    license: {
      id: mockLicense?.id ?? licenseId,
      productId,
      customerName,
      customerEmail,
      plan: normalizeLicensePlan(mockLicense?.plan),
      status: mockLicense?.status?.toLowerCase() ?? "active",
      seats,
      devices,
      maxDevices: seats,
      entitlements: [],
      offlineGraceDays: 14,
      expiresAt,
      createdAt: timestamp,
      updatedAt: timestamp
    },
    customer: {
      id: `demo_customer_${mockLicense?.id ?? licenseId}`,
      productId,
      name: customerName,
      email: customerEmail,
      status: "active",
      riskFlag: false,
      createdAt: timestamp,
      updatedAt: timestamp
    },
    activations: [],
    validationLogs: [],
    auditLogs: []
  };
}

function stringifyDetail(value?: Record<string, unknown>) {
  if (!value || Object.keys(value).length === 0) {
    return "-";
  }
  return Object.entries(value)
    .slice(0, 2)
    .map(([key, entry]) => `${key}: ${String(entry)}`)
    .join(", ");
}

function mapNotificationRecord(item: ApiNotificationItem): NotificationRecord {
  return {
    id: item.id,
    type: humanize(item.type),
    recipient: item.recipient,
    summary: stringifyDetail(item.payload),
    status: humanize(item.status),
    priority: humanize(item.priority),
    createdAt: formatDate(item.createdAt)
  };
}

function stringFromOutput(output: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = output[key];
    if (typeof value === "string" && value.trim().length > 0) {
      return value;
    }
  }
  return "等待人工查看分析结果。";
}

function mapAgentRequest(item: ApiAgentRequestItem): AgentRequestRecord {
  return {
    id: item.id,
    productId: item.productId,
    targetType: item.targetType,
    targetId: item.targetId,
    requestType: item.requestType,
    agentHint: item.agentHint,
    prompt: item.prompt,
    status: humanize(item.status),
    requestedBy: item.requestedBy,
    metadata: item.metadata,
    createdAt: formatDate(item.createdAt),
    updatedAt: formatDate(item.updatedAt)
  };
}

function configDetail(config: Record<string, unknown>) {
  const detail = stringifyDetail(config);
  return detail === "-" ? "默认配置" : detail;
}

function mapProduct(item: ApiProductItem) {
  return {
    id: item.id,
    name: item.name,
    platform: item.platform,
    bundleId: item.bundleId,
    iconUrl: item.iconUrl ?? "",
    description: item.description ?? "",
    currentStableVersion: item.currentStableVersion,
    currentBetaVersion: item.currentBetaVersion,
    supportEmail: item.supportEmail,
    githubOwner: item.githubOwner ?? "",
    githubRepository: item.githubRepository ?? "",
    updateBaseUrl: item.updateBaseUrl ?? "",
    appcastBaseUrl: item.appcastBaseUrl ?? "",
    licensePolicy: item.licensePolicy ?? {},
    dataRetentionPolicy: item.dataRetentionPolicy ?? {},
    emailBrand: item.emailBrand ?? {},
    objectStoragePrefix: item.objectStoragePrefix ?? "",
    status: item.status,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt
  };
}

export type ProductRecord = ReturnType<typeof mapProduct>;

export const opsClient = {
  async login(email: string, password: string): Promise<LoginResult> {
    const response = await fetch(`${apiBase}/auth/login`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ email, password })
    });
    const body = await response.json();
    if (!response.ok || !body.ok) {
      throw new Error(body.error?.message ?? "Login failed");
    }
    const data = body.data as Record<string, unknown>;
    const token = accessTokenFrom(data);
    const refreshToken = refreshTokenFrom(data);
    if (typeof token !== "string") {
      throw new Error("Login response did not include an access token");
    }
    setAuthToken(token);
    setRefreshToken(typeof refreshToken === "string" ? refreshToken : null);
    return {
      token,
      refreshToken: typeof refreshToken === "string" ? refreshToken : undefined,
      user: body.data.user
    };
  },
  async logout() {
    const refreshToken = getRefreshToken();
    const headers = authHeaders();
    setAuthToken(null);
    setRefreshToken(null);
    try {
      if (refreshToken) {
        await fetch(`${apiBase}/auth/logout`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...headers
          },
          body: JSON.stringify({ refreshToken })
        });
      }
    } catch {
      // Local logout must succeed even if remote revocation is temporarily unreachable.
    }
  },
  async currentUser() {
    return fetchJson<CurrentUserRecord>("/auth/me", demoCurrentUser);
  },
  async updateCurrentUser(input: UpdateCurrentUserInput) {
    return requestJson<UpdateCurrentUserResult>(
      "/auth/me",
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        user: {
          ...demoCurrentUser,
          name: input.name,
          email: input.email
        },
        reauthenticationRequired: Boolean(input.newPassword)
      }
    );
  },
  async adminRoles() {
    return fetchListJson<AdminRoleRecord[]>("/admin/roles", []);
  },
  async adminUsers() {
    const items = await fetchListJson<ApiAdminUserItem[]>("/admin/users", []);
    return items.map(mapAdminUser);
  },
  async agentApiKeys() {
    const items = await fetchListJson<ApiAgentApiKeyItem[]>("/admin/agent-api-keys", []);
    return items.map(mapAgentApiKey);
  },
  async createAdminUser(input: CreateAdminUserInput) {
    const user = await requestJson<ApiAdminUserItem>(
      "/admin/users",
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "usr_demo",
        email: input.email,
        name: input.name,
        status: "active",
        roles: [input.role],
        permissions: [],
        productIds: input.productIds
      }
    );
    return mapAdminUser(user);
  },
  async createAgentApiKey(input: CreateAgentApiKeyInput) {
    const item = await requestJson<ApiAgentApiKeyItem>(
      "/admin/agent-api-keys",
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "agent_key_demo",
        name: input.name,
        key: "agent_demo",
        keyPrefix: "agent_demo",
        productIds: input.productIds,
        scopes: input.scopes,
        expiresAt: input.expiresAt,
        status: "active"
      }
    );
    return mapAgentApiKey(item);
  },
  async updateAdminUser(userId: string, input: UpdateAdminUserInput) {
    const user = await requestJson<ApiAdminUserItem>(
      `/admin/users/${userId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: userId,
        email: "",
        name: "",
        status: input.status ?? "active",
        roles: input.role ? [input.role] : [],
        permissions: [],
        productIds: input.productIds ?? []
      }
    );
    return mapAdminUser(user);
  },
  async updateAgentApiKey(keyId: string, input: UpdateAgentApiKeyInput) {
    const item = await requestJson<ApiAgentApiKeyItem>(
      `/admin/agent-api-keys/${keyId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: keyId,
        name: "",
        keyPrefix: "",
        productIds: [],
        scopes: [],
        status: input.status
      }
    );
    return mapAgentApiKey(item);
  },
  async rotateAgentApiKey(keyId: string, input: RotateAgentApiKeyInput) {
    const item = await requestJson<ApiAgentApiKeyItem>(
      `/admin/agent-api-keys/${keyId}/rotate`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: keyId,
        name: "",
        key: "agent_demo",
        keyPrefix: "agent_demo",
        productIds: [],
        scopes: [],
        status: "active"
      }
    );
    return mapAgentApiKey(item);
  },
  async products() {
    const items = await fetchListJson<ApiProductItem[]>("/products", demoModeEnabled() ? [product as ApiProductItem] : []);
    return items.map(mapProduct);
  },
  async product(productId = "stacio") {
    const item = await fetchJson<ApiProductItem>(`/products/${productId}`, product as ApiProductItem);
    return mapProduct(item);
  },
  async createProduct(input: ProductInput) {
    return requestJson<{ product: ApiProductItem; feedbackApiKey: string }>(
      "/products",
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        product: {
          ...product,
          ...input,
          currentStableVersion: input.currentStableVersion ?? "",
          currentBetaVersion: input.currentBetaVersion ?? "",
          licensePolicy: input.licensePolicy ?? {},
          dataRetentionPolicy: input.dataRetentionPolicy ?? {},
          emailBrand: input.emailBrand ?? {},
          status: "active"
        },
        feedbackApiKey: "demo-product-feedback-key"
      }
    );
  },
  async updateProduct(productId: string, input: ProductUpdateInput) {
    return requestJson<ApiProductItem>(
      `/products/${productId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        ...product,
        ...input,
        id: productId,
        licensePolicy: input.licensePolicy ?? {},
        dataRetentionPolicy: input.dataRetentionPolicy ?? {},
        emailBrand: input.emailBrand ?? {},
        status: input.status ?? product.status
      } as ApiProductItem
    );
  },
  async archiveProduct(productId: string) {
    return requestJson<{ id: string; status: string }>(
      `/products/${productId}/archive`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "ARCHIVE" })
      },
      {
        id: productId,
        status: "archived"
      }
    );
  },
  async rotateFeedbackApiKey(productId: string) {
    return requestJson<{ feedbackApiKey: string }>(
      `/products/${productId}/feedback-api-key/rotate`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "ROTATE" })
      },
      {
        feedbackApiKey: "demo-product-feedback-key"
      }
    );
  },
  dashboard: (productId = "stacio") =>
    fetchJson(`/products/${productId}/dashboard`, dashboard),
  websiteAnalytics(productId = "stacio", range: WebsiteAnalyticsRange = "24h") {
    return fetchJson<WebsiteAnalyticsRecord>(
      `/products/${productId}/website-analytics?range=${encodeURIComponent(range)}`,
      {
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
      }
    );
  },
  githubDownloadMetrics(productId = "stacio") {
    return fetchJson<GitHubDownloadMetricsRecord>(
      `/products/${productId}/github/download-metrics`,
      { fetchedAt: new Date(0).toISOString(), sourceArchiveDetailAvailable: false, releases: [] }
    );
  },
  async channels(productId = "stacio"): Promise<ReleaseChannelRecord[]> {
    const items = await fetchListJson<ReleaseChannelRecord[]>(`/products/${productId}/channels`, []);
    if (demoModeEnabled() && items.length === 0) {
      return releaseChannels.map((item) => ({
        id: item.id,
        productId,
        name: item.name,
        status: item.status,
        appcastUrl: item.appcast === "-" ? undefined : item.appcast,
        allowedPlanIds:
          item.plans === "All"
            ? []
            : item.plans.split(",").map((value) => value.trim()),
        rolloutPercentage: Number.parseInt(item.rollout, 10),
        autoDownloadAllowed: item.autoDownload === "Yes",
        forceUpdatePrompt: item.forcePrompt === "Yes",
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString()
      }));
    }
    return items;
  },
  async createChannel(productId: string, input: ReleaseChannelInput) {
    return requestJson<ReleaseChannelRecord>(
      `/products/${productId}/channels`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: `channel_${Date.now()}`,
        productId,
        ...input,
        status: input.status ?? "active",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async updateChannel(
    productId: string,
    channelId: string,
    input: ReleaseChannelUpdateInput
  ) {
    return requestJson<ReleaseChannelRecord>(
      `/products/${productId}/channels/${channelId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: channelId,
        productId,
        name: input.name ?? "",
        status: input.status ?? "active",
        appcastUrl: input.appcastUrl ?? undefined,
        currentReleaseId: input.currentReleaseId ?? undefined,
        allowedPlanIds: input.allowedPlanIds ?? [],
        minimumUpgradableVersion: input.minimumUpgradableVersion ?? undefined,
        rolloutPercentage: input.rolloutPercentage ?? 100,
        autoDownloadAllowed: input.autoDownloadAllowed ?? false,
        forceUpdatePrompt: input.forceUpdatePrompt ?? false,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async channelHistory(productId: string, channelId: string) {
    return requestJson<ChannelHistoryRecord[]>(
      `/products/${productId}/channels/${channelId}/history`,
      { method: "GET" },
      []
    );
  },
  async rollbackChannel(productId: string, channelId: string, historyId: string) {
    return requestJson<ReleaseChannelRecord>(
      `/products/${productId}/channels/${channelId}/rollback`,
      {
        method: "POST",
        body: JSON.stringify({
          historyId,
          confirmation: "ROLLBACK"
        })
      },
      {
        id: channelId,
        productId,
        name: "",
        status: "active",
        allowedPlanIds: [],
        rolloutPercentage: 100,
        autoDownloadAllowed: false,
        forceUpdatePrompt: false,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async customers(productId = "stacio"): Promise<CustomerRecord[]> {
    const items = await fetchListJson<ApiCustomerItem[]>(`/products/${productId}/customers`, []);
    if (demoModeEnabled() && items.length === 0) {
      return customers.map((item) => ({
        id: item.id,
        productId,
        name: item.name,
        email: item.email,
        company: item.company === "-" ? undefined : item.company,
        status: item.status.toLowerCase(),
        riskFlag: item.risk === "Risk",
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString()
      }));
    }
    return items;
  },
  async createCustomer(productId: string, input: CustomerInput) {
    return requestJson<CustomerRecord>(
      `/products/${productId}/customers`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: `cust_${Date.now()}`,
        productId,
        email: input.email,
        name: input.name,
        company: input.company,
        status: input.status ?? "active",
        riskFlag: input.riskFlag ?? false,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async updateCustomer(
    productId: string,
    customerId: string,
    input: Partial<CustomerInput>
  ) {
    return requestJson<CustomerRecord>(
      `/products/${productId}/customers/${customerId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: customerId,
        productId,
        email: input.email ?? "",
        name: input.name ?? "",
        company: input.company,
        status: input.status ?? "active",
        riskFlag: input.riskFlag ?? false,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async customerDetail(productId: string, customerId: string) {
    return requestJson<CustomerDetailRecord>(
      `/products/${productId}/customers/${customerId}`,
      { method: "GET" },
      {
        customer: {
          id: customerId,
          productId,
          email: "",
          name: "",
          status: "active",
          riskFlag: false,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        },
        licenses: [],
        activations: [],
        feedback: [],
        notifications: [],
        notes: [],
        activationCount: 0,
        auditLogs: []
      }
    );
  },
  async addCustomerNote(productId: string, customerId: string, body: string) {
    return requestJson<CustomerNoteRecord>(
      `/products/${productId}/customers/${customerId}/notes`,
      {
        method: "POST",
        body: JSON.stringify({ body })
      },
      {
        id: `note_${Date.now()}`,
        customerId,
        body,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async mergeCustomer(
    productId: string,
    sourceCustomerId: string,
    targetCustomerId: string
  ) {
    return requestJson<{ source: CustomerRecord; target: CustomerRecord }>(
      `/products/${productId}/customers/${sourceCustomerId}/merge`,
      {
        method: "POST",
        body: JSON.stringify({
          targetCustomerId,
          confirmation: "MERGE"
        })
      },
      {
        source: {
          id: sourceCustomerId,
          productId,
          email: "",
          name: "",
          status: "merged",
          riskFlag: false,
          mergedIntoId: targetCustomerId,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        },
        target: {
          id: targetCustomerId,
          productId,
          email: "",
          name: "",
          status: "active",
          riskFlag: false,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        }
      }
    );
  },
  async plans(productId = "stacio"): Promise<PlanRecord[]> {
    const items = await fetchListJson<PlanRecord[]>(`/products/${productId}/plans`, []);
    if (demoModeEnabled() && items.length === 0) {
      return plans.map((item) => ({
        id: item.id,
        productId,
        name: item.name,
        status: item.status,
        maxDevices: Number.parseInt(item.devices, 10),
        maxSeats: Number.parseInt(item.seats, 10),
        trialDays: Number.parseInt(item.trial, 10),
        offlineGraceDays: Number.parseInt(item.offlineGrace, 10),
        allowedChannels: item.channels.split(",").map((value) => value.trim()),
        couponSupport: false,
        subscriptionSupport: false,
        entitlements: [],
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString()
      }));
    }
    return items;
  },
  async createPlan(productId: string, input: PlanInput) {
    return requestJson<PlanRecord>(
      `/products/${productId}/plans`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        ...input,
        productId,
        entitlements: input.entitlements ?? [],
        status: input.status ?? "active",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async updatePlan(productId: string, planId: string, input: PlanUpdateInput) {
    return requestJson<PlanRecord>(
      `/products/${productId}/plans/${planId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: planId,
        productId,
        name: input.name ?? "",
        maxDevices: input.maxDevices ?? 1,
        maxSeats: input.maxSeats ?? 1,
        trialDays: input.trialDays ?? 0,
        offlineGraceDays: input.offlineGraceDays ?? 14,
        allowedChannels: input.allowedChannels ?? ["stable"],
        couponSupport: input.couponSupport ?? false,
        subscriptionSupport: input.subscriptionSupport ?? false,
        entitlements: input.entitlements ?? [],
        status: input.status ?? "active",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async archivePlan(productId: string, planId: string) {
    return requestJson<PlanRecord>(
      `/products/${productId}/plans/${planId}/archive`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "ARCHIVE" })
      },
      {
        id: planId,
        productId,
        name: "",
        maxDevices: 1,
        maxSeats: 1,
        trialDays: 0,
        offlineGraceDays: 14,
        allowedChannels: ["stable"],
        entitlements: [],
        status: "archived",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async connectors(productId = "stacio"): Promise<ConnectorRecord[]> {
    const items = await fetchListJson<ApiConnectorItem[]>(`/products/${productId}/connectors`, []);
    if (demoModeEnabled() && items.length === 0) {
      return connectors.map((item) => ({
        id: item.id,
        productId,
        type: item.type as ConnectorType,
        name: item.name,
        status: item.status,
        config: {},
        hasSecrets: false,
        lastError: null,
        createdAt: new Date(0).toISOString(),
        updatedAt: new Date(0).toISOString()
      }));
    }
    return items;
  },
  async configureConnector(
    productId: string,
    type: ConnectorType,
    input: ConnectorConfigurationInput
  ) {
    return requestJson<ConnectorRecord>(
      `/products/${productId}/connectors/${type}`,
      {
        method: "PUT",
        body: JSON.stringify(input)
      },
      {
        id: `conn_${type}`,
        productId,
        type,
        name: humanize(type),
        config: input.config,
        hasSecrets: Boolean(input.secrets),
        status: input.secrets ? "configured" : "unconfigured",
        lastError: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async testConnector(productId: string, type: ConnectorType) {
    return requestJson<{
      connector: ConnectorRecord;
      result: { message: string; metadata?: Record<string, unknown> };
    }>(
      `/products/${productId}/connectors/${type}/test`,
      {
        method: "POST"
      },
      {
        connector: {
          id: `conn_${type}`,
          productId,
          type,
          name: humanize(type),
          config: {},
          hasSecrets: false,
          status: "configured",
          lastError: null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        },
        result: {
          message: "Demo connection verified"
        }
      }
    );
  },
  async disconnectConnector(productId: string, type: ConnectorType) {
    return requestJson<ConnectorRecord>(
      `/products/${productId}/connectors/${type}/disconnect`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "DISCONNECT" })
      },
      {
        id: `conn_${type}`,
        productId,
        type,
        name: humanize(type),
        config: {},
        hasSecrets: false,
        status: "disabled",
        lastError: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async settingsSummary(productId = "stacio") {
    return fetchJson<ApiSettingsSummary>(
      `/settings/summary?productId=${encodeURIComponent(productId)}`,
      settingsSummary
    );
  },
  async feedback(productId = "stacio", query: FeedbackQuery = {}) {
    const parameters = new URLSearchParams();
    for (const key of ["search", "type", "status", "priority", "source", "version", "licenseState", "createdFrom", "createdTo", "sort"] as const) {
      const value = query[key];
      if (value) {
        parameters.set(key, value);
      }
    }
    const queryString = parameters.toString();
    const path = `/products/${productId}/feedback${queryString ? `?${queryString}` : ""}`;
    const items = await fetchListJson<FeedbackRecord[]>(path, []);
    if (demoModeEnabled() && items.length === 0) {
      return demoFeedbackRecords();
    }
    return items;
  },
  async feedbackDetail(productId: string, feedbackId: string) {
    const demoItem = demoFeedbackRecords().find((item) => item.id === feedbackId)
      ?? demoFeedbackRecords()[0];
    return requestJson<FeedbackDetailRecord>(
      `/products/${productId}/feedback/${feedbackId}`,
      { method: "GET" },
      {
        ...demoItem,
        comments: [],
        attachments: [],
        linkedGitHubIssues: [],
        auditEvents: []
      }
    );
  },
  async feedbackAgentRequests(productId: string, feedbackId: string) {
    const items = await fetchListJson<ApiAgentRequestItem[]>(
      `/products/${productId}/feedback/${feedbackId}/agent-requests`,
      []
    );
    return items.map(mapAgentRequest);
  },
  async createFeedbackAgentRequest(
    productId: string,
    feedbackId: string,
    input: CreateAgentRequestInput
  ) {
    const item = await requestJson<ApiAgentRequestItem>(
      `/products/${productId}/feedback/${feedbackId}/agent-requests`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "agent_req_demo",
        productId,
        targetType: "feedback",
        targetId: feedbackId,
        requestType: input.requestType,
        agentHint: input.agentHint,
        prompt: input.prompt,
        status: "queued",
        metadata: {},
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
    return mapAgentRequest(item);
  },
  async updateFeedback(
    productId: string,
    feedbackId: string,
    input: FeedbackUpdateInput
  ) {
    return requestJson<FeedbackRecord>(
      `/products/${productId}/feedback/${feedbackId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        ...(demoFeedbackRecords().find((item) => item.id === feedbackId) ?? demoFeedbackRecords()[0]),
        ...input,
        updatedAt: new Date().toISOString()
      } as FeedbackRecord
    );
  },
  async batchUpdateFeedback(
    productId: string,
    feedbackIds: string[],
    changes: FeedbackUpdateInput
  ) {
    return requestJson<FeedbackRecord[]>(
      `/products/${productId}/feedback/batch`,
      {
        method: "POST",
        body: JSON.stringify({ feedbackIds, changes })
      },
      demoFeedbackRecords()
        .filter((item) => feedbackIds.includes(item.id))
        .map((item) => ({
          ...item,
          ...changes,
          updatedAt: new Date().toISOString()
        }) as FeedbackRecord)
    );
  },
  async addFeedbackComment(
    productId: string,
    feedbackId: string,
    input: { visibility: "internal" | "public"; body: string }
  ) {
    return requestJson<FeedbackCommentRecord>(
      `/products/${productId}/feedback/${feedbackId}/comments`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "comment_demo",
        feedbackId,
        authorType: "user",
        visibility: input.visibility,
        body: input.body,
        deliveryStatus: input.visibility === "public" ? "draft" : "not_applicable",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async sendFeedbackReply(productId: string, feedbackId: string, body: string) {
    return requestJson<{
      comment: FeedbackCommentRecord;
      notification?: Record<string, unknown>;
      job?: Record<string, unknown>;
    }>(
      `/products/${productId}/feedback/${feedbackId}/replies/send`,
      {
        method: "POST",
        body: JSON.stringify({
          confirmation: "SEND",
          body,
          mode: "queue"
        })
      },
      {
        comment: {
          id: "comment_demo_reply",
          feedbackId,
          authorType: "user",
          visibility: "public",
          body,
          deliveryStatus: "queued",
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        }
      }
    );
  },
  async registerFeedbackAttachment(
    productId: string,
    feedbackId: string,
    input: {
      objectKey: string;
      fileName: string;
      contentType: string;
      sizeBytes: number;
      sha256?: string;
    }
  ) {
    return requestJson<FeedbackAttachmentRecord>(
      `/products/${productId}/feedback/${feedbackId}/attachments`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "attachment_demo",
        feedbackId,
        ...input,
        createdAt: new Date().toISOString()
      }
    );
  },
  async redactFeedbackAttachment(
    productId: string,
    feedbackId: string,
    attachmentId: string
  ) {
    return requestJson<FeedbackAttachmentRecord>(
      `/products/${productId}/feedback/${feedbackId}/attachments/${attachmentId}/redact`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "REDACT" })
      },
      {
        id: attachmentId,
        feedbackId,
        objectKey: `redacted://feedback-attachment/${attachmentId}`,
        fileName: "[redacted attachment]",
        contentType: "application/octet-stream",
        sizeBytes: 0,
        redactedAt: new Date().toISOString(),
        createdAt: new Date().toISOString()
      }
    );
  },
  async deleteFeedbackAttachment(
    productId: string,
    feedbackId: string,
    attachmentId: string
  ) {
    return requestJson<FeedbackAttachmentRecord>(
      `/products/${productId}/feedback/${feedbackId}/attachments/${attachmentId}`,
      {
        method: "DELETE",
        body: JSON.stringify({ confirmation: "DELETE" })
      },
      {
        id: attachmentId,
        feedbackId,
        objectKey: "",
        fileName: "",
        contentType: "application/octet-stream",
        sizeBytes: 0,
        deletedAt: new Date().toISOString(),
        createdAt: new Date().toISOString()
      }
    );
  },
  async redactFeedback(
    productId: string,
    feedbackId: string,
    fields: FeedbackRedactionField[]
  ) {
    return requestJson<FeedbackRecord>(
      `/products/${productId}/feedback/${feedbackId}/redact`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "REDACT", fields })
      },
      demoFeedbackRecords().find((item) => item.id === feedbackId) ?? demoFeedbackRecords()[0]
    );
  },
  async deleteFeedback(productId: string, feedbackId: string) {
    const fallback = demoFeedbackRecords().find((item) => item.id === feedbackId)
      ?? demoFeedbackRecords()[0];
    return requestJson<FeedbackRecord>(
      `/products/${productId}/feedback/${feedbackId}`,
      {
        method: "DELETE",
        body: JSON.stringify({ confirmation: "DELETE" })
      },
      {
        ...fallback,
        deletedAt: new Date().toISOString()
      }
    );
  },
  async linkFeedbackGitHubIssue(
    productId: string,
    feedbackId: string,
    githubIssueId: string
  ) {
    return requestJson<LinkedGitHubIssueRecord>(
      `/products/${productId}/feedback/${feedbackId}/github-links`,
      {
        method: "POST",
        body: JSON.stringify({ githubIssueId })
      },
      {
        id: githubIssueId,
        productId,
        githubIssueId,
        number: 0,
        title: "Demo GitHub issue",
        labels: [],
        state: "open",
        commentsCount: 0,
        url: "#",
        syncedAt: new Date().toISOString(),
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async unlinkFeedbackGitHubIssue(
    productId: string,
    feedbackId: string,
    githubIssueId: string
  ) {
    return requestJson<LinkedGitHubIssueRecord>(
      `/products/${productId}/feedback/${feedbackId}/github-links/${githubIssueId}`,
      {
        method: "DELETE",
        body: JSON.stringify({ confirmation: "UNLINK" })
      },
      {
        id: githubIssueId,
        productId,
        githubIssueId,
        number: 0,
        title: "Demo GitHub issue",
        labels: [],
        state: "open",
        commentsCount: 0,
        url: "#",
        syncedAt: new Date().toISOString(),
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
  },
  async releases(productId = "stacio"): Promise<ReleaseListRecord[]> {
    const items = await fetchListJson<ReleaseRecord[]>(`/products/${productId}/releases`, []);
    if (demoModeEnabled() && items.length === 0) {
      return releases;
    }
    return items.map((item) => ({
      id: item.id,
      version: item.version,
      build: item.buildNumber,
      channel: item.channel,
      status: humanize(item.status),
      artifact: item.artifactName,
      artifactName: item.artifactName,
      artifactUrl: item.artifactUrl,
      artifactType: item.artifactType,
      artifactSize: item.artifactSize,
      minimumSystemVersion: item.minimumSystemVersion,
      sparkleEdDsaSignature: item.sparkleEdDsaSignature,
      releaseNotes: item.releaseNotes,
      aiReleaseSummary: item.aiReleaseSummary,
      aiRiskSummary: item.aiRiskSummary,
      preflightEvidence: item.preflightEvidence,
      createdBy: item.createdBy,
      publishedBy: item.publishedBy,
      checks: releaseCheckSummary(item.preflightEvidence),
      updatedAt: formatDate(item.publishedAt ?? item.createdAt)
    }));
  },
  async createRelease(productId: string, input: ReleaseInput) {
    return requestJson<ReleaseRecord>(
      `/products/${productId}/releases`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: `release_${Date.now()}`,
        productId,
        ...input,
        status: "draft",
        createdAt: new Date().toISOString()
      }
    );
  },
  async updateReleaseDraft(productId: string, releaseId: string, input: ReleaseDraftUpdateInput) {
    return requestJson<ReleaseRecord>(
      `/products/${productId}/releases/${releaseId}/draft`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: releaseId,
        productId,
        version: "demo",
        buildNumber: "0",
        channel: "stable",
        status: "draft",
        artifactName: input.artifactName ?? "demo.dmg",
        artifactUrl: input.artifactUrl,
        artifactType: input.artifactType,
        artifactSize: input.artifactSize,
        minimumSystemVersion: input.minimumSystemVersion,
        sparkleEdDsaSignature: input.sparkleEdDsaSignature,
        releaseNotes: input.releaseNotes,
        aiReleaseSummary: input.aiReleaseSummary,
        aiRiskSummary: input.aiRiskSummary,
        createdAt: new Date().toISOString()
      }
    );
  },
  async releaseAgentRequests(productId: string, releaseId: string) {
    const items = await fetchListJson<ApiAgentRequestItem[]>(
      `/products/${productId}/releases/${releaseId}/agent-requests`,
      []
    );
    return items.map(mapAgentRequest);
  },
  async createReleaseAgentRequest(
    productId: string,
    releaseId: string,
    input: CreateAgentRequestInput
  ) {
    const item = await requestJson<ApiAgentRequestItem>(
      `/products/${productId}/releases/${releaseId}/agent-requests`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: "agent_req_release_demo",
        productId,
        targetType: "release",
        targetId: releaseId,
        requestType: input.requestType,
        agentHint: input.agentHint,
        prompt: input.prompt,
        status: "queued",
        metadata: {},
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    );
    return mapAgentRequest(item);
  },
  async validateRelease(productId: string, releaseId: string) {
    return requestJson<ReleaseValidationResult>(
      `/products/${productId}/releases/${releaseId}/validate`,
      {
        method: "POST"
      },
      {
        passed: false,
        checks: []
      }
    );
  },
  async checkReleaseDownload(productId: string, releaseId: string) {
    return requestJson<ReleaseDownloadCheckResult>(
      `/products/${productId}/releases/${releaseId}/check-download`,
      {
        method: "POST"
      },
      {
        release: {
          id: releaseId,
          productId,
          version: "demo",
          buildNumber: "0",
          channel: "internal",
          status: "draft",
          artifactName: "demo.dmg",
          createdAt: new Date().toISOString()
        },
        downloadReachabilityEvidence: {
          status: "not_checked",
          summary: "Demo mode did not check download reachability"
        }
      }
    );
  },
  async previewReleaseAppcastDiff(productId: string, releaseId: string) {
    return requestJson<ReleaseAppcastDiff>(
      `/products/${productId}/releases/${releaseId}/appcast-diff`,
      {
        method: "GET"
      },
      {
        releaseId,
        channel: "stable",
        addedItem: {
          version: "demo",
          buildNumber: "0"
        },
        currentItemCount: 0,
        previewItemCount: 1,
        currentXml: "",
        previewXml: ""
      }
    );
  },
  async appcastEntries(productId = "stacio", channel?: string) {
    const query = channel ? `?channel=${encodeURIComponent(channel)}` : "";
    return fetchListJson<AppcastEntryRecord[]>(`/products/${productId}/appcast-entries${query}`, []);
  },
  async releaseArtifacts(productId: string, releaseId: string) {
    return fetchListJson<ReleaseArtifactRecord[]>(`/products/${productId}/releases/${releaseId}/artifacts`, []);
  },
  async releasePublications(productId: string, releaseId: string) {
    return fetchListJson<ReleasePublicationRecord[]>(
      `/products/${productId}/releases/${releaseId}/publications`,
      []
    );
  },
  async retryReleasePublication(productId: string, releaseId: string) {
    return requestJson<{ jobId?: string; targets: ReleasePublicationRecord["target"][] }>(
      `/products/${productId}/releases/${releaseId}/publications/retry`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "RETRY_SYNC" })
      },
      { targets: [] }
    );
  },
  async publishRelease(releaseId: string, productId = "stacio") {
    return requestJson<unknown | undefined>(
      `/products/${productId}/releases/${releaseId}/publish`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "PUBLISH" })
      },
      undefined
    );
  },
  async updateReleaseLifecycle(releaseId: string, action: ReleaseLifecycleAction, productId = "stacio") {
    return requestJson<unknown | undefined>(
      `/products/${productId}/releases/${releaseId}/lifecycle`,
      {
        method: "POST",
        body: JSON.stringify({ action, confirmation: releaseLifecycleConfirmations[action] })
      },
      undefined
    );
  },
  async licenses(productId = "stacio") {
    const items = await fetchListJson<LicenseRecord[]>(`/products/${productId}/licenses`, []);
    if (demoModeEnabled() && items.length === 0) {
      return licenses;
    }
    return items.map((item) => ({
      id: item.id,
      customer: item.customerName,
      email: item.customerEmail,
      plan: humanize(item.plan),
      status: humanize(item.status),
      devices: `${item.devices}/${item.seats}`,
      expires: formatDate(item.expiresAt)
    }));
  },
  async licenseDetail(licenseId: string, productId = "stacio") {
    return fetchJson<LicenseDetailRecord>(
      `/products/${productId}/licenses/${licenseId}`,
      fallbackLicenseDetail(productId, licenseId)
    );
  },
  async createLicense(productId: string, input: LicenseInput) {
    return requestJson<LicenseCreationResult>(
      `/products/${productId}/licenses`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        license: {
          id: `license_${Date.now()}`,
          productId,
          customerName: input.customerName,
          customerEmail: input.customerEmail,
          username: input.username,
          plan: input.plan,
          status: input.status ?? "active",
          seats: input.seats ?? 1,
          devices: 0,
          maxDevices: input.maxDevices,
          entitlements: input.entitlements ?? [],
          offlineGraceDays: input.offlineGraceDays,
          expiresAt: input.expiresAt,
          createdAt: new Date().toISOString()
        },
        licenseKey: "DEMO-LICENSE-KEY",
        revealPolicy: "one_time"
      }
    );
  },
  async sendLicenseEmail(
    licenseId: string,
    input: LicenseEmailInput,
    productId = "stacio"
  ): Promise<LicenseEmailResult> {
    const result = await requestJson<ApiLicenseEmailResult>(
      `/products/${productId}/licenses/${licenseId}/email`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        notification: {
          id: `notification_license_${Date.now()}`,
          type: "customer_license_issued",
          recipient: "",
          payload: {
            licenseId,
            licenseKey: input.licenseKey
          },
          priority: "normal",
          status: "queued",
          createdAt: new Date().toISOString()
        },
        job: {
          id: `job_license_${Date.now()}`,
          name: "notification.send",
          payload: {
            productId,
            licenseId
          }
        }
      }
    );
    return {
      notification: mapNotificationRecord(result.notification),
      job: result.job
    };
  },
  async batchSendLicenseEmails(
    productId: string,
    items: BatchLicenseEmailInput[],
    confirmation: "SEND"
  ): Promise<BatchLicenseEmailResult> {
    const result = await requestJson<ApiBatchLicenseEmailResult>(
      `/products/${productId}/licenses/batch-email`,
      {
        method: "POST",
        body: JSON.stringify({
          confirmation,
          items
        })
      },
      {
        requestedCount: items.length,
        queuedCount: items.length,
        skippedCount: 0,
        queued: items.map((item) => ({
          licenseId: item.licenseId,
          recipient: "",
          notification: {
            id: `notification_batch_license_${Date.now()}_${item.licenseId}`,
            type: "customer_license_issued",
            recipient: "",
            payload: {
              licenseId: item.licenseId,
              licenseKey: item.licenseKey
            },
            priority: "normal",
            status: "queued",
            createdAt: new Date().toISOString()
          },
          job: {
            id: `job_batch_license_${Date.now()}_${item.licenseId}`,
            name: "notification.send"
          }
        })),
        skipped: []
      }
    );
    return {
      ...result,
      queued: result.queued.map((item) => ({
        ...item,
        notification: mapNotificationRecord(item.notification)
      }))
    };
  },
  async batchCreateLicenses(productId: string, input: BatchLicenseInput) {
    const result = await requestJson<BatchLicenseCreationResponse>(
      `/products/${productId}/licenses/batch`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        items: input.recipients.map((recipient, index) => ({
          license: {
            id: `license_batch_${Date.now()}_${index}`,
            productId,
            customerName: recipient.customerName,
            customerEmail: recipient.customerEmail,
            username: recipient.username,
            plan: input.plan,
            status: input.status ?? "active",
            seats: input.seats ?? 1,
            devices: 0,
            maxDevices: input.maxDevices,
            entitlements: input.entitlements ?? [],
            offlineGraceDays: input.offlineGraceDays,
            expiresAt: input.expiresAt,
            createdAt: new Date().toISOString()
          },
          licenseKey: `DEMO-BATCH-LICENSE-KEY-${index + 1}`,
          revealPolicy: "one_time"
        }))
      }
    );
    return result.items;
  },
  async updateLicense(
    licenseId: string,
    input: UpdateLicenseInput,
    productId = "stacio"
  ) {
    return requestJson<unknown | undefined>(
      `/products/${productId}/licenses/${licenseId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      undefined
    );
  },
  async resetLicenseActivations(licenseId: string, confirmation: "RESET", productId = "stacio") {
    return requestJson<unknown | undefined>(
      `/products/${productId}/licenses/${licenseId}/reset-activations`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation })
      },
      undefined
    );
  },
  async githubIssues(productId = "stacio") {
    const items = await fetchListJson<ApiGitHubIssueItem[]>(`/products/${productId}/github/issues`, []);
    if (demoModeEnabled() && items.length === 0) {
      return githubIssues;
    }
    return items.map((item) => ({
      id: item.id,
      number: item.number,
      title: item.title,
      labels: item.labels,
      author: item.author ?? "-",
      state: humanize(item.state),
      comments: item.commentsCount,
      linkedFeedback: item.linkedFeedbackId ?? "-",
      url: item.url,
      updatedAt: formatDate(item.githubUpdatedAt ?? item.syncedAt ?? item.updatedAt)
    }));
  },
  async githubSyncRuns(productId = "stacio") {
    const items = await fetchListJson<ApiGitHubSyncRunItem[]>(
      `/products/${productId}/github/sync-runs`,
      []
    );
    if (demoModeEnabled() && items.length === 0) {
      return githubSyncRuns;
    }
    return items.map((item) => ({
      id: item.id,
      trigger: humanize(item.trigger),
      status: humanize(item.status),
      fetched: item.fetchedCount,
      changed: item.changedCount,
      feedbackCreated: item.feedbackCreatedCount ?? 0,
      error: item.error ?? undefined,
      finishedAt: formatDate(item.finishedAt ?? item.createdAt)
    }));
  },
  async pullGitHubIssues(productId = "stacio") {
    return requestJson<unknown | undefined>(
      `/products/${productId}/github/pull/enqueue`,
      {
        method: "POST",
        body: JSON.stringify({})
      },
      undefined
    );
  },
  async commentGitHubIssue(
    productId: string,
    issueId: string,
    input: GitHubIssueCommentInput
  ) {
    return requestJson<GitHubIssueCommentResult>(
      `/products/${productId}/github/issues/${issueId}/comments`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        commentId: "demo-comment",
        url: "#",
        body: input.body
      }
    );
  },
  async updateGitHubIssue(
    productId: string,
    issueId: string,
    input: GitHubIssueUpdateInput
  ) {
    const item = await requestJson<ApiGitHubIssueItem>(
      `/products/${productId}/github/issues/${issueId}`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        id: issueId,
        number: 0,
        title: "Demo GitHub issue",
        labels: input.labels ?? [],
        state: input.state ?? "open",
        commentsCount: 0,
        url: "#"
      }
    );
    return {
      id: item.id,
      number: item.number,
      title: item.title,
      labels: item.labels,
      author: item.author ?? "-",
      state: humanize(item.state),
      comments: item.commentsCount,
      linkedFeedback: item.linkedFeedbackId ?? "-",
      url: item.url,
      updatedAt: formatDate(item.githubUpdatedAt ?? item.syncedAt ?? item.updatedAt)
    };
  },
  async aiAnalysis(productId = "stacio", query: AiAnalysisQuery = {}): Promise<AiAnalysisRecord[]> {
    const parameters = new URLSearchParams();
    if (query.targetType) parameters.set("targetType", query.targetType);
    if (query.targetId) parameters.set("targetId", query.targetId);
    const queryString = parameters.toString();
    const items = await fetchListJson<ApiAiAnalysisItem[]>(
      `/products/${productId}/ai-analysis${queryString ? `?${queryString}` : ""}`,
      []
    );
    if (demoModeEnabled() && items.length === 0) {
      return aiAnalyses.filter((item) => {
        const [targetType, targetId] = item.target.split(" / ");
        return (!query.targetType || targetType === query.targetType) &&
          (!query.targetId || targetId === query.targetId);
      });
    }
    return items.map((item) => ({
      id: item.id,
      target: `${item.targetType} / ${item.targetId}`,
      targetType: item.targetType,
      targetId: item.targetId,
      agent: item.agentIdentity,
      model: item.model ?? item.provider ?? "-",
      analysisType: humanize(item.analysisType),
      summary: stringFromOutput(item.outputBody, ["summary", "riskSummary", "recommendation"]),
      classification: typeof item.outputBody.classification === "string" ? item.outputBody.classification : item.targetType,
      replyDraft: typeof item.outputBody.replyDraft === "string" ? item.outputBody.replyDraft : undefined,
      outputBody: item.outputBody,
      inputReferencesPreview: stringifyDetail(item.inputReferences),
      outputBodyPreview: stringifyDetail(item.outputBody),
      confidence: item.confidence ?? "-",
      adoptionState: humanize(item.adoptionState),
      createdAt: formatDate(item.createdAt)
    }));
  },
  async reviewAiAnalysis(
    analysisId: string,
    adoptionState: "accepted" | "edited_accepted" | "ignored",
    productId = "stacio",
    outputBody?: Record<string, unknown>
  ) {
    return requestJson<unknown | undefined>(
      `/products/${productId}/ai-analysis/${analysisId}`,
      {
        method: "PATCH",
        body: JSON.stringify({
          adoptionState,
          ...(outputBody ? { outputBody } : {})
        })
      },
      undefined
    );
  },
  async proposedActions(productId = "stacio") {
    const items = await fetchListJson<ApiProposedActionItem[]>(
      `/products/${productId}/proposed-actions`,
      []
    );
    if (demoModeEnabled() && items.length === 0) {
      return aiProposedActions;
    }
    return items.map((item) => ({
      id: item.id,
      actionType: item.actionType,
      target: `${item.targetType} / ${item.targetId}`,
      payloadPreview: stringifyDetail(item.payload),
      rationale:
        item.analysis?.outputBody && typeof item.analysis.outputBody.rationale === "string"
          ? item.analysis.outputBody.rationale
          : "等待人工查看建议动作。",
      agent: item.analysis?.agentIdentity ?? "-",
      model: item.analysis?.model ?? item.analysis?.provider ?? "-",
      status: humanize(item.status),
      createdAt: formatDate(item.createdAt)
    }));
  },
  async reviewProposedAction(
    actionId: string,
    status: "accepted" | "rejected" | "dismissed",
    productId = "stacio"
  ) {
    return requestJson<unknown | undefined>(
      `/products/${productId}/proposed-actions/${actionId}`,
      {
        method: "PATCH",
        body: JSON.stringify({ status })
      },
      undefined
    );
  },
  async executeProposedAction(actionId: string, productId = "stacio") {
    return requestJson<unknown | undefined>(
      `/products/${productId}/proposed-actions/${actionId}/execute`,
      {
        method: "POST",
        body: JSON.stringify({ confirmation: "EXECUTE" })
      },
      undefined
    );
  },
  async notificationTemplates(productId = "stacio"): Promise<NotificationTemplateRecord[]> {
    const items = await fetchListJson<ApiNotificationTemplateItem[]>(`/products/${productId}/notification-templates`, []);
    if (demoModeEnabled() && items.length === 0) {
      return notificationTemplates;
    }
    return items.map((item) => ({
      id: item.id,
      type: item.type,
      subject: item.subjectTemplate,
      status: humanize(item.status),
      updatedAt: formatDate(item.updatedAt),
      htmlTemplate: item.htmlTemplate,
      textTemplate: item.textTemplate
    }));
  },
  async upsertNotificationTemplate(
    productId: string,
    type: string,
    input: NotificationTemplateInput
  ): Promise<NotificationTemplateRecord> {
    const item = await requestJson<ApiNotificationTemplateItem>(
      `/products/${productId}/notification-templates/${encodeURIComponent(type)}`,
      {
        method: "PUT",
        body: JSON.stringify(input)
      },
      {
        id: `template_${type}`,
        type,
        subjectTemplate: input.subjectTemplate,
        htmlTemplate: input.htmlTemplate,
        textTemplate: input.textTemplate,
        status: input.status ?? "active",
        updatedAt: new Date().toISOString()
      }
    );
    return {
      id: item.id,
      type: item.type,
      subject: item.subjectTemplate,
      status: humanize(item.status),
      updatedAt: formatDate(item.updatedAt),
      htmlTemplate: item.htmlTemplate,
      textTemplate: item.textTemplate
    };
  },
  async notificationPolicy(productId = "stacio"): Promise<NotificationPolicyRecord> {
    return fetchJson<NotificationPolicyRecord>(
      `/products/${productId}/notification-policy`,
      {
        productId,
        quietHoursEnabled: false,
        quietHoursStart: "22:00",
        quietHoursEnd: "08:00",
        quietHoursTimeZone: "Asia/Shanghai",
        updatedAt: new Date(0).toISOString()
      }
    );
  },
  async updateNotificationPolicy(
    productId: string,
    input: NotificationPolicyInput
  ): Promise<NotificationPolicyRecord> {
    return requestJson<NotificationPolicyRecord>(
      `/products/${productId}/notification-policy`,
      {
        method: "PATCH",
        body: JSON.stringify(input)
      },
      {
        productId,
        ...input,
        updatedAt: new Date().toISOString()
      }
    );
  },
  async notifications(productId = "stacio"): Promise<NotificationRecord[]> {
    const items = await fetchListJson<ApiNotificationItem[]>(`/products/${productId}/notifications`, []);
    if (demoModeEnabled() && items.length === 0) {
      return notifications;
    }
    return items.map(mapNotificationRecord);
  },
  async createNotification(
    productId: string,
    input: NotificationInput
  ): Promise<NotificationRecord> {
    const item = await requestJson<ApiNotificationItem>(
      `/products/${productId}/notifications`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: `notification_${Date.now()}`,
        type: input.type,
        recipient: input.recipient,
        payload: input.payload,
        priority: input.priority ?? "normal",
        status: input.status ?? "queued",
        createdAt: new Date().toISOString()
      }
    );
    return mapNotificationRecord(item);
  },
  async createDailyFeedbackDigest(
    productId: string,
    input: { recipient: string; date?: string }
  ): Promise<NotificationRecord> {
    const item = await requestJson<ApiNotificationItem>(
      `/products/${productId}/notifications/daily-feedback-digest`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        id: `notification_digest_${Date.now()}`,
        type: "admin_daily_feedback_digest",
        recipient: input.recipient,
        payload: {
          summary: "Demo daily feedback digest"
        },
        priority: "normal",
        status: "queued",
        createdAt: new Date().toISOString()
      }
    );
    return mapNotificationRecord(item);
  },
  async createLicenseExpiringReminders(
    productId: string,
    input: LicenseExpiringReminderInput = {}
  ): Promise<LicenseExpiringReminderResult> {
    const now = new Date().toISOString();
    const result = await requestJson<ApiLicenseExpiringReminderResult>(
      `/products/${productId}/notifications/license-expiring`,
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        scannedCount: 0,
        createdCount: 0,
        skippedCount: 0,
        window: {
          referenceDate: input.referenceDate ?? now,
          days: input.days ?? 30,
          cutoffDate: input.referenceDate ?? now
        },
        created: [],
        skipped: []
      }
    );
    return {
      ...result,
      created: result.created.map(mapNotificationRecord)
    };
  },
  async previewTemplate(input: {
    productId?: string;
    subjectTemplate: string;
    htmlTemplate: string;
    textTemplate?: string;
    payload: Record<string, unknown>;
  }): Promise<TemplatePreview> {
    return requestJson(
      "/notification-templates/preview",
      {
        method: "POST",
        body: JSON.stringify(input)
      },
      {
        subject: input.subjectTemplate,
        html: input.htmlTemplate,
        text: input.textTemplate
      }
    );
  },
  async sendNotification(
    notificationId: string,
    dryRun = true,
    mode: "sync" | "queue" = "queue",
    productId = "stacio"
  ) {
    return requestJson<unknown | undefined>(
      `/products/${productId}/notifications/${notificationId}/send`,
      {
        method: "POST",
        body: JSON.stringify({
          mode,
          dryRun,
          ...(!dryRun ? { confirmation: "SEND" } : {})
        })
      },
      undefined
    );
  },
  async notificationDeliveries(productId: string, notificationId: string) {
    const items = await fetchListJson<ApiNotificationDeliveryItem[]>(
      `/products/${productId}/notifications/${notificationId}/deliveries`,
      []
    );
    return items.map((item) => ({
      id: item.id,
      notificationId: item.notificationId,
      provider: item.provider,
      attempt: item.attempt,
      status: humanize(item.status),
      providerMessageId: item.providerMessageId,
      error: item.error,
      sentAt: item.sentAt ? formatDate(item.sentAt) : undefined,
      createdAt: formatDate(item.createdAt)
    }));
  },
  async presignReleaseArtifactUpload(
    productId: string,
    input: PresignReleaseArtifactInput
  ) {
    return requestJson<PresignedUploadRecord>(
      `/products/${productId}/storage/presign-upload`,
      {
        method: "POST",
        body: JSON.stringify({
          category: "release_artifact",
          fileName: input.fileName,
          contentType: input.contentType,
          sizeBytes: input.sizeBytes,
          ...(input.refId ? { refId: input.refId } : {})
        })
      },
      {
        objectKey: `products/${productId}/release_artifact/${input.fileName}`,
        uploadUrl: `mock://object-storage/stacio-ops/products/${productId}/release_artifact/${input.fileName}`,
        publicUrl: undefined,
        dryRun: true
      }
    );
  },
  async presignUploadDryRun(productId = "stacio") {
    return requestJson<{ objectKey: string; uploadUrl: string } | undefined>(
      `/products/${productId}/storage/presign-upload`,
      {
        method: "POST",
        body: JSON.stringify({
          category: "release_artifact",
          refId: "rel_smoke",
          fileName: "Stacio-Smoke.dmg",
          contentType: "application/x-apple-diskimage",
          sizeBytes: 1024,
          dryRun: true
        })
      },
      undefined
    );
  },
  async auditLogs(productId = "stacio", filters: AuditLogFilters = {}) {
    const parameters = new URLSearchParams({ productId });
    for (const key of ["search", "actorType", "actorId", "action", "targetType", "targetId", "ipAddress", "createdFrom", "createdTo"] as const) {
      const value = filters[key];
      if (value) {
        parameters.set(key, value);
      }
    }
    const items = await fetchListJson<ApiAuditLogItem[]>(
      `/audit-logs?${parameters.toString()}`,
      []
    );
    if (demoModeEnabled() && items.length === 0) {
      return auditLogs;
    }
    return items.map((item) => ({
      id: item.id,
      time: formatDate(item.createdAt),
      actor: item.actorId ?? item.actorType,
      actorType: humanize(item.actorType),
      action: item.action,
      target: item.targetId ? `${item.targetType} / ${item.targetId}` : item.targetType,
      detail: stringifyDetail(item.afterValue ?? item.metadata),
      ip: item.ipAddress ?? "-"
    }));
  }
};
