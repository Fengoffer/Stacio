import { createHash, randomBytes } from "node:crypto";

function chunk(value: string) {
  return value.match(/.{1,4}/g)?.join("-") ?? value;
}

export function generateLicenseKey(productId: string) {
  const prefix = productId.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6) || "OPS";
  const body = randomBytes(12).toString("hex").toUpperCase();
  return `${prefix}-${chunk(body)}`;
}

export function licenseKeyPrefix(licenseKey: string) {
  return licenseKey.split("-").slice(0, 3).join("-");
}

export function hashLicenseKey(licenseKey: string) {
  return `sha256:${createHash("sha256").update(licenseKey.trim()).digest("hex")}`;
}
