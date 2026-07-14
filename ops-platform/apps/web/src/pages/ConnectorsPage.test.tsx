// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { ConnectorsPage } from "./ConnectorsPage";

const products = [
  {
    id: "stacio",
    name: "Stacio",
    platform: "macOS",
    bundleId: "com.stacio.Stacio",
    iconUrl: "",
    description: "",
    currentStableVersion: "",
    currentBetaVersion: "",
    supportEmail: "support@example.com",
    githubOwner: "zerx-lab",
    githubRepository: "stacio",
    updateBaseUrl: "",
    appcastBaseUrl: "",
    licensePolicy: {},
    dataRetentionPolicy: {},
    emailBrand: {},
    objectStoragePrefix: "products/stacio",
    status: "active" as const,
    createdAt: "2026-07-10T00:00:00.000Z",
    updatedAt: "2026-07-10T00:00:00.000Z"
  }
];

const githubConnector = {
  id: "conn_github",
  productId: "stacio",
  type: "github" as const,
  name: "GitHub Issues",
  config: {
    owner: "zerx-lab",
    repository: "stacio",
    apiBaseUrl: "https://api.github.com"
  },
  hasSecrets: true,
  status: "configured",
  lastSuccessAt: "2026-07-10T00:00:00.000Z",
  lastError: null,
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

describe("ConnectorsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue(products);
    vi.spyOn(opsClient, "connectors").mockResolvedValue([githubConnector]);
    vi.spyOn(opsClient, "configureConnector").mockResolvedValue({
      ...githubConnector,
      config: {
        owner: "stacio-labs",
        repository: "desktop",
        apiBaseUrl: "https://api.github.com"
      }
    });
    vi.spyOn(opsClient, "testConnector").mockResolvedValue({
      connector: githubConnector,
      result: {
        message: "GitHub repository is accessible"
      }
    });
    vi.spyOn(opsClient, "disconnectConnector").mockResolvedValue({
      ...githubConnector,
      hasSecrets: false,
      status: "disabled"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("configures, tests, and disconnects a connector through real client methods", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("DISCONNECT");
    render(<ConnectorsPage />);

    expect(await screen.findByRole("heading", { name: "连接器" })).toBeInTheDocument();
    expect(screen.getByText("Webhook")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "查看 GitHub Issues 审计日志" })).toHaveAttribute(
      "href",
      "/audit-logs?targetType=connector&targetId=github"
    );
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "配置 Webhook" }));
    const webhookDialog = await screen.findByRole("dialog", { name: "配置 Webhook" });
    fireEvent.change(within(webhookDialog).getByLabelText("Webhook URL"), {
      target: { value: "https://hooks.example.com/stacio" }
    });
    fireEvent.change(within(webhookDialog).getByLabelText("事件类型"), {
      target: { value: "feedback.created, license.revoked" }
    });
    fireEvent.change(within(webhookDialog).getByLabelText("签名密钥"), {
      target: { value: "webhook-signing-secret" }
    });
    fireEvent.click(within(webhookDialog).getByRole("button", { name: "保存连接器" }));

    await waitFor(() => {
      expect(opsClient.configureConnector).toHaveBeenCalledWith(
        "stacio",
        "webhook",
        {
          config: {
            url: "https://hooks.example.com/stacio",
            eventTypes: ["feedback.created", "license.revoked"],
            signingHeader: "X-Stacio-Signature"
          },
          secrets: {
            signingSecret: "webhook-signing-secret"
          }
        }
      );
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: "配置 GitHub Issues" }));
    const githubDialog = await screen.findByRole("dialog", { name: "配置 GitHub Issues" });
    fireEvent.change(within(githubDialog).getByLabelText("GitHub Owner"), {
      target: { value: "stacio-labs" }
    });
    fireEvent.change(within(githubDialog).getByLabelText("Repository"), {
      target: { value: "desktop" }
    });
    fireEvent.change(within(githubDialog).getByLabelText("GitHub Token"), {
      target: { value: "new-github-token" }
    });
    fireEvent.click(within(githubDialog).getByRole("button", { name: "保存连接器" }));

    await waitFor(() => {
      expect(opsClient.configureConnector).toHaveBeenCalledWith(
        "stacio",
        "github",
        {
          config: {
            owner: "stacio-labs",
            repository: "desktop",
            apiBaseUrl: "https://api.github.com",
            state: "all"
          },
          secrets: {
            token: "new-github-token"
          }
        }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "检测 GitHub Issues" }));
    expect(await screen.findByText("GitHub repository is accessible")).toBeInTheDocument();
    expect(opsClient.testConnector).toHaveBeenCalledWith("stacio", "github");

    fireEvent.click(screen.getByRole("button", { name: "断开 GitHub Issues" }));
    await waitFor(() => {
      expect(opsClient.disconnectConnector).toHaveBeenCalledWith("stacio", "github");
    });
  });
});
