import { Queue } from "bullmq";
import type { GitHubPullJobPayload, NotificationSendJobPayload, WebhookDispatchJobPayload } from "./handlers.js";
import type { ReleasePublicationJobPayload } from "./releasePublication.js";

export interface EnqueuedJob {
  id?: string;
  name: "notification.send" | "github.pull" | "webhook.dispatch" | "release.publish";
  payload: NotificationSendJobPayload | GitHubPullJobPayload | WebhookDispatchJobPayload | ReleasePublicationJobPayload;
  delayMs?: number;
  scheduledFor?: string;
}

export interface EnqueueNotificationOptions {
  delayMs?: number;
  scheduledFor?: string;
}

export interface OpsJobQueue {
  enqueueNotificationSend(payload: NotificationSendJobPayload, options?: EnqueueNotificationOptions): Promise<EnqueuedJob>;
  enqueueGitHubPull(payload: GitHubPullJobPayload): Promise<EnqueuedJob>;
  enqueueWebhookDispatch?(payload: WebhookDispatchJobPayload): Promise<EnqueuedJob>;
  enqueueReleasePublication?(payload: ReleasePublicationJobPayload): Promise<EnqueuedJob>;
  close?(): Promise<void>;
}

const queueName = "stacio-ops-jobs";

export function createBullMqJobQueue(redisUrl: string): OpsJobQueue {
  const queue = new Queue(queueName, {
    connection: {
      url: redisUrl,
      maxRetriesPerRequest: null
    }
  });

  return {
    async enqueueNotificationSend(payload, options) {
      const job = await queue.add("notification.send", payload, {
        attempts: 3,
        backoff: { type: "exponential", delay: 10_000 },
        delay: options?.delayMs,
        removeOnComplete: 500,
        removeOnFail: 1000
      });
      return {
        id: job.id,
        name: "notification.send",
        payload,
        delayMs: options?.delayMs,
        scheduledFor: options?.scheduledFor
      };
    },

    async enqueueGitHubPull(payload) {
      const job = await queue.add("github.pull", payload, {
        attempts: 3,
        backoff: { type: "exponential", delay: 10_000 },
        removeOnComplete: 500,
        removeOnFail: 1000
      });
      return {
        id: job.id,
        name: "github.pull",
        payload
      };
    },

    async enqueueWebhookDispatch(payload) {
      const job = await queue.add("webhook.dispatch", payload, {
        attempts: 3,
        backoff: { type: "exponential", delay: 10_000 },
        removeOnComplete: 500,
        removeOnFail: 1000
      });
      return {
        id: job.id,
        name: "webhook.dispatch",
        payload
      };
    },

    async enqueueReleasePublication(payload) {
      const job = await queue.add("release.publish", payload, {
        attempts: 3,
        backoff: { type: "exponential", delay: 15_000 },
        removeOnComplete: 500,
        removeOnFail: 1000
      });
      return {
        id: job.id,
        name: "release.publish",
        payload
      };
    },

    async close() {
      await queue.close();
    }
  };
}

export { queueName };
