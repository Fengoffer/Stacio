import type { FastifyInstance } from "fastify";
import type { OpsStore } from "../data/store.js";
import {
  fetchGitHubReleaseDownloadMetrics,
  resolveGitHubReleaseSettings
} from "../services/releasePublishers.js";

export async function registerGitHubMetricsRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Params: { productId: string } }>(
    "/api/v1/products/:productId/github/download-metrics",
    { preHandler: server.authorize("releases:read") },
    async (request, reply) => {
      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Product not found" }
        });
      }
      try {
        return {
          ok: true,
          data: await fetchGitHubReleaseDownloadMetrics(
            await resolveGitHubReleaseSettings(store, product)
          )
        };
      } catch (error) {
        return reply.code(503).send({
          ok: false,
          error: {
            code: "GITHUB_METRICS_UNAVAILABLE",
            message: error instanceof Error ? error.message : "GitHub metrics are unavailable"
          }
        });
      }
    }
  );
}
