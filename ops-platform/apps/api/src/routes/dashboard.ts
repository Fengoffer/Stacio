import type { FastifyInstance } from "fastify";
import type { OpsStore } from "../data/store.js";

export async function registerDashboardRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Params: { productId: string } }>(
    "/api/v1/products/:productId/dashboard",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const summary = await store.dashboard(request.params.productId);
      if (!summary) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      return {
        ok: true,
        data: summary
      };
    }
  );
}
