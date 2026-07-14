import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export function generateAgentApiKey() {
  return `agent_${randomBytes(24).toString("hex")}`;
}

export function agentApiKeyPrefix(apiKey: string) {
  return apiKey.slice(0, 18);
}

export function hashAgentApiKey(apiKey: string) {
  return createHash("sha256").update(apiKey, "utf8").digest("hex");
}

export function verifyAgentApiKey(apiKey: string, expectedHash: string) {
  const expected = Buffer.from(expectedHash, "hex");
  const actual = Buffer.from(hashAgentApiKey(apiKey), "hex");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}
