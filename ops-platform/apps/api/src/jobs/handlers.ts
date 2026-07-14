import { createHmac } from "node:crypto";
import type { OpsStore } from "../data/store.js";
import type { MailMessage, MailSendResult } from "../services/smtpMailer.js";
import type { fetchGitHubIssues } from "../services/githubClient.js";
import { decryptConnectorSecrets } from "../services/connectorSecrets.js";
import { buildNotificationTemplatePayload } from "../services/notificationTemplateContext.js";
import { renderTemplate } from "../services/templateRenderer.js";

export interface NotificationSendJobPayload {
  productId: string;
  notificationId: string;
  requestedBy?: string;
  dryRun?: boolean;
}

export interface GitHubPullJobPayload {
  productId: string;
  requestedBy?: string;
  options?: Parameters<typeof fetchGitHubIssues>[0];
}

export interface WebhookDispatchJobPayload {
  productId: string;
  eventType: string;
  eventId: string;
  payload: Record<string, unknown>;
  requestedBy?: string;
  occurredAt?: string;
}

export interface WebhookMessage {
  url: string;
  headers: Record<string, string>;
  body: string;
}

export interface WebhookSendResult {
  status: number;
  providerMessageId?: string;
}

export interface NotificationSendJobDependencies {
  store: OpsStore;
  sendMail: (message: MailMessage, options?: { dryRun?: boolean }) => Promise<MailSendResult>;
}

export interface GitHubPullJobDependencies {
  store: OpsStore;
  fetchIssues: typeof fetchGitHubIssues;
}

export interface WebhookDispatchJobDependencies {
  store: OpsStore;
  sendWebhook: (message: WebhookMessage) => Promise<WebhookSendResult>;
}

function stringArray(value: unknown) {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function webhookSubscribed(eventTypes: string[], eventType: string) {
  return eventTypes.length === 0 || eventTypes.includes("*") || eventTypes.includes(eventType);
}

export async function sendHttpWebhook(message: WebhookMessage): Promise<WebhookSendResult> {
  const response = await fetch(message.url, {
    method: "POST",
    headers: message.headers,
    body: message.body
  });
  return {
    status: response.status,
    providerMessageId: response.headers.get("x-request-id") ?? undefined
  };
}

export async function processNotificationSendJob(
  payload: NotificationSendJobPayload,
  dependencies: NotificationSendJobDependencies
) {
  const notification = (await dependencies.store.listNotifications(payload.productId)).find(
    (item) => item.id === payload.notificationId
  );
  if (!notification) {
    throw new Error("Notification not found");
  }
  const template = (await dependencies.store.listNotificationTemplates(payload.productId)).find(
    (item) => item.type === notification.type && item.status === "active"
  );
  if (!template) {
    throw new Error("Active notification template not found");
  }

  const deliveries = await dependencies.store.listNotificationDeliveries(notification.id);
  const templatePayload = await buildNotificationTemplatePayload(
    dependencies.store,
    payload.productId,
    notification.payload
  );
  const rendered = {
    subject: renderTemplate(template.subjectTemplate, templatePayload),
    html: renderTemplate(template.htmlTemplate, templatePayload),
    text: template.textTemplate ? renderTemplate(template.textTemplate, templatePayload) : undefined
  };
  const smtp = await dependencies.sendMail(
    {
      to: notification.recipient,
      ...rendered
    },
    { dryRun: payload.dryRun }
  );
  const delivery = await dependencies.store.createNotificationDelivery(notification.id, {
    provider: smtp.provider,
    attempt: deliveries.length + 1,
    status: smtp.status,
    providerMessageId: smtp.providerMessageId,
    sentAt: smtp.status === "sent" ? new Date().toISOString() : undefined
  });
  await dependencies.store.createAuditLog({
    actorType: "user",
    actorId: payload.requestedBy,
    action: smtp.status === "sent" ? "notification.sent" : "notification.dry_run",
    targetType: "notification",
    targetId: notification.id,
    productId: payload.productId,
    afterValue: {
      recipient: notification.recipient,
      type: notification.type,
      deliveryId: delivery?.id
    }
  });
  return {
    notification,
    delivery,
    rendered,
    smtp
  };
}

export async function processGitHubPullJob(payload: GitHubPullJobPayload, dependencies: GitHubPullJobDependencies) {
  try {
    const issues = await dependencies.fetchIssues(payload.options ?? {});
    const result = await dependencies.store.syncGitHubIssues(payload.productId, {
      trigger: "manual",
      issues
    });
    if (!result) {
      throw new Error("Product not found");
    }
    await dependencies.store.createAuditLog({
      actorType: "user",
      actorId: payload.requestedBy,
      action: "github.pull_sync",
      targetType: "github_sync_run",
      targetId: result.run.id,
      productId: payload.productId,
      afterValue: {
        fetchedCount: result.run.fetchedCount,
        changedCount: result.run.changedCount,
        feedbackCreatedCount: result.feedbackCreated.length,
        owner: payload.options?.owner ?? process.env.GITHUB_OWNER,
        repository: payload.options?.repository ?? process.env.GITHUB_REPOSITORY
      }
    });
    return result;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown GitHub sync error";
    const run = await dependencies.store.recordGitHubSyncFailure(payload.productId, {
      trigger: "manual",
      error: message
    });
    if (run) {
      await dependencies.store.createAuditLog({
        actorType: "user",
        actorId: payload.requestedBy,
        action: "github.pull_sync_failed",
        targetType: "github_sync_run",
        targetId: run.id,
        productId: payload.productId,
        afterValue: {
          error: message,
          owner: payload.options?.owner ?? process.env.GITHUB_OWNER,
          repository: payload.options?.repository ?? process.env.GITHUB_REPOSITORY
        }
      });
    }
    throw error;
  }
}

export async function processWebhookDispatchJob(
  payload: WebhookDispatchJobPayload,
  dependencies: WebhookDispatchJobDependencies
) {
  const connector = await dependencies.store.findConnector(payload.productId, "webhook");
  const url = stringValue(connector?.config.url);
  if (!connector || connector.status === "disabled" || !url) {
    throw new Error("Webhook connector is not configured");
  }

  const eventTypes = stringArray(connector.config.eventTypes);
  if (!webhookSubscribed(eventTypes, payload.eventType)) {
    await dependencies.store.createAuditLog({
      actorType: "user",
      actorId: payload.requestedBy,
      action: "webhook.skipped",
      targetType: "webhook_event",
      targetId: payload.eventId,
      productId: payload.productId,
      afterValue: {
        eventType: payload.eventType,
        reason: "event_not_subscribed"
      }
    });
    return {
      status: "skipped" as const,
      reason: "event_not_subscribed" as const
    };
  }

  const eventBody = {
    productId: payload.productId,
    eventType: payload.eventType,
    eventId: payload.eventId,
    occurredAt: payload.occurredAt ?? new Date().toISOString(),
    payload: payload.payload
  };
  const body = JSON.stringify(eventBody);
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "User-Agent": "stacio-ops-platform",
    "X-Stacio-Event": payload.eventType,
    "X-Stacio-Delivery": payload.eventId
  };

  try {
    const envelope = await dependencies.store.getConnectorSecretEnvelope(payload.productId, "webhook");
    const secrets = envelope ? decryptConnectorSecrets(envelope) : {};
    const signingSecret = stringValue(secrets.signingSecret);
    if (signingSecret) {
      const signingHeader = stringValue(connector.config.signingHeader) ?? "X-Stacio-Signature";
      headers[signingHeader] = `sha256=${createHmac("sha256", signingSecret).update(body).digest("hex")}`;
    }

    const result = await dependencies.sendWebhook({
      url,
      headers,
      body
    });
    if (result.status < 200 || result.status >= 300) {
      throw new Error(`Webhook endpoint returned ${result.status}`);
    }

    await dependencies.store.recordConnectorTest(payload.productId, "webhook", {
      succeeded: true,
      testedAt: new Date().toISOString()
    });
    await dependencies.store.createAuditLog({
      actorType: "user",
      actorId: payload.requestedBy,
      action: "webhook.dispatched",
      targetType: "webhook_event",
      targetId: payload.eventId,
      productId: payload.productId,
      afterValue: {
        eventType: payload.eventType,
        responseStatus: result.status,
        providerMessageId: result.providerMessageId,
        url
      }
    });

    return {
      status: "sent" as const,
      responseStatus: result.status,
      providerMessageId: result.providerMessageId
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Webhook dispatch failed";
    await dependencies.store.recordConnectorTest(payload.productId, "webhook", {
      succeeded: false,
      error: message,
      testedAt: new Date().toISOString()
    });
    await dependencies.store.createAuditLog({
      actorType: "user",
      actorId: payload.requestedBy,
      action: "webhook.dispatch_failed",
      targetType: "webhook_event",
      targetId: payload.eventId,
      productId: payload.productId,
      afterValue: {
        eventType: payload.eventType,
        error: message,
        url
      }
    });
    throw error;
  }
}
