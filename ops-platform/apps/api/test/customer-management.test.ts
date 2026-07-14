import { describe, expect, it } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("customer management", () => {
  it("creates, edits, annotates, and merges customer records with related history", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const sourceResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/customers",
      headers,
      payload: {
        email: "duplicate@example.com",
        name: "Duplicate Customer",
        company: "Example Labs",
        status: "active"
      }
    });
    expect(sourceResponse.statusCode).toBe(201);
    const sourceId = sourceResponse.json().data.id as string;

    const targetResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/customers",
      headers,
      payload: {
        email: "primary@example.com",
        name: "Primary Customer",
        company: "Example Labs",
        status: "active"
      }
    });
    expect(targetResponse.statusCode).toBe(201);
    const targetId = targetResponse.json().data.id as string;

    const duplicateEmail = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/customers",
      headers,
      payload: {
        email: "DUPLICATE@example.com",
        name: "Duplicate Again"
      }
    });
    expect(duplicateEmail.statusCode).toBe(409);

    const updated = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/customers/${sourceId}`,
      headers,
      payload: {
        name: "Duplicate Customer Updated",
        riskFlag: true,
        status: "blocked"
      }
    });
    expect(updated.statusCode).toBe(200);
    expect(updated.json().data).toEqual(
      expect.objectContaining({
        name: "Duplicate Customer Updated",
        riskFlag: true,
        status: "blocked"
      })
    );

    const note = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/customers/${sourceId}/notes`,
      headers,
      payload: {
        body: "Customer reported duplicate accounts after changing email."
      }
    });
    expect(note.statusCode).toBe(201);
    expect(note.json().data).toEqual(
      expect.objectContaining({
        customerId: sourceId,
        body: "Customer reported duplicate accounts after changing email."
      })
    );

    const license = await store.createLicense("stacio", {
      customerName: "Duplicate Customer Updated",
      customerEmail: "duplicate@example.com",
      username: "duplicate-user",
      plan: "pro",
      expiresAt: "2027-07-10T00:00:00.000Z"
    });
    const validation = await store.validateLicense("stacio", {
      licenseKey: license?.licenseKey ?? "",
      email: "duplicate@example.com",
      username: "duplicate-user",
      anonymousDeviceId: "device_customer_macbook",
      machineFingerprintHash: "sha256_customer_device",
      appVersion: "0.14.0",
      buildNumber: "140"
    });
    const feedback = await store.createFeedback("stacio", {
      title: "Duplicate account feedback",
      description: "Please merge my records.",
      type: "question",
      contactEmail: "duplicate@example.com"
    });
    const notification = await store.createNotification("stacio", {
      type: "customer_feedback_reply",
      recipient: "duplicate@example.com",
      payload: {
        reply: "We are reviewing your account."
      }
    });
    const notificationDelivery = await store.createNotificationDelivery(notification?.id ?? "", {
      provider: "smtp",
      attempt: 1,
      status: "failed",
      error: "Mailbox unavailable"
    });

    expect(license?.license.customerId).toBe(sourceId);
    expect(validation.valid).toBe(true);
    expect(feedback?.customerId).toBe(sourceId);
    expect(notification?.customerId).toBe(sourceId);

    const rejectedMerge = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/customers/${sourceId}/merge`,
      headers,
      payload: {
        targetCustomerId: targetId,
        confirmation: "wrong"
      }
    });
    expect(rejectedMerge.statusCode).toBe(409);

    const merged = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/customers/${sourceId}/merge`,
      headers,
      payload: {
        targetCustomerId: targetId,
        confirmation: "MERGE"
      }
    });
    expect(merged.statusCode).toBe(200);
    expect(merged.json().data).toEqual(
      expect.objectContaining({
        source: expect.objectContaining({
          id: sourceId,
          status: "merged",
          mergedIntoId: targetId
        }),
        target: expect.objectContaining({
          id: targetId,
          riskFlag: true
        })
      })
    );

    const detail = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/customers/${targetId}`,
      headers
    });
    expect(detail.statusCode).toBe(200);
    expect(detail.json().data).toEqual(
      expect.objectContaining({
        customer: expect.objectContaining({
          id: targetId,
          riskFlag: true
        }),
        licenses: expect.arrayContaining([
          expect.objectContaining({ id: license?.license.id, customerId: targetId })
        ]),
        activations: expect.arrayContaining([
          expect.objectContaining({
            licenseId: license?.license.id,
            anonymousDeviceId: "device_customer_macbook",
            machineFingerprintHash: "sha256_customer_device"
          })
        ]),
        activationCount: 1,
        feedback: expect.arrayContaining([
          expect.objectContaining({ id: feedback?.id, customerId: targetId })
        ]),
        notifications: expect.arrayContaining([
          expect.objectContaining({
            id: notification?.id,
            customerId: targetId,
            deliveries: expect.arrayContaining([
              expect.objectContaining({
                id: notificationDelivery?.id,
                provider: "smtp",
                attempt: 1,
                status: "failed",
                error: "Mailbox unavailable"
              })
            ])
          })
        ]),
        notes: expect.arrayContaining([
          expect.objectContaining({
            customerId: targetId,
            body: "Customer reported duplicate accounts after changing email."
          })
        ])
      })
    );

    const auditLogs = await store.listAuditLogs("stacio");
    expect(auditLogs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "customer.created", targetId: sourceId }),
        expect.objectContaining({ action: "customer.updated", targetId: sourceId }),
        expect.objectContaining({ action: "customer.note_added", targetId: sourceId }),
        expect.objectContaining({ action: "customer.merged", targetId: sourceId })
      ])
    );
  });
});
