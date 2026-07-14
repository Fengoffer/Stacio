import { randomUUID } from "node:crypto";
import { seedFeedback, seedLicenses, seedNotificationTemplates, seedProducts, seedReleases } from "./seed.js";
import { recentAuditEvents, summarizeEmailDeliveryStatus } from "./dashboardSummary.js";
import { summarizeWebsiteAnalytics } from "../services/websiteAnalytics.js";
import { buildReleasePreflightEvidence } from "./releaseValidation.js";
import { generateAppcastXml } from "../services/appcast.js";
import { generateLicenseKey, hashLicenseKey, licenseKeyPrefix } from "../services/licenseKeys.js";
import {
  agentApiKeyPrefix,
  generateAgentApiKey,
  hashAgentApiKey,
  verifyAgentApiKey
} from "../services/agentApiKeys.js";
import {
  generateProductFeedbackApiKey,
  hashProductFeedbackApiKey,
  verifyProductFeedbackApiKey
} from "../services/productApiKeys.js";
import { defaultNotificationPolicy } from "../services/notificationPolicy.js";
import type {
  AgentApiKeyItem,
  AgentRequestItem,
  AppcastEntryItem,
  AuditLogItem,
  AiAnalysisResultItem,
  AiProposedActionItem,
  ConnectorItem,
  CustomerDetail,
  CustomerItem,
  CustomerNoteItem,
  DashboardSummary,
  FeedbackAttachmentItem,
  FeedbackCommentItem,
  FeedbackItem,
  FeedbackPriority,
  FeedbackType,
  GitHubIssueItem,
  GitHubSyncRunItem,
  LicenseActivationItem,
  LicenseDetail,
  LicenseItem,
  LicenseValidationLogItem,
  NotificationDeliveryItem,
  NotificationItem,
  NotificationPolicyItem,
  NotificationTemplateItem,
  PlanItem,
  Product,
  ReleaseChannelItem,
  ReleaseArtifactItem,
  ReleaseItem,
  ReleasePublicationItem,
  ReleasePublicationStatus,
  ReleasePublicationTarget,
  SettingsSummary,
  WebsiteAnalyticsSummary,
  WebsiteEventItem,
  WebsiteEventType
} from "./types.js";

function customerSnapshotFromLicense(license: LicenseItem): CustomerItem {
  return {
    id: license.customerId ?? `license_customer_${license.id}`,
    productId: license.productId,
    email: license.customerEmail,
    name: license.customerName,
    status: license.status === "trial" ? "trial" : "active",
    riskFlag: false,
    createdAt: license.createdAt,
    updatedAt: license.createdAt
  };
}

export interface CreateFeedbackInput {
  title: string;
  description: string;
  type?: FeedbackType;
  contactEmail?: string;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  anonymousDeviceId?: string;
  licenseState?: string;
  licenseKeyHash?: string;
  diagnosticsSummary?: Record<string, unknown>;
}

export interface IdempotencyRecord {
  scope: string;
  key: string;
  requestHash: string;
  statusCode: number;
  responseBody: Record<string, unknown>;
  createdAt: string;
  expiresAt?: string;
}

export interface CreateIdempotencyRecordInput {
  scope: string;
  key: string;
  requestHash: string;
  statusCode: number;
  responseBody: Record<string, unknown>;
  expiresAt?: string;
}

export interface UpdateFeedbackInput {
  status?: FeedbackItem["status"];
  priority?: FeedbackItem["priority"];
  assignedUserId?: string | null;
  duplicateOfId?: string | null;
  relatedReleaseId?: string | null;
  aiSummary?: string | null;
  aiClassification?: string | null;
  aiSuggestedPriority?: FeedbackItem["priority"] | null;
}

export interface CreateFeedbackCommentInput {
  authorType: FeedbackCommentItem["authorType"];
  authorId?: string;
  visibility: FeedbackCommentItem["visibility"];
  body: string;
  deliveryId?: string;
  notificationId?: string;
  deliveryStatus?: FeedbackCommentItem["deliveryStatus"];
}

export interface CreateFeedbackAttachmentInput {
  objectKey: string;
  fileName: string;
  contentType: string;
  sizeBytes: number;
  sha256?: string;
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

export interface CreateAuditLogInput {
  actorType: AuditLogItem["actorType"];
  actorId?: string;
  action: string;
  targetType: string;
  targetId?: string;
  productId?: string;
  beforeValue?: Record<string, unknown>;
  afterValue?: Record<string, unknown>;
  ipAddress?: string;
  userAgent?: string;
  metadata?: Record<string, unknown>;
}

export interface CreateAgentApiKeyInput {
  name: string;
  productIds: string[];
  scopes: string[];
  expiresAt?: string;
  createdBy?: string;
}

export interface CreateAgentApiKeyResult {
  apiKey: AgentApiKeyItem;
  key: string;
}

export interface CreateAgentRequestInput {
  productId: string;
  targetType: AgentRequestItem["targetType"];
  targetId: string;
  requestType: AgentRequestItem["requestType"];
  agentHint?: string;
  prompt: string;
  requestedBy?: string;
  metadata?: Record<string, unknown>;
}

export interface AgentRequestQuery {
  targetType?: AgentRequestItem["targetType"];
  targetId?: string;
  status?: string;
}

export interface RotateAgentApiKeyResult {
  apiKey: AgentApiKeyItem;
  key: string;
}

export interface UpdateAgentApiKeyInput {
  status?: "active" | "disabled";
}

export interface AgentApiKeyAuthRecord extends AgentApiKeyItem {
  keyHash: string;
}

export interface CreateProductInput {
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

export type UpdateProductInput = Partial<Omit<CreateProductInput, "id">> & {
  status?: Product["status"];
};

export interface CreatePlanInput {
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
  billingInterval?: string;
  couponSupport?: boolean;
  subscriptionSupport?: boolean;
  entitlements?: string[];
  status?: PlanItem["status"];
}

export type UpdatePlanInput = Partial<Omit<CreatePlanInput, "id">>;

export interface CreateReleaseChannelInput {
  name: string;
  appcastUrl?: string;
  currentReleaseId?: string;
  allowedPlanIds?: string[];
  minimumUpgradableVersion?: string;
  rolloutPercentage?: number;
  autoDownloadAllowed?: boolean;
  forceUpdatePrompt?: boolean;
  status?: ReleaseChannelItem["status"];
}

export interface CreateWebsiteEventInput {
  eventId: string;
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
  deviceType: WebsiteEventItem["deviceType"];
  occurredAt: string;
}

export interface UpdateReleaseChannelInput {
  name?: string;
  appcastUrl?: string | null;
  currentReleaseId?: string | null;
  allowedPlanIds?: string[];
  minimumUpgradableVersion?: string | null;
  rolloutPercentage?: number;
  autoDownloadAllowed?: boolean;
  forceUpdatePrompt?: boolean;
  status?: ReleaseChannelItem["status"];
}

export interface CreateProductResult {
  product: Product;
  feedbackApiKey: string;
}

export interface CreateCustomerInput {
  email: string;
  name: string;
  company?: string;
  status?: CustomerItem["status"];
  riskFlag?: boolean;
}

export interface UpdateCustomerInput {
  email?: string;
  name?: string;
  company?: string | null;
  status?: CustomerItem["status"];
  riskFlag?: boolean;
}

export interface CreateCustomerNoteInput {
  authorId?: string;
  body: string;
}

export interface MergeCustomersResult {
  source: CustomerItem;
  target: CustomerItem;
}

export interface UpsertConnectorInput {
  name: string;
  config: Record<string, unknown>;
  encryptedSecrets?: string;
}

export interface RecordConnectorTestInput {
  succeeded: boolean;
  error?: string;
  testedAt: string;
}

export interface UpdateNotificationPolicyInput {
  quietHoursEnabled: boolean;
  quietHoursStart: string;
  quietHoursEnd: string;
  quietHoursTimeZone: string;
}

export interface UpsertGitHubIssueInput {
  githubIssueId: string;
  number: number;
  title: string;
  body?: string;
  labels?: string[];
  author?: string;
  state: "open" | "closed";
  commentsCount?: number;
  url: string;
  githubCreatedAt?: string;
  githubUpdatedAt?: string;
  githubClosedAt?: string;
}

export interface SyncGitHubIssuesInput {
  trigger: GitHubSyncRunItem["trigger"];
  issues: UpsertGitHubIssueInput[];
}

export interface UpdateGitHubIssueInput {
  title?: string;
  body?: string;
  labels?: string[];
  author?: string;
  state?: "open" | "closed";
  commentsCount?: number;
  url?: string;
  githubUpdatedAt?: string;
  githubClosedAt?: string;
}

export interface RecordGitHubSyncFailureInput {
  trigger: GitHubSyncRunItem["trigger"];
  error: string;
}

export interface CreateAiAnalysisInput {
  productId: string;
  targetType: AiAnalysisResultItem["targetType"];
  targetId: string;
  agentIdentity: string;
  provider?: string;
  model?: string;
  analysisType: string;
  inputReferences?: Record<string, unknown>;
  outputBody: Record<string, unknown>;
  confidence?: string;
}

export interface ReviewAiAnalysisInput {
  adoptionState: Extract<AiAnalysisResultItem["adoptionState"], "accepted" | "edited_accepted" | "ignored">;
  outputBody?: Record<string, unknown>;
  reviewedBy?: string;
}

export interface CreateProposedActionInput {
  analysisId: string;
  actionType: string;
  payload: Record<string, unknown>;
}

export interface ReviewProposedActionInput {
  status: "accepted" | "rejected" | "dismissed" | "executed";
  reviewedBy?: string;
}

export interface UpsertNotificationTemplateInput {
  type: string;
  subjectTemplate: string;
  htmlTemplate: string;
  textTemplate?: string;
  status?: NotificationTemplateItem["status"];
}

export interface CreateNotificationInput {
  type: string;
  recipient: string;
  payload: Record<string, unknown>;
  priority?: NotificationItem["priority"];
  status?: NotificationItem["status"];
  scheduledAt?: string;
}

export interface CreateNotificationDeliveryInput {
  provider: string;
  attempt?: number;
  status: NotificationDeliveryItem["status"];
  providerMessageId?: string;
  error?: string;
  sentAt?: string;
}

export interface CreateLicenseInput {
  customerName: string;
  customerEmail: string;
  username?: string;
  plan: LicenseItem["plan"];
  seats?: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  expiresAt: string;
  status?: LicenseItem["status"];
}

export interface UpdateLicenseInput {
  plan?: LicenseItem["plan"];
  status?: LicenseItem["status"];
  seats?: number;
  maxDevices?: number;
  entitlements?: string[];
  offlineGraceDays?: number;
  expiresAt?: string;
}

export interface CreateLicenseResult {
  license: LicenseItem;
  licenseKey: string;
}

export interface ValidateLicenseInput {
  licenseKey: string;
  email: string;
  username: string;
  appVersion?: string;
  buildNumber?: string;
  anonymousDeviceId?: string;
  machineFingerprintHash?: string;
}

export interface LicenseValidationResult {
  valid: boolean;
  reason?: string;
  license?: LicenseItem;
  offlineGraceSeconds?: number;
}

export interface CreateReleaseInput {
  channel: ReleaseItem["channel"];
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
  packageSignatureEvidence?: Record<string, unknown>;
  downloadReachabilityEvidence?: Record<string, unknown>;
  createdBy?: string;
}

export interface UpdateReleaseDraftInput {
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
  packageSignatureEvidence?: Record<string, unknown>;
  downloadReachabilityEvidence?: Record<string, unknown>;
}

export interface ReleaseValidationResult {
  release: ReleaseItem;
  passed: boolean;
  checks: Array<{ key: string; passed: boolean; message: string }>;
}

export interface UpdateReleasePublicationInput {
  status: ReleasePublicationStatus;
  objectKey?: string | null;
  externalUrl?: string | null;
  lastError?: string | null;
  metadata?: Record<string, unknown>;
  startedAt?: string | null;
  completedAt?: string | null;
  incrementAttempts?: boolean;
}

export interface FinalizePublishedReleaseArtifactInput {
  objectKey: string;
  artifactUrl: string;
}

function initialReleasePreflightEvidence(input: {
  packageSignatureEvidence?: Record<string, unknown>;
  downloadReachabilityEvidence?: Record<string, unknown>;
}) {
  return {
    ...(input.packageSignatureEvidence ? { packageSignatureEvidence: input.packageSignatureEvidence } : {}),
    ...(input.downloadReachabilityEvidence
      ? { downloadReachabilityEvidence: input.downloadReachabilityEvidence }
      : {})
  };
}

type StoredProposedAction = Omit<AiProposedActionItem, "analysis">;
interface StoredAgentApiKey extends AgentApiKeyItem {
  keyHash: string;
}

export interface OpsStore {
  listProducts(): Promise<Product[]>;
  findProduct(productId: string): Promise<Product | undefined>;
  createProduct(input: CreateProductInput): Promise<CreateProductResult | undefined>;
  updateProduct(productId: string, input: UpdateProductInput): Promise<Product | undefined>;
  archiveProduct(productId: string): Promise<Product | undefined>;
  rotateProductFeedbackApiKey(productId: string): Promise<string | undefined>;
  verifyProductFeedbackApiKey(productId: string, apiKey: string): Promise<boolean>;
  listReleaseChannels(productId: string): Promise<ReleaseChannelItem[]>;
  createReleaseChannel(
    productId: string,
    input: CreateReleaseChannelInput
  ): Promise<ReleaseChannelItem | undefined>;
  updateReleaseChannel(
    productId: string,
    channelId: string,
    input: UpdateReleaseChannelInput
  ): Promise<ReleaseChannelItem | undefined>;
  listCustomers(productId: string): Promise<CustomerItem[]>;
  findCustomer(productId: string, customerId: string): Promise<CustomerItem | undefined>;
  createCustomer(productId: string, input: CreateCustomerInput): Promise<CustomerItem | undefined>;
  updateCustomer(
    productId: string,
    customerId: string,
    input: UpdateCustomerInput
  ): Promise<CustomerItem | undefined>;
  customerDetail(productId: string, customerId: string): Promise<CustomerDetail | undefined>;
  addCustomerNote(
    productId: string,
    customerId: string,
    input: CreateCustomerNoteInput
  ): Promise<CustomerNoteItem | undefined>;
  mergeCustomers(
    productId: string,
    sourceCustomerId: string,
    targetCustomerId: string
  ): Promise<MergeCustomersResult | undefined>;
  listPlans(productId: string): Promise<PlanItem[]>;
  createPlan(productId: string, input: CreatePlanInput): Promise<PlanItem | undefined>;
  updatePlan(
    productId: string,
    planId: string,
    input: UpdatePlanInput
  ): Promise<PlanItem | undefined>;
  listConnectors(productId: string): Promise<ConnectorItem[]>;
  findConnector(productId: string, type: string): Promise<ConnectorItem | undefined>;
  getConnectorSecretEnvelope(productId: string, type: string): Promise<string | undefined>;
  upsertConnector(
    productId: string,
    type: string,
    input: UpsertConnectorInput
  ): Promise<ConnectorItem | undefined>;
  recordConnectorTest(
    productId: string,
    type: string,
    input: RecordConnectorTestInput
  ): Promise<ConnectorItem | undefined>;
  disconnectConnector(productId: string, type: string): Promise<ConnectorItem | undefined>;
  findIdempotencyRecord(scope: string, key: string): Promise<IdempotencyRecord | undefined>;
  createIdempotencyRecord(input: CreateIdempotencyRecordInput): Promise<IdempotencyRecord>;
  notificationPolicy(productId: string): Promise<NotificationPolicyItem | undefined>;
  updateNotificationPolicy(
    productId: string,
    input: UpdateNotificationPolicyInput
  ): Promise<NotificationPolicyItem | undefined>;
  settingsSummary(productId: string): Promise<SettingsSummary | undefined>;
  dashboard(productId: string): Promise<DashboardSummary | undefined>;
  listFeedback(productId: string): Promise<FeedbackItem[]>;
  findFeedback(productId: string, feedbackId: string): Promise<FeedbackItem | undefined>;
  createFeedback(productId: string, input: CreateFeedbackInput): Promise<FeedbackItem | undefined>;
  updateFeedback(
    productId: string,
    feedbackId: string,
    input: UpdateFeedbackInput
  ): Promise<FeedbackItem | undefined>;
  listFeedbackComments(feedbackId: string): Promise<FeedbackCommentItem[]>;
  createFeedbackComment(
    feedbackId: string,
    input: CreateFeedbackCommentInput
  ): Promise<FeedbackCommentItem | undefined>;
  listFeedbackAttachments(feedbackId: string): Promise<FeedbackAttachmentItem[]>;
  createFeedbackAttachment(
    productId: string,
    feedbackId: string,
    input: CreateFeedbackAttachmentInput
  ): Promise<FeedbackAttachmentItem | undefined>;
  redactFeedbackAttachment(
    productId: string,
    feedbackId: string,
    attachmentId: string
  ): Promise<FeedbackAttachmentItem | undefined>;
  deleteFeedbackAttachment(
    productId: string,
    feedbackId: string,
    attachmentId: string
  ): Promise<FeedbackAttachmentItem | undefined>;
  redactFeedback(
    productId: string,
    feedbackId: string,
    fields: FeedbackRedactionField[]
  ): Promise<FeedbackItem | undefined>;
  deleteFeedback(productId: string, feedbackId: string): Promise<FeedbackItem | undefined>;
  listLinkedGitHubIssues(productId: string, feedbackId: string): Promise<GitHubIssueItem[]>;
  linkGitHubIssue(
    productId: string,
    feedbackId: string,
    githubIssueId: string,
    createdBy?: string
  ): Promise<GitHubIssueItem | "conflict" | undefined>;
  unlinkGitHubIssue(
    productId: string,
    feedbackId: string,
    githubIssueId: string
  ): Promise<GitHubIssueItem | undefined>;
  listReleases(productId: string): Promise<ReleaseItem[]>;
  listAppcastEntries(productId: string, channelName?: string): Promise<AppcastEntryItem[]>;
  listReleaseArtifacts(productId: string, releaseId: string): Promise<ReleaseArtifactItem[]>;
  listReleasePublications(productId: string, releaseId: string): Promise<ReleasePublicationItem[]>;
  updateReleasePublication(
    productId: string,
    releaseId: string,
    target: ReleasePublicationTarget,
    input: UpdateReleasePublicationInput
  ): Promise<ReleasePublicationItem | undefined>;
  finalizePublishedReleaseArtifact(
    productId: string,
    releaseId: string,
    input: FinalizePublishedReleaseArtifactInput
  ): Promise<ReleaseItem | undefined>;
  recordWebsiteEvent(
    productId: string,
    input: CreateWebsiteEventInput
  ): Promise<{ event: WebsiteEventItem; created: boolean } | undefined>;
  websiteAnalytics(productId: string, since?: string): Promise<WebsiteAnalyticsSummary | undefined>;
  listLicenses(productId: string): Promise<LicenseItem[]>;
  createRelease(productId: string, input: CreateReleaseInput): Promise<ReleaseItem | undefined>;
  updateReleaseDraft(
    productId: string,
    releaseId: string,
    input: UpdateReleaseDraftInput
  ): Promise<ReleaseItem | undefined>;
  validateRelease(productId: string, releaseId: string): Promise<ReleaseValidationResult | undefined>;
  publishRelease(productId: string, releaseId: string, publishedBy?: string): Promise<ReleaseItem | undefined>;
  updateReleaseStatus(
    productId: string,
    releaseId: string,
    status: Extract<ReleaseItem["status"], "published" | "paused" | "withdrawn">
  ): Promise<ReleaseItem | undefined>;
  createLicense(productId: string, input: CreateLicenseInput): Promise<CreateLicenseResult | undefined>;
  updateLicense(productId: string, licenseId: string, input: UpdateLicenseInput): Promise<LicenseItem | undefined>;
  resetLicenseActivations(productId: string, licenseId: string): Promise<LicenseItem | undefined>;
  validateLicense(productId: string, input: ValidateLicenseInput): Promise<LicenseValidationResult>;
  licenseDetail(productId: string, licenseId: string): Promise<LicenseDetail | undefined>;
  listGitHubIssues(productId: string): Promise<GitHubIssueItem[]>;
  updateGitHubIssue(
    productId: string,
    githubIssueId: string,
    input: UpdateGitHubIssueInput
  ): Promise<GitHubIssueItem | undefined>;
  syncGitHubIssues(productId: string, input: SyncGitHubIssuesInput): Promise<{
    run: GitHubSyncRunItem;
    issues: GitHubIssueItem[];
    feedbackCreated: FeedbackItem[];
  } | undefined>;
  recordGitHubSyncFailure(
    productId: string,
    input: RecordGitHubSyncFailureInput
  ): Promise<GitHubSyncRunItem | undefined>;
  listGitHubSyncRuns(productId: string): Promise<GitHubSyncRunItem[]>;
  listAiAnalysis(productId: string, targetType?: string, targetId?: string): Promise<AiAnalysisResultItem[]>;
  createAiAnalysis(input: CreateAiAnalysisInput): Promise<AiAnalysisResultItem | undefined>;
  reviewAiAnalysis(
    productId: string,
    analysisId: string,
    input: ReviewAiAnalysisInput
  ): Promise<AiAnalysisResultItem | undefined>;
  listProposedActions(productId: string, status?: string): Promise<AiProposedActionItem[]>;
  createProposedAction(input: CreateProposedActionInput): Promise<AiProposedActionItem | undefined>;
  reviewProposedAction(
    productId: string,
    actionId: string,
    input: ReviewProposedActionInput
  ): Promise<AiProposedActionItem | undefined>;
  listAgentRequests(productId: string, query?: AgentRequestQuery): Promise<AgentRequestItem[]>;
  createAgentRequest(input: CreateAgentRequestInput): Promise<AgentRequestItem | undefined>;
  listNotificationTemplates(productId: string): Promise<NotificationTemplateItem[]>;
  upsertNotificationTemplate(
    productId: string,
    input: UpsertNotificationTemplateInput
  ): Promise<NotificationTemplateItem | undefined>;
  listNotifications(productId: string): Promise<NotificationItem[]>;
  createNotification(productId: string, input: CreateNotificationInput): Promise<NotificationItem | undefined>;
  listNotificationDeliveries(notificationId: string): Promise<NotificationDeliveryItem[]>;
  createNotificationDelivery(
    notificationId: string,
    input: CreateNotificationDeliveryInput
  ): Promise<NotificationDeliveryItem | undefined>;
  listAgentApiKeys(): Promise<AgentApiKeyItem[]>;
  createAgentApiKey(input: CreateAgentApiKeyInput): Promise<CreateAgentApiKeyResult>;
  rotateAgentApiKey(keyId: string): Promise<RotateAgentApiKeyResult | undefined>;
  updateAgentApiKey(keyId: string, input: UpdateAgentApiKeyInput): Promise<AgentApiKeyItem | undefined>;
  findAgentApiKeyByToken(token: string): Promise<AgentApiKeyAuthRecord | undefined>;
  touchAgentApiKeyLastUsed(keyId: string): Promise<void>;
  listAuditLogs(productId?: string): Promise<AuditLogItem[]>;
  createAuditLog(input: CreateAuditLogInput): Promise<AuditLogItem>;
}

function labelMappedType(labels: string[] | undefined): FeedbackType {
  const normalized = new Set((labels ?? []).map((label) => label.toLowerCase()));
  if (normalized.has("bug")) return "bug";
  if (normalized.has("crash")) return "crash";
  if (normalized.has("license") || normalized.has("license_issue")) return "license_issue";
  if (normalized.has("question")) return "question";
  if (normalized.has("feature") || normalized.has("enhancement")) return "feature";
  return "other";
}

function labelMappedPriority(labels: string[] | undefined): FeedbackPriority {
  const normalized = new Set((labels ?? []).map((label) => label.toLowerCase()));
  if (normalized.has("p0") || normalized.has("priority:p0")) return "P0";
  if (normalized.has("p1") || normalized.has("priority:p1")) return "P1";
  if (normalized.has("p3") || normalized.has("priority:p3")) return "P3";
  return "P2";
}

export function createMemoryStore(): OpsStore {
  const products = structuredClone(seedProducts);
  const feedbackApiKeyHashes = new Map<string, string>();
  const feedback = structuredClone(seedFeedback);
  const feedbackComments: FeedbackCommentItem[] = [];
  const feedbackAttachments: FeedbackAttachmentItem[] = [];
  const feedbackGitHubLinks: Array<{
    productId: string;
    feedbackId: string;
    githubIssueId: string;
    createdBy?: string;
  }> = [];
  const releases = structuredClone(seedReleases);
  const appcastEntries: AppcastEntryItem[] = [];
  const releaseArtifacts: ReleaseArtifactItem[] = [];
  const releasePublications: ReleasePublicationItem[] = [];
  const websiteEvents: WebsiteEventItem[] = [];
  const licenses: LicenseItem[] = structuredClone(seedLicenses).map((license, index) => ({
    ...license,
    customerId: index === 0 ? "cust_internal_tester" : "cust_pro_user"
  }));
  const licenseKeyHashes = new Map<string, string>(
    seedLicenses.map((license, index) => [
      license.id,
      hashLicenseKey(index === 0 ? "STACIO-INT-SEED-KEY" : "STACIO-PRO-SEED-KEY")
    ])
  );
  const auditLogs: AuditLogItem[] = [];
  const githubIssues: GitHubIssueItem[] = [];
  const githubSyncRuns: GitHubSyncRunItem[] = [];
  const aiAnalysisResults: AiAnalysisResultItem[] = [];
  const aiProposedActions: StoredProposedAction[] = [];
  const agentRequests: AgentRequestItem[] = [];
  const notificationTemplates: NotificationTemplateItem[] = structuredClone(seedNotificationTemplates);
  const notifications: NotificationItem[] = [];
  const notificationDeliveries: NotificationDeliveryItem[] = [];
  const customerNotes: CustomerNoteItem[] = [];
  const licenseActivations: LicenseActivationItem[] = [];
  const licenseValidationLogs: LicenseValidationLogItem[] = [];
  const agentApiKeys: StoredAgentApiKey[] = [];
  const releaseChannels: ReleaseChannelItem[] = ["stable", "beta", "dev", "internal"].map((name) => ({
    id: `channel_stacio_${name}`,
    productId: "stacio",
    name,
    appcastUrl: `/updates/stacio/${name}/appcast.xml`,
    allowedPlanIds: name === "stable" ? ["plan_free", "plan_pro", "plan_team", "plan_internal"] : ["plan_pro", "plan_team", "plan_internal"],
    rolloutPercentage: 100,
    autoDownloadAllowed: false,
    forceUpdatePrompt: false,
    status: "active",
    createdAt: "2026-07-09T12:00:00.000Z",
    updatedAt: "2026-07-09T12:00:00.000Z"
  }));
  const customers: CustomerItem[] = seedLicenses.map((license, index) => ({
    id: index === 0 ? "cust_internal_tester" : "cust_pro_user",
    productId: "stacio",
    email: license.customerEmail,
    name: license.customerName,
    company: index === 0 ? "Stacio" : undefined,
    status: "active",
    riskFlag: false,
    createdAt: license.createdAt,
    updatedAt: license.createdAt
  }));

  function appcastObjectKey(product: Product | undefined, channelName: string) {
    const prefix = product?.objectStoragePrefix?.replace(/\/+$/, "") || `products/${product?.id ?? "unknown"}`;
    return `${prefix}/releases/${channelName}/appcast.xml`;
  }

  function recordAppcastEntry(release: ReleaseItem) {
    const product = products.find((candidate) => candidate.id === release.productId);
    const channel = releaseChannels.find(
      (candidate) => candidate.productId === release.productId && candidate.name === release.channel
    );
    if (!channel) {
      return undefined;
    }
    const timestamp = new Date().toISOString();
    const entry: AppcastEntryItem = {
      id: `appcast_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
      productId: release.productId,
      channelId: channel.id,
      channelName: channel.name,
      releaseId: release.id,
      xml: generateAppcastXml(product?.name ?? release.productId, release.channel, releases),
      objectKey: appcastObjectKey(product, release.channel),
      publishedAt: timestamp,
      createdAt: timestamp
    };
    const existingIndex = appcastEntries.findIndex(
      (candidate) => candidate.channelId === entry.channelId && candidate.releaseId === entry.releaseId
    );
    if (existingIndex >= 0) {
      appcastEntries[existingIndex] = {
        ...appcastEntries[existingIndex],
        xml: entry.xml,
        objectKey: entry.objectKey,
        publishedAt: entry.publishedAt
      };
      return appcastEntries[existingIndex];
    }
    appcastEntries.unshift(entry);
    return entry;
  }

  function createReleasePublications(release: ReleaseItem) {
    const timestamp = new Date().toISOString();
    const targets: ReleasePublicationTarget[] = ["object_storage", "appcast", "github", "website_catalog"];
    for (const target of targets) {
      if (releasePublications.some((item) => item.releaseId === release.id && item.target === target)) {
        continue;
      }
      releasePublications.push({
        id: `release_publication_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId: release.productId,
        releaseId: release.id,
        target,
        status: "queued",
        attempts: 0,
        metadata: {},
        createdAt: timestamp,
        updatedAt: timestamp
      });
    }
  }

  function recordObject(value: unknown) {
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  }

  function releaseArtifactInputPresent(input: UpdateReleaseDraftInput) {
    return [
      input.artifactName,
      input.artifactUrl,
      input.artifactObjectKey,
      input.artifactType,
      input.artifactSize,
      input.artifactSha256,
      input.packageSignatureEvidence
    ].some((value) => value !== undefined);
  }

  function recordReleaseArtifact(
    release: ReleaseItem,
    input: Pick<
      CreateReleaseInput,
      "artifactObjectKey" | "artifactSha256" | "packageSignatureEvidence"
    > = {}
  ) {
    if (!release.artifactUrl) {
      return undefined;
    }
    const artifact: ReleaseArtifactItem = {
      id: `artifact_${Date.now()}_${randomUUID().replaceAll("-", "").slice(0, 12)}`,
      productId: release.productId,
      releaseId: release.id,
      objectKey: input.artifactObjectKey,
      url: release.artifactUrl,
      fileName: release.artifactName,
      contentType: release.artifactType,
      sizeBytes: release.artifactSize,
      sha256: input.artifactSha256,
      signatureEvidence:
        input.packageSignatureEvidence ??
        recordObject(release.preflightEvidence?.packageSignatureEvidence),
      createdAt: new Date().toISOString()
    };
    const duplicate = releaseArtifacts.find(
      (candidate) =>
        candidate.releaseId === artifact.releaseId &&
        candidate.objectKey === artifact.objectKey &&
        candidate.url === artifact.url &&
        candidate.fileName === artifact.fileName &&
        candidate.sizeBytes === artifact.sizeBytes
    );
    if (duplicate) {
      return duplicate;
    }
    releaseArtifacts.unshift(artifact);
    return artifact;
  }

  function proposedActionWithAnalysis(action: StoredProposedAction): AiProposedActionItem | undefined {
    const analysis = aiAnalysisResults.find((item) => item.id === action.analysisId);
    if (!analysis) {
      return undefined;
    }
    return {
      ...action,
      analysis
    };
  }

  function publicAgentApiKey(item: StoredAgentApiKey): AgentApiKeyItem {
    const { keyHash: _keyHash, ...publicItem } = item;
    return publicItem;
  }

  const plans: PlanItem[] = [
    {
      id: "plan_free",
      productId: "stacio",
      name: "Free",
      description: "Personal evaluation plan",
      maxDevices: 1,
      maxSeats: 1,
      trialDays: 0,
      offlineGraceDays: 14,
      allowedChannels: ["stable"],
      entitlements: ["core_features"],
      status: "active",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "plan_pro",
      productId: "stacio",
      name: "Pro",
      description: "Paid individual plan",
      maxDevices: 2,
      maxSeats: 1,
      trialDays: 14,
      offlineGraceDays: 14,
      allowedChannels: ["stable", "beta"],
      entitlements: ["core_features", "pro_features", "beta_channel"],
      status: "active",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "plan_team",
      productId: "stacio",
      name: "Team",
      description: "Team license with shared seats",
      maxDevices: 20,
      maxSeats: 10,
      trialDays: 14,
      offlineGraceDays: 30,
      allowedChannels: ["stable", "beta"],
      entitlements: ["core_features", "pro_features", "team_features", "beta_channel"],
      status: "active",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "plan_internal",
      productId: "stacio",
      name: "Internal",
      description: "Internal operators and testers",
      maxDevices: 20,
      maxSeats: 20,
      trialDays: 0,
      offlineGraceDays: 90,
      allowedChannels: ["stable", "beta", "dev", "internal"],
      entitlements: ["core_features", "pro_features", "team_features", "beta_channel", "internal_tools"],
      status: "active",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    }
  ];
  const connectors: Array<ConnectorItem & { encryptedSecrets?: string }> = [
    {
      id: "conn_github",
      productId: "stacio",
      type: "github",
      name: "GitHub Issues",
      config: { mode: "read_only_sync" },
      hasSecrets: false,
      status: "unconfigured",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "conn_smtp",
      productId: "stacio",
      type: "smtp",
      name: "Feishu SMTP",
      config: { provider: "smtp" },
      hasSecrets: false,
      status: process.env.SMTP_HOST ? "configured" : "unconfigured",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "conn_object_storage",
      productId: "stacio",
      type: "object_storage",
      name: "Object Storage",
      config: { prefix: "products/stacio" },
      hasSecrets: false,
      status: process.env.S3_BUCKET && process.env.S3_ACCESS_KEY_ID && process.env.S3_SECRET_ACCESS_KEY ? "configured" : "unconfigured",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "conn_agent_api",
      productId: "stacio",
      type: "agent_api",
      name: "Agent API",
      config: { dangerousActions: "blocked" },
      hasSecrets: false,
      status: process.env.AGENT_API_KEY ? "configured" : "unconfigured",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    },
    {
      id: "conn_webhook",
      productId: "stacio",
      type: "webhook",
      name: "Webhook",
      config: { eventTypes: [] },
      hasSecrets: false,
      status: "unconfigured",
      createdAt: "2026-07-09T12:00:00.000Z",
      updatedAt: "2026-07-09T12:00:00.000Z"
    }
  ];
  const notificationPolicies: NotificationPolicyItem[] = [
    defaultNotificationPolicy("stacio")
  ];
  const idempotencyRecords: IdempotencyRecord[] = [];

  return {
    async findIdempotencyRecord(scope, key) {
      const now = Date.now();
      return idempotencyRecords.find(
        (record) =>
          record.scope === scope &&
          record.key === key &&
          (!record.expiresAt || new Date(record.expiresAt).getTime() > now)
      );
    },

    async createIdempotencyRecord(input) {
      const timestamp = new Date().toISOString();
      const existingIndex = idempotencyRecords.findIndex(
        (record) => record.scope === input.scope && record.key === input.key
      );
      const record: IdempotencyRecord = {
        ...input,
        createdAt: timestamp
      };
      if (existingIndex >= 0) {
        idempotencyRecords[existingIndex] = record;
        return record;
      }
      idempotencyRecords.unshift(record);
      return record;
    },

    async listProducts() {
      return products;
    },

    async findProduct(productId) {
      return products.find((product) => product.id === productId);
    },

    async createProduct(input) {
      if (products.some((product) => product.id === input.id)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const feedbackApiKey = generateProductFeedbackApiKey();
      const product: Product = {
        ...input,
        currentStableVersion: input.currentStableVersion ?? "",
        currentBetaVersion: input.currentBetaVersion ?? "",
        licensePolicy: input.licensePolicy ?? {},
        dataRetentionPolicy: input.dataRetentionPolicy ?? {},
        emailBrand: input.emailBrand ?? {},
        status: "active",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      products.push(product);
      feedbackApiKeyHashes.set(product.id, hashProductFeedbackApiKey(feedbackApiKey));
      return {
        product,
        feedbackApiKey
      };
    },

    async updateProduct(productId, input) {
      const product = products.find((candidate) => candidate.id === productId);
      if (!product) {
        return undefined;
      }
      Object.assign(product, input, {
        updatedAt: new Date().toISOString()
      });
      return product;
    },

    async archiveProduct(productId) {
      const product = products.find((candidate) => candidate.id === productId);
      if (!product) {
        return undefined;
      }
      product.status = "archived";
      product.updatedAt = new Date().toISOString();
      return product;
    },

    async rotateProductFeedbackApiKey(productId) {
      const product = products.find((candidate) => candidate.id === productId);
      if (!product) {
        return undefined;
      }
      const feedbackApiKey = generateProductFeedbackApiKey();
      feedbackApiKeyHashes.set(productId, hashProductFeedbackApiKey(feedbackApiKey));
      product.updatedAt = new Date().toISOString();
      return feedbackApiKey;
    },

    async verifyProductFeedbackApiKey(productId, apiKey) {
      const product = products.find((candidate) => candidate.id === productId);
      const expectedHash = feedbackApiKeyHashes.get(productId);
      return Boolean(
        product?.status === "active" &&
          expectedHash &&
          verifyProductFeedbackApiKey(apiKey, expectedHash)
      );
    },

    async listReleaseChannels(productId) {
      return releaseChannels.filter((channel) => channel.productId === productId);
    },

    async createReleaseChannel(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      if (
        releaseChannels.some(
          (channel) => channel.productId === productId && channel.name === input.name
        )
      ) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const channel: ReleaseChannelItem = {
        id: `channel_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        name: input.name,
        appcastUrl: input.appcastUrl,
        currentReleaseId: input.currentReleaseId,
        allowedPlanIds: input.allowedPlanIds ?? [],
        minimumUpgradableVersion: input.minimumUpgradableVersion,
        rolloutPercentage: input.rolloutPercentage ?? 100,
        autoDownloadAllowed: input.autoDownloadAllowed ?? false,
        forceUpdatePrompt: input.forceUpdatePrompt ?? false,
        status: input.status ?? "active",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      releaseChannels.push(channel);
      return channel;
    },

    async updateReleaseChannel(productId, channelId, input) {
      const channel = releaseChannels.find(
        (candidate) => candidate.productId === productId && candidate.id === channelId
      );
      if (!channel) {
        return undefined;
      }
      if (
        input.name &&
        releaseChannels.some(
          (candidate) =>
            candidate.productId === productId &&
            candidate.id !== channelId &&
            candidate.name === input.name
        )
      ) {
        return undefined;
      }
      if (input.name !== undefined) channel.name = input.name;
      if (input.appcastUrl !== undefined) channel.appcastUrl = input.appcastUrl ?? undefined;
      if (input.currentReleaseId !== undefined) {
        channel.currentReleaseId = input.currentReleaseId ?? undefined;
      }
      if (input.allowedPlanIds !== undefined) channel.allowedPlanIds = input.allowedPlanIds;
      if (input.minimumUpgradableVersion !== undefined) {
        channel.minimumUpgradableVersion = input.minimumUpgradableVersion ?? undefined;
      }
      if (input.rolloutPercentage !== undefined) {
        channel.rolloutPercentage = input.rolloutPercentage;
      }
      if (input.autoDownloadAllowed !== undefined) {
        channel.autoDownloadAllowed = input.autoDownloadAllowed;
      }
      if (input.forceUpdatePrompt !== undefined) {
        channel.forceUpdatePrompt = input.forceUpdatePrompt;
      }
      if (input.status !== undefined) channel.status = input.status;
      channel.updatedAt = new Date().toISOString();
      return channel;
    },

    async listCustomers(productId) {
      return customers.filter((customer) => customer.productId === productId);
    },

    async findCustomer(productId, customerId) {
      return customers.find(
        (customer) => customer.productId === productId && customer.id === customerId
      );
    },

    async createCustomer(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const normalizedEmail = input.email.trim().toLowerCase();
      if (
        customers.some(
          (customer) =>
            customer.productId === productId &&
            customer.email.toLowerCase() === normalizedEmail
        )
      ) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const customer: CustomerItem = {
        id: `cust_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        email: normalizedEmail,
        name: input.name,
        company: input.company,
        status: input.status ?? "active",
        riskFlag: input.riskFlag ?? false,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      customers.unshift(customer);
      return customer;
    },

    async updateCustomer(productId, customerId, input) {
      const customer = customers.find(
        (candidate) => candidate.productId === productId && candidate.id === customerId
      );
      if (!customer) {
        return undefined;
      }
      if (input.email !== undefined) {
        const normalizedEmail = input.email.trim().toLowerCase();
        const duplicate = customers.some(
          (candidate) =>
            candidate.productId === productId &&
            candidate.id !== customerId &&
            candidate.email.toLowerCase() === normalizedEmail
        );
        if (duplicate) {
          return undefined;
        }
        customer.email = normalizedEmail;
      }
      if (input.name !== undefined) customer.name = input.name;
      if (input.company !== undefined) customer.company = input.company ?? undefined;
      if (input.status !== undefined) customer.status = input.status;
      if (input.riskFlag !== undefined) customer.riskFlag = input.riskFlag;
      customer.updatedAt = new Date().toISOString();
      return customer;
    },

    async customerDetail(productId, customerId) {
      const customer = customers.find(
        (candidate) => candidate.productId === productId && candidate.id === customerId
      );
      if (!customer) {
        return undefined;
      }
      const customerNotifications = notifications.filter(
        (item) => item.productId === productId && item.customerId === customerId
      );
      const customerLicenses = licenses.filter(
        (license) => license.productId === productId && license.customerId === customerId
      );
      const customerLicenseIds = new Set(customerLicenses.map((license) => license.id));
      const customerActivations = licenseActivations.filter((activation) =>
        customerLicenseIds.has(activation.licenseId)
      );
      return {
        customer,
        licenses: customerLicenses,
        activations: customerActivations,
        feedback: feedback.filter(
          (item) => item.productId === productId && item.customerId === customerId
        ),
        notifications: customerNotifications.map((notification) => ({
          ...notification,
          deliveries: notificationDeliveries.filter(
            (delivery) => delivery.notificationId === notification.id
          )
        })),
        notes: customerNotes.filter((note) => note.customerId === customerId),
        activationCount: customerActivations.filter((activation) => !activation.resetAt).length,
        auditLogs: auditLogs.filter(
          (log) =>
            log.productId === productId &&
            log.targetType === "customer" &&
            (log.targetId === customerId ||
              log.metadata.sourceCustomerId === customerId ||
              log.metadata.targetCustomerId === customerId)
        )
      };
    },

    async addCustomerNote(productId, customerId, input) {
      const customer = customers.find(
        (candidate) => candidate.productId === productId && candidate.id === customerId
      );
      if (!customer) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const note: CustomerNoteItem = {
        id: `cnote_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        customerId,
        authorId: input.authorId,
        body: input.body,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      customerNotes.unshift(note);
      customer.updatedAt = timestamp;
      return note;
    },

    async mergeCustomers(productId, sourceCustomerId, targetCustomerId) {
      if (sourceCustomerId === targetCustomerId) {
        return undefined;
      }
      const source = customers.find(
        (candidate) =>
          candidate.productId === productId && candidate.id === sourceCustomerId
      );
      const target = customers.find(
        (candidate) =>
          candidate.productId === productId && candidate.id === targetCustomerId
      );
      if (!source || !target || source.status === "merged") {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      for (const license of licenses) {
        if (license.productId === productId && license.customerId === sourceCustomerId) {
          license.customerId = targetCustomerId;
        }
      }
      for (const item of feedback) {
        if (item.productId === productId && item.customerId === sourceCustomerId) {
          item.customerId = targetCustomerId;
          item.updatedAt = timestamp;
        }
      }
      for (const notification of notifications) {
        if (
          notification.productId === productId &&
          notification.customerId === sourceCustomerId
        ) {
          notification.customerId = targetCustomerId;
          notification.updatedAt = timestamp;
        }
      }
      for (const note of customerNotes) {
        if (note.customerId === sourceCustomerId) {
          note.customerId = targetCustomerId;
          note.updatedAt = timestamp;
        }
      }
      target.riskFlag = target.riskFlag || source.riskFlag;
      target.company = target.company ?? source.company;
      target.updatedAt = timestamp;
      source.status = "merged";
      source.mergedIntoId = targetCustomerId;
      source.updatedAt = timestamp;
      return { source, target };
    },

    async listPlans(productId) {
      return plans.filter((plan) => plan.productId === productId);
    },

    async createPlan(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      if (
        plans.some(
          (plan) =>
            plan.id === input.id ||
            (plan.productId === productId &&
              plan.name.toLowerCase() === input.name.toLowerCase())
        )
      ) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const plan: PlanItem = {
        ...input,
        productId,
        entitlements: input.entitlements ?? [],
        status: input.status ?? "active",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      plans.push(plan);
      return plan;
    },

    async updatePlan(productId, planId, input) {
      const plan = plans.find(
        (candidate) => candidate.productId === productId && candidate.id === planId
      );
      if (!plan) {
        return undefined;
      }
      if (
        input.name &&
        plans.some(
          (candidate) =>
            candidate.productId === productId &&
            candidate.id !== planId &&
            candidate.name.toLowerCase() === input.name?.toLowerCase()
        )
      ) {
        return undefined;
      }
      Object.assign(plan, input, {
        entitlements: input.entitlements ?? plan.entitlements,
        updatedAt: new Date().toISOString()
      });
      return plan;
    },

    async listConnectors(productId) {
      return connectors
        .filter((connector) => !connector.productId || connector.productId === productId)
        .map(({ encryptedSecrets: _encryptedSecrets, ...connector }) => ({
          ...connector,
          hasSecrets: Boolean(_encryptedSecrets)
        }));
    },

    async findConnector(productId, type) {
      const connector = connectors.find(
        (candidate) => candidate.productId === productId && candidate.type === type
      );
      if (!connector) {
        return undefined;
      }
      const { encryptedSecrets, ...publicConnector } = connector;
      return {
        ...publicConnector,
        hasSecrets: Boolean(encryptedSecrets)
      };
    },

    async getConnectorSecretEnvelope(productId, type) {
      return connectors.find(
        (candidate) => candidate.productId === productId && candidate.type === type
      )?.encryptedSecrets;
    },

    async upsertConnector(productId, type, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      let connector = connectors.find(
        (candidate) => candidate.productId === productId && candidate.type === type
      );
      if (!connector) {
        connector = {
          id: `conn_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          type,
          name: input.name,
          config: input.config,
          hasSecrets: Boolean(input.encryptedSecrets),
          encryptedSecrets: input.encryptedSecrets,
          status: input.encryptedSecrets ? "configured" : "unconfigured",
          lastError: null,
          createdAt: timestamp,
          updatedAt: timestamp
        };
        connectors.push(connector);
      } else {
        connector.name = input.name;
        connector.config = input.config;
        if (input.encryptedSecrets !== undefined) {
          connector.encryptedSecrets = input.encryptedSecrets;
        }
        connector.hasSecrets = Boolean(connector.encryptedSecrets);
        connector.status = connector.encryptedSecrets ? "configured" : "unconfigured";
        connector.lastError = null;
        connector.updatedAt = timestamp;
      }
      const { encryptedSecrets, ...publicConnector } = connector;
      return {
        ...publicConnector,
        hasSecrets: Boolean(encryptedSecrets)
      };
    },

    async recordConnectorTest(productId, type, input) {
      const connector = connectors.find(
        (candidate) => candidate.productId === productId && candidate.type === type
      );
      if (!connector) {
        return undefined;
      }
      connector.status = input.succeeded ? "configured" : "error";
      connector.lastSuccessAt = input.succeeded
        ? input.testedAt
        : connector.lastSuccessAt;
      connector.lastError = input.succeeded ? null : input.error ?? "Connection test failed";
      connector.updatedAt = input.testedAt;
      const { encryptedSecrets, ...publicConnector } = connector;
      return {
        ...publicConnector,
        hasSecrets: Boolean(encryptedSecrets)
      };
    },

    async disconnectConnector(productId, type) {
      const connector = connectors.find(
        (candidate) => candidate.productId === productId && candidate.type === type
      );
      if (!connector) {
        return undefined;
      }
      connector.encryptedSecrets = undefined;
      connector.hasSecrets = false;
      connector.status = "disabled";
      connector.lastError = null;
      connector.updatedAt = new Date().toISOString();
      const { encryptedSecrets: _encryptedSecrets, ...publicConnector } = connector;
      return publicConnector;
    },

    async notificationPolicy(productId) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      return (
        notificationPolicies.find((policy) => policy.productId === productId) ??
        defaultNotificationPolicy(productId)
      );
    },

    async updateNotificationPolicy(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const existing = notificationPolicies.find((policy) => policy.productId === productId);
      if (existing) {
        Object.assign(existing, {
          ...input,
          updatedAt: timestamp
        });
        return existing;
      }
      const policy: NotificationPolicyItem = {
        productId,
        ...input,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      notificationPolicies.push(policy);
      return policy;
    },

    async settingsSummary(productId) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      return {
        productId,
        persistence: process.env.DATABASE_URL ? "postgres" : "memory",
        smtpConfigured: Boolean(process.env.SMTP_HOST),
        objectStorageConfigured: Boolean(process.env.S3_BUCKET && process.env.S3_ACCESS_KEY_ID && process.env.S3_SECRET_ACCESS_KEY),
        redisConfigured: Boolean(process.env.REDIS_URL),
        bootstrapOwnerConfigured: Boolean(process.env.BOOTSTRAP_OWNER_EMAIL && process.env.BOOTSTRAP_OWNER_PASSWORD),
        roleCount: 5,
        userCount: 1,
        apiKeyCount: agentApiKeys.length,
        policy: {
          otaRequiresManualConfirmation: true,
          agentDangerousActionsBlocked: true,
          licenseOfflineGraceDays: 14
        }
      };
    },

    async dashboard(productId) {
      const product = products.find((candidate) => candidate.id === productId);
      if (!product) {
        return undefined;
      }

      const productFeedback = feedback.filter(
        (item) => item.productId === productId && !item.deletedAt
      );
      const productLicenses = licenses.filter((item) => item.productId === productId);
      const latestRelease = releases
        .filter((item) => item.productId === productId)
        .sort((left, right) => right.createdAt.localeCompare(left.createdAt))[0];
      const productNotifications = notifications.filter((item) => item.productId === productId);
      const productNotificationIds = new Set(productNotifications.map((item) => item.id));
      const productNotificationDeliveries = notificationDeliveries.filter((item) =>
        productNotificationIds.has(item.notificationId)
      );
      const productAuditLogs = auditLogs.filter((item) => item.productId === productId);
      const latestGitHubSync = githubSyncRuns
        .filter((item) => item.productId === productId)
        .sort((left, right) => right.startedAt.localeCompare(left.startedAt))[0];

      return {
        productId,
        currentStableVersion: product.currentStableVersion,
        currentBetaVersion: product.currentBetaVersion,
        todayFeedbackCount: productFeedback.length,
        unhandledFeedbackCount: productFeedback.filter((item) => !["resolved", "closed", "duplicate"].includes(item.status)).length,
        p0p1BugCount: productFeedback.filter((item) => item.type === "bug" && ["P0", "P1"].includes(item.priority)).length,
        activeLicenseCount: productLicenses.filter((item) => item.status === "active" || item.status === "trial").length,
        expiringLicenseCount: productLicenses.filter((item) => {
          const remaining = new Date(item.expiresAt).getTime() - Date.now();
          return remaining >= 0 && remaining <= 30 * 86_400_000;
        }).length,
        latestReleaseStatus: latestRelease?.status ?? "none",
        githubSyncStatus: latestGitHubSync?.status ?? "unconfigured",
        aiPendingSuggestionCount: 3,
        licenseValidationErrorCount: licenseValidationLogs.filter(
          (item) => item.productId === productId && item.result !== "valid"
        ).length,
        emailDeliveryStatus: summarizeEmailDeliveryStatus(
          productNotifications,
          productNotificationDeliveries
        ),
        recentAuditEvents: recentAuditEvents(productAuditLogs)
      };
    },

    async listFeedback(productId) {
      return feedback.filter((item) => item.productId === productId && !item.deletedAt);
    },

    async findFeedback(productId, feedbackId) {
      return feedback.find(
        (item) => item.productId === productId && item.id === feedbackId && !item.deletedAt
      );
    },

    async createFeedback(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }

      const timestamp = new Date().toISOString();
      const priority: FeedbackPriority = input.type === "crash" ? "P1" : "P2";
      const item: FeedbackItem = {
        id: `fb_${randomUUID().slice(0, 8)}`,
        productId,
        customerId: input.contactEmail
          ? customers.find(
              (customer) =>
                customer.productId === productId &&
                customer.email.toLowerCase() === input.contactEmail?.toLowerCase()
            )?.id
          : undefined,
        title: input.title,
        description: input.description,
        type: input.type ?? "other",
        status: "new",
        priority,
        source: "app",
        contactEmail: input.contactEmail,
        appVersion: input.appVersion,
        buildNumber: input.buildNumber,
        osVersion: input.osVersion,
        licenseState: input.licenseState,
        licenseKeyHash: input.licenseKeyHash,
        anonymousDeviceId: input.anonymousDeviceId,
        diagnosticsSummary: input.diagnosticsSummary,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      feedback.unshift(item);
      return item;
    },

    async updateFeedback(productId, feedbackId, input) {
      const item = feedback.find(
        (candidate) =>
          candidate.productId === productId &&
          candidate.id === feedbackId &&
          !candidate.deletedAt
      );
      if (!item) {
        return undefined;
      }

      if (input.status !== undefined) item.status = input.status;
      if (input.priority !== undefined) item.priority = input.priority;
      if (input.assignedUserId !== undefined) item.assignedUserId = input.assignedUserId ?? undefined;
      if (input.duplicateOfId !== undefined) item.duplicateOfId = input.duplicateOfId ?? undefined;
      if (input.relatedReleaseId !== undefined) item.relatedReleaseId = input.relatedReleaseId ?? undefined;
      if (input.aiSummary !== undefined) item.aiSummary = input.aiSummary ?? undefined;
      if (input.aiClassification !== undefined) item.aiClassification = input.aiClassification ?? undefined;
      if (input.aiSuggestedPriority !== undefined) {
        item.aiSuggestedPriority = input.aiSuggestedPriority ?? undefined;
      }
      item.updatedAt = new Date().toISOString();
      return item;
    },

    async listFeedbackComments(feedbackId) {
      return feedbackComments.filter((comment) => comment.feedbackId === feedbackId);
    },

    async createFeedbackComment(feedbackId, input) {
      if (!feedback.some((item) => item.id === feedbackId && !item.deletedAt)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const comment: FeedbackCommentItem = {
        id: `comment_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        feedbackId,
        ...input,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      feedbackComments.push(comment);
      return comment;
    },

    async listFeedbackAttachments(feedbackId) {
      return feedbackAttachments.filter(
        (attachment) => attachment.feedbackId === feedbackId && !attachment.deletedAt
      );
    },

    async createFeedbackAttachment(productId, feedbackId, input) {
      const feedbackItem = feedback.find(
        (item) =>
          item.productId === productId &&
          item.id === feedbackId &&
          !item.deletedAt
      );
      if (!feedbackItem) {
        return undefined;
      }
      const attachment: FeedbackAttachmentItem = {
        id: `fba_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        feedbackId,
        ...input,
        createdAt: new Date().toISOString()
      };
      feedbackAttachments.push(attachment);
      feedbackItem.updatedAt = attachment.createdAt;
      return attachment;
    },

    async redactFeedbackAttachment(productId, feedbackId, attachmentId) {
      const feedbackItem = feedback.find(
        (item) =>
          item.productId === productId &&
          item.id === feedbackId &&
          !item.deletedAt
      );
      const attachment = feedbackAttachments.find(
        (item) =>
          item.feedbackId === feedbackId &&
          item.id === attachmentId &&
          !item.deletedAt
      );
      if (!feedbackItem || !attachment) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      attachment.objectKey = `redacted://feedback-attachment/${attachment.id}`;
      attachment.fileName = "[redacted attachment]";
      attachment.contentType = "application/octet-stream";
      attachment.sizeBytes = 0;
      attachment.sha256 = undefined;
      attachment.redactedAt = timestamp;
      feedbackItem.updatedAt = timestamp;
      return attachment;
    },

    async deleteFeedbackAttachment(productId, feedbackId, attachmentId) {
      const feedbackItem = feedback.find(
        (item) =>
          item.productId === productId &&
          item.id === feedbackId &&
          !item.deletedAt
      );
      const attachment = feedbackAttachments.find(
        (item) =>
          item.feedbackId === feedbackId &&
          item.id === attachmentId &&
          !item.deletedAt
      );
      if (!feedbackItem || !attachment) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      attachment.deletedAt = timestamp;
      feedbackItem.updatedAt = timestamp;
      return attachment;
    },

    async redactFeedback(productId, feedbackId, fields) {
      const item = feedback.find(
        (candidate) =>
          candidate.productId === productId &&
          candidate.id === feedbackId &&
          !candidate.deletedAt
      );
      if (!item) {
        return undefined;
      }
      for (const field of fields) {
        switch (field) {
          case "title":
            item.title = "[redacted feedback title]";
            break;
          case "description":
            item.description = "[redacted feedback description]";
            break;
          case "contactEmail":
            item.contactEmail = "redacted@example.invalid";
            break;
          case "diagnosticsSummary":
            item.diagnosticsSummary = { redacted: true };
            break;
          case "appVersion":
            item.appVersion = "[redacted]";
            break;
          case "buildNumber":
            item.buildNumber = "[redacted]";
            break;
          case "osVersion":
            item.osVersion = "[redacted]";
            break;
          case "licenseState":
            item.licenseState = "[redacted]";
            break;
          case "licenseKeyHash":
            item.licenseKeyHash = "[redacted]";
            break;
          case "anonymousDeviceId":
            item.anonymousDeviceId = "[redacted]";
            break;
        }
      }
      item.updatedAt = new Date().toISOString();
      return item;
    },

    async deleteFeedback(productId, feedbackId) {
      const item = feedback.find(
        (candidate) =>
          candidate.productId === productId &&
          candidate.id === feedbackId &&
          !candidate.deletedAt
      );
      if (!item) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      item.deletedAt = timestamp;
      item.updatedAt = timestamp;
      return item;
    },

    async listLinkedGitHubIssues(productId, feedbackId) {
      const linkedIds = new Set(
        feedbackGitHubLinks
          .filter(
            (link) =>
              link.productId === productId &&
              link.feedbackId === feedbackId
          )
          .map((link) => link.githubIssueId)
      );
      return githubIssues.filter(
        (issue) =>
          issue.productId === productId &&
          (issue.linkedFeedbackId === feedbackId || linkedIds.has(issue.id))
      );
    },

    async linkGitHubIssue(productId, feedbackId, githubIssueId, createdBy) {
      const feedbackItem = feedback.find(
        (item) =>
          item.productId === productId &&
          item.id === feedbackId &&
          !item.deletedAt
      );
      const issue = githubIssues.find(
        (item) => item.productId === productId && item.id === githubIssueId
      );
      if (!feedbackItem || !issue) {
        return undefined;
      }
      const duplicate = feedbackGitHubLinks.some(
        (link) =>
          link.productId === productId &&
          link.feedbackId === feedbackId &&
          link.githubIssueId === githubIssueId
      );
      if (duplicate) {
        return "conflict";
      }
      feedbackGitHubLinks.push({
        productId,
        feedbackId,
        githubIssueId,
        createdBy
      });
      feedbackItem.updatedAt = new Date().toISOString();
      return issue;
    },

    async unlinkGitHubIssue(productId, feedbackId, githubIssueId) {
      const feedbackItem = feedback.find(
        (item) =>
          item.productId === productId &&
          item.id === feedbackId &&
          !item.deletedAt
      );
      const issue = githubIssues.find(
        (item) => item.productId === productId && item.id === githubIssueId
      );
      if (!feedbackItem || !issue) {
        return undefined;
      }
      const linkIndex = feedbackGitHubLinks.findIndex(
        (link) =>
          link.productId === productId &&
          link.feedbackId === feedbackId &&
          link.githubIssueId === githubIssueId
      );
      if (linkIndex < 0) {
        return undefined;
      }
      feedbackGitHubLinks.splice(linkIndex, 1);
      feedbackItem.updatedAt = new Date().toISOString();
      return issue;
    },

    async listReleases(productId) {
      return releases.filter((item) => item.productId === productId);
    },

    async listAppcastEntries(productId, channelName) {
      return appcastEntries.filter(
        (item) => item.productId === productId && (channelName === undefined || item.channelName === channelName)
      );
    },

    async listReleaseArtifacts(productId, releaseId) {
      const release = releases.find((item) => item.productId === productId && item.id === releaseId);
      if (!release) {
        return [];
      }
      return releaseArtifacts.filter((item) => item.productId === productId && item.releaseId === releaseId);
    },

    async listReleasePublications(productId, releaseId) {
      return releasePublications
        .filter((item) => item.productId === productId && item.releaseId === releaseId)
        .sort((left, right) => left.target.localeCompare(right.target));
    },

    async updateReleasePublication(productId, releaseId, target, input) {
      const publication = releasePublications.find(
        (item) => item.productId === productId && item.releaseId === releaseId && item.target === target
      );
      if (!publication) {
        return undefined;
      }
      publication.status = input.status;
      if (input.objectKey !== undefined) publication.objectKey = input.objectKey ?? undefined;
      if (input.externalUrl !== undefined) publication.externalUrl = input.externalUrl ?? undefined;
      if (input.lastError !== undefined) publication.lastError = input.lastError ?? undefined;
      if (input.metadata !== undefined) publication.metadata = input.metadata;
      if (input.startedAt !== undefined) publication.startedAt = input.startedAt ?? undefined;
      if (input.completedAt !== undefined) publication.completedAt = input.completedAt ?? undefined;
      if (input.incrementAttempts) publication.attempts += 1;
      publication.updatedAt = new Date().toISOString();
      return publication;
    },

    async finalizePublishedReleaseArtifact(productId, releaseId, input) {
      const release = releases.find(
        (item) => item.productId === productId && item.id === releaseId && item.status === "published"
      );
      if (!release) {
        return undefined;
      }
      release.artifactUrl = input.artifactUrl;
      recordReleaseArtifact(release, { artifactObjectKey: input.objectKey });
      recordAppcastEntry(release);
      return release;
    },

    async recordWebsiteEvent(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const existing = websiteEvents.find(
        (event) => event.productId === productId && event.eventId === input.eventId
      );
      if (existing) {
        return { event: existing, created: false };
      }
      const event: WebsiteEventItem = {
        productId,
        ...input
      };
      websiteEvents.push(event);
      return { event, created: true };
    },

    async websiteAnalytics(productId, since) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const start = since ? new Date(since).getTime() : 0;
      const events = websiteEvents.filter((event) =>
        event.productId === productId && (Number.isNaN(start) || new Date(event.occurredAt).getTime() >= start)
      );
      return summarizeWebsiteAnalytics(events);
    },

    async listLicenses(productId) {
      return licenses.filter((item) => item.productId === productId);
    },

    async createRelease(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const release: ReleaseItem = {
        id: `rel_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        channel: input.channel,
        version: input.version,
        buildNumber: input.buildNumber,
        status: "draft",
        minimumSystemVersion: input.minimumSystemVersion,
        artifactName: input.artifactName,
        artifactUrl: input.artifactUrl,
        artifactType: input.artifactType,
        artifactSize: input.artifactSize,
        sparkleEdDsaSignature: input.sparkleEdDsaSignature,
        releaseNotes: input.releaseNotes,
        aiReleaseSummary: input.aiReleaseSummary,
        aiRiskSummary: input.aiRiskSummary,
        createdBy: input.createdBy,
        preflightEvidence: initialReleasePreflightEvidence(input),
        createdAt: timestamp
      };
      releases.unshift(release);
      recordReleaseArtifact(release, input);
      return release;
    },

    async updateReleaseDraft(productId, releaseId, input) {
      const release = releases.find((candidate) => candidate.productId === productId && candidate.id === releaseId);
      if (!release) {
        return undefined;
      }
      if (["published", "paused", "withdrawn"].includes(release.status)) {
        return undefined;
      }
      if (input.minimumSystemVersion !== undefined) release.minimumSystemVersion = input.minimumSystemVersion;
      if (input.artifactName !== undefined) release.artifactName = input.artifactName;
      if (input.artifactUrl !== undefined) release.artifactUrl = input.artifactUrl;
      if (input.artifactType !== undefined) release.artifactType = input.artifactType;
      if (input.artifactSize !== undefined) release.artifactSize = input.artifactSize;
      if (input.sparkleEdDsaSignature !== undefined) release.sparkleEdDsaSignature = input.sparkleEdDsaSignature;
      if (input.releaseNotes !== undefined) release.releaseNotes = input.releaseNotes;
      if (input.aiReleaseSummary !== undefined) release.aiReleaseSummary = input.aiReleaseSummary;
      if (input.aiRiskSummary !== undefined) release.aiRiskSummary = input.aiRiskSummary;
      release.status = "draft";
      release.preflightEvidence = initialReleasePreflightEvidence(input);
      if (releaseArtifactInputPresent(input)) {
        recordReleaseArtifact(release, input);
      }
      return release;
    },

    async validateRelease(productId, releaseId) {
      const release = releases.find((candidate) => candidate.productId === productId && candidate.id === releaseId);
      if (!release) {
        return undefined;
      }
      const product = products.find((candidate) => candidate.id === productId);
      const evidence = buildReleasePreflightEvidence(product?.name ?? productId, release, releases, release.preflightEvidence);
      const passed = evidence.checks.every((check) => check.passed);
      release.status = passed ? "ready" : "failed";
      release.preflightEvidence = evidence;
      return { release, passed, checks: evidence.checks };
    },

    async publishRelease(productId, releaseId, publishedBy) {
      const release = releases.find((candidate) => candidate.productId === productId && candidate.id === releaseId);
      if (!release || release.status !== "ready") {
        return undefined;
      }
      release.status = "published";
      release.publishedBy = publishedBy;
      release.publishedAt = new Date().toISOString();
      const product = products.find((candidate) => candidate.id === productId);
      if (product) {
        if (release.channel === "stable") product.currentStableVersion = release.version;
        if (release.channel === "beta") product.currentBetaVersion = release.version;
      }
      const channel = releaseChannels.find((candidate) => candidate.productId === productId && candidate.name === release.channel);
      if (channel) {
        channel.currentReleaseId = release.id;
        channel.updatedAt = new Date().toISOString();
      }
      recordAppcastEntry(release);
      createReleasePublications(release);
      return release;
    },

    async updateReleaseStatus(productId, releaseId, status) {
      const release = releases.find((candidate) => candidate.productId === productId && candidate.id === releaseId);
      if (!release) {
        return undefined;
      }
      release.status = status;
      if (status === "published" && !release.publishedAt) {
        release.publishedAt = new Date().toISOString();
      }
      const channel = releaseChannels.find((candidate) => candidate.productId === productId && candidate.name === release.channel);
      if (channel) {
        channel.currentReleaseId = status === "withdrawn" ? undefined : release.id;
        channel.updatedAt = new Date().toISOString();
      }
      return release;
    },

    async createLicense(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const licenseKey = generateLicenseKey(productId);
      const timestamp = new Date().toISOString();
      const license: LicenseItem = {
        id: `lic_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        customerId: customers.find(
          (customer) =>
            customer.productId === productId &&
            customer.email.toLowerCase() === input.customerEmail.toLowerCase()
        )?.id,
        customerName: input.customerName,
        customerEmail: input.customerEmail,
        username: input.username ?? input.customerName,
        plan: input.plan,
        status: input.status ?? "active",
        seats: input.seats ?? 1,
        devices: 0,
        maxDevices: input.maxDevices ?? input.seats ?? 1,
        entitlements: input.entitlements ?? (input.plan === "free" ? [] : ["pro_features"]),
        offlineGraceDays: input.offlineGraceDays ?? (input.plan === "internal" ? 90 : input.plan === "team" ? 30 : 14),
        keyPrefix: licenseKeyPrefix(licenseKey),
        expiresAt: input.expiresAt,
        createdAt: timestamp
      };
      licenses.unshift(license);
      licenseKeyHashes.set(license.id, hashLicenseKey(licenseKey));
      return { license, licenseKey };
    },

    async updateLicense(productId, licenseId, input) {
      const license = licenses.find((candidate) => candidate.productId === productId && candidate.id === licenseId);
      if (!license) {
        return undefined;
      }
      if (input.plan !== undefined) license.plan = input.plan;
      if (input.status !== undefined) license.status = input.status;
      if (input.seats !== undefined) license.seats = input.seats;
      if (input.maxDevices !== undefined) license.maxDevices = input.maxDevices;
      if (input.entitlements !== undefined) license.entitlements = input.entitlements;
      if (input.offlineGraceDays !== undefined) license.offlineGraceDays = input.offlineGraceDays;
      if (input.expiresAt !== undefined) license.expiresAt = input.expiresAt;
      return license;
    },

    async resetLicenseActivations(productId, licenseId) {
      const license = licenses.find((candidate) => candidate.productId === productId && candidate.id === licenseId);
      if (!license) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      for (const activation of licenseActivations.filter((item) => item.licenseId === licenseId)) {
        activation.resetAt = timestamp;
        activation.updatedAt = timestamp;
      }
      license.devices = 0;
      return license;
    },

    async validateLicense(productId, input) {
      const expectedHash = hashLicenseKey(input.licenseKey);
      const timestamp = new Date().toISOString();
      const logBase = {
        id: `liclog_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        keyPrefix: licenseKeyPrefix(input.licenseKey),
        email: input.email,
        anonymousDeviceId: input.anonymousDeviceId,
        machineFingerprintHash: input.machineFingerprintHash,
        appVersion: input.appVersion,
        buildNumber: input.buildNumber,
        createdAt: timestamp
      };
      const license = licenses.find(
        (candidate) =>
          candidate.productId === productId &&
          candidate.customerEmail.toLowerCase() === input.email.toLowerCase() &&
          licenseKeyHashes.get(candidate.id) === expectedHash
      );
      if (!license) {
        licenseValidationLogs.unshift({ ...logBase, result: "invalid", reason: "not_found" });
        return { valid: false, reason: "not_found" };
      }
      if (license.status === "revoked" || license.status === "suspended") {
        licenseValidationLogs.unshift({ ...logBase, licenseId: license.id, result: "invalid", reason: license.status });
        return { valid: false, reason: license.status, license };
      }
      if (new Date(license.expiresAt).getTime() < Date.now()) {
        licenseValidationLogs.unshift({ ...logBase, licenseId: license.id, result: "invalid", reason: "expired" });
        return { valid: false, reason: "expired", license };
      }
      if (input.anonymousDeviceId || input.machineFingerprintHash) {
        const existingActivation = licenseActivations.find(
          (activation) =>
            activation.licenseId === license.id &&
            (input.anonymousDeviceId
              ? activation.anonymousDeviceId === input.anonymousDeviceId
              : activation.machineFingerprintHash === input.machineFingerprintHash)
        );
        if (existingActivation) {
          existingActivation.lastSeenAt = timestamp;
          existingActivation.updatedAt = timestamp;
        } else {
          licenseActivations.unshift({
            id: `act_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
            licenseId: license.id,
            anonymousDeviceId: input.anonymousDeviceId,
            machineFingerprintHash: input.machineFingerprintHash,
            firstSeenAt: timestamp,
            lastSeenAt: timestamp,
            riskSignals: {},
            createdAt: timestamp,
            updatedAt: timestamp
          });
        }
        license.devices = licenseActivations.filter(
          (activation) => activation.licenseId === license.id && !activation.resetAt
        ).length;
      }
      licenseValidationLogs.unshift({ ...logBase, licenseId: license.id, result: "valid" });
      return {
        valid: true,
        license,
        offlineGraceSeconds: (license.offlineGraceDays ?? 14) * 86_400
      };
    },

    async licenseDetail(productId, licenseId) {
      const license = licenses.find((candidate) => candidate.productId === productId && candidate.id === licenseId);
      if (!license) {
        return undefined;
      }
      const customer =
        customers.find(
          (candidate) =>
            candidate.productId === productId &&
            (candidate.id === license.customerId ||
              candidate.email.toLowerCase() === license.customerEmail.toLowerCase())
        ) ?? customerSnapshotFromLicense(license);
      return {
        license,
        customer,
        activations: licenseActivations.filter((activation) => activation.licenseId === license.id),
        validationLogs: licenseValidationLogs.filter(
          (log) =>
            log.productId === productId &&
            (log.licenseId === license.id ||
              log.email?.toLowerCase() === license.customerEmail.toLowerCase())
        ),
        auditLogs: auditLogs.filter(
          (log) => log.productId === productId && log.targetType === "license" && log.targetId === license.id
        )
      };
    },

    async listGitHubIssues(productId) {
      return githubIssues.filter((item) => item.productId === productId);
    },

    async updateGitHubIssue(productId, githubIssueId, input) {
      const issue = githubIssues.find((item) => item.productId === productId && item.id === githubIssueId);
      if (!issue) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      if (input.title !== undefined) issue.title = input.title;
      if (input.body !== undefined) issue.body = input.body;
      if (input.labels !== undefined) issue.labels = input.labels;
      if (input.author !== undefined) issue.author = input.author;
      if (input.state !== undefined) issue.state = input.state;
      if (input.commentsCount !== undefined) issue.commentsCount = input.commentsCount;
      if (input.url !== undefined) issue.url = input.url;
      if (input.githubUpdatedAt !== undefined) issue.githubUpdatedAt = input.githubUpdatedAt;
      if (input.githubClosedAt !== undefined) issue.githubClosedAt = input.githubClosedAt;
      issue.syncedAt = timestamp;
      issue.updatedAt = timestamp;
      return issue;
    },

    async syncGitHubIssues(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const startedAt = new Date().toISOString();
      const changed: GitHubIssueItem[] = [];
      const feedbackCreated: FeedbackItem[] = [];

      for (const issue of input.issues) {
        const existing = githubIssues.find(
          (candidate) => candidate.productId === productId && candidate.githubIssueId === issue.githubIssueId
        );
        const timestamp = new Date().toISOString();
        if (existing) {
          existing.number = issue.number;
          existing.title = issue.title;
          existing.body = issue.body;
          existing.labels = issue.labels ?? [];
          existing.author = issue.author;
          existing.state = issue.state;
          existing.commentsCount = issue.commentsCount ?? 0;
          existing.url = issue.url;
          existing.githubCreatedAt = issue.githubCreatedAt;
          existing.githubUpdatedAt = issue.githubUpdatedAt;
          existing.githubClosedAt = issue.githubClosedAt;
          existing.syncedAt = timestamp;
          existing.updatedAt = timestamp;
          changed.push(existing);
          continue;
        }

        const feedbackItem: FeedbackItem = {
          id: `fb_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          title: issue.title,
          description: issue.body ?? "",
          type: labelMappedType(issue.labels),
          status: "new",
          priority: labelMappedPriority(issue.labels),
          source: "github",
          contactEmail: issue.author,
          createdAt: timestamp,
          updatedAt: timestamp
        };
        feedback.unshift(feedbackItem);
        feedbackCreated.push(feedbackItem);

        const item: GitHubIssueItem = {
          id: `ghi_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          githubIssueId: issue.githubIssueId,
          number: issue.number,
          title: issue.title,
          body: issue.body,
          labels: issue.labels ?? [],
          author: issue.author,
          state: issue.state,
          commentsCount: issue.commentsCount ?? 0,
          url: issue.url,
          linkedFeedbackId: feedbackItem.id,
          githubCreatedAt: issue.githubCreatedAt,
          githubUpdatedAt: issue.githubUpdatedAt,
          githubClosedAt: issue.githubClosedAt,
          syncedAt: timestamp,
          createdAt: timestamp,
          updatedAt: timestamp
        };
        githubIssues.push(item);
        changed.push(item);
      }

      const finishedAt = new Date().toISOString();
      const run: GitHubSyncRunItem = {
        id: `ghsync_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        trigger: input.trigger,
        status: "success",
        fetchedCount: input.issues.length,
        changedCount: changed.length,
        startedAt,
        finishedAt,
        createdAt: startedAt
      };
      githubSyncRuns.unshift(run);
      return {
        run,
        issues: changed,
        feedbackCreated
      };
    },

    async recordGitHubSyncFailure(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const run: GitHubSyncRunItem = {
        id: `ghsync_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        trigger: input.trigger,
        status: "failed",
        fetchedCount: 0,
        changedCount: 0,
        error: input.error,
        startedAt: timestamp,
        finishedAt: timestamp,
        createdAt: timestamp
      };
      githubSyncRuns.unshift(run);
      return run;
    },

    async listGitHubSyncRuns(productId) {
      return githubSyncRuns.filter((run) => run.productId === productId);
    },

    async listAiAnalysis(productId, targetType, targetId) {
      return aiAnalysisResults.filter(
        (item) =>
          item.productId === productId &&
          (!targetType || item.targetType === targetType) &&
          (!targetId || item.targetId === targetId)
      );
    },

    async createAiAnalysis(input) {
      if (!products.some((product) => product.id === input.productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const item: AiAnalysisResultItem = {
        id: `ai_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        ...input,
        inputReferences: input.inputReferences ?? {},
        adoptionState: "pending",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      aiAnalysisResults.unshift(item);
      return item;
    },

    async reviewAiAnalysis(productId, analysisId, input) {
      const item = aiAnalysisResults.find((candidate) => candidate.productId === productId && candidate.id === analysisId);
      if (!item) {
        return undefined;
      }
      item.adoptionState = input.adoptionState;
      if (input.outputBody) {
        item.outputBody = input.outputBody;
      }
      item.updatedAt = new Date().toISOString();
      return item;
    },

    async listProposedActions(productId, status) {
      return aiProposedActions
        .filter((action) => action.productId === productId && (!status || action.status === status))
        .map((action) => proposedActionWithAnalysis(action))
        .filter((action): action is AiProposedActionItem => Boolean(action));
    },

    async createProposedAction(input) {
      const analysis = aiAnalysisResults.find((item) => item.id === input.analysisId);
      if (!analysis) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const action: StoredProposedAction = {
        id: `act_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        analysisId: analysis.id,
        productId: analysis.productId,
        targetType: analysis.targetType,
        targetId: analysis.targetId,
        actionType: input.actionType,
        payload: input.payload,
        status: "pending",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      aiProposedActions.unshift(action);
      return proposedActionWithAnalysis(action);
    },

    async reviewProposedAction(productId, actionId, input) {
      const action = aiProposedActions.find(
        (candidate) => candidate.productId === productId && candidate.id === actionId
      );
      if (!action) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      action.status = input.status;
      action.reviewedBy = input.reviewedBy;
      action.reviewedAt = timestamp;
      action.updatedAt = timestamp;
      return proposedActionWithAnalysis(action);
    },

    async listAgentRequests(productId, query = {}) {
      return agentRequests.filter((item) =>
        item.productId === productId &&
        (!query.targetType || item.targetType === query.targetType) &&
        (!query.targetId || item.targetId === query.targetId) &&
        (!query.status || item.status === query.status)
      );
    },

    async createAgentRequest(input) {
      if (!products.some((product) => product.id === input.productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const item: AgentRequestItem = {
        id: `agent_req_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId: input.productId,
        targetType: input.targetType,
        targetId: input.targetId,
        requestType: input.requestType,
        agentHint: input.agentHint,
        prompt: input.prompt,
        status: "queued",
        requestedBy: input.requestedBy,
        metadata: input.metadata ?? {},
        createdAt: timestamp,
        updatedAt: timestamp
      };
      agentRequests.unshift(item);
      return item;
    },

    async listNotificationTemplates(productId) {
      return notificationTemplates.filter((template) => template.productId === productId);
    },

    async upsertNotificationTemplate(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const existing = notificationTemplates.find((template) => template.productId === productId && template.type === input.type);
      const timestamp = new Date().toISOString();
      if (existing) {
        existing.subjectTemplate = input.subjectTemplate;
        existing.htmlTemplate = input.htmlTemplate;
        existing.textTemplate = input.textTemplate;
        existing.status = input.status ?? existing.status;
        existing.updatedAt = timestamp;
        return existing;
      }
      const item: NotificationTemplateItem = {
        id: `tmpl_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        type: input.type,
        subjectTemplate: input.subjectTemplate,
        htmlTemplate: input.htmlTemplate,
        textTemplate: input.textTemplate,
        status: input.status ?? "active",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      notificationTemplates.unshift(item);
      return item;
    },

    async listNotifications(productId) {
      return notifications.filter((notification) => notification.productId === productId);
    },

    async createNotification(productId, input) {
      if (!products.some((product) => product.id === productId)) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const item: NotificationItem = {
        id: `ntf_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        customerId: customers.find(
          (customer) =>
            customer.productId === productId &&
            customer.email.toLowerCase() === input.recipient.toLowerCase()
        )?.id,
        type: input.type,
        recipient: input.recipient,
        payload: input.payload,
        priority: input.priority ?? "normal",
        status: input.status ?? "queued",
        scheduledAt: input.scheduledAt,
        createdAt: timestamp,
        updatedAt: timestamp
      };
      notifications.unshift(item);
      return item;
    },

    async listNotificationDeliveries(notificationId) {
      return notificationDeliveries.filter((delivery) => delivery.notificationId === notificationId);
    },

    async createNotificationDelivery(notificationId, input) {
      const notification = notifications.find((candidate) => candidate.id === notificationId);
      if (!notification) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const item: NotificationDeliveryItem = {
        id: `delivery_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        notificationId,
        provider: input.provider,
        attempt: input.attempt ?? 1,
        status: input.status,
        providerMessageId: input.providerMessageId,
        error: input.error,
        sentAt: input.sentAt,
        createdAt: timestamp
      };
      notificationDeliveries.unshift(item);
      if (input.status === "sent") {
        notification.status = "sent";
      }
      if (input.status === "failed") {
        notification.status = "failed";
      }
      notification.updatedAt = timestamp;
      return item;
    },

    async listAgentApiKeys() {
      return agentApiKeys.map(publicAgentApiKey);
    },

    async createAgentApiKey(input) {
      const timestamp = new Date().toISOString();
      const key = generateAgentApiKey();
      const apiKey: StoredAgentApiKey = {
        id: `agent_key_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        ownerType: "agent",
        ownerId: input.createdBy ?? "admin",
        name: input.name,
        keyPrefix: agentApiKeyPrefix(key),
        keyHash: hashAgentApiKey(key),
        productIds: [...new Set(input.productIds)],
        scopes: [...new Set(input.scopes)],
        expiresAt: input.expiresAt,
        status: "active",
        createdAt: timestamp,
        updatedAt: timestamp
      };
      agentApiKeys.unshift(apiKey);
      return {
        apiKey: publicAgentApiKey(apiKey),
        key
      };
    },

    async rotateAgentApiKey(keyId) {
      const item = agentApiKeys.find((candidate) => candidate.id === keyId);
      if (!item) {
        return undefined;
      }
      const timestamp = new Date().toISOString();
      const key = generateAgentApiKey();
      item.keyPrefix = agentApiKeyPrefix(key);
      item.keyHash = hashAgentApiKey(key);
      item.lastUsedAt = undefined;
      item.updatedAt = timestamp;
      return {
        apiKey: publicAgentApiKey(item),
        key
      };
    },

    async updateAgentApiKey(keyId, input) {
      const item = agentApiKeys.find((candidate) => candidate.id === keyId);
      if (!item) {
        return undefined;
      }
      if (input.status !== undefined) {
        item.status = input.status;
      }
      item.updatedAt = new Date().toISOString();
      return publicAgentApiKey(item);
    },

    async findAgentApiKeyByToken(token) {
      const prefix = agentApiKeyPrefix(token);
      return agentApiKeys.find(
        (item) => item.keyPrefix === prefix && verifyAgentApiKey(token, item.keyHash)
      );
    },

    async touchAgentApiKeyLastUsed(keyId) {
      const item = agentApiKeys.find((candidate) => candidate.id === keyId);
      if (item) {
        const timestamp = new Date().toISOString();
        item.lastUsedAt = timestamp;
        item.updatedAt = timestamp;
      }
    },

    async listAuditLogs(productId) {
      return auditLogs.filter((item) => !productId || item.productId === productId);
    },

    async createAuditLog(input) {
      const item: AuditLogItem = {
        id: `audit_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        ...input,
        metadata: input.metadata ?? {},
        createdAt: new Date().toISOString()
      };
      auditLogs.unshift(item);
      return item;
    }
  };
}
