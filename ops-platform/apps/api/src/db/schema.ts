import {
  boolean,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  varchar
} from "drizzle-orm/pg-core";

const createdAt = () => timestamp("created_at", { withTimezone: true }).notNull().defaultNow();
const updatedAt = () => timestamp("updated_at", { withTimezone: true }).notNull().defaultNow();

export const products = pgTable("products", {
  id: varchar("id", { length: 64 }).primaryKey(),
  name: varchar("name", { length: 160 }).notNull(),
  platform: varchar("platform", { length: 80 }).notNull(),
  bundleId: varchar("bundle_id", { length: 255 }).notNull(),
  iconUrl: text("icon_url"),
  description: text("description"),
  supportEmail: varchar("support_email", { length: 320 }).notNull(),
  currentStableVersion: varchar("current_stable_version", { length: 80 }).notNull().default(""),
  currentBetaVersion: varchar("current_beta_version", { length: 80 }).notNull().default(""),
  githubOwner: varchar("github_owner", { length: 160 }),
  githubRepository: varchar("github_repository", { length: 160 }),
  updateBaseUrl: text("update_base_url"),
  appcastBaseUrl: text("appcast_base_url"),
  feedbackApiKeyHash: text("feedback_api_key_hash"),
  licensePolicy: jsonb("license_policy").$type<Record<string, unknown>>().notNull().default({}),
  dataRetentionPolicy: jsonb("data_retention_policy").$type<Record<string, unknown>>().notNull().default({}),
  emailBrand: jsonb("email_brand").$type<Record<string, unknown>>().notNull().default({}),
  objectStoragePrefix: text("object_storage_prefix"),
  status: varchar("status", { length: 32 }).notNull().default("active"),
  createdAt: createdAt(),
  updatedAt: updatedAt()
});

export const users = pgTable(
  "users",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    email: varchar("email", { length: 320 }).notNull(),
    name: varchar("name", { length: 160 }).notNull(),
    passwordHash: text("password_hash").notNull(),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    lastLoginAt: timestamp("last_login_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("users_email_unique").on(table.email)]
);

export const refreshTokens = pgTable(
  "refresh_tokens",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    userId: varchar("user_id", { length: 64 })
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    replacedByTokenHash: text("replaced_by_token_hash"),
    ipAddress: varchar("ip_address", { length: 120 }),
    userAgent: text("user_agent"),
    createdAt: createdAt()
  },
  (table) => [
    uniqueIndex("refresh_tokens_token_hash_unique").on(table.tokenHash),
    index("refresh_tokens_user_idx").on(table.userId),
    index("refresh_tokens_expires_idx").on(table.expiresAt)
  ]
);

export const roles = pgTable(
  "roles",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    name: varchar("name", { length: 64 }).notNull(),
    description: text("description"),
    permissions: jsonb("permissions").$type<string[]>().notNull().default([]),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("roles_name_unique").on(table.name)]
);

export const userRoles = pgTable(
  "user_roles",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    userId: varchar("user_id", { length: 64 })
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    roleId: varchar("role_id", { length: 64 })
      .notNull()
      .references(() => roles.id, { onDelete: "cascade" }),
    productId: varchar("product_id", { length: 64 }).references(() => products.id, { onDelete: "cascade" }),
    createdAt: createdAt()
  },
  (table) => [uniqueIndex("user_roles_assignment_unique").on(table.userId, table.roleId, table.productId)]
);

export const apiKeys = pgTable(
  "api_keys",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    ownerType: varchar("owner_type", { length: 32 }).notNull(),
    ownerId: varchar("owner_id", { length: 64 }).notNull(),
    productId: varchar("product_id", { length: 64 }).references(() => products.id, { onDelete: "cascade" }),
    productIds: jsonb("product_ids").$type<string[]>().notNull().default([]),
    name: varchar("name", { length: 160 }).notNull(),
    keyPrefix: varchar("key_prefix", { length: 32 }).notNull(),
    keyHash: text("key_hash").notNull(),
    scopes: jsonb("scopes").$type<string[]>().notNull().default([]),
    expiresAt: timestamp("expires_at", { withTimezone: true }),
    lastUsedAt: timestamp("last_used_at", { withTimezone: true }),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("api_keys_prefix_unique").on(table.keyPrefix),
    index("api_keys_owner_idx").on(table.ownerType, table.ownerId)
  ]
);

export const idempotencyRecords = pgTable(
  "idempotency_records",
  {
    scope: varchar("scope", { length: 160 }).notNull(),
    idempotencyKey: varchar("idempotency_key", { length: 200 }).notNull(),
    requestHash: text("request_hash").notNull(),
    statusCode: integer("status_code").notNull(),
    responseBody: jsonb("response_body").$type<Record<string, unknown>>().notNull(),
    expiresAt: timestamp("expires_at", { withTimezone: true }),
    createdAt: createdAt()
  },
  (table) => [
    primaryKey({ columns: [table.scope, table.idempotencyKey] }),
    index("idempotency_records_expires_idx").on(table.expiresAt)
  ]
);

export const customers = pgTable(
  "customers",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    email: varchar("email", { length: 320 }).notNull(),
    name: varchar("name", { length: 160 }).notNull(),
    company: varchar("company", { length: 200 }),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    notes: text("notes"),
    riskFlag: boolean("risk_flag").notNull().default(false),
    mergedIntoId: varchar("merged_into_id", { length: 64 }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("customers_product_email_unique").on(table.productId, table.email),
    index("customers_product_status_idx").on(table.productId, table.status)
  ]
);

export const customerNotes = pgTable(
  "customer_notes",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    customerId: varchar("customer_id", { length: 64 })
      .notNull()
      .references(() => customers.id, { onDelete: "cascade" }),
    authorId: varchar("author_id", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    body: text("body").notNull(),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [index("customer_notes_customer_created_idx").on(table.customerId, table.createdAt)]
);

export const plans = pgTable(
  "plans",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    name: varchar("name", { length: 120 }).notNull(),
    description: text("description"),
    maxDevices: integer("max_devices").notNull().default(1),
    maxSeats: integer("max_seats").notNull().default(1),
    trialDays: integer("trial_days").notNull().default(0),
    offlineGraceDays: integer("offline_grace_days").notNull().default(14),
    allowedChannels: jsonb("allowed_channels").$type<string[]>().notNull().default(["stable"]),
    supportedVersionRange: varchar("supported_version_range", { length: 160 }),
    paymentProvider: varchar("payment_provider", { length: 64 }),
    providerPlanId: varchar("provider_plan_id", { length: 160 }),
    priceMinor: integer("price_minor"),
    currency: varchar("currency", { length: 8 }),
    billingInterval: varchar("billing_interval", { length: 32 }),
    couponSupport: boolean("coupon_support").notNull().default(false),
    subscriptionSupport: boolean("subscription_support").notNull().default(false),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("plans_product_id_unique").on(table.productId, table.id)]
);

export const entitlements = pgTable(
  "entitlements",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    key: varchar("key", { length: 120 }).notNull(),
    name: varchar("name", { length: 160 }).notNull(),
    description: text("description"),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("entitlements_product_key_unique").on(table.productId, table.key)]
);

export const planEntitlements = pgTable(
  "plan_entitlements",
  {
    planId: varchar("plan_id", { length: 64 })
      .notNull()
      .references(() => plans.id, { onDelete: "cascade" }),
    entitlementId: varchar("entitlement_id", { length: 64 })
      .notNull()
      .references(() => entitlements.id, { onDelete: "cascade" }),
    createdAt: createdAt()
  },
  (table) => [primaryKey({ columns: [table.planId, table.entitlementId] })]
);

export const feedbackItems = pgTable(
  "feedback_items",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    customerId: varchar("customer_id", { length: 64 }).references(() => customers.id, { onDelete: "set null" }),
    title: text("title").notNull(),
    description: text("description").notNull(),
    type: varchar("type", { length: 32 }).notNull(),
    status: varchar("status", { length: 32 }).notNull(),
    priority: varchar("priority", { length: 8 }).notNull(),
    source: varchar("source", { length: 32 }).notNull(),
    contactEmail: varchar("contact_email", { length: 320 }),
    appVersion: varchar("app_version", { length: 80 }),
    buildNumber: varchar("build_number", { length: 80 }),
    osVersion: varchar("os_version", { length: 160 }),
    licenseState: varchar("license_state", { length: 32 }),
    licenseKeyHash: text("license_key_hash"),
    anonymousDeviceId: varchar("anonymous_device_id", { length: 160 }),
    diagnosticsSummary: jsonb("diagnostics_summary").$type<Record<string, unknown>>(),
    aiSummary: text("ai_summary"),
    aiClassification: varchar("ai_classification", { length: 80 }),
    aiSuggestedPriority: varchar("ai_suggested_priority", { length: 8 }),
    assignedUserId: varchar("assigned_user_id", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    duplicateOfId: varchar("duplicate_of_id", { length: 64 }),
    relatedReleaseId: varchar("related_release_id", { length: 64 }),
    lastActivityAt: timestamp("last_activity_at", { withTimezone: true }).notNull().defaultNow(),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    index("feedback_product_status_idx").on(table.productId, table.status),
    index("feedback_product_priority_idx").on(table.productId, table.priority),
    index("feedback_contact_email_idx").on(table.contactEmail),
    index("feedback_last_activity_idx").on(table.lastActivityAt)
  ]
);

export const feedbackComments = pgTable(
  "feedback_comments",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    feedbackId: varchar("feedback_id", { length: 64 })
      .notNull()
      .references(() => feedbackItems.id, { onDelete: "cascade" }),
    authorType: varchar("author_type", { length: 32 }).notNull(),
    authorId: varchar("author_id", { length: 64 }),
    visibility: varchar("visibility", { length: 32 }).notNull().default("internal"),
    body: text("body").notNull(),
    deliveryId: varchar("delivery_id", { length: 64 }),
    notificationId: varchar("notification_id", { length: 64 }),
    deliveryStatus: varchar("delivery_status", { length: 32 }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [index("feedback_comments_feedback_idx").on(table.feedbackId, table.createdAt)]
);

export const feedbackAttachments = pgTable(
  "feedback_attachments",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    feedbackId: varchar("feedback_id", { length: 64 })
      .notNull()
      .references(() => feedbackItems.id, { onDelete: "cascade" }),
    objectKey: text("object_key").notNull(),
    fileName: text("file_name").notNull(),
    contentType: varchar("content_type", { length: 160 }).notNull(),
    sizeBytes: integer("size_bytes").notNull(),
    sha256: varchar("sha256", { length: 64 }),
    redactedAt: timestamp("redacted_at", { withTimezone: true }),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
    createdAt: createdAt()
  },
  (table) => [index("feedback_attachments_feedback_idx").on(table.feedbackId)]
);

export const githubIssues = pgTable(
  "github_issues",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    githubIssueId: varchar("github_issue_id", { length: 80 }).notNull(),
    number: integer("number").notNull(),
    title: text("title").notNull(),
    body: text("body"),
    labels: jsonb("labels").$type<string[]>().notNull().default([]),
    author: varchar("author", { length: 160 }),
    state: varchar("state", { length: 32 }).notNull(),
    commentsCount: integer("comments_count").notNull().default(0),
    url: text("url").notNull(),
    githubCreatedAt: timestamp("github_created_at", { withTimezone: true }),
    githubUpdatedAt: timestamp("github_updated_at", { withTimezone: true }),
    githubClosedAt: timestamp("github_closed_at", { withTimezone: true }),
    syncedAt: timestamp("synced_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("github_issues_product_issue_unique").on(table.productId, table.githubIssueId),
    uniqueIndex("github_issues_product_number_unique").on(table.productId, table.number)
  ]
);

export const githubIssueLinks = pgTable(
  "github_issue_links",
  {
    feedbackId: varchar("feedback_id", { length: 64 })
      .notNull()
      .references(() => feedbackItems.id, { onDelete: "cascade" }),
    githubIssueId: varchar("github_issue_id", { length: 64 })
      .notNull()
      .references(() => githubIssues.id, { onDelete: "cascade" }),
    createdBy: varchar("created_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    createdAt: createdAt()
  },
  (table) => [primaryKey({ columns: [table.feedbackId, table.githubIssueId] })]
);

export const githubSyncRuns = pgTable(
  "github_sync_runs",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    trigger: varchar("trigger", { length: 32 }).notNull(),
    status: varchar("status", { length: 32 }).notNull(),
    fetchedCount: integer("fetched_count").notNull().default(0),
    changedCount: integer("changed_count").notNull().default(0),
    error: text("error"),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
    finishedAt: timestamp("finished_at", { withTimezone: true }),
    createdAt: createdAt()
  },
  (table) => [index("github_sync_runs_product_started_idx").on(table.productId, table.startedAt)]
);

export const aiAnalysisResults = pgTable(
  "ai_analysis_results",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    targetType: varchar("target_type", { length: 64 }).notNull(),
    targetId: varchar("target_id", { length: 64 }).notNull(),
    agentIdentity: varchar("agent_identity", { length: 160 }).notNull(),
    provider: varchar("provider", { length: 80 }),
    model: varchar("model", { length: 160 }),
    analysisType: varchar("analysis_type", { length: 80 }).notNull(),
    inputReferences: jsonb("input_references").$type<Record<string, unknown>>().notNull().default({}),
    outputBody: jsonb("output_body").$type<Record<string, unknown>>().notNull(),
    confidence: varchar("confidence", { length: 32 }),
    adoptionState: varchar("adoption_state", { length: 32 }).notNull().default("pending"),
    adoptedBy: varchar("adopted_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    adoptedAt: timestamp("adopted_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [index("ai_analysis_target_idx").on(table.targetType, table.targetId)]
);

export const aiProposedActions = pgTable(
  "ai_proposed_actions",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    analysisId: varchar("analysis_id", { length: 64 })
      .notNull()
      .references(() => aiAnalysisResults.id, { onDelete: "cascade" }),
    actionType: varchar("action_type", { length: 80 }).notNull(),
    payload: jsonb("payload").$type<Record<string, unknown>>().notNull(),
    status: varchar("status", { length: 32 }).notNull().default("pending"),
    reviewedBy: varchar("reviewed_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    reviewedAt: timestamp("reviewed_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [index("ai_proposed_actions_status_idx").on(table.status, table.createdAt)]
);

export const agentRequests = pgTable(
  "agent_requests",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    targetType: varchar("target_type", { length: 64 }).notNull(),
    targetId: varchar("target_id", { length: 64 }).notNull(),
    requestType: varchar("request_type", { length: 80 }).notNull(),
    agentHint: varchar("agent_hint", { length: 160 }),
    prompt: text("prompt").notNull(),
    status: varchar("status", { length: 32 }).notNull().default("queued"),
    requestedBy: varchar("requested_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    index("agent_requests_target_idx").on(table.productId, table.targetType, table.targetId),
    index("agent_requests_status_idx").on(table.productId, table.status, table.createdAt)
  ]
);

export const releaseChannels = pgTable(
  "release_channels",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    name: varchar("name", { length: 64 }).notNull(),
    appcastUrl: text("appcast_url"),
    currentReleaseId: varchar("current_release_id", { length: 64 }),
    allowedPlanIds: jsonb("allowed_plan_ids").$type<string[]>().notNull().default([]),
    minimumUpgradableVersion: varchar("minimum_upgradable_version", { length: 80 }),
    rolloutPercentage: integer("rollout_percentage").notNull().default(100),
    autoDownloadAllowed: boolean("auto_download_allowed").notNull().default(false),
    forceUpdatePrompt: boolean("force_update_prompt").notNull().default(false),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("release_channels_product_name_unique").on(table.productId, table.name)]
);

export const releases = pgTable(
  "releases",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    channel: varchar("channel", { length: 64 }).notNull(),
    version: varchar("version", { length: 80 }).notNull(),
    buildNumber: varchar("build_number", { length: 80 }).notNull(),
    minimumSystemVersion: varchar("minimum_system_version", { length: 80 }),
    artifactName: text("artifact_name").notNull(),
    artifactUrl: text("artifact_url"),
    artifactType: varchar("artifact_type", { length: 64 }),
    artifactSize: integer("artifact_size"),
    sparkleEdDsaSignature: text("sparkle_eddsa_signature"),
    releaseNotes: text("release_notes"),
    aiReleaseSummary: text("ai_release_summary"),
    aiRiskSummary: text("ai_risk_summary"),
    preflightEvidence: jsonb("preflight_evidence").$type<Record<string, unknown>>().notNull().default({}),
    status: varchar("status", { length: 32 }).notNull().default("draft"),
    createdBy: varchar("created_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    publishedBy: varchar("published_by", { length: 64 }).references(() => users.id, { onDelete: "set null" }),
    publishedAt: timestamp("published_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("releases_product_channel_build_unique").on(table.productId, table.channel, table.buildNumber),
    index("releases_product_status_idx").on(table.productId, table.status)
  ]
);

export const releaseArtifacts = pgTable(
  "release_artifacts",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    releaseId: varchar("release_id", { length: 64 })
      .notNull()
      .references(() => releases.id, { onDelete: "cascade" }),
    objectKey: text("object_key"),
    url: text("url").notNull(),
    fileName: text("file_name").notNull(),
    contentType: varchar("content_type", { length: 160 }),
    sizeBytes: integer("size_bytes"),
    sha256: varchar("sha256", { length: 64 }),
    signatureEvidence: jsonb("signature_evidence").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt()
  },
  (table) => [index("release_artifacts_release_idx").on(table.releaseId)]
);

export const appcastEntries = pgTable(
  "appcast_entries",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    channelId: varchar("channel_id", { length: 64 })
      .notNull()
      .references(() => releaseChannels.id, { onDelete: "cascade" }),
    releaseId: varchar("release_id", { length: 64 })
      .notNull()
      .references(() => releases.id, { onDelete: "cascade" }),
    xml: text("xml").notNull(),
    objectKey: text("object_key"),
    publishedAt: timestamp("published_at", { withTimezone: true }),
    createdAt: createdAt()
  },
  (table) => [uniqueIndex("appcast_entries_channel_release_unique").on(table.channelId, table.releaseId)]
);

export const websiteEvents = pgTable(
  "website_events",
  {
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    eventId: varchar("event_id", { length: 96 }).notNull(),
    type: varchar("type", { length: 48 }).notNull(),
    path: text("path").notNull(),
    referrer: text("referrer"),
    visitorHash: varchar("visitor_hash", { length: 64 }).notNull(),
    sessionHash: varchar("session_hash", { length: 64 }),
    releaseId: varchar("release_id", { length: 64 }),
    platform: varchar("platform", { length: 120 }),
    architecture: varchar("architecture", { length: 80 }),
    ipAddress: varchar("ip_address", { length: 120 }).notNull(),
    ipHash: varchar("ip_hash", { length: 64 }).notNull(),
    browserName: varchar("browser_name", { length: 80 }).notNull(),
    browserVersion: varchar("browser_version", { length: 80 }),
    operatingSystem: varchar("operating_system", { length: 160 }).notNull(),
    deviceType: varchar("device_type", { length: 24 }).notNull(),
    occurredAt: timestamp("occurred_at", { withTimezone: true }).notNull(),
    createdAt: createdAt()
  },
  (table) => [
    primaryKey({ columns: [table.productId, table.eventId] }),
    index("website_events_product_occurred_idx").on(table.productId, table.occurredAt),
    index("website_events_product_type_occurred_idx").on(table.productId, table.type, table.occurredAt)
  ]
);

export const releasePublications = pgTable(
  "release_publications",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    releaseId: varchar("release_id", { length: 64 })
      .notNull()
      .references(() => releases.id, { onDelete: "cascade" }),
    target: varchar("target", { length: 48 }).notNull(),
    status: varchar("status", { length: 32 }).notNull().default("queued"),
    attempts: integer("attempts").notNull().default(0),
    objectKey: text("object_key"),
    externalUrl: text("external_url"),
    lastError: text("last_error"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default({}),
    startedAt: timestamp("started_at", { withTimezone: true }),
    completedAt: timestamp("completed_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("release_publications_release_target_unique").on(table.releaseId, table.target),
    index("release_publications_product_release_idx").on(table.productId, table.releaseId)
  ]
);

export const licenses = pgTable(
  "licenses",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    customerId: varchar("customer_id", { length: 64 }).references(() => customers.id, { onDelete: "set null" }),
    planId: varchar("plan_id", { length: 64 }).references(() => plans.id, { onDelete: "set null" }),
    customerName: varchar("customer_name", { length: 160 }).notNull(),
    customerEmail: varchar("customer_email", { length: 320 }).notNull(),
    username: varchar("username", { length: 160 }).notNull(),
    keyPrefix: varchar("key_prefix", { length: 32 }).notNull(),
    keyHash: text("key_hash").notNull(),
    plan: varchar("plan", { length: 64 }).notNull(),
    entitlements: jsonb("entitlements").$type<string[]>().notNull().default([]),
    status: varchar("status", { length: 32 }).notNull(),
    seats: integer("seats").notNull().default(1),
    devices: integer("devices").notNull().default(0),
    maxDevices: integer("max_devices").notNull().default(1),
    offlineGraceDays: integer("offline_grace_days").notNull().default(14),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    suspendedAt: timestamp("suspended_at", { withTimezone: true }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    uniqueIndex("licenses_key_prefix_unique").on(table.keyPrefix),
    index("licenses_product_status_idx").on(table.productId, table.status),
    index("licenses_customer_email_idx").on(table.customerEmail)
  ]
);

export const licenseActivations = pgTable(
  "license_activations",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    licenseId: varchar("license_id", { length: 64 })
      .notNull()
      .references(() => licenses.id, { onDelete: "cascade" }),
    anonymousDeviceId: varchar("anonymous_device_id", { length: 160 }),
    machineFingerprintHash: text("machine_fingerprint_hash"),
    firstSeenAt: timestamp("first_seen_at", { withTimezone: true }).notNull().defaultNow(),
    lastSeenAt: timestamp("last_seen_at", { withTimezone: true }).notNull().defaultNow(),
    resetAt: timestamp("reset_at", { withTimezone: true }),
    riskSignals: jsonb("risk_signals").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [index("license_activations_license_idx").on(table.licenseId)]
);

export const licenseValidationLogs = pgTable(
  "license_validation_logs",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    licenseId: varchar("license_id", { length: 64 }).references(() => licenses.id, { onDelete: "set null" }),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    keyPrefix: varchar("key_prefix", { length: 32 }),
    email: varchar("email", { length: 320 }),
    anonymousDeviceId: varchar("anonymous_device_id", { length: 160 }),
    machineFingerprintHash: text("machine_fingerprint_hash"),
    result: varchar("result", { length: 32 }).notNull(),
    reason: varchar("reason", { length: 160 }),
    appVersion: varchar("app_version", { length: 80 }),
    buildNumber: varchar("build_number", { length: 80 }),
    ipAddress: varchar("ip_address", { length: 80 }),
    createdAt: createdAt()
  },
  (table) => [index("license_validation_logs_product_created_idx").on(table.productId, table.createdAt)]
);

export const notificationTemplates = pgTable(
  "notification_templates",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    type: varchar("type", { length: 80 }).notNull(),
    subjectTemplate: text("subject_template").notNull(),
    htmlTemplate: text("html_template").notNull(),
    textTemplate: text("text_template"),
    status: varchar("status", { length: 32 }).notNull().default("active"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("notification_templates_product_type_unique").on(table.productId, table.type)]
);

export const notifications = pgTable(
  "notifications",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 })
      .notNull()
      .references(() => products.id, { onDelete: "cascade" }),
    customerId: varchar("customer_id", { length: 64 }).references(() => customers.id, { onDelete: "set null" }),
    type: varchar("type", { length: 80 }).notNull(),
    recipient: varchar("recipient", { length: 320 }).notNull(),
    payload: jsonb("payload").$type<Record<string, unknown>>().notNull(),
    priority: varchar("priority", { length: 16 }).notNull().default("normal"),
    status: varchar("status", { length: 32 }).notNull().default("queued"),
    scheduledAt: timestamp("scheduled_at", { withTimezone: true }),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [
    index("notifications_status_scheduled_idx").on(table.status, table.scheduledAt),
    index("notifications_customer_idx").on(table.customerId, table.createdAt)
  ]
);

export const notificationDeliveries = pgTable(
  "notification_deliveries",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    notificationId: varchar("notification_id", { length: 64 })
      .notNull()
      .references(() => notifications.id, { onDelete: "cascade" }),
    provider: varchar("provider", { length: 64 }).notNull(),
    attempt: integer("attempt").notNull().default(1),
    status: varchar("status", { length: 32 }).notNull(),
    providerMessageId: varchar("provider_message_id", { length: 255 }),
    error: text("error"),
    sentAt: timestamp("sent_at", { withTimezone: true }),
    createdAt: createdAt()
  },
  (table) => [index("notification_deliveries_notification_idx").on(table.notificationId, table.attempt)]
);

export const notificationPolicies = pgTable("notification_policies", {
  productId: varchar("product_id", { length: 64 })
    .primaryKey()
    .references(() => products.id, { onDelete: "cascade" }),
  quietHoursEnabled: boolean("quiet_hours_enabled").notNull().default(false),
  quietHoursStart: varchar("quiet_hours_start", { length: 5 }).notNull().default("22:00"),
  quietHoursEnd: varchar("quiet_hours_end", { length: 5 }).notNull().default("08:00"),
  quietHoursTimeZone: varchar("quiet_hours_time_zone", { length: 80 }).notNull().default("Asia/Shanghai"),
  createdAt: createdAt(),
  updatedAt: updatedAt()
});

export const connectors = pgTable(
  "connectors",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    productId: varchar("product_id", { length: 64 }).references(() => products.id, { onDelete: "cascade" }),
    type: varchar("type", { length: 64 }).notNull(),
    name: varchar("name", { length: 160 }).notNull(),
    encryptedSecrets: text("encrypted_secrets"),
    config: jsonb("config").$type<Record<string, unknown>>().notNull().default({}),
    status: varchar("status", { length: 32 }).notNull().default("unconfigured"),
    lastSuccessAt: timestamp("last_success_at", { withTimezone: true }),
    lastError: text("last_error"),
    createdAt: createdAt(),
    updatedAt: updatedAt()
  },
  (table) => [uniqueIndex("connectors_product_type_unique").on(table.productId, table.type)]
);

export const auditLogs = pgTable(
  "audit_logs",
  {
    id: varchar("id", { length: 64 }).primaryKey(),
    actorType: varchar("actor_type", { length: 32 }).notNull(),
    actorId: varchar("actor_id", { length: 64 }),
    action: varchar("action", { length: 120 }).notNull(),
    targetType: varchar("target_type", { length: 64 }).notNull(),
    targetId: varchar("target_id", { length: 64 }),
    productId: varchar("product_id", { length: 64 }).references(() => products.id, { onDelete: "set null" }),
    beforeValue: jsonb("before_value").$type<Record<string, unknown>>(),
    afterValue: jsonb("after_value").$type<Record<string, unknown>>(),
    ipAddress: varchar("ip_address", { length: 80 }),
    userAgent: text("user_agent"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt()
  },
  (table) => [
    index("audit_logs_product_created_idx").on(table.productId, table.createdAt),
    index("audit_logs_actor_idx").on(table.actorType, table.actorId)
  ]
);
