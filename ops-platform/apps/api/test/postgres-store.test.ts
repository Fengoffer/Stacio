import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { afterEach, describe, expect, it } from "vitest";
import { hashPassword } from "../src/auth/password.js";
import { createPostgresAuthStore } from "../src/auth/store.js";
import { requiredNotificationTemplateTypes } from "../src/data/seed.js";
import { createPostgresStore } from "../src/data/postgresStore.js";
import type { OpsDatabase } from "../src/db/database.js";
import * as schema from "../src/db/schema.js";
import { userRoles, users } from "../src/db/schema.js";
import { seedDatabase } from "../src/db/seed.js";
import { encryptConnectorSecrets } from "../src/services/connectorSecrets.js";

describe("PostgreSQL persistence", () => {
  let client: PGlite | undefined;

  afterEach(async () => {
    await client?.close();
    client = undefined;
  });

  it("applies the initial migration and persists core operations", async () => {
    client = new PGlite();

    const migrationsDirectory = resolve(process.cwd(), "apps/api/drizzle");
    const migrationFiles = readdirSync(migrationsDirectory)
      .filter((file) => file.endsWith(".sql"))
      .sort();
    for (const migrationFile of migrationFiles) {
      const migrationSql = readFileSync(resolve(migrationsDirectory, migrationFile), "utf8").replaceAll(
        "--> statement-breakpoint",
        ""
      );
      await client.exec(migrationSql);
    }

    const tableResult = await client.query<{ table_name: string }>(
      "select table_name from information_schema.tables where table_schema = 'public'"
    );
    expect(tableResult.rows.map((row) => row.table_name)).toEqual(
      expect.arrayContaining([
        "products",
        "feedback_items",
        "releases",
        "licenses",
        "audit_logs",
        "customer_notes"
      ])
    );

    const database = drizzle(client, { schema }) as unknown as OpsDatabase;
    await seedDatabase(database);
    const store = createPostgresStore(database);
    const authStore = createPostgresAuthStore(database);

    expect(await store.findProduct("stacio")).toEqual(
      expect.objectContaining({
        id: "stacio",
        name: "Stacio"
      })
    );
    const createdProduct = await store.createProduct({
      id: "portdesk",
      name: "PortDesk",
      platform: "macOS",
      bundleId: "com.zerxlab.portdesk",
      supportEmail: "support@example.com",
      githubOwner: "zerx-lab",
      githubRepository: "portdesk",
      updateBaseUrl: "https://updates.example.com/portdesk",
      appcastBaseUrl: "https://updates.example.com/portdesk",
      objectStoragePrefix: "products/portdesk",
      licensePolicy: {
        defaultOfflineGraceDays: 14
      },
      emailBrand: {
        name: "PortDesk",
        accentColor: "#0070C0"
      }
    });
    expect(createdProduct?.feedbackApiKey).toMatch(/^pfk_/);
    expect(await store.verifyProductFeedbackApiKey("portdesk", createdProduct?.feedbackApiKey ?? "")).toBe(true);
    expect(
      await store.updateProduct("portdesk", {
        supportEmail: "help@example.com",
        githubRepository: "portdesk-app"
      })
    ).toEqual(
      expect.objectContaining({
        supportEmail: "help@example.com",
        githubRepository: "portdesk-app"
      })
    );
    const rotatedProductKey = await store.rotateProductFeedbackApiKey("portdesk");
    expect(rotatedProductKey).toMatch(/^pfk_/);
    expect(await store.verifyProductFeedbackApiKey("portdesk", createdProduct?.feedbackApiKey ?? "")).toBe(false);
    expect(await store.verifyProductFeedbackApiKey("portdesk", rotatedProductKey ?? "")).toBe(true);
    expect(await store.archiveProduct("portdesk")).toEqual(
      expect.objectContaining({
        status: "archived"
      })
    );
    expect(await store.verifyProductFeedbackApiKey("portdesk", rotatedProductKey ?? "")).toBe(false);
    expect(await createPostgresStore(database).findProduct("portdesk")).toEqual(
      expect.objectContaining({
        id: "portdesk",
        supportEmail: "help@example.com",
        status: "archived"
      })
    );
    expect(await store.listFeedback("stacio")).toHaveLength(2);
    expect(await store.listReleases("stacio")).toHaveLength(2);
    expect(await store.listLicenses("stacio")).toHaveLength(2);
    expect((await store.listNotificationTemplates("stacio")).map((template) => template.type).sort()).toEqual(
      [...requiredNotificationTemplateTypes].sort()
    );

    const connectorEnvelope = encryptConnectorSecrets({
      token: "postgres-connector-secret"
    });
    expect(
      await store.upsertConnector("stacio", "github", {
        name: "GitHub Issues",
        config: {
          owner: "zerx-lab",
          repository: "stacio"
        },
        encryptedSecrets: connectorEnvelope
      })
    ).toEqual(
      expect.objectContaining({
        type: "github",
        hasSecrets: true,
        status: "configured"
      })
    );
    expect(await store.getConnectorSecretEnvelope("stacio", "github")).toBe(
      connectorEnvelope
    );
    expect(
      await createPostgresStore(database).findConnector("stacio", "github")
    ).toEqual(
      expect.objectContaining({
        type: "github",
        hasSecrets: true,
        config: {
          owner: "zerx-lab",
          repository: "stacio"
        }
      })
    );
    expect(
      await store.recordConnectorTest("stacio", "github", {
        succeeded: false,
        error: "Repository denied",
        testedAt: "2026-07-10T04:00:00.000Z"
      })
    ).toEqual(
      expect.objectContaining({
        status: "error",
        lastError: "Repository denied"
      })
    );
    expect(await store.disconnectConnector("stacio", "github")).toEqual(
      expect.objectContaining({
        status: "disabled",
        hasSecrets: false
      })
    );
    expect(await store.getConnectorSecretEnvelope("stacio", "github")).toBeUndefined();

    await database.insert(users).values({
      id: "usr_database_owner",
      email: "database-owner@example.com",
      name: "Database Owner",
      passwordHash: await hashPassword("database-owner-password"),
      status: "active"
    });
    await database.insert(userRoles).values({
      id: "user_role_database_owner",
      userId: "usr_database_owner",
      roleId: "role_owner"
    });
    expect(await authStore.findByEmail("database-owner@example.com")).toEqual(
      expect.objectContaining({
        id: "usr_database_owner",
        roles: ["owner"],
        permissions: ["*"]
      })
    );

    const created = await store.createFeedback("stacio", {
      title: "Database-backed feedback",
      description: "This item must be stored in PostgreSQL.",
      type: "bug",
      contactEmail: "db-test@example.com"
    });
    expect(created).toEqual(
      expect.objectContaining({
        productId: "stacio",
        title: "Database-backed feedback",
        status: "new",
        priority: "P2"
      })
    );
    expect(await store.listFeedback("stacio")).toHaveLength(3);

    const summary = await store.dashboard("stacio");
    expect(summary).toEqual(
      expect.objectContaining({
        productId: "stacio",
        unhandledFeedbackCount: 3,
        activeLicenseCount: 2
      })
    );

    await store.createAuditLog({
      actorType: "user",
      actorId: "usr_test",
      action: "feedback.triaged",
      targetType: "feedback",
      targetId: created?.id,
      productId: "stacio"
    });
    expect(await store.listAuditLogs("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actorId: "usr_test",
          action: "feedback.triaged"
        })
      ])
    );

    const githubSync = await store.syncGitHubIssues("stacio", {
      trigger: "manual",
      issues: [
        {
          githubIssueId: "pg-github-1",
          number: 101,
          title: "Postgres GitHub issue",
          body: "Stored through PostgreSQL",
          labels: ["bug", "p1"],
          author: "pg-user",
          state: "open",
          url: "https://github.com/example/stacio/issues/101"
        }
      ]
    });
    expect(githubSync).toEqual(
      expect.objectContaining({
        feedbackCreated: [
          expect.objectContaining({
            source: "github",
            priority: "P1"
          })
        ]
      })
    );
    expect(await store.listGitHubIssues("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          number: 101,
          linkedFeedbackId: expect.stringMatching(/^fb_/)
        })
      ])
    );

    const analysis = await store.createAiAnalysis({
      productId: "stacio",
      targetType: "feedback",
      targetId: "fb_001",
      agentIdentity: "postgres-agent",
      analysisType: "feedback_triage",
      outputBody: {
        summary: "PostgreSQL-backed analysis"
      }
    });
    expect(analysis).toEqual(
      expect.objectContaining({
        agentIdentity: "postgres-agent",
        adoptionState: "pending"
      })
    );
    expect(await store.reviewAiAnalysis("stacio", analysis?.id ?? "", { adoptionState: "accepted" })).toEqual(
      expect.objectContaining({
        id: analysis?.id,
        adoptionState: "accepted"
      })
    );
    const proposedAction = await store.createProposedAction({
      analysisId: analysis?.id ?? "",
      actionType: "feedback.update_status",
      payload: {
        status: "in_progress"
      }
    });
    expect(proposedAction).toEqual(
      expect.objectContaining({
        productId: "stacio",
        targetType: "feedback",
        targetId: "fb_001",
        actionType: "feedback.update_status",
        status: "pending",
        analysis: expect.objectContaining({
          id: analysis?.id
        })
      })
    );
    expect(await store.listProposedActions("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: proposedAction?.id,
          status: "pending"
        })
      ])
    );
    expect(
      await store.reviewProposedAction("stacio", proposedAction?.id ?? "", {
        status: "accepted",
        reviewedBy: "usr_database_owner"
      })
    ).toEqual(
      expect.objectContaining({
        id: proposedAction?.id,
        status: "accepted",
        reviewedBy: "usr_database_owner"
      })
    );

    const template = await store.upsertNotificationTemplate("stacio", {
      type: "customer_feedback_reply",
      subjectTemplate: "{{productName}} reply",
      htmlTemplate: "<p>{{reply}}</p>"
    });
    expect(template).toEqual(
      expect.objectContaining({
        type: "customer_feedback_reply",
        status: "active"
      })
    );
    const notification = await store.createNotification("stacio", {
      type: "customer_feedback_reply",
      recipient: "user@example.com",
      payload: {
        productName: "Stacio",
        reply: "Thanks"
      }
    });
    expect(notification?.status).toBe("queued");
    const delivery = await store.createNotificationDelivery(notification?.id ?? "", {
      provider: "smtp",
      status: "dry_run",
      providerMessageId: "pg-dry-run"
    });
    expect(delivery).toEqual(
      expect.objectContaining({
        status: "dry_run"
      })
    );

    const licenseResult = await store.createLicense("stacio", {
      customerName: "Database License",
      customerEmail: "database-license@example.com",
      username: "Database License",
      plan: "pro",
      expiresAt: "2027-07-10T00:00:00.000Z"
    });
    expect(licenseResult?.licenseKey).toMatch(/^STACIO-/);
    expect(
      await store.validateLicense("stacio", {
        licenseKey: licenseResult?.licenseKey ?? "",
        email: "database-license@example.com",
        username: "Database License",
        anonymousDeviceId: "pg-device-1",
        appVersion: "0.15.0",
        buildNumber: "30"
      })
    ).toEqual(
      expect.objectContaining({
        valid: true,
        offlineGraceSeconds: 1_209_600
      })
    );
    const licenseDetail = await store.licenseDetail("stacio", licenseResult?.license.id ?? "");
    expect(licenseDetail).toEqual(
      expect.objectContaining({
        license: expect.objectContaining({
          id: licenseResult?.license.id,
          customerEmail: "database-license@example.com"
        }),
        customer: expect.objectContaining({
          email: "database-license@example.com"
        }),
        activations: expect.arrayContaining([
          expect.objectContaining({
            anonymousDeviceId: "pg-device-1"
          })
        ]),
        validationLogs: expect.arrayContaining([
          expect.objectContaining({
            result: "valid",
            appVersion: "0.15.0",
            buildNumber: "30"
          })
        ])
      })
    );
    expect(
      await store.updateLicense("stacio", licenseResult?.license.id ?? "", {
        status: "suspended",
        offlineGraceDays: 30
      })
    ).toEqual(
      expect.objectContaining({
        status: "suspended",
        offlineGraceDays: 30
      })
    );
    expect(await store.resetLicenseActivations("stacio", licenseResult?.license.id ?? "")).toEqual(
      expect.objectContaining({
        devices: 0
      })
    );

    const release = await store.createRelease("stacio", {
      channel: "beta",
      version: "0.14.1-Beta",
      buildNumber: "21",
      minimumSystemVersion: "14.0",
      artifactName: "Stacio-0.14.1-Beta.dmg",
      artifactUrl: "https://updates.example.com/Stacio-0.14.1-Beta.dmg",
      artifactType: "application/octet-stream",
      artifactSize: 1234,
      sparkleEdDsaSignature: "sig",
      releaseNotes: "PostgreSQL release",
      downloadReachabilityEvidence: {
        status: "reachable",
        checkedAt: "2026-07-10T10:00:00.000Z",
        statusCode: 200,
        contentLength: 1234,
        summary: "HEAD request returned 200 with expected content length."
      }
    });
    const validation = await store.validateRelease("stacio", release?.id ?? "");
    expect(validation).toEqual(
      expect.objectContaining({
        passed: true,
        release: expect.objectContaining({
          status: "ready"
        })
      })
    );
    expect(await store.listReleaseArtifacts("stacio", release?.id ?? "")).toEqual([
      expect.objectContaining({
        productId: "stacio",
        releaseId: release?.id,
        url: "https://updates.example.com/Stacio-0.14.1-Beta.dmg",
        fileName: "Stacio-0.14.1-Beta.dmg",
        contentType: "application/octet-stream",
        sizeBytes: 1234,
        createdAt: expect.any(String)
      })
    ]);
    expect(await store.publishRelease("stacio", release?.id ?? "", "usr_database_owner")).toEqual(
      expect.objectContaining({
        status: "published",
        publishedAt: expect.any(String)
      })
    );
    expect(await store.listReleaseChannels("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "beta",
          currentReleaseId: release?.id
        })
      ])
    );
    expect(await store.updateReleaseStatus("stacio", release?.id ?? "", "paused")).toEqual(
      expect.objectContaining({
        status: "paused"
      })
    );
    expect(await store.updateReleaseStatus("stacio", release?.id ?? "", "published")).toEqual(
      expect.objectContaining({
        status: "published"
      })
    );
    expect(await store.updateReleaseStatus("stacio", release?.id ?? "", "withdrawn")).toEqual(
      expect.objectContaining({
        status: "withdrawn"
      })
    );
    expect(await store.listAppcastEntries("stacio", "beta")).toEqual([
      expect.objectContaining({
        productId: "stacio",
        channelName: "beta",
        releaseId: release?.id,
        objectKey: "products/stacio/releases/beta/appcast.xml",
        xml: expect.stringContaining("PostgreSQL release"),
        publishedAt: expect.any(String)
      })
    ]);

    const createdPlan = await store.createPlan("stacio", {
      id: "plan_database_enterprise",
      name: "Database Enterprise",
      description: "PostgreSQL-backed plan",
      maxDevices: 100,
      maxSeats: 50,
      trialDays: 30,
      offlineGraceDays: 60,
      allowedChannels: ["stable", "beta"],
      supportedVersionRange: ">=0.13.0",
      entitlements: ["pro_features", "priority_support"]
    });
    expect(createdPlan).toEqual(
      expect.objectContaining({
        id: "plan_database_enterprise",
        entitlements: ["pro_features", "priority_support"]
      })
    );
    expect(
      await store.updatePlan("stacio", "plan_database_enterprise", {
        maxSeats: 75,
        allowedChannels: ["stable", "beta", "internal"],
        entitlements: ["pro_features", "priority_support", "sso"]
      })
    ).toEqual(
      expect.objectContaining({
        maxSeats: 75,
        allowedChannels: ["stable", "beta", "internal"],
        entitlements: ["pro_features", "priority_support", "sso"]
      })
    );

    const createdChannel = await store.createReleaseChannel("stacio", {
      name: "canary",
      appcastUrl: "https://updates.example.com/stacio/canary/appcast.xml",
      allowedPlanIds: ["plan_database_enterprise"],
      rolloutPercentage: 100
    });
    expect(createdChannel).toEqual(
      expect.objectContaining({
        name: "canary",
        rolloutPercentage: 100,
        status: "active"
      })
    );
    expect(
      await store.updateReleaseChannel("stacio", createdChannel?.id ?? "", {
        rolloutPercentage: 25,
        autoDownloadAllowed: true,
        status: "paused"
      })
    ).toEqual(
      expect.objectContaining({
        rolloutPercentage: 25,
        autoDownloadAllowed: true,
        status: "paused"
      })
    );

    const reloadedStore = createPostgresStore(database);
    expect(await reloadedStore.listPlans("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "plan_database_enterprise",
          maxSeats: 75,
          entitlements: ["pro_features", "priority_support", "sso"]
        })
      ])
    );
    expect(await reloadedStore.listReleaseChannels("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: createdChannel?.id,
          rolloutPercentage: 25,
          autoDownloadAllowed: true,
          status: "paused"
        })
      ])
    );
  });
});
