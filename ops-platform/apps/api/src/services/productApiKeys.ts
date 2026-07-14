import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export function generateProductFeedbackApiKey() {
  return `pfk_${randomBytes(32).toString("base64url")}`;
}

export function hashProductFeedbackApiKey(apiKey: string) {
  return createHash("sha256").update(apiKey).digest("hex");
}

export function verifyProductFeedbackApiKey(apiKey: string, expectedHash: string) {
  const actual = Buffer.from(hashProductFeedbackApiKey(apiKey), "hex");
  const expected = Buffer.from(expectedHash, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
