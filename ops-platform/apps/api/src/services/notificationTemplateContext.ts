import type { OpsStore } from "../data/store.js";
import type { Product } from "../data/types.js";

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function stringValue(record: Record<string, unknown>, keys: string[], fallback?: string) {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number") return String(value);
  }
  return fallback;
}

export function templatePayloadForProduct(product: Product, payload: Record<string, unknown>) {
  const emailBrand = product.emailBrand ?? {};
  const brandContext = {
    productId: product.id,
    name: stringValue(emailBrand, ["name", "brandName"], product.name),
    senderName: stringValue(emailBrand, ["senderName", "fromName"], product.name),
    supportEmail: stringValue(emailBrand, ["supportEmail"], product.supportEmail),
    replyToEmail: stringValue(emailBrand, ["replyToEmail", "replyTo"], product.supportEmail),
    accentColor: stringValue(emailBrand, ["accentColor", "brandColor"], "#0070C0"),
    brandColor: stringValue(emailBrand, ["brandColor", "accentColor"], "#0070C0"),
    logoUrl: stringValue(emailBrand, ["logoUrl", "logo", "imageUrl"], product.iconUrl),
    supportUrl: stringValue(emailBrand, ["supportUrl", "supportURL"]),
    footerText: stringValue(emailBrand, ["footerText", "footer"]),
    legalText: stringValue(emailBrand, ["legalText", "legal"])
  };
  const productContext = {
    id: product.id,
    name: product.name,
    platform: product.platform,
    bundleId: product.bundleId,
    supportEmail: product.supportEmail,
    currentStableVersion: product.currentStableVersion,
    currentBetaVersion: product.currentBetaVersion
  };
  return {
    productName: product.name,
    ...payload,
    brand: {
      ...brandContext,
      ...asRecord(payload.brand)
    },
    product: {
      ...productContext,
      ...asRecord(payload.product)
    }
  };
}

export async function buildNotificationTemplatePayload(
  store: OpsStore,
  productId: string,
  payload: Record<string, unknown>
) {
  const product = await store.findProduct(productId);
  return product ? templatePayloadForProduct(product, payload) : payload;
}
