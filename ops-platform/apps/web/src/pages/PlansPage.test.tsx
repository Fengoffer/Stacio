// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient, type PlanRecord } from "../api/client";
import { PlansPage } from "./PlansPage";

const product = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  iconUrl: "",
  description: "",
  currentStableVersion: "",
  currentBetaVersion: "",
  supportEmail: "support@example.com",
  githubOwner: "",
  githubRepository: "",
  updateBaseUrl: "",
  appcastBaseUrl: "",
  licensePolicy: {},
  dataRetentionPolicy: {},
  emailBrand: {},
  objectStoragePrefix: "products/stacio",
  status: "active" as const,
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const proPlan: PlanRecord = {
  id: "plan_pro",
  productId: "stacio",
  name: "Pro",
  description: "Professional plan",
  maxDevices: 2,
  maxSeats: 1,
  trialDays: 14,
  offlineGraceDays: 14,
  allowedChannels: ["stable", "beta"],
  supportedVersionRange: ">=0.13.0",
  paymentProvider: "stripe",
  providerPlanId: "price_pro_monthly",
  priceMinor: 1200,
  currency: "USD",
  billingInterval: "month",
  couponSupport: true,
  subscriptionSupport: true,
  entitlements: ["pro_features", "beta_channel"],
  status: "active",
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

describe("PlansPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue([product]);
    vi.spyOn(opsClient, "plans").mockResolvedValue([proPlan]);
    vi.spyOn(opsClient, "createPlan").mockImplementation(async (_productId, input) => ({
      ...input,
      productId: "stacio",
      entitlements: input.entitlements ?? [],
      status: input.status ?? "active",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    }));
    vi.spyOn(opsClient, "updatePlan").mockResolvedValue({
      ...proPlan,
      maxSeats: 2
    });
    vi.spyOn(opsClient, "archivePlan").mockResolvedValue({
      ...proPlan,
      status: "archived"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates, edits, and archives product plans", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("ARCHIVE");
    render(<PlansPage />);

    expect(await screen.findByText("Pro")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "新建套餐" }));
    fireEvent.change(screen.getByLabelText("套餐 ID"), {
      target: { value: "plan_enterprise" }
    });
    fireEvent.change(screen.getByLabelText("套餐名称"), {
      target: { value: "Enterprise" }
    });
    fireEvent.change(screen.getByLabelText("最大设备数"), {
      target: { value: "100" }
    });
    fireEvent.change(screen.getByLabelText("最大席位"), {
      target: { value: "50" }
    });
    fireEvent.change(screen.getByLabelText("试用天数"), {
      target: { value: "30" }
    });
    fireEvent.change(screen.getByLabelText("离线宽限天数"), {
      target: { value: "60" }
    });
    fireEvent.change(screen.getByLabelText("可用渠道"), {
      target: { value: "stable, beta" }
    });
    fireEvent.change(screen.getByLabelText("Entitlements"), {
      target: { value: "pro_features, priority_support" }
    });
    fireEvent.change(screen.getByLabelText("支付提供方"), {
      target: { value: "stripe" }
    });
    fireEvent.change(screen.getByLabelText("Provider Plan ID"), {
      target: { value: "price_enterprise_yearly" }
    });
    fireEvent.change(screen.getByLabelText("价格（最小货币单位）"), {
      target: { value: "19900" }
    });
    fireEvent.change(screen.getByLabelText("币种"), {
      target: { value: "USD" }
    });
    fireEvent.change(screen.getByLabelText("计费周期"), {
      target: { value: "year" }
    });
    fireEvent.click(screen.getByLabelText("支持优惠券"));
    fireEvent.click(screen.getByLabelText("支持订阅"));
    fireEvent.click(screen.getByRole("button", { name: "保存套餐" }));

    await waitFor(() => {
      expect(opsClient.createPlan).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          id: "plan_enterprise",
          name: "Enterprise",
          maxDevices: 100,
          maxSeats: 50,
          allowedChannels: ["stable", "beta"],
          entitlements: ["pro_features", "priority_support"],
          paymentProvider: "stripe",
          providerPlanId: "price_enterprise_yearly",
          priceMinor: 19900,
          currency: "USD",
          billingInterval: "year",
          couponSupport: true,
          subscriptionSupport: true
        })
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "编辑 Pro" }));
    fireEvent.change(screen.getByLabelText("最大席位"), {
      target: { value: "2" }
    });
    fireEvent.click(screen.getByLabelText("支持优惠券"));
    fireEvent.click(screen.getByRole("button", { name: "保存套餐" }));
    await waitFor(() => {
      expect(opsClient.updatePlan).toHaveBeenCalledWith(
        "stacio",
        "plan_pro",
        expect.objectContaining({
          maxSeats: 2,
          paymentProvider: "stripe",
          providerPlanId: "price_pro_monthly",
          couponSupport: false,
          subscriptionSupport: true
        })
      );
    });

    const archiveButton = screen.getByRole("button", { name: "归档 Pro" });
    await waitFor(() => {
      expect(archiveButton).toBeEnabled();
    });
    fireEvent.click(archiveButton);
    await waitFor(() => {
      expect(opsClient.archivePlan).toHaveBeenCalledWith("stacio", "plan_pro");
    });
  });
});
