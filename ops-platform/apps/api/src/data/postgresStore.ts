import { randomUUID } from "node:crypto";
import { and, desc, eq, gte, inArray, isNull, sql } from "drizzle-orm";
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
  FeedbackSource,
  FeedbackStatus,
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
  SettingsSummary,
  WebsiteEventItem
} from "./types.js";
import type {
  CreateAiAnalysisInput,
  CreateAgentRequestInput,
  CreateAuditLogInput,
  CreateCustomerInput,
  CreateCustomerNoteInput,
  CreateFeedbackCommentInput,
  CreateFeedbackAttachmentInput,
  CreateFeedbackInput,
  CreateLicenseInput,
  CreatePlanInput,
  CreateProductInput,
  CreateProductResult,
  CreateReleaseChannelInput,
  CreateReleaseInput,
  CreateWebsiteEventInput,
  FinalizePublishedReleaseArtifactInput,
  CreateNotificationDeliveryInput,
  CreateNotificationInput,
  CreateProposedActionInput,
  UpdateNotificationPolicyInput,
  AgentApiKeyAuthRecord,
  AgentRequestQuery,
  FeedbackRedactionField,
  LicenseValidationResult,
  OpsStore,
  MergeCustomersResult,
  ReviewAiAnalysisInput,
  ReviewProposedActionInput,
  RecordConnectorTestInput,
  SyncGitHubIssuesInput,
  UpsertConnectorInput,
  UpsertNotificationTemplateInput,
  ValidateLicenseInput,
  UpdateFeedbackInput,
  UpdateGitHubIssueInput,
  UpdateCustomerInput,
  UpdateLicenseInput,
  UpdatePlanInput,
  UpdateProductInput,
  UpdateReleaseDraftInput,
  UpdateReleasePublicationInput,
  UpdateReleaseChannelInput
} from "./store.js";
import type { OpsDatabase } from "../db/database.js";
import {
  aiAnalysisResults,
  aiProposedActions,
  agentRequests,
  apiKeys,
  auditLogs,
  connectors,
  customerNotes,
  customers,
  feedbackComments,
  feedbackAttachments,
  feedbackItems,
  githubIssueLinks,
  githubIssues,
  githubSyncRuns,
  idempotencyRecords,
  entitlements,
  licenseActivations,
  licenseValidationLogs,
  licenses,
  notificationDeliveries,
  notificationPolicies,
  notifications,
  notificationTemplates,
  appcastEntries,
  planEntitlements,
  plans,
  products,
  releaseArtifacts,
  releaseChannels,
  releasePublications,
  roles,
  releases,
  users,
  websiteEvents
} from "../db/schema.js";

function asIso(value: Date) {
  return value.toISOString();
}

function mapProduct(row: typeof products.$inferSelect): Product {
  return {
    id: row.id,
    name: row.name,
    platform: row.platform,
    bundleId: row.bundleId,
    iconUrl: row.iconUrl ?? undefined,
    description: row.description ?? undefined,
    currentStableVersion: row.currentStableVersion,
    currentBetaVersion: row.currentBetaVersion,
    supportEmail: row.supportEmail,
    githubOwner: row.githubOwner ?? undefined,
    githubRepository: row.githubRepository ?? undefined,
    updateBaseUrl: row.updateBaseUrl ?? undefined,
    appcastBaseUrl: row.appcastBaseUrl ?? undefined,
    licensePolicy: row.licensePolicy,
    dataRetentionPolicy: row.dataRetentionPolicy,
    emailBrand: row.emailBrand,
    objectStoragePrefix: row.objectStoragePrefix ?? undefined,
    status: row.status as Product["status"],
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapAgentApiKey(row: typeof apiKeys.$inferSelect): AgentApiKeyItem {
  const productIds = row.productIds.length > 0
    ? row.productIds
    : row.productId
      ? [row.productId]
      : [];
  return {
    id: row.id,
    ownerType: "agent",
    ownerId: row.ownerId,
    name: row.name,
    keyPrefix: row.keyPrefix,
    productIds,
    scopes: row.scopes,
    expiresAt: row.expiresAt?.toISOString(),
    lastUsedAt: row.lastUsedAt?.toISOString(),
    status: row.status,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString()
  };
}

function mapAgentApiKeyAuth(row: typeof apiKeys.$inferSelect): AgentApiKeyAuthRecord {
  return {
    ...mapAgentApiKey(row),
    keyHash: row.keyHash
  };
}

function mapReleaseChannel(row: typeof releaseChannels.$inferSelect): ReleaseChannelItem {
  return {
    id: row.id,
    productId: row.productId,
    name: row.name,
    appcastUrl: row.appcastUrl ?? undefined,
    currentReleaseId: row.currentReleaseId ?? undefined,
    allowedPlanIds: row.allowedPlanIds,
    minimumUpgradableVersion: row.minimumUpgradableVersion ?? undefined,
    rolloutPercentage: row.rolloutPercentage,
    autoDownloadAllowed: row.autoDownloadAllowed,
    forceUpdatePrompt: row.forceUpdatePrompt,
    status: row.status,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapCustomer(row: typeof customers.$inferSelect): CustomerItem {
  return {
    id: row.id,
    productId: row.productId,
    email: row.email,
    name: row.name,
    company: row.company ?? undefined,
    status: row.status,
    notes: row.notes ?? undefined,
    riskFlag: row.riskFlag,
    mergedIntoId: row.mergedIntoId ?? undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

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

function mapCustomerNote(row: typeof customerNotes.$inferSelect): CustomerNoteItem {
  return {
    id: row.id,
    customerId: row.customerId,
    authorId: row.authorId ?? undefined,
    body: row.body,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapPlan(row: typeof plans.$inferSelect, entitlementKeys: string[] = []): PlanItem {
  return {
    id: row.id,
    productId: row.productId,
    name: row.name,
    description: row.description ?? undefined,
    maxDevices: row.maxDevices,
    maxSeats: row.maxSeats,
    trialDays: row.trialDays,
    offlineGraceDays: row.offlineGraceDays,
    allowedChannels: row.allowedChannels,
    supportedVersionRange: row.supportedVersionRange ?? undefined,
    paymentProvider: row.paymentProvider ?? undefined,
    providerPlanId: row.providerPlanId ?? undefined,
    priceMinor: row.priceMinor ?? undefined,
    currency: row.currency ?? undefined,
    billingInterval: row.billingInterval ?? undefined,
    couponSupport: row.couponSupport,
    subscriptionSupport: row.subscriptionSupport,
    entitlements: entitlementKeys,
    status: row.status,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapConnector(row: typeof connectors.$inferSelect): ConnectorItem {
  return {
    id: row.id,
    productId: row.productId ?? undefined,
    type: row.type,
    name: row.name,
    config: row.config,
    hasSecrets: Boolean(row.encryptedSecrets),
    status: row.status,
    lastSuccessAt: row.lastSuccessAt ? asIso(row.lastSuccessAt) : undefined,
    lastError: row.lastError,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapFeedback(row: typeof feedbackItems.$inferSelect): FeedbackItem {
  return {
    id: row.id,
    productId: row.productId,
    customerId: row.customerId ?? undefined,
    title: row.title,
    description: row.description,
    type: row.type as FeedbackType,
    status: row.status as FeedbackStatus,
    priority: row.priority as FeedbackPriority,
    source: row.source as FeedbackSource,
    contactEmail: row.contactEmail ?? undefined,
    appVersion: row.appVersion ?? undefined,
    buildNumber: row.buildNumber ?? undefined,
    osVersion: row.osVersion ?? undefined,
    licenseState: row.licenseState ?? undefined,
    licenseKeyHash: row.licenseKeyHash ?? undefined,
    anonymousDeviceId: row.anonymousDeviceId ?? undefined,
    diagnosticsSummary: row.diagnosticsSummary ?? undefined,
    aiSummary: row.aiSummary ?? undefined,
    aiClassification: row.aiClassification ?? undefined,
    aiSuggestedPriority: (row.aiSuggestedPriority as FeedbackPriority | null) ?? undefined,
    assignedUserId: row.assignedUserId ?? undefined,
    duplicateOfId: row.duplicateOfId ?? undefined,
    relatedReleaseId: row.relatedReleaseId ?? undefined,
    deletedAt: row.deletedAt ? asIso(row.deletedAt) : undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapFeedbackComment(row: typeof feedbackComments.$inferSelect): FeedbackCommentItem {
  return {
    id: row.id,
    feedbackId: row.feedbackId,
    authorType: row.authorType as FeedbackCommentItem["authorType"],
    authorId: row.authorId ?? undefined,
    visibility: row.visibility as FeedbackCommentItem["visibility"],
    body: row.body,
    deliveryId: row.deliveryId ?? undefined,
    notificationId: row.notificationId ?? undefined,
    deliveryStatus:
      (row.deliveryStatus as FeedbackCommentItem["deliveryStatus"] | null) ?? undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapFeedbackAttachment(
  row: typeof feedbackAttachments.$inferSelect
): FeedbackAttachmentItem {
  return {
    id: row.id,
    feedbackId: row.feedbackId,
    objectKey: row.objectKey,
    fileName: row.fileName,
    contentType: row.contentType,
    sizeBytes: row.sizeBytes,
    sha256: row.sha256 ?? undefined,
    redactedAt: row.redactedAt ? asIso(row.redactedAt) : undefined,
    deletedAt: row.deletedAt ? asIso(row.deletedAt) : undefined,
    createdAt: asIso(row.createdAt)
  };
}

function mapRelease(row: typeof releases.$inferSelect): ReleaseItem {
  return {
    id: row.id,
    productId: row.productId,
    channel: row.channel as ReleaseItem["channel"],
    version: row.version,
    buildNumber: row.buildNumber,
    status: row.status as ReleaseItem["status"],
    artifactName: row.artifactName,
    artifactUrl: row.artifactUrl ?? undefined,
    artifactType: row.artifactType ?? undefined,
    artifactSize: row.artifactSize ?? undefined,
    minimumSystemVersion: row.minimumSystemVersion ?? undefined,
    sparkleEdDsaSignature: row.sparkleEdDsaSignature ?? undefined,
    releaseNotes: row.releaseNotes ?? undefined,
    aiReleaseSummary: row.aiReleaseSummary ?? undefined,
    aiRiskSummary: row.aiRiskSummary ?? undefined,
    preflightEvidence: row.preflightEvidence,
    createdBy: row.createdBy ?? undefined,
    publishedBy: row.publishedBy ?? undefined,
    publishedAt: row.publishedAt ? asIso(row.publishedAt) : undefined,
    createdAt: asIso(row.createdAt)
  };
}

function mapWebsiteEvent(row: typeof websiteEvents.$inferSelect): WebsiteEventItem {
  return {
    eventId: row.eventId,
    productId: row.productId,
    type: row.type as WebsiteEventItem["type"],
    path: row.path,
    referrer: row.referrer ?? undefined,
    visitorHash: row.visitorHash,
    sessionHash: row.sessionHash ?? undefined,
    releaseId: row.releaseId ?? undefined,
    platform: row.platform ?? undefined,
    architecture: row.architecture ?? undefined,
    ipAddress: row.ipAddress,
    ipHash: row.ipHash,
    browserName: row.browserName,
    browserVersion: row.browserVersion ?? undefined,
    operatingSystem: row.operatingSystem,
    deviceType: row.deviceType as WebsiteEventItem["deviceType"],
    occurredAt: asIso(row.occurredAt)
  };
}

function mapReleasePublication(row: typeof releasePublications.$inferSelect): ReleasePublicationItem {
  return {
    id: row.id,
    productId: row.productId,
    releaseId: row.releaseId,
    target: row.target as ReleasePublicationItem["target"],
    status: row.status as ReleasePublicationItem["status"],
    attempts: row.attempts,
    objectKey: row.objectKey ?? undefined,
    externalUrl: row.externalUrl ?? undefined,
    lastError: row.lastError ?? undefined,
    metadata: row.metadata,
    startedAt: row.startedAt ? asIso(row.startedAt) : undefined,
    completedAt: row.completedAt ? asIso(row.completedAt) : undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapAppcastEntry(
  row: typeof appcastEntries.$inferSelect,
  channel: typeof releaseChannels.$inferSelect
): AppcastEntryItem {
  return {
    id: row.id,
    productId: channel.productId,
    channelId: row.channelId,
    channelName: channel.name,
    releaseId: row.releaseId,
    xml: row.xml,
    objectKey: row.objectKey ?? undefined,
    publishedAt: row.publishedAt ? asIso(row.publishedAt) : undefined,
    createdAt: asIso(row.createdAt)
  };
}

function mapReleaseArtifact(
  row: typeof releaseArtifacts.$inferSelect,
  release: typeof releases.$inferSelect
): ReleaseArtifactItem {
  return {
    id: row.id,
    productId: release.productId,
    releaseId: row.releaseId,
    objectKey: row.objectKey ?? undefined,
    url: row.url,
    fileName: row.fileName,
    contentType: row.contentType ?? undefined,
    sizeBytes: row.sizeBytes ?? undefined,
    sha256: row.sha256 ?? undefined,
    signatureEvidence: row.signatureEvidence,
    createdAt: asIso(row.createdAt)
  };
}

function mapLicense(row: typeof licenses.$inferSelect): LicenseItem {
  return {
    id: row.id,
    productId: row.productId,
    customerId: row.customerId ?? undefined,
    customerName: row.customerName,
    customerEmail: row.customerEmail,
    username: row.username,
    plan: row.plan as LicenseItem["plan"],
    status: row.status as LicenseItem["status"],
    seats: row.seats,
    devices: row.devices,
    maxDevices: row.maxDevices,
    entitlements: row.entitlements,
    offlineGraceDays: row.offlineGraceDays,
    keyPrefix: row.keyPrefix,
    expiresAt: asIso(row.expiresAt),
    createdAt: asIso(row.createdAt)
  };
}

function mapLicenseActivation(row: typeof licenseActivations.$inferSelect): LicenseActivationItem {
  return {
    id: row.id,
    licenseId: row.licenseId,
    anonymousDeviceId: row.anonymousDeviceId ?? undefined,
    machineFingerprintHash: row.machineFingerprintHash ?? undefined,
    firstSeenAt: asIso(row.firstSeenAt),
    lastSeenAt: asIso(row.lastSeenAt),
    resetAt: row.resetAt ? asIso(row.resetAt) : undefined,
    riskSignals: row.riskSignals,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapLicenseValidationLog(row: typeof licenseValidationLogs.$inferSelect): LicenseValidationLogItem {
  return {
    id: row.id,
    licenseId: row.licenseId ?? undefined,
    productId: row.productId,
    keyPrefix: row.keyPrefix ?? undefined,
    email: row.email ?? undefined,
    anonymousDeviceId: row.anonymousDeviceId ?? undefined,
    machineFingerprintHash: row.machineFingerprintHash ?? undefined,
    result: row.result,
    reason: row.reason ?? undefined,
    appVersion: row.appVersion ?? undefined,
    buildNumber: row.buildNumber ?? undefined,
    ipAddress: row.ipAddress ?? undefined,
    createdAt: asIso(row.createdAt)
  };
}

function mapAuditLog(row: typeof auditLogs.$inferSelect): AuditLogItem {
  return {
    id: row.id,
    actorType: row.actorType as AuditLogItem["actorType"],
    actorId: row.actorId ?? undefined,
    action: row.action,
    targetType: row.targetType,
    targetId: row.targetId ?? undefined,
    productId: row.productId ?? undefined,
    beforeValue: row.beforeValue ?? undefined,
    afterValue: row.afterValue ?? undefined,
    ipAddress: row.ipAddress ?? undefined,
    userAgent: row.userAgent ?? undefined,
    metadata: row.metadata,
    createdAt: asIso(row.createdAt)
  };
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

function mapGitHubIssue(row: typeof githubIssues.$inferSelect, linkedFeedbackId?: string): GitHubIssueItem {
  return {
    id: row.id,
    productId: row.productId,
    githubIssueId: row.githubIssueId,
    number: row.number,
    title: row.title,
    body: row.body ?? undefined,
    labels: row.labels,
    author: row.author ?? undefined,
    state: row.state as GitHubIssueItem["state"],
    commentsCount: row.commentsCount,
    url: row.url,
    linkedFeedbackId,
    githubCreatedAt: row.githubCreatedAt ? asIso(row.githubCreatedAt) : undefined,
    githubUpdatedAt: row.githubUpdatedAt ? asIso(row.githubUpdatedAt) : undefined,
    githubClosedAt: row.githubClosedAt ? asIso(row.githubClosedAt) : undefined,
    syncedAt: asIso(row.syncedAt),
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapGitHubSyncRun(row: typeof githubSyncRuns.$inferSelect): GitHubSyncRunItem {
  return {
    id: row.id,
    productId: row.productId,
    trigger: row.trigger as GitHubSyncRunItem["trigger"],
    status: row.status as GitHubSyncRunItem["status"],
    fetchedCount: row.fetchedCount,
    changedCount: row.changedCount,
    error: row.error ?? undefined,
    startedAt: asIso(row.startedAt),
    finishedAt: row.finishedAt ? asIso(row.finishedAt) : undefined,
    createdAt: asIso(row.createdAt)
  };
}

function mapAiAnalysis(row: typeof aiAnalysisResults.$inferSelect): AiAnalysisResultItem {
  return {
    id: row.id,
    productId: row.productId,
    targetType: row.targetType as AiAnalysisResultItem["targetType"],
    targetId: row.targetId,
    agentIdentity: row.agentIdentity,
    provider: row.provider ?? undefined,
    model: row.model ?? undefined,
    analysisType: row.analysisType,
    inputReferences: row.inputReferences,
    outputBody: row.outputBody,
    confidence: row.confidence ?? undefined,
    adoptionState: row.adoptionState as AiAnalysisResultItem["adoptionState"],
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapAiProposedAction(
  row: typeof aiProposedActions.$inferSelect,
  analysis: typeof aiAnalysisResults.$inferSelect
): AiProposedActionItem {
  const mappedAnalysis = mapAiAnalysis(analysis);
  return {
    id: row.id,
    analysisId: row.analysisId,
    productId: mappedAnalysis.productId,
    targetType: mappedAnalysis.targetType,
    targetId: mappedAnalysis.targetId,
    actionType: row.actionType,
    payload: row.payload,
    status: row.status,
    reviewedBy: row.reviewedBy ?? undefined,
    reviewedAt: row.reviewedAt ? asIso(row.reviewedAt) : undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt),
    analysis: mappedAnalysis
  };
}

function mapAgentRequest(row: typeof agentRequests.$inferSelect): AgentRequestItem {
  return {
    id: row.id,
    productId: row.productId,
    targetType: row.targetType as AgentRequestItem["targetType"],
    targetId: row.targetId,
    requestType: row.requestType,
    agentHint: row.agentHint ?? undefined,
    prompt: row.prompt,
    status: row.status,
    requestedBy: row.requestedBy ?? undefined,
    metadata: row.metadata,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapNotificationTemplate(row: typeof notificationTemplates.$inferSelect): NotificationTemplateItem {
  return {
    id: row.id,
    productId: row.productId,
    type: row.type,
    subjectTemplate: row.subjectTemplate,
    htmlTemplate: row.htmlTemplate,
    textTemplate: row.textTemplate ?? undefined,
    status: row.status as NotificationTemplateItem["status"],
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapNotification(row: typeof notifications.$inferSelect): NotificationItem {
  return {
    id: row.id,
    productId: row.productId,
    customerId: row.customerId ?? undefined,
    type: row.type,
    recipient: row.recipient,
    payload: row.payload,
    priority: row.priority as NotificationItem["priority"],
    status: row.status as NotificationItem["status"],
    scheduledAt: row.scheduledAt ? asIso(row.scheduledAt) : undefined,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapNotificationPolicy(row: typeof notificationPolicies.$inferSelect): NotificationPolicyItem {
  return {
    productId: row.productId,
    quietHoursEnabled: row.quietHoursEnabled,
    quietHoursStart: row.quietHoursStart,
    quietHoursEnd: row.quietHoursEnd,
    quietHoursTimeZone: row.quietHoursTimeZone,
    createdAt: asIso(row.createdAt),
    updatedAt: asIso(row.updatedAt)
  };
}

function mapNotificationDelivery(row: typeof notificationDeliveries.$inferSelect): NotificationDeliveryItem {
  return {
    id: row.id,
    notificationId: row.notificationId,
    provider: row.provider,
    attempt: row.attempt,
    status: row.status as NotificationDeliveryItem["status"],
    providerMessageId: row.providerMessageId ?? undefined,
    error: row.error ?? undefined,
    sentAt: row.sentAt ? asIso(row.sentAt) : undefined,
    createdAt: asIso(row.createdAt)
  };
}

export function createPostgresStore(db: OpsDatabase): OpsStore {
  function recordObject(value: unknown) {
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  }

  async function recordAppcastEntry(release: ReleaseItem) {
    const [[product], [channel], releaseRows] = await Promise.all([
      db.select().from(products).where(eq(products.id, release.productId)).limit(1),
      db
        .select()
        .from(releaseChannels)
        .where(and(eq(releaseChannels.productId, release.productId), eq(releaseChannels.name, release.channel)))
        .limit(1),
      db.select().from(releases).where(eq(releases.productId, release.productId))
    ]);
    if (!channel) {
      return undefined;
    }
    const timestamp = new Date();
    const prefix = (product?.objectStoragePrefix ?? `products/${release.productId}`).replace(/\/+$/, "");
    const objectKey = `${prefix}/releases/${release.channel}/appcast.xml`;
    const xml = generateAppcastXml(product?.name ?? release.productId, release.channel, releaseRows.map(mapRelease));
    const [entry] = await db
      .insert(appcastEntries)
      .values({
        id: `appcast_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        channelId: channel.id,
        releaseId: release.id,
        xml,
        objectKey,
        publishedAt: timestamp,
        createdAt: timestamp
      })
      .onConflictDoUpdate({
        target: [appcastEntries.channelId, appcastEntries.releaseId],
        set: {
          xml,
          objectKey,
          publishedAt: timestamp
        }
      })
      .returning();
    return entry ? mapAppcastEntry(entry, channel) : undefined;
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

  async function recordReleaseArtifact(
    release: ReleaseItem,
    input: Pick<
      CreateReleaseInput,
      "artifactObjectKey" | "artifactSha256" | "packageSignatureEvidence"
    > = {}
  ) {
    if (!release.artifactUrl) {
      return undefined;
    }
    const [row] = await db
      .insert(releaseArtifacts)
      .values({
        id: `artifact_${Date.now()}_${randomUUID().replaceAll("-", "").slice(0, 12)}`,
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
        createdAt: new Date()
      })
      .returning();
    const releaseRow = {
      id: release.id,
      productId: release.productId
    } as typeof releases.$inferSelect;
    return row ? mapReleaseArtifact(row, releaseRow) : undefined;
  }

  return {
    async findIdempotencyRecord(scope, key) {
      const [row] = await db
        .select()
        .from(idempotencyRecords)
        .where(
          and(
            eq(idempotencyRecords.scope, scope),
            eq(idempotencyRecords.idempotencyKey, key)
          )
        )
        .limit(1);
      if (!row || (row.expiresAt && row.expiresAt.getTime() <= Date.now())) {
        return undefined;
      }
      return {
        scope: row.scope,
        key: row.idempotencyKey,
        requestHash: row.requestHash,
        statusCode: row.statusCode,
        responseBody: row.responseBody,
        expiresAt: row.expiresAt?.toISOString(),
        createdAt: row.createdAt.toISOString()
      };
    },

    async createIdempotencyRecord(input) {
      const timestamp = new Date();
      const [row] = await db
        .insert(idempotencyRecords)
        .values({
          scope: input.scope,
          idempotencyKey: input.key,
          requestHash: input.requestHash,
          statusCode: input.statusCode,
          responseBody: input.responseBody,
          expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
          createdAt: timestamp
        })
        .onConflictDoUpdate({
          target: [idempotencyRecords.scope, idempotencyRecords.idempotencyKey],
          set: {
            requestHash: input.requestHash,
            statusCode: input.statusCode,
            responseBody: input.responseBody,
            expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
            createdAt: timestamp
          }
        })
        .returning();
      return {
        scope: row.scope,
        key: row.idempotencyKey,
        requestHash: row.requestHash,
        statusCode: row.statusCode,
        responseBody: row.responseBody,
        expiresAt: row.expiresAt?.toISOString(),
        createdAt: row.createdAt.toISOString()
      };
    },

    async listProducts() {
      const rows = await db.select().from(products).orderBy(products.name);
      return rows.map(mapProduct);
    },

    async findProduct(productId) {
      const [row] = await db.select().from(products).where(eq(products.id, productId)).limit(1);
      return row ? mapProduct(row) : undefined;
    },

    async createProduct(input: CreateProductInput): Promise<CreateProductResult | undefined> {
      const [existing] = await db.select({ id: products.id }).from(products).where(eq(products.id, input.id)).limit(1);
      if (existing) {
        return undefined;
      }
      const feedbackApiKey = generateProductFeedbackApiKey();
      const [row] = await db
        .insert(products)
        .values({
          id: input.id,
          name: input.name,
          platform: input.platform,
          bundleId: input.bundleId,
          iconUrl: input.iconUrl,
          description: input.description,
          supportEmail: input.supportEmail,
          currentStableVersion: input.currentStableVersion ?? "",
          currentBetaVersion: input.currentBetaVersion ?? "",
          githubOwner: input.githubOwner,
          githubRepository: input.githubRepository,
          updateBaseUrl: input.updateBaseUrl,
          appcastBaseUrl: input.appcastBaseUrl,
          feedbackApiKeyHash: hashProductFeedbackApiKey(feedbackApiKey),
          licensePolicy: input.licensePolicy ?? {},
          dataRetentionPolicy: input.dataRetentionPolicy ?? {},
          emailBrand: input.emailBrand ?? {},
          objectStoragePrefix: input.objectStoragePrefix,
          status: "active"
        })
        .returning();
      return row
        ? {
            product: mapProduct(row),
            feedbackApiKey
          }
        : undefined;
    },

    async updateProduct(productId: string, input: UpdateProductInput) {
      const [row] = await db
        .update(products)
        .set({
          name: input.name,
          platform: input.platform,
          bundleId: input.bundleId,
          iconUrl: input.iconUrl,
          description: input.description,
          supportEmail: input.supportEmail,
          currentStableVersion: input.currentStableVersion,
          currentBetaVersion: input.currentBetaVersion,
          githubOwner: input.githubOwner,
          githubRepository: input.githubRepository,
          updateBaseUrl: input.updateBaseUrl,
          appcastBaseUrl: input.appcastBaseUrl,
          licensePolicy: input.licensePolicy,
          dataRetentionPolicy: input.dataRetentionPolicy,
          emailBrand: input.emailBrand,
          objectStoragePrefix: input.objectStoragePrefix,
          status: input.status,
          updatedAt: new Date()
        })
        .where(eq(products.id, productId))
        .returning();
      return row ? mapProduct(row) : undefined;
    },

    async archiveProduct(productId) {
      const [row] = await db
        .update(products)
        .set({
          status: "archived",
          updatedAt: new Date()
        })
        .where(eq(products.id, productId))
        .returning();
      return row ? mapProduct(row) : undefined;
    },

    async rotateProductFeedbackApiKey(productId) {
      const feedbackApiKey = generateProductFeedbackApiKey();
      const [row] = await db
        .update(products)
        .set({
          feedbackApiKeyHash: hashProductFeedbackApiKey(feedbackApiKey),
          updatedAt: new Date()
        })
        .where(eq(products.id, productId))
        .returning({ id: products.id });
      return row ? feedbackApiKey : undefined;
    },

    async verifyProductFeedbackApiKey(productId, apiKey) {
      const [row] = await db
        .select({
          feedbackApiKeyHash: products.feedbackApiKeyHash,
          status: products.status
        })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      return Boolean(
        row?.status === "active" &&
          row.feedbackApiKeyHash &&
          verifyProductFeedbackApiKey(apiKey, row.feedbackApiKeyHash)
      );
    },

    async listReleaseChannels(productId) {
      const rows = await db
        .select()
        .from(releaseChannels)
        .where(eq(releaseChannels.productId, productId))
        .orderBy(releaseChannels.name);
      return rows.map(mapReleaseChannel);
    },

    async createReleaseChannel(productId, input: CreateReleaseChannelInput) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(releaseChannels)
        .values({
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
        })
        .onConflictDoNothing()
        .returning();
      return row ? mapReleaseChannel(row) : undefined;
    },

    async updateReleaseChannel(
      productId,
      channelId,
      input: UpdateReleaseChannelInput
    ) {
      const [row] = await db
        .update(releaseChannels)
        .set({
          name: input.name,
          appcastUrl: input.appcastUrl,
          currentReleaseId: input.currentReleaseId,
          allowedPlanIds: input.allowedPlanIds,
          minimumUpgradableVersion: input.minimumUpgradableVersion,
          rolloutPercentage: input.rolloutPercentage,
          autoDownloadAllowed: input.autoDownloadAllowed,
          forceUpdatePrompt: input.forceUpdatePrompt,
          status: input.status,
          updatedAt: new Date()
        })
        .where(
          and(
            eq(releaseChannels.productId, productId),
            eq(releaseChannels.id, channelId)
          )
        )
        .returning();
      return row ? mapReleaseChannel(row) : undefined;
    },

    async listCustomers(productId) {
      const rows = await db
        .select()
        .from(customers)
        .where(eq(customers.productId, productId))
        .orderBy(desc(customers.createdAt));
      return rows.map(mapCustomer);
    },

    async findCustomer(productId, customerId) {
      const [row] = await db
        .select()
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.id, customerId)))
        .limit(1);
      return row ? mapCustomer(row) : undefined;
    },

    async createCustomer(productId, input: CreateCustomerInput) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      const email = input.email.trim().toLowerCase();
      const [duplicate] = await db
        .select({ id: customers.id })
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.email, email)))
        .limit(1);
      if (duplicate) {
        return undefined;
      }
      const [row] = await db
        .insert(customers)
        .values({
          id: `cust_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          email,
          name: input.name,
          company: input.company,
          status: input.status ?? "active",
          riskFlag: input.riskFlag ?? false
        })
        .returning();
      return row ? mapCustomer(row) : undefined;
    },

    async updateCustomer(
      productId,
      customerId,
      input: UpdateCustomerInput
    ) {
      const [existing] = await db
        .select()
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.id, customerId)))
        .limit(1);
      if (!existing) {
        return undefined;
      }
      const email = input.email?.trim().toLowerCase();
      if (email) {
        const [duplicate] = await db
          .select({ id: customers.id })
          .from(customers)
          .where(and(eq(customers.productId, productId), eq(customers.email, email)))
          .limit(1);
        if (duplicate && duplicate.id !== customerId) {
          return undefined;
        }
      }
      const [row] = await db
        .update(customers)
        .set({
          ...(email !== undefined ? { email } : {}),
          ...(input.name !== undefined ? { name: input.name } : {}),
          ...(input.company !== undefined ? { company: input.company } : {}),
          ...(input.status !== undefined ? { status: input.status } : {}),
          ...(input.riskFlag !== undefined ? { riskFlag: input.riskFlag } : {}),
          updatedAt: new Date()
        })
        .where(eq(customers.id, customerId))
        .returning();
      return row ? mapCustomer(row) : undefined;
    },

    async customerDetail(productId, customerId) {
      const [customerRow] = await db
        .select()
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.id, customerId)))
        .limit(1);
      if (!customerRow) {
        return undefined;
      }
      const [
        licenseRows,
        feedbackRows,
        notificationRows,
        noteRows,
        activationRows,
        productAuditRows
      ] = await Promise.all([
        db
          .select()
          .from(licenses)
          .where(and(eq(licenses.productId, productId), eq(licenses.customerId, customerId)))
          .orderBy(desc(licenses.createdAt)),
        db
          .select()
          .from(feedbackItems)
          .where(
            and(
              eq(feedbackItems.productId, productId),
              eq(feedbackItems.customerId, customerId)
            )
          )
          .orderBy(desc(feedbackItems.createdAt)),
        db
          .select()
          .from(notifications)
          .where(
            and(
              eq(notifications.productId, productId),
              eq(notifications.customerId, customerId)
            )
          )
          .orderBy(desc(notifications.createdAt)),
        db
          .select()
          .from(customerNotes)
          .where(eq(customerNotes.customerId, customerId))
          .orderBy(desc(customerNotes.createdAt)),
        db
          .select({
            id: licenseActivations.id,
            licenseId: licenseActivations.licenseId,
            anonymousDeviceId: licenseActivations.anonymousDeviceId,
            machineFingerprintHash: licenseActivations.machineFingerprintHash,
            firstSeenAt: licenseActivations.firstSeenAt,
            lastSeenAt: licenseActivations.lastSeenAt,
            resetAt: licenseActivations.resetAt,
            riskSignals: licenseActivations.riskSignals,
            createdAt: licenseActivations.createdAt,
            updatedAt: licenseActivations.updatedAt
          })
          .from(licenseActivations)
          .innerJoin(licenses, eq(licenseActivations.licenseId, licenses.id))
          .where(
            and(eq(licenses.productId, productId), eq(licenses.customerId, customerId))
          ),
        db
          .select()
          .from(auditLogs)
          .where(eq(auditLogs.productId, productId))
          .orderBy(desc(auditLogs.createdAt))
      ]);
      const notificationIds = notificationRows.map((notification) => notification.id);
      const notificationDeliveryRows = notificationIds.length > 0
        ? await db
            .select()
            .from(notificationDeliveries)
            .where(inArray(notificationDeliveries.notificationId, notificationIds))
            .orderBy(desc(notificationDeliveries.createdAt))
        : [];
      const deliveriesByNotificationId = new Map<string, NotificationDeliveryItem[]>();
      for (const delivery of notificationDeliveryRows.map(mapNotificationDelivery)) {
        const existing = deliveriesByNotificationId.get(delivery.notificationId) ?? [];
        existing.push(delivery);
        deliveriesByNotificationId.set(delivery.notificationId, existing);
      }
      const detail: CustomerDetail = {
        customer: mapCustomer(customerRow),
        licenses: licenseRows.map(mapLicense),
        feedback: feedbackRows.map(mapFeedback),
        notifications: notificationRows.map((notificationRow) => {
          const notification = mapNotification(notificationRow);
          return {
            ...notification,
            deliveries: deliveriesByNotificationId.get(notification.id) ?? []
          };
        }),
        notes: noteRows.map(mapCustomerNote),
        activations: activationRows.map(mapLicenseActivation),
        activationCount: activationRows.filter((activation) => !activation.resetAt).length,
        auditLogs: productAuditRows
          .map(mapAuditLog)
          .filter(
            (log) =>
              log.targetType === "customer" &&
              (log.targetId === customerId ||
                log.metadata.sourceCustomerId === customerId ||
                log.metadata.targetCustomerId === customerId)
          )
      };
      return detail;
    },

    async addCustomerNote(
      productId,
      customerId,
      input: CreateCustomerNoteInput
    ) {
      const [customer] = await db
        .select({ id: customers.id })
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.id, customerId)))
        .limit(1);
      if (!customer) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(customerNotes)
        .values({
          id: `cnote_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          customerId,
          authorId: input.authorId,
          body: input.body,
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      await db
        .update(customers)
        .set({ updatedAt: timestamp })
        .where(eq(customers.id, customerId));
      return row ? mapCustomerNote(row) : undefined;
    },

    async mergeCustomers(
      productId,
      sourceCustomerId,
      targetCustomerId
    ): Promise<MergeCustomersResult | undefined> {
      if (sourceCustomerId === targetCustomerId) {
        return undefined;
      }
      return db.transaction(async (tx) => {
        const [source] = await tx
          .select()
          .from(customers)
          .where(
            and(
              eq(customers.productId, productId),
              eq(customers.id, sourceCustomerId)
            )
          )
          .limit(1);
        const [target] = await tx
          .select()
          .from(customers)
          .where(
            and(
              eq(customers.productId, productId),
              eq(customers.id, targetCustomerId)
            )
          )
          .limit(1);
        if (!source || !target || source.status === "merged") {
          return undefined;
        }
        const timestamp = new Date();
        await Promise.all([
          tx
            .update(licenses)
            .set({ customerId: targetCustomerId, updatedAt: timestamp })
            .where(
              and(
                eq(licenses.productId, productId),
                eq(licenses.customerId, sourceCustomerId)
              )
            ),
          tx
            .update(feedbackItems)
            .set({ customerId: targetCustomerId, updatedAt: timestamp })
            .where(
              and(
                eq(feedbackItems.productId, productId),
                eq(feedbackItems.customerId, sourceCustomerId)
              )
            ),
          tx
            .update(notifications)
            .set({ customerId: targetCustomerId, updatedAt: timestamp })
            .where(
              and(
                eq(notifications.productId, productId),
                eq(notifications.customerId, sourceCustomerId)
              )
            ),
          tx
            .update(customerNotes)
            .set({ customerId: targetCustomerId, updatedAt: timestamp })
            .where(eq(customerNotes.customerId, sourceCustomerId))
        ]);
        const [updatedTarget] = await tx
          .update(customers)
          .set({
            riskFlag: target.riskFlag || source.riskFlag,
            company: target.company ?? source.company,
            updatedAt: timestamp
          })
          .where(eq(customers.id, targetCustomerId))
          .returning();
        const [updatedSource] = await tx
          .update(customers)
          .set({
            status: "merged",
            mergedIntoId: targetCustomerId,
            updatedAt: timestamp
          })
          .where(eq(customers.id, sourceCustomerId))
          .returning();
        return updatedSource && updatedTarget
          ? {
              source: mapCustomer(updatedSource),
              target: mapCustomer(updatedTarget)
            }
          : undefined;
      });
    },

    async listPlans(productId) {
      const rows = await db
        .select()
        .from(plans)
        .where(eq(plans.productId, productId))
        .orderBy(plans.name);
      const assignments = await db
        .select({
          planId: planEntitlements.planId,
          key: entitlements.key
        })
        .from(planEntitlements)
        .innerJoin(entitlements, eq(planEntitlements.entitlementId, entitlements.id))
        .where(eq(entitlements.productId, productId));
      const keysByPlan = new Map<string, string[]>();
      for (const assignment of assignments) {
        const keys = keysByPlan.get(assignment.planId) ?? [];
        keys.push(assignment.key);
        keysByPlan.set(assignment.planId, keys);
      }
      return rows.map((row) => mapPlan(row, keysByPlan.get(row.id) ?? []));
    },

    async createPlan(productId, input: CreatePlanInput) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      return db.transaction(async (tx) => {
        const timestamp = new Date();
        const [row] = await tx
          .insert(plans)
          .values({
            id: input.id,
            productId,
            name: input.name,
            description: input.description,
            maxDevices: input.maxDevices,
            maxSeats: input.maxSeats,
            trialDays: input.trialDays,
            offlineGraceDays: input.offlineGraceDays,
            allowedChannels: input.allowedChannels,
            supportedVersionRange: input.supportedVersionRange,
            paymentProvider: input.paymentProvider,
            providerPlanId: input.providerPlanId,
            priceMinor: input.priceMinor,
            currency: input.currency,
            billingInterval: input.billingInterval,
            couponSupport: input.couponSupport,
            subscriptionSupport: input.subscriptionSupport,
            status: input.status ?? "active",
            createdAt: timestamp,
            updatedAt: timestamp
          })
          .onConflictDoNothing()
          .returning();
        if (!row) {
          return undefined;
        }
        const keys = [...new Set(input.entitlements ?? [])];
        for (const key of keys) {
          let [entitlement] = await tx
            .select()
            .from(entitlements)
            .where(
              and(eq(entitlements.productId, productId), eq(entitlements.key, key))
            )
            .limit(1);
          if (!entitlement) {
            [entitlement] = await tx
              .insert(entitlements)
              .values({
                id: `ent_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
                productId,
                key,
                name: key
                  .split("_")
                  .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
                  .join(" "),
                status: "active",
                createdAt: timestamp,
                updatedAt: timestamp
              })
              .returning();
          }
          await tx
            .insert(planEntitlements)
            .values({
              planId: row.id,
              entitlementId: entitlement.id,
              createdAt: timestamp
            })
            .onConflictDoNothing();
        }
        return mapPlan(row, keys);
      });
    },

    async updatePlan(productId, planId, input: UpdatePlanInput) {
      return db.transaction(async (tx) => {
        const [existing] = await tx
          .select()
          .from(plans)
          .where(and(eq(plans.productId, productId), eq(plans.id, planId)))
          .limit(1);
        if (!existing) {
          return undefined;
        }
        const timestamp = new Date();
        const [row] = await tx
          .update(plans)
          .set({
            name: input.name,
            description: input.description,
            maxDevices: input.maxDevices,
            maxSeats: input.maxSeats,
            trialDays: input.trialDays,
            offlineGraceDays: input.offlineGraceDays,
            allowedChannels: input.allowedChannels,
            supportedVersionRange: input.supportedVersionRange,
            paymentProvider: input.paymentProvider,
            providerPlanId: input.providerPlanId,
            priceMinor: input.priceMinor,
            currency: input.currency,
            billingInterval: input.billingInterval,
            couponSupport: input.couponSupport,
            subscriptionSupport: input.subscriptionSupport,
            status: input.status,
            updatedAt: timestamp
          })
          .where(and(eq(plans.productId, productId), eq(plans.id, planId)))
          .returning();
        let keys: string[];
        if (input.entitlements) {
          keys = [...new Set(input.entitlements)];
          await tx.delete(planEntitlements).where(eq(planEntitlements.planId, planId));
          for (const key of keys) {
            let [entitlement] = await tx
              .select()
              .from(entitlements)
              .where(
                and(eq(entitlements.productId, productId), eq(entitlements.key, key))
              )
              .limit(1);
            if (!entitlement) {
              [entitlement] = await tx
                .insert(entitlements)
                .values({
                  id: `ent_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
                  productId,
                  key,
                  name: key
                    .split("_")
                    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
                    .join(" "),
                  status: "active",
                  createdAt: timestamp,
                  updatedAt: timestamp
                })
                .returning();
            }
            await tx.insert(planEntitlements).values({
              planId,
              entitlementId: entitlement.id,
              createdAt: timestamp
            });
          }
        } else {
          const assignments = await tx
            .select({ key: entitlements.key })
            .from(planEntitlements)
            .innerJoin(entitlements, eq(planEntitlements.entitlementId, entitlements.id))
            .where(eq(planEntitlements.planId, planId));
          keys = assignments.map((assignment) => assignment.key);
        }
        return row ? mapPlan(row, keys) : undefined;
      });
    },

    async listConnectors(productId) {
      const rows = await db.select().from(connectors).where(eq(connectors.productId, productId)).orderBy(connectors.type);
      return rows.map(mapConnector);
    },

    async findConnector(productId, type) {
      const [row] = await db
        .select()
        .from(connectors)
        .where(and(eq(connectors.productId, productId), eq(connectors.type, type)))
        .limit(1);
      return row ? mapConnector(row) : undefined;
    },

    async getConnectorSecretEnvelope(productId, type) {
      const [row] = await db
        .select({ encryptedSecrets: connectors.encryptedSecrets })
        .from(connectors)
        .where(and(eq(connectors.productId, productId), eq(connectors.type, type)))
        .limit(1);
      return row?.encryptedSecrets ?? undefined;
    },

    async upsertConnector(productId, type, input: UpsertConnectorInput) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }

      const [existing] = await db
        .select()
        .from(connectors)
        .where(and(eq(connectors.productId, productId), eq(connectors.type, type)))
        .limit(1);
      const now = new Date();
      if (existing) {
        const [row] = await db
          .update(connectors)
          .set({
            name: input.name,
            config: input.config,
            ...(input.encryptedSecrets !== undefined
              ? { encryptedSecrets: input.encryptedSecrets }
              : {}),
            status: input.encryptedSecrets ?? existing.encryptedSecrets
              ? "configured"
              : "unconfigured",
            lastError: null,
            updatedAt: now
          })
          .where(eq(connectors.id, existing.id))
          .returning();
        return row ? mapConnector(row) : undefined;
      }

      const [row] = await db
        .insert(connectors)
        .values({
          id: `conn_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          type,
          name: input.name,
          config: input.config,
          encryptedSecrets: input.encryptedSecrets,
          status: input.encryptedSecrets ? "configured" : "unconfigured"
        })
        .returning();
      return row ? mapConnector(row) : undefined;
    },

    async recordConnectorTest(productId, type, input: RecordConnectorTestInput) {
      const [row] = await db
        .update(connectors)
        .set({
          status: input.succeeded ? "configured" : "error",
          ...(input.succeeded ? { lastSuccessAt: new Date(input.testedAt) } : {}),
          lastError: input.succeeded ? null : input.error ?? "Connection test failed",
          updatedAt: new Date(input.testedAt)
        })
        .where(and(eq(connectors.productId, productId), eq(connectors.type, type)))
        .returning();
      return row ? mapConnector(row) : undefined;
    },

    async disconnectConnector(productId, type) {
      const [row] = await db
        .update(connectors)
        .set({
          encryptedSecrets: null,
          status: "disabled",
          lastError: null,
          updatedAt: new Date()
        })
        .where(and(eq(connectors.productId, productId), eq(connectors.type, type)))
        .returning();
      return row ? mapConnector(row) : undefined;
    },

    async notificationPolicy(productId) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      const [row] = await db
        .select()
        .from(notificationPolicies)
        .where(eq(notificationPolicies.productId, productId))
        .limit(1);
      return row ? mapNotificationPolicy(row) : defaultNotificationPolicy(productId);
    },

    async updateNotificationPolicy(productId, input: UpdateNotificationPolicyInput) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(notificationPolicies)
        .values({
          productId,
          quietHoursEnabled: input.quietHoursEnabled,
          quietHoursStart: input.quietHoursStart,
          quietHoursEnd: input.quietHoursEnd,
          quietHoursTimeZone: input.quietHoursTimeZone,
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .onConflictDoUpdate({
          target: notificationPolicies.productId,
          set: {
            quietHoursEnabled: input.quietHoursEnabled,
            quietHoursStart: input.quietHoursStart,
            quietHoursEnd: input.quietHoursEnd,
            quietHoursTimeZone: input.quietHoursTimeZone,
            updatedAt: timestamp
          }
        })
        .returning();
      return row ? mapNotificationPolicy(row) : undefined;
    },

    async settingsSummary(productId) {
      const [productRows, roleRows, userRows, apiKeyRows] = await Promise.all([
        db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1),
        db.select({ id: roles.id }).from(roles),
        db.select({ id: users.id }).from(users),
        db.select({ id: apiKeys.id }).from(apiKeys)
      ]);
      if (!productRows[0]) {
        return undefined;
      }
      const summary: SettingsSummary = {
        productId,
        persistence: "postgres",
        smtpConfigured: Boolean(process.env.SMTP_HOST),
        objectStorageConfigured: Boolean(process.env.S3_BUCKET && process.env.S3_ACCESS_KEY_ID && process.env.S3_SECRET_ACCESS_KEY),
        redisConfigured: Boolean(process.env.REDIS_URL),
        bootstrapOwnerConfigured: Boolean(process.env.BOOTSTRAP_OWNER_EMAIL && process.env.BOOTSTRAP_OWNER_PASSWORD),
        roleCount: roleRows.length,
        userCount: userRows.length,
        apiKeyCount: apiKeyRows.length,
        policy: {
          otaRequiresManualConfirmation: true,
          agentDangerousActionsBlocked: true,
          licenseOfflineGraceDays: 14
        }
      };
      return summary;
    },

    async dashboard(productId) {
      const [
        productRows,
        feedbackRows,
        licenseRows,
        releaseRows,
        syncRows,
        aiRows,
        validationRows,
        notificationRows,
        auditRows
      ] = await Promise.all([
        db.select().from(products).where(eq(products.id, productId)).limit(1),
        db
          .select()
          .from(feedbackItems)
          .where(and(eq(feedbackItems.productId, productId), isNull(feedbackItems.deletedAt))),
        db.select().from(licenses).where(eq(licenses.productId, productId)),
        db.select().from(releases).where(eq(releases.productId, productId)).orderBy(desc(releases.createdAt)),
        db.select().from(githubSyncRuns).where(eq(githubSyncRuns.productId, productId)).orderBy(desc(githubSyncRuns.startedAt)).limit(1),
        db.select().from(aiAnalysisResults).where(eq(aiAnalysisResults.productId, productId)),
        db.select().from(licenseValidationLogs).where(eq(licenseValidationLogs.productId, productId)),
        db.select().from(notifications).where(eq(notifications.productId, productId)),
        db.select().from(auditLogs).where(eq(auditLogs.productId, productId)).orderBy(desc(auditLogs.createdAt)).limit(5)
      ]);

      const product = productRows[0];
      if (!product) {
        return undefined;
      }
      const deliveryRows = notificationRows.length > 0
        ? await db
          .select()
          .from(notificationDeliveries)
          .where(inArray(notificationDeliveries.notificationId, notificationRows.map((item) => item.id)))
        : [];

      const summary: DashboardSummary = {
        productId,
        currentStableVersion: product.currentStableVersion,
        currentBetaVersion: product.currentBetaVersion,
        todayFeedbackCount: feedbackRows.filter((item) => {
          const age = Date.now() - item.createdAt.getTime();
          return age >= 0 && age <= 86_400_000;
        }).length,
        unhandledFeedbackCount: feedbackRows.filter((item) => !["resolved", "closed", "duplicate"].includes(item.status)).length,
        p0p1BugCount: feedbackRows.filter((item) => item.type === "bug" && ["P0", "P1"].includes(item.priority)).length,
        activeLicenseCount: licenseRows.filter((item) => item.status === "active" || item.status === "trial").length,
        expiringLicenseCount: licenseRows.filter((item) => {
          const remaining = item.expiresAt.getTime() - Date.now();
          return remaining >= 0 && remaining <= 30 * 86_400_000;
        }).length,
        latestReleaseStatus: releaseRows[0]?.status ?? "none",
        githubSyncStatus: syncRows[0]?.status ?? "unconfigured",
        aiPendingSuggestionCount: aiRows.filter((item) => item.adoptionState === "pending").length,
        licenseValidationErrorCount: validationRows.filter((item) => item.result !== "valid").length,
        emailDeliveryStatus: summarizeEmailDeliveryStatus(
          notificationRows.map(mapNotification),
          deliveryRows.map(mapNotificationDelivery)
        ),
        recentAuditEvents: recentAuditEvents(auditRows.map(mapAuditLog))
      };

      return summary;
    },

    async listFeedback(productId) {
      const rows = await db
        .select()
        .from(feedbackItems)
        .where(and(eq(feedbackItems.productId, productId), isNull(feedbackItems.deletedAt)))
        .orderBy(desc(feedbackItems.lastActivityAt));
      return rows.map(mapFeedback);
    },

    async findFeedback(productId, feedbackId) {
      const [row] = await db
        .select()
        .from(feedbackItems)
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .limit(1);
      return row ? mapFeedback(row) : undefined;
    },

    async createFeedback(productId, input: CreateFeedbackInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }

      const [customer] = input.contactEmail
        ? await db
            .select({ id: customers.id })
            .from(customers)
            .where(
              and(
                eq(customers.productId, productId),
                eq(customers.email, input.contactEmail.trim().toLowerCase())
              )
            )
            .limit(1)
        : [];
      const timestamp = new Date();
      const priority: FeedbackPriority = input.type === "crash" ? "P1" : "P2";
      const [row] = await db
        .insert(feedbackItems)
        .values({
          id: `fb_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          customerId: customer?.id,
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
          lastActivityAt: timestamp,
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();

      return row ? mapFeedback(row) : undefined;
    },

    async updateFeedback(productId, feedbackId, input: UpdateFeedbackInput) {
      const [row] = await db
        .update(feedbackItems)
        .set({
          ...input,
          updatedAt: new Date(),
          lastActivityAt: new Date()
        })
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .returning();
      return row ? mapFeedback(row) : undefined;
    },

    async listFeedbackComments(feedbackId) {
      const rows = await db
        .select()
        .from(feedbackComments)
        .where(eq(feedbackComments.feedbackId, feedbackId))
        .orderBy(feedbackComments.createdAt);
      return rows.map(mapFeedbackComment);
    },

    async createFeedbackComment(feedbackId, input: CreateFeedbackCommentInput) {
      const [feedback] = await db
        .select({ id: feedbackItems.id })
        .from(feedbackItems)
        .where(and(eq(feedbackItems.id, feedbackId), isNull(feedbackItems.deletedAt)))
        .limit(1);
      if (!feedback) {
        return undefined;
      }

      const timestamp = new Date();
      const [row] = await db
        .insert(feedbackComments)
        .values({
          id: `comment_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          feedbackId,
          authorType: input.authorType,
          authorId: input.authorId,
          visibility: input.visibility,
          body: input.body,
          deliveryId: input.deliveryId,
          notificationId: input.notificationId,
          deliveryStatus: input.deliveryStatus,
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      await db
        .update(feedbackItems)
        .set({ lastActivityAt: timestamp, updatedAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return row ? mapFeedbackComment(row) : undefined;
    },

    async listFeedbackAttachments(feedbackId) {
      const rows = await db
        .select()
        .from(feedbackAttachments)
        .where(
          and(
            eq(feedbackAttachments.feedbackId, feedbackId),
            isNull(feedbackAttachments.deletedAt)
          )
        )
        .orderBy(feedbackAttachments.createdAt);
      return rows.map(mapFeedbackAttachment);
    },

    async createFeedbackAttachment(
      productId,
      feedbackId,
      input: CreateFeedbackAttachmentInput
    ) {
      const [feedback] = await db
        .select({ id: feedbackItems.id })
        .from(feedbackItems)
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .limit(1);
      if (!feedback) {
        return undefined;
      }

      const timestamp = new Date();
      const [row] = await db
        .insert(feedbackAttachments)
        .values({
          id: `fba_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          feedbackId,
          objectKey: input.objectKey,
          fileName: input.fileName,
          contentType: input.contentType,
          sizeBytes: input.sizeBytes,
          sha256: input.sha256,
          createdAt: timestamp
        })
        .returning();
      await db
        .update(feedbackItems)
        .set({ updatedAt: timestamp, lastActivityAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return row ? mapFeedbackAttachment(row) : undefined;
    },

    async redactFeedbackAttachment(productId, feedbackId, attachmentId) {
      const [feedback] = await db
        .select({ id: feedbackItems.id })
        .from(feedbackItems)
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .limit(1);
      if (!feedback) {
        return undefined;
      }

      const timestamp = new Date();
      const [row] = await db
        .update(feedbackAttachments)
        .set({
          objectKey: `redacted://feedback-attachment/${attachmentId}`,
          fileName: "[redacted attachment]",
          contentType: "application/octet-stream",
          sizeBytes: 0,
          sha256: null,
          redactedAt: timestamp
        })
        .where(
          and(
            eq(feedbackAttachments.feedbackId, feedbackId),
            eq(feedbackAttachments.id, attachmentId),
            isNull(feedbackAttachments.deletedAt)
          )
        )
        .returning();
      if (!row) {
        return undefined;
      }
      await db
        .update(feedbackItems)
        .set({ updatedAt: timestamp, lastActivityAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return mapFeedbackAttachment(row);
    },

    async deleteFeedbackAttachment(productId, feedbackId, attachmentId) {
      const [feedback] = await db
        .select({ id: feedbackItems.id })
        .from(feedbackItems)
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .limit(1);
      if (!feedback) {
        return undefined;
      }

      const timestamp = new Date();
      const [row] = await db
        .update(feedbackAttachments)
        .set({ deletedAt: timestamp })
        .where(
          and(
            eq(feedbackAttachments.feedbackId, feedbackId),
            eq(feedbackAttachments.id, attachmentId),
            isNull(feedbackAttachments.deletedAt)
          )
        )
        .returning();
      if (!row) {
        return undefined;
      }
      await db
        .update(feedbackItems)
        .set({ updatedAt: timestamp, lastActivityAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return mapFeedbackAttachment(row);
    },

    async redactFeedback(productId, feedbackId, fields) {
      const updates: Partial<typeof feedbackItems.$inferInsert> = {
        updatedAt: new Date(),
        lastActivityAt: new Date()
      };
      for (const field of fields) {
        switch (field) {
          case "title":
            updates.title = "[redacted feedback title]";
            break;
          case "description":
            updates.description = "[redacted feedback description]";
            break;
          case "contactEmail":
            updates.contactEmail = "redacted@example.invalid";
            break;
          case "diagnosticsSummary":
            updates.diagnosticsSummary = { redacted: true };
            break;
          case "appVersion":
            updates.appVersion = "[redacted]";
            break;
          case "buildNumber":
            updates.buildNumber = "[redacted]";
            break;
          case "osVersion":
            updates.osVersion = "[redacted]";
            break;
          case "licenseState":
            updates.licenseState = "[redacted]";
            break;
          case "licenseKeyHash":
            updates.licenseKeyHash = "[redacted]";
            break;
          case "anonymousDeviceId":
            updates.anonymousDeviceId = "[redacted]";
            break;
        }
      }
      const [row] = await db
        .update(feedbackItems)
        .set(updates)
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .returning();
      return row ? mapFeedback(row) : undefined;
    },

    async deleteFeedback(productId, feedbackId) {
      const timestamp = new Date();
      const [row] = await db
        .update(feedbackItems)
        .set({
          deletedAt: timestamp,
          updatedAt: timestamp,
          lastActivityAt: timestamp
        })
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt)
          )
        )
        .returning();
      return row ? mapFeedback(row) : undefined;
    },

    async listLinkedGitHubIssues(productId, feedbackId) {
      const rows = await db
        .select({ issue: githubIssues })
        .from(githubIssueLinks)
        .innerJoin(
          feedbackItems,
          eq(githubIssueLinks.feedbackId, feedbackItems.id)
        )
        .innerJoin(
          githubIssues,
          eq(githubIssueLinks.githubIssueId, githubIssues.id)
        )
        .where(
          and(
            eq(feedbackItems.productId, productId),
            eq(feedbackItems.id, feedbackId),
            isNull(feedbackItems.deletedAt),
            eq(githubIssues.productId, productId)
          )
        )
        .orderBy(githubIssues.number);
      return rows.map(({ issue }) => mapGitHubIssue(issue, feedbackId));
    },

    async linkGitHubIssue(productId, feedbackId, githubIssueId, createdBy) {
      const [[feedback], [issue]] = await Promise.all([
        db
          .select({ id: feedbackItems.id })
          .from(feedbackItems)
          .where(
            and(
              eq(feedbackItems.productId, productId),
              eq(feedbackItems.id, feedbackId),
              isNull(feedbackItems.deletedAt)
            )
          )
          .limit(1),
        db
          .select()
          .from(githubIssues)
          .where(
            and(
              eq(githubIssues.productId, productId),
              eq(githubIssues.id, githubIssueId)
            )
          )
          .limit(1)
      ]);
      if (!feedback || !issue) {
        return undefined;
      }
      const [existing] = await db
        .select({ feedbackId: githubIssueLinks.feedbackId })
        .from(githubIssueLinks)
        .where(
          and(
            eq(githubIssueLinks.feedbackId, feedbackId),
            eq(githubIssueLinks.githubIssueId, githubIssueId)
          )
        )
        .limit(1);
      if (existing) {
        return "conflict";
      }

      const timestamp = new Date();
      await db.insert(githubIssueLinks).values({
        feedbackId,
        githubIssueId,
        createdBy,
        createdAt: timestamp
      });
      await db
        .update(feedbackItems)
        .set({ updatedAt: timestamp, lastActivityAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return mapGitHubIssue(issue, feedbackId);
    },

    async unlinkGitHubIssue(productId, feedbackId, githubIssueId) {
      const [[feedback], [issue], [link]] = await Promise.all([
        db
          .select({ id: feedbackItems.id })
          .from(feedbackItems)
          .where(
            and(
              eq(feedbackItems.productId, productId),
              eq(feedbackItems.id, feedbackId),
              isNull(feedbackItems.deletedAt)
            )
          )
          .limit(1),
        db
          .select()
          .from(githubIssues)
          .where(
            and(
              eq(githubIssues.productId, productId),
              eq(githubIssues.id, githubIssueId)
            )
          )
          .limit(1),
        db
          .select({ feedbackId: githubIssueLinks.feedbackId })
          .from(githubIssueLinks)
          .where(
            and(
              eq(githubIssueLinks.feedbackId, feedbackId),
              eq(githubIssueLinks.githubIssueId, githubIssueId)
            )
          )
          .limit(1)
      ]);
      if (!feedback || !issue || !link) {
        return undefined;
      }

      const timestamp = new Date();
      await db
        .delete(githubIssueLinks)
        .where(
          and(
            eq(githubIssueLinks.feedbackId, feedbackId),
            eq(githubIssueLinks.githubIssueId, githubIssueId)
          )
        );
      await db
        .update(feedbackItems)
        .set({ updatedAt: timestamp, lastActivityAt: timestamp })
        .where(eq(feedbackItems.id, feedbackId));
      return mapGitHubIssue(issue);
    },

    async listReleases(productId) {
      const rows = await db
        .select()
        .from(releases)
        .where(eq(releases.productId, productId))
        .orderBy(desc(releases.createdAt));
      return rows.map(mapRelease);
    },

    async listAppcastEntries(productId, channelName) {
      const condition = channelName
        ? and(eq(releaseChannels.productId, productId), eq(releaseChannels.name, channelName))
        : eq(releaseChannels.productId, productId);
      const rows = await db
        .select({ entry: appcastEntries, channel: releaseChannels })
        .from(appcastEntries)
        .innerJoin(releaseChannels, eq(appcastEntries.channelId, releaseChannels.id))
        .where(condition)
        .orderBy(desc(appcastEntries.createdAt));
      return rows.map(({ entry, channel }) => mapAppcastEntry(entry, channel));
    },

    async listReleaseArtifacts(productId, releaseId) {
      const rows = await db
        .select({ artifact: releaseArtifacts, release: releases })
        .from(releaseArtifacts)
        .innerJoin(releases, eq(releaseArtifacts.releaseId, releases.id))
        .where(and(eq(releases.productId, productId), eq(releases.id, releaseId)))
        .orderBy(desc(releaseArtifacts.createdAt), desc(releaseArtifacts.id));
      return rows.map(({ artifact, release }) => mapReleaseArtifact(artifact, release));
    },

    async listReleasePublications(productId, releaseId) {
      const rows = await db
        .select()
        .from(releasePublications)
        .where(and(eq(releasePublications.productId, productId), eq(releasePublications.releaseId, releaseId)))
        .orderBy(releasePublications.target);
      return rows.map(mapReleasePublication);
    },

    async updateReleasePublication(productId, releaseId, target, input: UpdateReleasePublicationInput) {
      const timestamp = new Date();
      const [updated] = await db
        .update(releasePublications)
        .set({
          status: input.status,
          ...(input.objectKey !== undefined ? { objectKey: input.objectKey } : {}),
          ...(input.externalUrl !== undefined ? { externalUrl: input.externalUrl } : {}),
          ...(input.lastError !== undefined ? { lastError: input.lastError } : {}),
          ...(input.metadata !== undefined ? { metadata: input.metadata } : {}),
          ...(input.startedAt !== undefined ? { startedAt: input.startedAt ? new Date(input.startedAt) : null } : {}),
          ...(input.completedAt !== undefined ? { completedAt: input.completedAt ? new Date(input.completedAt) : null } : {}),
          ...(input.incrementAttempts ? { attempts: sql`${releasePublications.attempts} + 1` } : {}),
          updatedAt: timestamp
        })
        .where(
          and(
            eq(releasePublications.productId, productId),
            eq(releasePublications.releaseId, releaseId),
            eq(releasePublications.target, target)
          )
        )
        .returning();
      return updated ? mapReleasePublication(updated) : undefined;
    },

    async finalizePublishedReleaseArtifact(
      productId,
      releaseId,
      input: FinalizePublishedReleaseArtifactInput
    ) {
      const [updated] = await db
        .update(releases)
        .set({ artifactUrl: input.artifactUrl, updatedAt: new Date() })
        .where(
          and(
            eq(releases.productId, productId),
            eq(releases.id, releaseId),
            eq(releases.status, "published")
          )
        )
        .returning();
      if (!updated) {
        return undefined;
      }
      const release = mapRelease(updated);
      await db.insert(releaseArtifacts).values({
        id: `artifact_${Date.now()}_${randomUUID().replaceAll("-", "").slice(0, 12)}`,
        releaseId,
        objectKey: input.objectKey,
        url: input.artifactUrl,
        fileName: release.artifactName,
        contentType: release.artifactType,
        sizeBytes: release.artifactSize,
        signatureEvidence: recordObject(release.preflightEvidence?.packageSignatureEvidence) ?? {},
        createdAt: new Date()
      });
      await recordAppcastEntry(release);
      return release;
    },

    async recordWebsiteEvent(productId, input) {
      const [created] = await db
        .insert(websiteEvents)
        .values({
          productId,
          ...input,
          occurredAt: new Date(input.occurredAt)
        })
        .onConflictDoNothing()
        .returning();
      if (created) {
        return { event: mapWebsiteEvent(created), created: true };
      }
      const [existing] = await db
        .select()
        .from(websiteEvents)
        .where(and(eq(websiteEvents.productId, productId), eq(websiteEvents.eventId, input.eventId)))
        .limit(1);
      return existing ? { event: mapWebsiteEvent(existing), created: false } : undefined;
    },

    async websiteAnalytics(productId, since) {
      const conditions = [eq(websiteEvents.productId, productId)];
      if (since) {
        conditions.push(gte(websiteEvents.occurredAt, new Date(since)));
      }
      const rows = await db
        .select()
        .from(websiteEvents)
        .where(and(...conditions))
        .orderBy(desc(websiteEvents.occurredAt))
        .limit(10_000);
      return summarizeWebsiteAnalytics(rows.map(mapWebsiteEvent));
    },

    async listLicenses(productId) {
      const rows = await db
        .select()
        .from(licenses)
        .where(eq(licenses.productId, productId))
        .orderBy(desc(licenses.createdAt));
      return rows.map(mapLicense);
    },

    async createRelease(productId, input: CreateReleaseInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(releases)
        .values({
          id: `rel_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          channel: input.channel,
          version: input.version,
          buildNumber: input.buildNumber,
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
          status: "draft",
          preflightEvidence: {
            ...(input.packageSignatureEvidence ? { packageSignatureEvidence: input.packageSignatureEvidence } : {}),
            ...(input.downloadReachabilityEvidence
              ? { downloadReachabilityEvidence: input.downloadReachabilityEvidence }
              : {})
          },
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      if (!row) {
        return undefined;
      }
      const release = mapRelease(row);
      await recordReleaseArtifact(release, input);
      return release;
    },

    async updateReleaseDraft(productId, releaseId, input: UpdateReleaseDraftInput) {
      const [current] = await db
        .select()
        .from(releases)
        .where(and(eq(releases.productId, productId), eq(releases.id, releaseId)))
        .limit(1);
      if (!current || ["published", "paused", "withdrawn"].includes(current.status)) {
        return undefined;
      }
      const [updated] = await db
        .update(releases)
        .set({
          ...(input.minimumSystemVersion !== undefined ? { minimumSystemVersion: input.minimumSystemVersion } : {}),
          ...(input.artifactName !== undefined ? { artifactName: input.artifactName } : {}),
          ...(input.artifactUrl !== undefined ? { artifactUrl: input.artifactUrl } : {}),
          ...(input.artifactType !== undefined ? { artifactType: input.artifactType } : {}),
          ...(input.artifactSize !== undefined ? { artifactSize: input.artifactSize } : {}),
          ...(input.sparkleEdDsaSignature !== undefined ? { sparkleEdDsaSignature: input.sparkleEdDsaSignature } : {}),
          ...(input.releaseNotes !== undefined ? { releaseNotes: input.releaseNotes } : {}),
          ...(input.aiReleaseSummary !== undefined ? { aiReleaseSummary: input.aiReleaseSummary } : {}),
          ...(input.aiRiskSummary !== undefined ? { aiRiskSummary: input.aiRiskSummary } : {}),
          status: "draft",
          preflightEvidence: {
            ...(input.packageSignatureEvidence ? { packageSignatureEvidence: input.packageSignatureEvidence } : {}),
            ...(input.downloadReachabilityEvidence
              ? { downloadReachabilityEvidence: input.downloadReachabilityEvidence }
              : {})
          },
          updatedAt: new Date()
        })
        .where(and(eq(releases.productId, productId), eq(releases.id, releaseId)))
        .returning();
      if (!updated) {
        return undefined;
      }
      const release = mapRelease(updated);
      if (releaseArtifactInputPresent(input)) {
        await recordReleaseArtifact(release, input);
      }
      return release;
    },

    async validateRelease(productId, releaseId) {
      const releaseRows = await db
        .select()
        .from(releases)
        .where(eq(releases.productId, productId));
      const release = releaseRows.find((candidate) => candidate.id === releaseId);
      if (!release) {
        return undefined;
      }
      const [product] = await db
        .select({ name: products.name })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      const evidence = buildReleasePreflightEvidence(
        product?.name ?? productId,
        mapRelease(release),
        releaseRows.map(mapRelease),
        release.preflightEvidence
      );
      const passed = evidence.checks.every((check) => check.passed);
      const [updated] = await db
        .update(releases)
        .set({
          status: passed ? "ready" : "failed",
          preflightEvidence: evidence,
          updatedAt: new Date()
        })
        .where(eq(releases.id, release.id))
        .returning();
      return {
        release: mapRelease(updated),
        passed,
        checks: evidence.checks
      };
    },

    async publishRelease(productId, releaseId, publishedBy) {
      const [release] = await db
        .select()
        .from(releases)
        .where(and(eq(releases.productId, productId), eq(releases.id, releaseId)))
        .limit(1);
      if (!release || release.status !== "ready") {
        return undefined;
      }
      const [updated] = await db
        .update(releases)
        .set({
          status: "published",
          publishedBy,
          publishedAt: new Date(),
          updatedAt: new Date()
        })
        .where(eq(releases.id, release.id))
        .returning();
      if (updated.channel === "stable") {
        await db.update(products).set({ currentStableVersion: updated.version, updatedAt: new Date() }).where(eq(products.id, productId));
      }
      if (updated.channel === "beta") {
        await db.update(products).set({ currentBetaVersion: updated.version, updatedAt: new Date() }).where(eq(products.id, productId));
      }
      await db
        .update(releaseChannels)
        .set({
          currentReleaseId: updated.id,
          updatedAt: new Date()
        })
        .where(and(eq(releaseChannels.productId, productId), eq(releaseChannels.name, updated.channel)));
      const releaseItem = mapRelease(updated);
      await recordAppcastEntry(releaseItem);
      const timestamp = new Date();
      await db
        .insert(releasePublications)
        .values(
          (["object_storage", "appcast", "github", "website_catalog"] as const).map((target) => ({
            id: `release_publication_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
            productId,
            releaseId: updated.id,
            target,
            status: "queued",
            attempts: 0,
            metadata: {},
            createdAt: timestamp,
            updatedAt: timestamp
          }))
        )
        .onConflictDoNothing();
      return releaseItem;
    },

    async updateReleaseStatus(productId, releaseId, status) {
      const timestamp = new Date();
      const [updated] = await db
        .update(releases)
        .set({
          status,
          publishedAt: status === "published" ? timestamp : undefined,
          updatedAt: timestamp
        })
        .where(and(eq(releases.productId, productId), eq(releases.id, releaseId)))
        .returning();
      if (!updated) {
        return undefined;
      }
      await db
        .update(releaseChannels)
        .set({
          currentReleaseId: status === "withdrawn" ? null : updated.id,
          updatedAt: timestamp
        })
        .where(and(eq(releaseChannels.productId, productId), eq(releaseChannels.name, updated.channel)));
      return mapRelease(updated);
    },

    async createLicense(productId, input: CreateLicenseInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const [customer] = await db
        .select({ id: customers.id })
        .from(customers)
        .where(
          and(
            eq(customers.productId, productId),
            eq(customers.email, input.customerEmail.trim().toLowerCase())
          )
        )
        .limit(1);
      const licenseKey = generateLicenseKey(productId);
      const timestamp = new Date();
      const [row] = await db
        .insert(licenses)
        .values({
          id: `lic_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          customerId: customer?.id,
          customerName: input.customerName,
          customerEmail: input.customerEmail,
          username: input.username ?? input.customerName,
          keyPrefix: licenseKeyPrefix(licenseKey),
          keyHash: hashLicenseKey(licenseKey),
          plan: input.plan,
          entitlements: input.entitlements ?? (input.plan === "free" ? [] : ["pro_features"]),
          status: input.status ?? "active",
          seats: input.seats ?? 1,
          devices: 0,
          maxDevices: input.maxDevices ?? input.seats ?? 1,
          offlineGraceDays: input.offlineGraceDays ?? (input.plan === "internal" ? 90 : input.plan === "team" ? 30 : 14),
          expiresAt: new Date(input.expiresAt),
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      return row ? { license: mapLicense(row), licenseKey } : undefined;
    },

    async updateLicense(productId, licenseId, input: UpdateLicenseInput) {
      const timestamp = new Date();
      const statusTimestamps =
        input.status === "revoked"
          ? { revokedAt: timestamp, suspendedAt: null }
          : input.status === "suspended"
            ? { suspendedAt: timestamp }
            : {};
      const [row] = await db
        .update(licenses)
        .set({
          plan: input.plan,
          status: input.status,
          seats: input.seats,
          maxDevices: input.maxDevices,
          entitlements: input.entitlements,
          offlineGraceDays: input.offlineGraceDays,
          expiresAt: input.expiresAt ? new Date(input.expiresAt) : undefined,
          ...statusTimestamps,
          updatedAt: timestamp
        })
        .where(and(eq(licenses.productId, productId), eq(licenses.id, licenseId)))
        .returning();
      return row ? mapLicense(row) : undefined;
    },

    async resetLicenseActivations(productId, licenseId) {
      const timestamp = new Date();
      await db.update(licenseActivations).set({ resetAt: timestamp, updatedAt: timestamp }).where(eq(licenseActivations.licenseId, licenseId));
      const [row] = await db
        .update(licenses)
        .set({
          devices: 0,
          updatedAt: timestamp
        })
        .where(and(eq(licenses.productId, productId), eq(licenses.id, licenseId)))
        .returning();
      return row ? mapLicense(row) : undefined;
    },

    async validateLicense(productId, input: ValidateLicenseInput): Promise<LicenseValidationResult> {
      const [row] = await db
        .select()
        .from(licenses)
        .where(and(eq(licenses.productId, productId), eq(licenses.keyHash, hashLicenseKey(input.licenseKey))))
        .limit(1);
      const logBase = {
        id: `liclog_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
        productId,
        keyPrefix: licenseKeyPrefix(input.licenseKey),
        email: input.email,
        anonymousDeviceId: input.anonymousDeviceId,
        machineFingerprintHash: input.machineFingerprintHash,
        appVersion: input.appVersion,
        buildNumber: input.buildNumber
      };
      if (!row || row.customerEmail.toLowerCase() !== input.email.toLowerCase()) {
        await db.insert(licenseValidationLogs).values({ ...logBase, result: "invalid", reason: "not_found" });
        return { valid: false, reason: "not_found" };
      }
      const license = mapLicense(row);
      if (row.status === "revoked" || row.status === "suspended") {
        await db.insert(licenseValidationLogs).values({ ...logBase, licenseId: row.id, result: "invalid", reason: row.status });
        return { valid: false, reason: row.status, license };
      }
      if (row.expiresAt.getTime() < Date.now()) {
        await db.insert(licenseValidationLogs).values({ ...logBase, licenseId: row.id, result: "invalid", reason: "expired" });
        return { valid: false, reason: "expired", license };
      }
      if (input.anonymousDeviceId || input.machineFingerprintHash) {
        const timestamp = new Date();
        const activationRows = await db
          .select()
          .from(licenseActivations)
          .where(eq(licenseActivations.licenseId, row.id));
        const existingActivation = activationRows.find((activation) =>
          input.anonymousDeviceId
            ? activation.anonymousDeviceId === input.anonymousDeviceId
            : activation.machineFingerprintHash === input.machineFingerprintHash
        );
        if (existingActivation) {
          await db
            .update(licenseActivations)
            .set({ lastSeenAt: timestamp, updatedAt: timestamp })
            .where(eq(licenseActivations.id, existingActivation.id));
        } else {
          await db.insert(licenseActivations).values({
            id: `act_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
            licenseId: row.id,
            anonymousDeviceId: input.anonymousDeviceId,
            machineFingerprintHash: input.machineFingerprintHash,
            riskSignals: {}
          });
        }
        const activeActivationRows = await db
          .select({ id: licenseActivations.id })
          .from(licenseActivations)
          .where(and(eq(licenseActivations.licenseId, row.id), isNull(licenseActivations.resetAt)));
        await db
          .update(licenses)
          .set({
            devices: activeActivationRows.length,
            updatedAt: timestamp
          })
          .where(eq(licenses.id, row.id));
        license.devices = activeActivationRows.length;
      }
      await db.insert(licenseValidationLogs).values({ ...logBase, licenseId: row.id, result: "valid" });
      return {
        valid: true,
        license,
        offlineGraceSeconds: row.offlineGraceDays * 86_400
      };
    },

    async licenseDetail(productId, licenseId): Promise<LicenseDetail | undefined> {
      const [licenseRow] = await db
        .select()
        .from(licenses)
        .where(and(eq(licenses.productId, productId), eq(licenses.id, licenseId)))
        .limit(1);
      if (!licenseRow) {
        return undefined;
      }
      const [customerRow] = await db
        .select()
        .from(customers)
        .where(and(eq(customers.productId, productId), eq(customers.email, licenseRow.customerEmail.toLowerCase())))
        .limit(1);
      const [activationRows, validationRows, auditRows] = await Promise.all([
        db
          .select()
          .from(licenseActivations)
          .where(eq(licenseActivations.licenseId, licenseId))
          .orderBy(desc(licenseActivations.lastSeenAt)),
        db
          .select()
          .from(licenseValidationLogs)
          .where(eq(licenseValidationLogs.productId, productId))
          .orderBy(desc(licenseValidationLogs.createdAt)),
        db
          .select()
          .from(auditLogs)
          .where(eq(auditLogs.productId, productId))
          .orderBy(desc(auditLogs.createdAt))
      ]);
      const license = mapLicense(licenseRow);
      return {
        license,
        customer: customerRow ? mapCustomer(customerRow) : customerSnapshotFromLicense(license),
        activations: activationRows.map(mapLicenseActivation),
        validationLogs: validationRows
          .filter(
            (log) =>
              log.licenseId === licenseId ||
              log.email?.toLowerCase() === licenseRow.customerEmail.toLowerCase()
          )
          .map(mapLicenseValidationLog),
        auditLogs: auditRows
          .filter((log) => log.targetType === "license" && log.targetId === licenseId)
          .map(mapAuditLog)
      };
    },

    async listGitHubIssues(productId) {
      const rows = await db
        .select()
        .from(githubIssues)
        .where(eq(githubIssues.productId, productId))
        .orderBy(desc(githubIssues.syncedAt));
      const links = await db.select().from(githubIssueLinks);
      return rows.map((row) => {
        const link = links.find((candidate) => candidate.githubIssueId === row.id);
        return mapGitHubIssue(row, link?.feedbackId);
      });
    },

    async updateGitHubIssue(productId, githubIssueId, input: UpdateGitHubIssueInput) {
      const timestamp = new Date();
      const [updated] = await db
        .update(githubIssues)
        .set({
          ...(input.title !== undefined ? { title: input.title } : {}),
          ...(input.body !== undefined ? { body: input.body } : {}),
          ...(input.labels !== undefined ? { labels: input.labels } : {}),
          ...(input.author !== undefined ? { author: input.author } : {}),
          ...(input.state !== undefined ? { state: input.state } : {}),
          ...(input.commentsCount !== undefined ? { commentsCount: input.commentsCount } : {}),
          ...(input.url !== undefined ? { url: input.url } : {}),
          ...(input.githubUpdatedAt !== undefined ? { githubUpdatedAt: new Date(input.githubUpdatedAt) } : {}),
          ...(input.githubClosedAt !== undefined ? { githubClosedAt: new Date(input.githubClosedAt) } : {}),
          syncedAt: timestamp,
          updatedAt: timestamp
        })
        .where(and(eq(githubIssues.productId, productId), eq(githubIssues.id, githubIssueId)))
        .returning();
      if (!updated) {
        return undefined;
      }
      const [link] = await db.select().from(githubIssueLinks).where(eq(githubIssueLinks.githubIssueId, updated.id)).limit(1);
      return mapGitHubIssue(updated, link?.feedbackId);
    },

    async syncGitHubIssues(productId, input: SyncGitHubIssuesInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }

      const startedAt = new Date();
      const changed: GitHubIssueItem[] = [];
      const feedbackCreated: FeedbackItem[] = [];

      await db.transaction(async (tx) => {
        for (const issue of input.issues) {
          const [existing] = await tx
            .select()
            .from(githubIssues)
            .where(and(eq(githubIssues.productId, productId), eq(githubIssues.githubIssueId, issue.githubIssueId)))
            .limit(1);
          const timestamp = new Date();
          if (existing) {
            const [updated] = await tx
              .update(githubIssues)
              .set({
                number: issue.number,
                title: issue.title,
                body: issue.body,
                labels: issue.labels ?? [],
                author: issue.author,
                state: issue.state,
                commentsCount: issue.commentsCount ?? 0,
                url: issue.url,
                githubCreatedAt: issue.githubCreatedAt ? new Date(issue.githubCreatedAt) : null,
                githubUpdatedAt: issue.githubUpdatedAt ? new Date(issue.githubUpdatedAt) : null,
                githubClosedAt: issue.githubClosedAt ? new Date(issue.githubClosedAt) : null,
                syncedAt: timestamp,
                updatedAt: timestamp
              })
              .where(eq(githubIssues.id, existing.id))
              .returning();
            const [link] = await tx.select().from(githubIssueLinks).where(eq(githubIssueLinks.githubIssueId, existing.id)).limit(1);
            changed.push(mapGitHubIssue(updated, link?.feedbackId));
            continue;
          }

          const feedbackId = `fb_${randomUUID().replaceAll("-", "").slice(0, 16)}`;
          const [feedbackRow] = await tx
            .insert(feedbackItems)
            .values({
              id: feedbackId,
              productId,
              title: issue.title,
              description: issue.body ?? "",
              type: labelMappedType(issue.labels),
              status: "new",
              priority: labelMappedPriority(issue.labels),
              source: "github",
              contactEmail: issue.author,
              lastActivityAt: timestamp,
              createdAt: timestamp,
              updatedAt: timestamp
            })
            .returning();
          feedbackCreated.push(mapFeedback(feedbackRow));

          const issueId = `ghi_${randomUUID().replaceAll("-", "").slice(0, 16)}`;
          const [issueRow] = await tx
            .insert(githubIssues)
            .values({
              id: issueId,
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
              githubCreatedAt: issue.githubCreatedAt ? new Date(issue.githubCreatedAt) : null,
              githubUpdatedAt: issue.githubUpdatedAt ? new Date(issue.githubUpdatedAt) : null,
              githubClosedAt: issue.githubClosedAt ? new Date(issue.githubClosedAt) : null,
              syncedAt: timestamp,
              createdAt: timestamp,
              updatedAt: timestamp
            })
            .returning();
          await tx.insert(githubIssueLinks).values({
            feedbackId,
            githubIssueId: issueId
          });
          changed.push(mapGitHubIssue(issueRow, feedbackId));
        }

        await tx.insert(githubSyncRuns).values({
          id: `ghsync_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          trigger: input.trigger,
          status: "success",
          fetchedCount: input.issues.length,
          changedCount: changed.length,
          startedAt,
          finishedAt: new Date()
        });
      });

      const [runRow] = await db
        .select()
        .from(githubSyncRuns)
        .where(eq(githubSyncRuns.productId, productId))
        .orderBy(desc(githubSyncRuns.startedAt))
        .limit(1);
      return {
        run: mapGitHubSyncRun(runRow),
        issues: changed,
        feedbackCreated
      };
    },

    async recordGitHubSyncFailure(productId, input) {
      const [product] = await db
        .select({ id: products.id })
        .from(products)
        .where(eq(products.id, productId))
        .limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(githubSyncRuns)
        .values({
          id: `ghsync_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          trigger: input.trigger,
          status: "failed",
          fetchedCount: 0,
          changedCount: 0,
          error: input.error,
          startedAt: timestamp,
          finishedAt: timestamp
        })
        .returning();
      return row ? mapGitHubSyncRun(row) : undefined;
    },

    async listGitHubSyncRuns(productId) {
      const rows = await db
        .select()
        .from(githubSyncRuns)
        .where(eq(githubSyncRuns.productId, productId))
        .orderBy(desc(githubSyncRuns.startedAt));
      return rows.map(mapGitHubSyncRun);
    },

    async listAiAnalysis(productId, targetType, targetId) {
      const rows = await db.select().from(aiAnalysisResults).where(eq(aiAnalysisResults.productId, productId));
      return rows
        .filter((item) => (!targetType || item.targetType === targetType) && (!targetId || item.targetId === targetId))
        .map(mapAiAnalysis);
    },

    async createAiAnalysis(input: CreateAiAnalysisInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, input.productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(aiAnalysisResults)
        .values({
          id: `ai_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId: input.productId,
          targetType: input.targetType,
          targetId: input.targetId,
          agentIdentity: input.agentIdentity,
          provider: input.provider,
          model: input.model,
          analysisType: input.analysisType,
          inputReferences: input.inputReferences ?? {},
          outputBody: input.outputBody,
          confidence: input.confidence,
          adoptionState: "pending",
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      return row ? mapAiAnalysis(row) : undefined;
    },

    async reviewAiAnalysis(productId, analysisId, input: ReviewAiAnalysisInput) {
      const timestamp = new Date();
      const [row] = await db
        .update(aiAnalysisResults)
        .set({
          adoptionState: input.adoptionState,
          outputBody: input.outputBody,
          adoptedBy: input.reviewedBy,
          adoptedAt: timestamp,
          updatedAt: timestamp
        })
        .where(and(eq(aiAnalysisResults.productId, productId), eq(aiAnalysisResults.id, analysisId)))
        .returning();
      return row ? mapAiAnalysis(row) : undefined;
    },

    async listProposedActions(productId, status) {
      const rows = await db
        .select({
          action: aiProposedActions,
          analysis: aiAnalysisResults
        })
        .from(aiProposedActions)
        .innerJoin(aiAnalysisResults, eq(aiProposedActions.analysisId, aiAnalysisResults.id))
        .where(eq(aiAnalysisResults.productId, productId))
        .orderBy(desc(aiProposedActions.createdAt));
      return rows
        .filter((row) => !status || row.action.status === status)
        .map((row) => mapAiProposedAction(row.action, row.analysis));
    },

    async createProposedAction(input: CreateProposedActionInput) {
      const [analysis] = await db
        .select()
        .from(aiAnalysisResults)
        .where(eq(aiAnalysisResults.id, input.analysisId))
        .limit(1);
      if (!analysis) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(aiProposedActions)
        .values({
          id: `act_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          analysisId: input.analysisId,
          actionType: input.actionType,
          payload: input.payload,
          status: "pending",
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      return row ? mapAiProposedAction(row, analysis) : undefined;
    },

    async reviewProposedAction(productId, actionId, input: ReviewProposedActionInput) {
      const [existing] = await db
        .select({
          action: aiProposedActions,
          analysis: aiAnalysisResults
        })
        .from(aiProposedActions)
        .innerJoin(aiAnalysisResults, eq(aiProposedActions.analysisId, aiAnalysisResults.id))
        .where(and(eq(aiProposedActions.id, actionId), eq(aiAnalysisResults.productId, productId)))
        .limit(1);
      if (!existing) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .update(aiProposedActions)
        .set({
          status: input.status,
          reviewedBy: input.reviewedBy,
          reviewedAt: timestamp,
          updatedAt: timestamp
        })
        .where(eq(aiProposedActions.id, actionId))
        .returning();
      return row ? mapAiProposedAction(row, existing.analysis) : undefined;
    },

    async listAgentRequests(productId, query: AgentRequestQuery = {}) {
      const conditions = [eq(agentRequests.productId, productId)];
      if (query.targetType) conditions.push(eq(agentRequests.targetType, query.targetType));
      if (query.targetId) conditions.push(eq(agentRequests.targetId, query.targetId));
      if (query.status) conditions.push(eq(agentRequests.status, query.status));
      const rows = await db
        .select()
        .from(agentRequests)
        .where(and(...conditions))
        .orderBy(desc(agentRequests.createdAt));
      return rows.map(mapAgentRequest);
    },

    async createAgentRequest(input: CreateAgentRequestInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, input.productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(agentRequests)
        .values({
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
        })
        .returning();
      return row ? mapAgentRequest(row) : undefined;
    },

    async listNotificationTemplates(productId) {
      const rows = await db
        .select()
        .from(notificationTemplates)
        .where(eq(notificationTemplates.productId, productId))
        .orderBy(notificationTemplates.type);
      return rows.map(mapNotificationTemplate);
    },

    async upsertNotificationTemplate(productId, input: UpsertNotificationTemplateInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const timestamp = new Date();
      const [row] = await db
        .insert(notificationTemplates)
        .values({
          id: `tmpl_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          type: input.type,
          subjectTemplate: input.subjectTemplate,
          htmlTemplate: input.htmlTemplate,
          textTemplate: input.textTemplate,
          status: input.status ?? "active",
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .onConflictDoUpdate({
          target: [notificationTemplates.productId, notificationTemplates.type],
          set: {
            subjectTemplate: input.subjectTemplate,
            htmlTemplate: input.htmlTemplate,
            textTemplate: input.textTemplate,
            status: input.status ?? "active",
            updatedAt: timestamp
          }
        })
        .returning();
      return row ? mapNotificationTemplate(row) : undefined;
    },

    async listNotifications(productId) {
      const rows = await db
        .select()
        .from(notifications)
        .where(eq(notifications.productId, productId))
        .orderBy(desc(notifications.createdAt));
      return rows.map(mapNotification);
    },

    async createNotification(productId, input: CreateNotificationInput) {
      const [product] = await db.select({ id: products.id }).from(products).where(eq(products.id, productId)).limit(1);
      if (!product) {
        return undefined;
      }
      const [customer] = await db
        .select({ id: customers.id })
        .from(customers)
        .where(
          and(
            eq(customers.productId, productId),
            eq(customers.email, input.recipient.trim().toLowerCase())
          )
        )
        .limit(1);
      const timestamp = new Date();
      const [row] = await db
        .insert(notifications)
        .values({
          id: `ntf_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          productId,
          customerId: customer?.id,
          type: input.type,
          recipient: input.recipient,
          payload: input.payload,
          priority: input.priority ?? "normal",
          status: input.status ?? "queued",
          scheduledAt: input.scheduledAt ? new Date(input.scheduledAt) : null,
          createdAt: timestamp,
          updatedAt: timestamp
        })
        .returning();
      return row ? mapNotification(row) : undefined;
    },

    async listNotificationDeliveries(notificationId) {
      const rows = await db
        .select()
        .from(notificationDeliveries)
        .where(eq(notificationDeliveries.notificationId, notificationId))
        .orderBy(desc(notificationDeliveries.createdAt));
      return rows.map(mapNotificationDelivery);
    },

    async createNotificationDelivery(notificationId, input: CreateNotificationDeliveryInput) {
      const [notification] = await db
        .select({ id: notifications.id })
        .from(notifications)
        .where(eq(notifications.id, notificationId))
        .limit(1);
      if (!notification) {
        return undefined;
      }
      const [row] = await db
        .insert(notificationDeliveries)
        .values({
          id: `delivery_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          notificationId,
          provider: input.provider,
          attempt: input.attempt ?? 1,
          status: input.status,
          providerMessageId: input.providerMessageId,
          error: input.error,
          sentAt: input.sentAt ? new Date(input.sentAt) : null
        })
        .returning();
      if (input.status === "sent" || input.status === "failed") {
        await db
          .update(notifications)
          .set({ status: input.status, updatedAt: new Date() })
          .where(eq(notifications.id, notificationId));
      }
      return row ? mapNotificationDelivery(row) : undefined;
    },

    async listAgentApiKeys() {
      const rows = await db
        .select()
        .from(apiKeys)
        .where(eq(apiKeys.ownerType, "agent"))
        .orderBy(desc(apiKeys.createdAt));
      return rows.map(mapAgentApiKey);
    },

    async createAgentApiKey(input) {
      const key = generateAgentApiKey();
      const [row] = await db
        .insert(apiKeys)
        .values({
          id: `agent_key_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          ownerType: "agent",
          ownerId: input.createdBy ?? "admin",
          productId: input.productIds[0] ?? null,
          productIds: [...new Set(input.productIds)],
          name: input.name,
          keyPrefix: agentApiKeyPrefix(key),
          keyHash: hashAgentApiKey(key),
          scopes: [...new Set(input.scopes)],
          expiresAt: input.expiresAt ? new Date(input.expiresAt) : null,
          status: "active"
        })
        .returning();
      return {
        apiKey: mapAgentApiKey(row),
        key
      };
    },

    async rotateAgentApiKey(keyId) {
      const key = generateAgentApiKey();
      const [row] = await db
        .update(apiKeys)
        .set({
          keyPrefix: agentApiKeyPrefix(key),
          keyHash: hashAgentApiKey(key),
          lastUsedAt: null,
          updatedAt: new Date()
        })
        .where(and(eq(apiKeys.id, keyId), eq(apiKeys.ownerType, "agent")))
        .returning();
      return row
        ? {
            apiKey: mapAgentApiKey(row),
            key
          }
        : undefined;
    },

    async updateAgentApiKey(keyId, input) {
      const update: Partial<typeof apiKeys.$inferInsert> = {
        updatedAt: new Date()
      };
      if (input.status !== undefined) {
        update.status = input.status;
      }
      const [row] = await db
        .update(apiKeys)
        .set(update)
        .where(and(eq(apiKeys.id, keyId), eq(apiKeys.ownerType, "agent")))
        .returning();
      return row ? mapAgentApiKey(row) : undefined;
    },

    async findAgentApiKeyByToken(token) {
      const [row] = await db
        .select()
        .from(apiKeys)
        .where(and(eq(apiKeys.ownerType, "agent"), eq(apiKeys.keyPrefix, agentApiKeyPrefix(token))))
        .limit(1);
      if (!row || !verifyAgentApiKey(token, row.keyHash)) {
        return undefined;
      }
      return mapAgentApiKeyAuth(row);
    },

    async touchAgentApiKeyLastUsed(keyId) {
      await db
        .update(apiKeys)
        .set({ lastUsedAt: new Date(), updatedAt: new Date() })
        .where(eq(apiKeys.id, keyId));
    },

    async listAuditLogs(productId) {
      const query = db.select().from(auditLogs);
      const rows = productId
        ? await query.where(eq(auditLogs.productId, productId)).orderBy(desc(auditLogs.createdAt))
        : await query.orderBy(desc(auditLogs.createdAt));
      return rows.map(mapAuditLog);
    },

    async createAuditLog(input: CreateAuditLogInput) {
      const [row] = await db
        .insert(auditLogs)
        .values({
          id: `audit_${randomUUID().replaceAll("-", "").slice(0, 16)}`,
          ...input,
          metadata: input.metadata ?? {}
        })
        .returning();
      return mapAuditLog(row);
    }
  };
}
