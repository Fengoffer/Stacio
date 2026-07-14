import { Worker } from "bullmq";
import type { OpsStore } from "../data/store.js";
import { createRuntimeStore } from "../db/runtime.js";
import { fetchGitHubIssues } from "../services/githubClient.js";
import { sendSmtpMail } from "../services/smtpMailer.js";
import { createReleasePublisher } from "../services/releasePublishers.js";
import { processReleasePublicationJob, type ReleasePublicationJobPayload } from "./releasePublication.js";
import {
  processGitHubPullJob,
  processNotificationSendJob,
  processWebhookDispatchJob,
  sendHttpWebhook,
  type GitHubPullJobPayload,
  type NotificationSendJobPayload,
  type WebhookDispatchJobPayload
} from "./handlers.js";
import { queueName } from "./queue.js";

interface QueueJobLike {
  name: string;
  data: unknown;
}

interface QueueJobProcessorDependencies {
  processNotification: (payload: NotificationSendJobPayload) => Promise<unknown>;
  processGitHubPull: (payload: GitHubPullJobPayload) => Promise<unknown>;
  processWebhookDispatch: (payload: WebhookDispatchJobPayload) => Promise<unknown>;
  processReleasePublication: (payload: ReleasePublicationJobPayload) => Promise<unknown>;
}

export async function processOpsQueueJob(job: QueueJobLike, dependencies: QueueJobProcessorDependencies) {
  if (job.name === "notification.send") {
    return dependencies.processNotification(job.data as NotificationSendJobPayload);
  }
  if (job.name === "github.pull") {
    return dependencies.processGitHubPull(job.data as GitHubPullJobPayload);
  }
  if (job.name === "webhook.dispatch") {
    return dependencies.processWebhookDispatch(job.data as WebhookDispatchJobPayload);
  }
  if (job.name === "release.publish") {
    return dependencies.processReleasePublication(job.data as ReleasePublicationJobPayload);
  }
  throw new Error(`Unsupported job: ${job.name}`);
}

export function createBullMqWorker(redisUrl: string, store: OpsStore) {
  const worker = new Worker(
    queueName,
    async (job) =>
      processOpsQueueJob(job, {
        processNotification: (payload) =>
          processNotificationSendJob(payload, {
            store,
            sendMail: sendSmtpMail
          }),
        processGitHubPull: (payload) =>
          processGitHubPullJob(payload, {
            store,
            fetchIssues: fetchGitHubIssues
          }),
        processWebhookDispatch: (payload) =>
          processWebhookDispatchJob(payload, {
            store,
            sendWebhook: sendHttpWebhook
          }),
        processReleasePublication: (payload) => processReleasePublicationJob(payload, createReleasePublisher(store))
      }),
    {
      connection: {
        url: redisUrl,
        maxRetriesPerRequest: null
      }
    }
  );

  worker.on("completed", (job) => {
    console.log(`Completed job ${job.name}:${job.id}`);
  });
  worker.on("failed", (job, error) => {
    console.error(`Failed job ${job?.name}:${job?.id}`, error);
  });

  return {
    async close() {
      await worker.close();
    }
  };
}

async function start() {
  if (!process.env.REDIS_URL) {
    throw new Error("REDIS_URL is required for the worker");
  }
  const runtime = await createRuntimeStore();
  const worker = createBullMqWorker(process.env.REDIS_URL, runtime.store);
  const shutdown = async () => {
    await worker.close();
    await runtime.close();
  };
  process.once("SIGINT", () => void shutdown().then(() => process.exit(0)));
  process.once("SIGTERM", () => void shutdown().then(() => process.exit(0)));
  console.log("Stacio Ops worker started");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  start().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
