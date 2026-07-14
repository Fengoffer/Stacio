import { createServer } from "node:http";
import { describe, expect, it, vi } from "vitest";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

function reachableDownloadEvidence(contentLength: number) {
  return {
    status: "reachable" as const,
    checkedAt: "2026-07-10T10:00:00.000Z",
    statusCode: 200,
    contentLength,
    summary: "HEAD request returned 200 with expected content length."
  };
}

function webhookJobQueue() {
  const enqueueNotificationSend = vi.fn(async (payload: unknown) => ({
    id: `job_notification_${String(enqueueNotificationSend.mock.calls.length)}`,
    name: "notification.send" as const,
    payload
  }));
  const enqueueWebhookDispatch = vi.fn(async (payload: unknown) => ({
    id: `job_webhook_${String(enqueueWebhookDispatch.mock.calls.length)}`,
    name: "webhook.dispatch" as const,
    payload
  }));
  const jobQueue: OpsJobQueue = {
    enqueueNotificationSend,
    async enqueueGitHubPull(payload) {
      return {
        id: "job_github_unused",
        name: "github.pull",
        payload
      };
    },
    enqueueWebhookDispatch
  };
  return { jobQueue, enqueueNotificationSend, enqueueWebhookDispatch };
}

describe("release and license management", () => {
  it("creates licenses, validates keys, and returns offline tokens", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses",
      headers,
      payload: {
        customerName: "Paid User",
        customerEmail: "paid@example.com",
        username: "Paid User",
        plan: "pro",
        seats: 1,
        maxDevices: 2,
        entitlements: ["pro_features", "beta_channel"],
        expiresAt: "2027-07-10T00:00:00.000Z"
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const created = createResponse.json().data;
    expect(created).toEqual(
      expect.objectContaining({
        licenseKey: expect.stringMatching(/^STACIO-/),
        revealPolicy: "one_time",
        license: expect.objectContaining({
          customerEmail: "paid@example.com",
          keyPrefix: expect.any(String)
        })
      })
    );

    const validateResponse = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/licenses/validate",
      payload: {
        licenseKey: created.licenseKey,
        email: "paid@example.com",
        username: "Paid User",
        appVersion: "0.13.2-Beta",
        buildNumber: "12",
        anonymousDeviceId: "device_paid"
      }
    });
    expect(validateResponse.statusCode).toBe(200);
    expect(validateResponse.json().data).toEqual(
      expect.objectContaining({
        valid: true,
        status: "active",
        plan: "pro",
        entitlements: ["pro_features", "beta_channel"],
        offlineGraceSeconds: 1_209_600,
        signedLicenseToken: expect.stringMatching(/^dev\./)
      })
    );

    const invalidResponse = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/licenses/validate",
      payload: {
        licenseKey: "WRONG-KEY",
        email: "paid@example.com",
        username: "Paid User"
      }
    });
    expect(invalidResponse.json().data).toEqual(
      expect.objectContaining({
        valid: false,
        reason: "not_found"
      })
    );

    const detailResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/licenses/${created.license.id}`,
      headers
    });
    expect(detailResponse.statusCode).toBe(200);
    expect(detailResponse.json().data).toEqual(
      expect.objectContaining({
        license: expect.objectContaining({
          id: created.license.id,
          customerEmail: "paid@example.com"
        }),
        customer: expect.objectContaining({
          email: "paid@example.com"
        }),
        activations: expect.arrayContaining([
          expect.objectContaining({
            anonymousDeviceId: "device_paid"
          })
        ]),
        validationLogs: expect.arrayContaining([
          expect.objectContaining({
            result: "valid",
            appVersion: "0.13.2-Beta",
            buildNumber: "12"
          }),
          expect.objectContaining({
            result: "invalid",
            reason: "not_found"
          })
        ]),
        auditLogs: expect.any(Array)
      })
    );
  });

  it("queues customer license issued email after manual confirmation", async () => {
    const { jobQueue, enqueueNotificationSend } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses",
      headers,
      payload: {
        customerName: "Paid User",
        customerEmail: "paid@example.com",
        username: "paid-user",
        plan: "pro",
        seats: 1,
        maxDevices: 2,
        entitlements: ["pro_features"],
        expiresAt: "2027-07-10T00:00:00.000Z"
      }
    });
    const created = createResponse.json().data;

    const withoutConfirmation = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/licenses/${created.license.id}/email`,
      headers,
      payload: {
        licenseKey: created.licenseKey
      }
    });
    expect(withoutConfirmation.statusCode).toBe(409);
    expect(withoutConfirmation.json().error.code).toBe("MANUAL_CONFIRMATION_REQUIRED");

    const sendResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/licenses/${created.license.id}/email`,
      headers,
      payload: {
        licenseKey: created.licenseKey,
        confirmation: "SEND"
      }
    });

    expect(sendResponse.statusCode).toBe(202);
    expect(sendResponse.json().data.notification).toEqual(
      expect.objectContaining({
        type: "customer_license_issued",
        recipient: "paid@example.com",
        priority: "normal",
        status: "queued",
        payload: expect.objectContaining({
          licenseId: created.license.id,
          customerName: "Paid User",
          email: "paid@example.com",
          username: "paid-user",
          plan: "pro",
          expiresAt: "2027-07-10T00:00:00.000Z",
          licenseKey: created.licenseKey
        })
      })
    );
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: sendResponse.json().data.notification.id,
      requestedBy: "usr_development_owner",
      dryRun: false
    });
  });

  it("queues admin license anomaly notifications for invalid public validation attempts", async () => {
    const { jobQueue, enqueueNotificationSend } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/licenses/validate",
      payload: {
        licenseKey: "WRONG-KEY",
        email: "paid@example.com",
        username: "Paid User"
      }
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        valid: false,
        reason: "not_found"
      })
    );

    const notificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(notificationsResponse.statusCode).toBe(200);
    expect(notificationsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "admin_license_anomaly",
          recipient: "support@stacio.dev",
          priority: "high",
          status: "queued",
          payload: expect.objectContaining({
            email: "paid@example.com",
            reason: "not_found",
            keyPrefix: "WRONG-KEY"
          })
        })
      ])
    );
    const anomalyNotification = notificationsResponse.json().data.find(
      (item: { type: string }) => item.type === "admin_license_anomaly"
    );
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: anomalyNotification.id,
      dryRun: false
    });

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "notification.queued",
          targetType: "notification",
          afterValue: expect.objectContaining({
            type: "admin_license_anomaly",
            recipient: "support@stacio.dev",
            reason: "not_found"
          })
        })
      ])
    );
  });

  it("batch generates identity-bound licenses with one-time keys and audit logs", async () => {
    const { jobQueue, enqueueNotificationSend } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses/batch",
      headers,
      payload: {
        recipients: [
          {
            customerName: "Team User One",
            customerEmail: "team-one@example.com",
            username: "team-one"
          },
          {
            customerName: "Team User Two",
            customerEmail: "team-two@example.com",
            username: "team-two"
          }
        ],
        plan: "team",
        seats: 1,
        maxDevices: 3,
        offlineGraceDays: 30,
        entitlements: ["team_features"],
        expiresAt: "2027-07-10T00:00:00.000Z"
      }
    });

    expect(response.statusCode).toBe(201);
    expect(response.json().data.items).toHaveLength(2);
    expect(response.json().data.items).toEqual([
      expect.objectContaining({
        licenseKey: expect.stringMatching(/^STACIO-/),
        revealPolicy: "one_time",
        license: expect.objectContaining({
          customerEmail: "team-one@example.com",
          plan: "team",
          maxDevices: 3,
          offlineGraceDays: 30,
          entitlements: ["team_features"]
        })
      }),
      expect.objectContaining({
        licenseKey: expect.stringMatching(/^STACIO-/),
        revealPolicy: "one_time",
        license: expect.objectContaining({
          customerEmail: "team-two@example.com",
          plan: "team"
        })
      })
    ]);
    const batchEmailWithoutConfirmation = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses/batch-email",
      headers,
      payload: {
        items: response.json().data.items.map((item: { license: { id: string }; licenseKey: string }) => ({
          licenseId: item.license.id,
          licenseKey: item.licenseKey
        }))
      }
    });
    expect(batchEmailWithoutConfirmation.statusCode).toBe(409);
    expect(batchEmailWithoutConfirmation.json().error.code).toBe("MANUAL_CONFIRMATION_REQUIRED");

    const batchEmailResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses/batch-email",
      headers,
      payload: {
        confirmation: "SEND",
        items: response.json().data.items.map((item: { license: { id: string }; licenseKey: string }) => ({
          licenseId: item.license.id,
          licenseKey: item.licenseKey
        }))
      }
    });
    expect(batchEmailResponse.statusCode).toBe(202);
    expect(batchEmailResponse.json().data).toEqual(
      expect.objectContaining({
        requestedCount: 2,
        queuedCount: 2,
        skippedCount: 0,
        queued: [
          expect.objectContaining({
            licenseId: response.json().data.items[0].license.id,
            recipient: "team-one@example.com",
            notification: expect.objectContaining({
              type: "customer_license_issued",
              recipient: "team-one@example.com",
              payload: expect.objectContaining({
                licenseKey: response.json().data.items[0].licenseKey,
                username: "team-one"
              })
            }),
            job: expect.objectContaining({
              name: "notification.send"
            })
          }),
          expect.objectContaining({
            licenseId: response.json().data.items[1].license.id,
            recipient: "team-two@example.com",
            notification: expect.objectContaining({
              type: "customer_license_issued",
              recipient: "team-two@example.com",
              payload: expect.objectContaining({
                licenseKey: response.json().data.items[1].licenseKey,
                username: "team-two"
              })
            })
          })
        ],
        skipped: []
      })
    );
    expect(enqueueNotificationSend).toHaveBeenCalledTimes(2);
    expect(enqueueNotificationSend).toHaveBeenNthCalledWith(1, {
      productId: "stacio",
      notificationId: batchEmailResponse.json().data.queued[0].notification.id,
      requestedBy: "usr_development_owner",
      dryRun: false
    });

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "license.batch_created",
          targetType: "license_batch",
          productId: "stacio",
          afterValue: expect.objectContaining({
            count: 2,
            plan: "team"
          })
        })
      ])
    );
  });

  it("manages license lifecycle actions with confirmation and audit logs", async () => {
    const { jobQueue, enqueueNotificationSend, enqueueWebhookDispatch } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const updateResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/licenses/lic_002",
      headers,
      payload: {
        plan: "team",
        seats: 5,
        maxDevices: 10,
        offlineGraceDays: 30,
        expiresAt: "2027-08-09T00:00:00.000Z"
      }
    });
    expect(updateResponse.statusCode).toBe(200);
    expect(updateResponse.json().data).toEqual(
      expect.objectContaining({
        id: "lic_002",
        plan: "team",
        seats: 5,
        maxDevices: 10,
        offlineGraceDays: 30,
        expiresAt: "2027-08-09T00:00:00.000Z"
      })
    );

    const resetWithoutConfirmation = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses/lic_001/reset-activations",
      headers
    });
    expect(resetWithoutConfirmation.statusCode).toBe(422);
    expect(resetWithoutConfirmation.json().error.code).toBe("LICENSE_CONFIRMATION_REQUIRED");

    const resetResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/licenses/lic_001/reset-activations",
      headers,
      payload: {
        confirmation: "RESET"
      }
    });
    expect(resetResponse.statusCode).toBe(200);
    expect(resetResponse.json().data).toEqual(
      expect.objectContaining({
        id: "lic_001",
        devices: 0
      })
    );

    const suspendResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/licenses/lic_002",
      headers,
      payload: {
        status: "suspended",
        confirmation: "SUSPEND"
      }
    });
    expect(suspendResponse.statusCode).toBe(200);
    expect(suspendResponse.json().data).toEqual(expect.objectContaining({ status: "suspended" }));

    const revokeWithoutConfirmation = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/licenses/lic_001",
      headers,
      payload: {
        status: "revoked"
      }
    });
    expect(revokeWithoutConfirmation.statusCode).toBe(422);
    expect(revokeWithoutConfirmation.json().error.code).toBe("LICENSE_CONFIRMATION_REQUIRED");

    const revokeResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/licenses/lic_001",
      headers,
      payload: {
        status: "revoked",
        confirmation: "REVOKE"
      }
    });
    expect(revokeResponse.statusCode).toBe(200);
    expect(revokeResponse.json().data).toEqual(expect.objectContaining({ status: "revoked" }));
    expect(enqueueWebhookDispatch).toHaveBeenCalledTimes(2);
    expect(enqueueWebhookDispatch).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        productId: "stacio",
        eventType: "license.suspended",
        eventId: "lic_002",
        payload: {
          license: expect.objectContaining({
            id: "lic_002",
            status: "suspended",
            customerEmail: "pro@example.com"
          })
        }
      })
    );
    expect(enqueueWebhookDispatch).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        productId: "stacio",
        eventType: "license.revoked",
        eventId: "lic_001",
        payload: {
          license: expect.objectContaining({
            id: "lic_001",
            status: "revoked",
            customerEmail: "tester@example.com"
          })
        }
      })
    );

    const lifecycleNotificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(lifecycleNotificationsResponse.statusCode).toBe(200);
    expect(lifecycleNotificationsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "customer_license_suspended",
          recipient: "pro@example.com",
          priority: "normal",
          status: "queued",
          payload: expect.objectContaining({
            licenseId: "lic_002",
            customerName: "Pro User",
            email: "pro@example.com",
            plan: "team",
            status: "suspended"
          })
        }),
        expect.objectContaining({
          type: "customer_license_revoked",
          recipient: "tester@example.com",
          priority: "high",
          status: "queued",
          payload: expect.objectContaining({
            licenseId: "lic_001",
            customerName: "Internal Tester",
            email: "tester@example.com",
            plan: "internal",
            status: "revoked"
          })
        })
      ])
    );
    const lifecycleNotifications = lifecycleNotificationsResponse.json().data;
    const suspendedNotification = lifecycleNotifications.find(
      (item: { type: string }) => item.type === "customer_license_suspended"
    );
    const revokedNotification = lifecycleNotifications.find(
      (item: { type: string }) => item.type === "customer_license_revoked"
    );
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: suspendedNotification.id,
      dryRun: false
    });
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: revokedNotification.id,
      dryRun: false
    });

    const validateRevoked = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/licenses/validate",
      payload: {
        licenseKey: "STACIO-INT-SEED-KEY",
        email: "tester@example.com",
        username: "Internal Tester"
      }
    });
    expect(validateRevoked.json().data).toEqual(
      expect.objectContaining({
        valid: false,
        reason: "revoked"
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "license.updated", targetId: "lic_002" }),
        expect.objectContaining({ action: "license.activations_reset", targetId: "lic_001" }),
        expect.objectContaining({ action: "license.suspended", targetId: "lic_002" }),
        expect.objectContaining({ action: "license.revoked", targetId: "lic_001" })
      ])
    );
  });

  it("requires manual confirmation for OTA publish and serves appcast XML", async () => {
    const { jobQueue, enqueueNotificationSend, enqueueWebhookDispatch } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.0-Beta",
        buildNumber: "20",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.0-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.0-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "New beta release.",
        downloadReachabilityEvidence: reachableDownloadEvidence(12345678)
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;
    expect(createResponse.json().data).toEqual(
      expect.objectContaining({
        createdBy: "usr_development_owner"
      })
    );

    const publishWithoutConfirmation = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/publish`,
      headers,
      payload: {}
    });
    expect(publishWithoutConfirmation.statusCode).toBe(422);
    expect(publishWithoutConfirmation.json().error.code).toBe("MANUAL_CONFIRMATION_REQUIRED");

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });
    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: true,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "appcast_xml",
            passed: true
          })
        ]),
        release: expect.objectContaining({
          status: "ready",
          preflightEvidence: expect.objectContaining({
            appcastPreviewXml: expect.stringContaining("Stacio 0.14.0-Beta")
          })
        })
      })
    );

    const diffResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${releaseId}/appcast-diff`,
      headers
    });
    expect(diffResponse.statusCode).toBe(200);
    expect(diffResponse.json().data).toEqual(
      expect.objectContaining({
        releaseId,
        channel: "beta",
        addedItem: expect.objectContaining({
          version: "0.14.0-Beta",
          buildNumber: "20"
        }),
        currentItemCount: expect.any(Number),
        previewItemCount: expect.any(Number),
        currentXml: expect.not.stringContaining("Stacio 0.14.0-Beta"),
        previewXml: expect.stringContaining("Stacio 0.14.0-Beta")
      })
    );

    const publishResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/publish`,
      headers,
      payload: {
        confirmation: "PUBLISH"
      }
    });
    expect(publishResponse.statusCode).toBe(200);
    expect(publishResponse.json().data).toEqual(
      expect.objectContaining({
        status: "published",
        createdBy: "usr_development_owner",
        publishedBy: "usr_development_owner",
        publishedAt: expect.any(String)
      })
    );
    expect(enqueueWebhookDispatch).toHaveBeenCalledWith(
      expect.objectContaining({
        productId: "stacio",
        eventType: "release.published",
        eventId: releaseId,
        requestedBy: "usr_development_owner",
        payload: {
          release: expect.objectContaining({
            id: releaseId,
            status: "published",
            channel: "beta",
            version: "0.14.0-Beta",
            buildNumber: "20"
          })
        }
      })
    );

    const channelsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/channels",
      headers
    });
    expect(channelsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "beta",
          currentReleaseId: releaseId
        })
      ])
    );

    const appcastResponse = await server.inject({
      method: "GET",
      url: "/updates/stacio/beta/appcast.xml"
    });
    expect(appcastResponse.statusCode).toBe(200);
    expect(appcastResponse.body).toContain("Stacio 0.14.0-Beta");
    expect(appcastResponse.body).toContain("sparkle:edSignature=\"sparkle-signature\"");

    const appcastEntriesResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/appcast-entries?channel=beta",
      headers
    });
    expect(appcastEntriesResponse.statusCode).toBe(200);
    expect(appcastEntriesResponse.json().data).toEqual([
      expect.objectContaining({
        productId: "stacio",
        channelName: "beta",
        releaseId,
        objectKey: "products/stacio/releases/beta/appcast.xml",
        xml: expect.stringContaining("Stacio 0.14.0-Beta"),
        publishedAt: expect.any(String)
      })
    ]);

    const publishNotificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(publishNotificationsResponse.statusCode).toBe(200);
    expect(publishNotificationsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "admin_ota_publish_success",
          recipient: "support@stacio.dev",
          priority: "high",
          status: "queued",
          payload: expect.objectContaining({
            releaseId,
            version: "0.14.0-Beta",
            channel: "beta",
            buildNumber: "20",
            publishedBy: "usr_development_owner"
          })
        })
      ])
    );
    const publishNotification = publishNotificationsResponse.json().data.find(
      (item: { type: string }) => item.type === "admin_ota_publish_success"
    );
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: publishNotification.id,
      dryRun: false
    });

    const pauseWithoutConfirmation = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/lifecycle`,
      headers,
      payload: {
        action: "pause"
      }
    });
    expect(pauseWithoutConfirmation.statusCode).toBe(422);
    expect(pauseWithoutConfirmation.json().error.code).toBe("RELEASE_CONFIRMATION_REQUIRED");

    const pauseResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/lifecycle`,
      headers,
      payload: {
        action: "pause",
        confirmation: "PAUSE"
      }
    });
    expect(pauseResponse.statusCode).toBe(200);
    expect(pauseResponse.json().data).toEqual(expect.objectContaining({ status: "paused" }));
    const pausedAppcastResponse = await server.inject({
      method: "GET",
      url: "/updates/stacio/beta/appcast.xml"
    });
    expect(pausedAppcastResponse.body).not.toContain("Stacio 0.14.0-Beta");

    const resumeResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/lifecycle`,
      headers,
      payload: {
        action: "resume",
        confirmation: "RESUME"
      }
    });
    expect(resumeResponse.json().data).toEqual(expect.objectContaining({ status: "published" }));

    const withdrawResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/lifecycle`,
      headers,
      payload: {
        action: "withdraw",
        confirmation: "WITHDRAW"
      }
    });
    expect(withdrawResponse.json().data).toEqual(expect.objectContaining({ status: "withdrawn" }));
  });

  it("edits release drafts and invalidates previous preflight evidence", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.2-Beta",
        buildNumber: "22",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.2-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.2-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "old-signature",
        releaseNotes: "Initial notes.",
        downloadReachabilityEvidence: reachableDownloadEvidence(12345678)
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });
    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data.release.status).toBe("ready");

    const editResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/releases/${releaseId}/draft`,
      headers,
      payload: {
        artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg",
        artifactSize: 22334455,
        sparkleEdDsaSignature: "new-signature",
        releaseNotes: "Edited release notes.",
        aiReleaseSummary: "Agent summary for the edited draft.",
        aiRiskSummary: "Risk summary after artifact replacement."
      }
    });

    expect(editResponse.statusCode).toBe(200);
    expect(editResponse.json().data).toEqual(
      expect.objectContaining({
        id: releaseId,
        status: "draft",
        artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg",
        artifactSize: 22334455,
        sparkleEdDsaSignature: "new-signature",
        releaseNotes: "Edited release notes.",
        aiReleaseSummary: "Agent summary for the edited draft.",
        aiRiskSummary: "Risk summary after artifact replacement.",
        preflightEvidence: {}
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "release.draft_updated",
          targetId: releaseId,
          afterValue: expect.objectContaining({
            status: "draft",
            artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg"
          })
        })
      ])
    );
  });

  it("rejects release draft edits after publication", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.3-Beta",
        buildNumber: "23",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.3-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.3-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Publishable notes.",
        downloadReachabilityEvidence: reachableDownloadEvidence(12345678)
      }
    });
    const releaseId = createResponse.json().data.id;

    await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });
    await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/publish`,
      headers,
      payload: {
        confirmation: "PUBLISH"
      }
    });

    const editPublishedResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/releases/${releaseId}/draft`,
      headers,
      payload: {
        releaseNotes: "This must not mutate a published release."
      }
    });

    expect(editPublishedResponse.statusCode).toBe(409);
    expect(editPublishedResponse.json().error.code).toBe("RELEASE_LOCKED");
  });

  it("records release artifact registrations for audit and object storage traceability", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.7-Beta",
        buildNumber: "27",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.7-Beta.dmg",
        artifactUrl: "https://objects.example.com/Stacio-0.14.7-Beta.dmg",
        artifactObjectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta.dmg",
        artifactType: "application/x-apple-diskimage",
        artifactSize: 4096,
        artifactSha256: "a".repeat(64),
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Artifact audit release.",
        downloadReachabilityEvidence: reachableDownloadEvidence(4096)
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const firstArtifactsResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${releaseId}/artifacts`,
      headers
    });
    expect(firstArtifactsResponse.statusCode).toBe(200);
    expect(firstArtifactsResponse.json().data).toEqual([
      expect.objectContaining({
        productId: "stacio",
        releaseId,
        objectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta.dmg",
        url: "https://objects.example.com/Stacio-0.14.7-Beta.dmg",
        fileName: "Stacio-0.14.7-Beta.dmg",
        contentType: "application/x-apple-diskimage",
        sizeBytes: 4096,
        sha256: "a".repeat(64),
        signatureEvidence: expect.any(Object),
        createdAt: expect.any(String)
      })
    ]);

    const editResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/releases/${releaseId}/draft`,
      headers,
      payload: {
        artifactName: "Stacio-0.14.7-Beta-r2.dmg",
        artifactUrl: "https://objects.example.com/Stacio-0.14.7-Beta-r2.dmg",
        artifactObjectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta-r2.dmg",
        artifactType: "application/x-apple-diskimage",
        artifactSize: 8192,
        artifactSha256: "b".repeat(64),
        downloadReachabilityEvidence: reachableDownloadEvidence(8192)
      }
    });
    expect(editResponse.statusCode).toBe(200);

    const artifactHistoryResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${releaseId}/artifacts`,
      headers
    });
    expect(artifactHistoryResponse.statusCode).toBe(200);
    expect(artifactHistoryResponse.json().data).toEqual([
      expect.objectContaining({
        objectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta-r2.dmg",
        sizeBytes: 8192,
        sha256: "b".repeat(64)
      }),
      expect.objectContaining({
        objectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta.dmg",
        sizeBytes: 4096,
        sha256: "a".repeat(64)
      })
    ]);
  });

  it("fails OTA preflight when the build number does not advance the channel", async () => {
    const { jobQueue, enqueueNotificationSend } = webhookJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.13.3-Beta",
        buildNumber: "11",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.13.3-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.13.3-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "New beta release."
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });

    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: false,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "build_number_gt_previous",
            passed: false
          })
        ]),
        release: expect.objectContaining({
          status: "failed"
        })
      })
    );

    const failureNotificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(failureNotificationsResponse.statusCode).toBe(200);
    expect(failureNotificationsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "admin_ota_publish_failure",
          recipient: "support@stacio.dev",
          priority: "high",
          status: "queued",
          payload: expect.objectContaining({
            releaseId,
            version: "0.13.3-Beta",
            channel: "beta",
            error: "Release preflight failed",
            failedChecks: expect.arrayContaining([
              expect.objectContaining({
                key: "build_number_gt_previous",
                passed: false
              })
            ])
          })
        })
      ])
    );
    const failureNotification = failureNotificationsResponse.json().data.find(
      (item: { type: string }) => item.type === "admin_ota_publish_failure"
    );
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: failureNotification.id,
      dryRun: false
    });
  });

  it("attaches package signature verification evidence to OTA preflight", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.4-Beta",
        buildNumber: "24",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.4-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.4-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Package signature evidence release.",
        packageSignatureEvidence: {
          status: "passed",
          tool: "codesign",
          checkedAt: "2026-07-10T10:00:00.000Z",
          summary: "Developer ID Application signature verified."
        },
        downloadReachabilityEvidence: reachableDownloadEvidence(12345678)
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });

    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: true,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "package_signature_verification",
            passed: true
          })
        ]),
        release: expect.objectContaining({
          preflightEvidence: expect.objectContaining({
            packageSignatureEvidence: expect.objectContaining({
              status: "passed",
              tool: "codesign",
              summary: "Developer ID Application signature verified."
            })
          })
        })
      })
    );
  });

  it("attaches download reachability evidence to OTA preflight", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.5-Beta",
        buildNumber: "25",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.5-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.5-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Download reachability evidence release.",
        downloadReachabilityEvidence: {
          status: "reachable",
          checkedAt: "2026-07-10T10:05:00.000Z",
          statusCode: 200,
          contentLength: 12345678,
          summary: "HEAD request returned 200 with expected content length."
        }
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });

    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: true,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "download_url_reachable",
            passed: true
          })
        ]),
        release: expect.objectContaining({
          preflightEvidence: expect.objectContaining({
            downloadReachabilityEvidence: expect.objectContaining({
              status: "reachable",
              statusCode: 200,
              contentLength: 12345678
            })
          })
        })
      })
    );
  });

  it("requires download reachability evidence before OTA preflight can pass", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.5-Beta",
        buildNumber: "25",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.5-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.5-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Release without download evidence."
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });

    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: false,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "download_url_reachable",
            passed: false
          }),
          expect.objectContaining({
            key: "artifact_size_matches",
            passed: false
          })
        ]),
        release: expect.objectContaining({
          status: "failed"
        })
      })
    );
  });

  it("fails OTA preflight when download evidence content length differs from artifact size", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.14.6-Beta",
        buildNumber: "26",
        minimumSystemVersion: "14.0",
        artifactName: "Stacio-0.14.6-Beta.dmg",
        artifactUrl: "https://updates.example.com/Stacio-0.14.6-Beta.dmg",
        artifactType: "application/octet-stream",
        artifactSize: 12345678,
        sparkleEdDsaSignature: "sparkle-signature",
        releaseNotes: "Size mismatch release.",
        downloadReachabilityEvidence: {
          status: "reachable",
          checkedAt: "2026-07-10T10:10:00.000Z",
          statusCode: 200,
          contentLength: 87654321,
          summary: "HEAD request returned 200 but with a different content length."
        }
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const releaseId = createResponse.json().data.id;

    const validationResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/validate`,
      headers
    });

    expect(validationResponse.statusCode).toBe(200);
    expect(validationResponse.json().data).toEqual(
      expect.objectContaining({
        passed: false,
        checks: expect.arrayContaining([
          expect.objectContaining({
            key: "artifact_size_matches",
            passed: false
          })
        ]),
        release: expect.objectContaining({
          status: "failed"
        })
      })
    );
  });

  it("actively probes an artifact download URL and stores reachability evidence", async () => {
    const artifactSize = 2048;
    const probeServer = createServer((request, response) => {
      response.statusCode = 200;
      response.setHeader("Content-Length", String(artifactSize));
      response.end(request.method === "HEAD" ? undefined : "ok");
    });

    await new Promise<void>((resolve) => {
      probeServer.listen(0, "127.0.0.1", resolve);
    });

    try {
      const address = probeServer.address();
      const port = typeof address === "object" && address ? address.port : 0;
      const server = buildServer();
      const headers = await ownerAuthorization(server);

      const createResponse = await server.inject({
        method: "POST",
        url: "/api/v1/products/stacio/releases",
        headers,
        payload: {
          channel: "internal",
          version: "0.14.6-Internal",
          buildNumber: "26",
          minimumSystemVersion: "14.0",
          artifactName: "Stacio-0.14.6-Internal.dmg",
          artifactUrl: `http://127.0.0.1:${port}/Stacio-0.14.6-Internal.dmg`,
          artifactType: "application/octet-stream",
          artifactSize: artifactSize,
          sparkleEdDsaSignature: "sparkle-signature",
          releaseNotes: "Active reachability probe release."
        }
      });
      expect(createResponse.statusCode).toBe(201);
      const releaseId = createResponse.json().data.id;

      const probeResponse = await server.inject({
        method: "POST",
        url: `/api/v1/products/stacio/releases/${releaseId}/check-download`,
        headers
      });

      expect(probeResponse.statusCode).toBe(200);
      expect(probeResponse.json().data).toEqual(
        expect.objectContaining({
          release: expect.objectContaining({
            id: releaseId,
            preflightEvidence: expect.objectContaining({
              downloadReachabilityEvidence: expect.objectContaining({
                status: "reachable",
                statusCode: 200,
                contentLength: artifactSize,
                summary: "Download URL responded to HEAD"
              })
            })
          })
        })
      );
    } finally {
      await new Promise<void>((resolve, reject) => {
        probeServer.close((error) => {
          if (error) {
            reject(error);
          } else {
            resolve();
          }
        });
      });
    }
  });
});
