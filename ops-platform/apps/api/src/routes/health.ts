import type { FastifyInstance } from "fastify";

export async function registerHealthRoutes(server: FastifyInstance) {
  server.get("/api/v1/health", async () => ({
    ok: true,
    data: {
      service: "stacio-ops-api",
      status: "ok"
    }
  }));
}
