import { seedFeedback, seedLicenses, seedNotificationTemplates, seedProducts, seedReleases } from "../data/seed.js";
import { hashPassword } from "../auth/password.js";
import { hashLicenseKey } from "../services/licenseKeys.js";
import type { OpsDatabase } from "./database.js";
import {
  customers,
  entitlements,
  feedbackItems,
  licenses,
  notificationTemplates,
  planEntitlements,
  plans,
  products,
  releaseChannels,
  releases,
  roles,
  userRoles,
  users
} from "./schema.js";

const defaultRoles = [
  {
    id: "role_owner",
    name: "owner",
    description: "Full system control",
    permissions: ["*"]
  },
  {
    id: "role_admin",
    name: "admin",
    description: "Manage products, feedback, releases, customers, licenses and settings",
    permissions: [
      "products:read",
      "products:write",
      "feedback:read",
      "feedback:write",
      "releases:read",
      "releases:write",
      "licenses:read",
      "licenses:write",
      "customers:read",
      "customers:write",
      "connectors:read",
      "connectors:write",
      "audit:read"
    ]
  },
  {
    id: "role_operator",
    name: "operator",
    description: "Triage feedback and operate non-destructive workflows",
    permissions: [
      "feedback:read",
      "feedback:write",
      "releases:read",
      "licenses:read",
      "customers:read",
      "notifications:write_draft"
    ]
  },
  {
    id: "role_readonly",
    name: "readonly",
    description: "Read-only access",
    permissions: ["products:read", "feedback:read", "releases:read", "licenses:read", "customers:read", "audit:read"]
  },
  {
    id: "role_agent",
    name: "agent",
    description: "Scoped external agent access",
    permissions: [
      "feedback:read",
      "feedback:write_analysis",
      "feedback:write_draft",
      "issues:read",
      "customers:read",
      "licenses:read",
      "notifications:write_draft",
      "actions:propose",
      "releases:read",
      "releases:write_draft"
    ]
  }
];

const defaultPlans = [
  {
    id: "plan_free",
    productId: "stacio",
    name: "Free",
    maxDevices: 1,
    maxSeats: 1,
    trialDays: 0,
    offlineGraceDays: 14,
    allowedChannels: ["stable"],
    status: "active"
  },
  {
    id: "plan_pro",
    productId: "stacio",
    name: "Pro",
    maxDevices: 2,
    maxSeats: 1,
    trialDays: 14,
    offlineGraceDays: 14,
    allowedChannels: ["stable", "beta"],
    status: "active"
  },
  {
    id: "plan_team",
    productId: "stacio",
    name: "Team",
    maxDevices: 20,
    maxSeats: 10,
    trialDays: 14,
    offlineGraceDays: 30,
    allowedChannels: ["stable", "beta"],
    status: "active"
  },
  {
    id: "plan_internal",
    productId: "stacio",
    name: "Internal",
    maxDevices: 20,
    maxSeats: 20,
    trialDays: 0,
    offlineGraceDays: 90,
    allowedChannels: ["stable", "beta", "dev", "internal"],
    status: "active"
  }
];

const defaultEntitlements = [
  {
    id: "ent_pro_features",
    productId: "stacio",
    key: "pro_features",
    name: "Pro Features",
    description: "Paid Stacio functionality",
    status: "active"
  },
  {
    id: "ent_beta_channel",
    productId: "stacio",
    key: "beta_channel",
    name: "Beta Channel",
    description: "Access to human-confirmed beta OTA releases",
    status: "active"
  }
];

export async function seedDatabase(db: OpsDatabase) {
  const bootstrapEmail = process.env.BOOTSTRAP_OWNER_EMAIL?.trim().toLowerCase();
  const bootstrapPassword = process.env.BOOTSTRAP_OWNER_PASSWORD;
  if ((bootstrapEmail && !bootstrapPassword) || (!bootstrapEmail && bootstrapPassword)) {
    throw new Error("BOOTSTRAP_OWNER_EMAIL and BOOTSTRAP_OWNER_PASSWORD must be configured together");
  }
  const bootstrapPasswordHash =
    bootstrapEmail && bootstrapPassword ? await hashPassword(bootstrapPassword) : undefined;

  await db.transaction(async (tx) => {
    await tx
      .insert(products)
      .values(
        seedProducts.map(({ createdAt: _createdAt, updatedAt: _updatedAt, ...product }) => ({
          ...product,
          licensePolicy: {
            binding: ["username", "email"],
            offlineGraceDays: 14,
            deviceFingerprintPolicy: "risk_signal"
          },
          dataRetentionPolicy: product.dataRetentionPolicy ?? {
            feedbackRetentionDays: 730,
            diagnosticsRetentionDays: 90,
            auditLogRetentionDays: 1095,
            inactiveCustomerRetentionDays: 730
          },
          emailBrand: {
            brandColor: "#007AFF",
            senderName: "Stacio",
            supportEmail: product.supportEmail
          },
          objectStoragePrefix: `products/${product.id}`
        }))
      )
      .onConflictDoNothing();

    await tx.insert(roles).values(defaultRoles).onConflictDoNothing();
    if (bootstrapEmail && bootstrapPasswordHash) {
      await tx
        .insert(users)
        .values({
          id: "usr_bootstrap_owner",
          email: bootstrapEmail,
          name: process.env.BOOTSTRAP_OWNER_NAME ?? "Stacio Owner",
          passwordHash: bootstrapPasswordHash,
          status: "active"
        })
        .onConflictDoNothing();
      await tx
        .insert(userRoles)
        .values({
          id: "user_role_bootstrap_owner",
          userId: "usr_bootstrap_owner",
          roleId: "role_owner"
        })
        .onConflictDoNothing();
    }

    await tx.insert(plans).values(defaultPlans).onConflictDoNothing();
    await tx.insert(entitlements).values(defaultEntitlements).onConflictDoNothing();
    await tx
      .insert(planEntitlements)
      .values([
        { planId: "plan_pro", entitlementId: "ent_pro_features" },
        { planId: "plan_pro", entitlementId: "ent_beta_channel" },
        { planId: "plan_team", entitlementId: "ent_pro_features" },
        { planId: "plan_team", entitlementId: "ent_beta_channel" },
        { planId: "plan_internal", entitlementId: "ent_pro_features" },
        { planId: "plan_internal", entitlementId: "ent_beta_channel" }
      ])
      .onConflictDoNothing();

    await tx
      .insert(customers)
      .values([
        {
          id: "cust_internal_tester",
          productId: "stacio",
          email: "tester@example.com",
          name: "Internal Tester",
          status: "active"
        },
        {
          id: "cust_pro_user",
          productId: "stacio",
          email: "pro@example.com",
          name: "Pro User",
          status: "active"
        }
      ])
      .onConflictDoNothing();

    await tx
      .insert(feedbackItems)
      .values(
        seedFeedback.map((item) => ({
          ...item,
          deletedAt: item.deletedAt ? new Date(item.deletedAt) : null,
          createdAt: new Date(item.createdAt),
          updatedAt: new Date(item.updatedAt),
          lastActivityAt: new Date(item.updatedAt)
        }))
      )
      .onConflictDoNothing();

    await tx
      .insert(releaseChannels)
      .values([
        { id: "channel_stacio_stable", productId: "stacio", name: "stable", rolloutPercentage: 100 },
        { id: "channel_stacio_beta", productId: "stacio", name: "beta", rolloutPercentage: 100 },
        { id: "channel_stacio_dev", productId: "stacio", name: "dev", rolloutPercentage: 100 },
        { id: "channel_stacio_internal", productId: "stacio", name: "internal", rolloutPercentage: 100 }
      ])
      .onConflictDoNothing();

    await tx
      .insert(releases)
      .values(
        seedReleases.map((release) => ({
          ...release,
          publishedAt: release.publishedAt ? new Date(release.publishedAt) : null,
          createdAt: new Date(release.createdAt),
          updatedAt: new Date(release.createdAt),
          preflightEvidence: {}
        }))
      )
      .onConflictDoNothing();

    await tx
      .insert(licenses)
      .values(
        seedLicenses.map((license, index) => ({
          ...license,
          customerId: index === 0 ? "cust_internal_tester" : "cust_pro_user",
          planId: license.plan === "internal" ? "plan_internal" : "plan_pro",
          username: license.customerName,
          keyPrefix: index === 0 ? "STACIO-INT-SEED" : "STACIO-PRO-SEED",
          keyHash: hashLicenseKey(index === 0 ? "STACIO-INT-SEED-KEY" : "STACIO-PRO-SEED-KEY"),
          entitlements: ["pro_features", "beta_channel"],
          maxDevices: license.seats,
          offlineGraceDays: license.plan === "internal" ? 90 : 14,
          expiresAt: new Date(license.expiresAt),
          createdAt: new Date(license.createdAt),
          updatedAt: new Date(license.createdAt)
        }))
      )
      .onConflictDoNothing();

    await tx
      .insert(notificationTemplates)
      .values(
        seedNotificationTemplates.map((template) => ({
          id: template.id,
          productId: template.productId,
          type: template.type,
          subjectTemplate: template.subjectTemplate,
          htmlTemplate: template.htmlTemplate,
          textTemplate: template.textTemplate,
          status: template.status,
          createdAt: new Date(template.createdAt),
          updatedAt: new Date(template.updatedAt)
        }))
      )
      .onConflictDoNothing();
  });
}
