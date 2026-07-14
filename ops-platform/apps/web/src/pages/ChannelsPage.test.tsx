// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  opsClient,
  type ChannelHistoryRecord,
  type ReleaseChannelRecord
} from "../api/client";
import { ChannelsPage } from "./ChannelsPage";

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

const stableChannel: ReleaseChannelRecord = {
  id: "channel_stable",
  productId: "stacio",
  name: "stable",
  appcastUrl: "https://updates.example.com/stacio/stable/appcast.xml",
  allowedPlanIds: ["plan_free", "plan_pro"],
  rolloutPercentage: 100,
  autoDownloadAllowed: false,
  forceUpdatePrompt: false,
  status: "active",
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const history: ChannelHistoryRecord[] = [
  {
    id: "audit_channel_rollout",
    action: "channel.updated",
    targetType: "channel",
    targetId: "channel_stable",
    beforeValue: { rolloutPercentage: 100 },
    afterValue: { rolloutPercentage: 20 },
    createdAt: "2026-07-10T00:00:00.000Z"
  }
];

describe("ChannelsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue([product]);
    vi.spyOn(opsClient, "plans").mockResolvedValue([]);
    vi.spyOn(opsClient, "channels").mockResolvedValue([stableChannel]);
    vi.spyOn(opsClient, "createChannel").mockImplementation(async (_productId, input) => ({
      id: "channel_canary",
      productId: "stacio",
      ...input,
      status: input.status ?? "active",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    }));
    vi.spyOn(opsClient, "updateChannel").mockImplementation(async (_productId, _channelId, input) => ({
      ...stableChannel,
      ...input,
      appcastUrl: input.appcastUrl ?? stableChannel.appcastUrl,
      currentReleaseId: input.currentReleaseId ?? stableChannel.currentReleaseId,
      minimumUpgradableVersion:
        input.minimumUpgradableVersion ?? stableChannel.minimumUpgradableVersion
    }));
    vi.spyOn(opsClient, "channelHistory").mockResolvedValue(history);
    vi.spyOn(opsClient, "rollbackChannel").mockResolvedValue(stableChannel);
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates, adjusts, pauses, inspects, and rolls back release channels", async () => {
    vi.spyOn(window, "prompt").mockImplementation((message) =>
      (message ?? "").includes("暂停") ? "PAUSE" : "ROLLBACK"
    );
    render(<ChannelsPage />);

    expect(await screen.findByText("stable")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "新建通道" }));
    fireEvent.change(screen.getByLabelText("通道名称"), {
      target: { value: "canary" }
    });
    fireEvent.change(screen.getByLabelText("Appcast URL"), {
      target: { value: "https://updates.example.com/stacio/canary/appcast.xml" }
    });
    fireEvent.change(screen.getByLabelText("灰度百分比"), {
      target: { value: "25" }
    });
    fireEvent.change(screen.getByLabelText("允许套餐 ID"), {
      target: { value: "plan_internal" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存通道" }));
    await waitFor(() => {
      expect(opsClient.createChannel).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          name: "canary",
          rolloutPercentage: 25,
          allowedPlanIds: ["plan_internal"]
        })
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "编辑 stable" }));
    fireEvent.change(screen.getByLabelText("灰度百分比"), {
      target: { value: "20" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存通道" }));
    await waitFor(() => {
      expect(opsClient.updateChannel).toHaveBeenCalledWith(
        "stacio",
        "channel_stable",
        expect.objectContaining({
          rolloutPercentage: 20
        })
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "暂停 stable" }));
    await waitFor(() => {
      expect(opsClient.updateChannel).toHaveBeenCalledWith(
        "stacio",
        "channel_stable",
        {
          status: "paused",
          confirmation: "PAUSE"
        }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "历史 stable" }));
    expect(await screen.findByText("channel.updated")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "回滚 audit_channel_rollout" }));
    await waitFor(() => {
      expect(opsClient.rollbackChannel).toHaveBeenCalledWith(
        "stacio",
        "channel_stable",
        "audit_channel_rollout"
      );
    });
  });
});
