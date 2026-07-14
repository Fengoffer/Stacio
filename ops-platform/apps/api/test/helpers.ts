import type { FastifyInstance } from "fastify";
import { developmentOwnerCredentials } from "../src/auth/store.js";

export async function ownerAuthorization(server: FastifyInstance) {
  const response = await server.inject({
    method: "POST",
    url: "/api/v1/auth/login",
    payload: developmentOwnerCredentials
  });
  if (response.statusCode !== 200) {
    throw new Error(`Owner login failed: ${response.statusCode} ${response.body}`);
  }
  const body = response.json();
  return {
    authorization: `Bearer ${body.data.token}`
  };
}
