import { createPrivateKey, sign } from "node:crypto";

export interface OfflineLicensePayload {
  licenseId: string;
  productId: string;
  email: string;
  username: string;
  plan: string;
  entitlements: string[];
  expiresAt: string;
  offlineGraceSeconds: number;
  issuedAt: string;
}

function base64url(value: Buffer | string) {
  return Buffer.from(value).toString("base64url");
}

export function signOfflineLicenseToken(payload: OfflineLicensePayload) {
  const encodedPayload = base64url(JSON.stringify(payload));
  const configuredKey = process.env.LICENSE_PRIVATE_KEY_BASE64;

  if (!configuredKey) {
    if (process.env.NODE_ENV === "production") {
      throw new Error("LICENSE_PRIVATE_KEY_BASE64 is required in production");
    }
    return `dev.${encodedPayload}.unsigned`;
  }

  const decoded = Buffer.from(configuredKey, "base64");
  const keyMaterial = decoded.includes(Buffer.from("PRIVATE KEY")) ? decoded.toString("utf8") : decoded;
  const privateKey = createPrivateKey(keyMaterial);
  const signature = sign(null, Buffer.from(encodedPayload), privateKey);
  return `v1.${encodedPayload}.${base64url(signature)}`;
}
