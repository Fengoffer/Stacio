// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { ProductsPage } from "./ProductsPage";

const productRecord = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  iconUrl: "",
  description: "Desktop operations client",
  supportEmail: "support@stacio.dev",
  currentStableVersion: "0.13.1-Beta",
  currentBetaVersion: "0.13.2-Beta",
  githubOwner: "zerx-lab",
  githubRepository: "stacio",
  updateBaseUrl: "https://updates.example.com/stacio",
  appcastBaseUrl: "https://updates.example.com/stacio",
  objectStoragePrefix: "products/stacio",
  licensePolicy: {},
  dataRetentionPolicy: {
    feedbackRetentionDays: 730,
    diagnosticsRetentionDays: 90,
    auditLogRetentionDays: 1095,
    inactiveCustomerRetentionDays: 730
  },
  emailBrand: {},
  status: "active",
  createdAt: "2026-07-09T12:00:00.000Z",
  updatedAt: "2026-07-09T12:00:00.000Z"
};

describe("ProductsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue([productRecord]);
    vi.spyOn(opsClient, "updateProduct").mockResolvedValue({
      ...productRecord,
      supportEmail: "help@stacio.dev"
    });
    vi.spyOn(opsClient, "createProduct").mockResolvedValue({
      product: {
        ...productRecord,
        id: "portdesk",
        name: "PortDesk",
        bundleId: "com.zerxlab.portdesk"
      },
      feedbackApiKey: "pfk_created_once"
    });
    vi.spyOn(opsClient, "rotateFeedbackApiKey").mockResolvedValue({
      feedbackApiKey: "pfk_rotated_once"
    });
    vi.spyOn(opsClient, "archiveProduct").mockResolvedValue({
      id: "stacio",
      status: "archived"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("edits the selected product through the real admin API client", async () => {
    render(<ProductsPage />);

    expect(await screen.findByRole("heading", { name: "产品管理" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "编辑产品" }));
    fireEvent.change(screen.getByLabelText("支持邮箱"), {
      target: { value: "help@stacio.dev" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存产品" }));

    await waitFor(() => {
      expect(opsClient.updateProduct).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          supportEmail: "help@stacio.dev"
        })
      );
    });
  });

  it("saves complete product email brand settings for reusable templates", async () => {
    render(<ProductsPage />);

    expect(await screen.findByRole("heading", { name: "产品管理" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "编辑产品" }));
    fireEvent.change(screen.getByLabelText("邮件品牌名称"), {
      target: { value: "Stacio Ops" }
    });
    fireEvent.change(screen.getByLabelText("邮件 Logo URL"), {
      target: { value: "https://cdn.example.com/stacio-logo.png" }
    });
    fireEvent.change(screen.getByLabelText("邮件发件人名称"), {
      target: { value: "Stacio Support" }
    });
    fireEvent.change(screen.getByLabelText("邮件 Reply-To"), {
      target: { value: "reply@stacio.dev" }
    });
    fireEvent.change(screen.getByLabelText("邮件支持 URL"), {
      target: { value: "https://stacio.dev/support" }
    });
    fireEvent.change(screen.getByLabelText("邮件 Footer 文案"), {
      target: { value: "Stacio Team" }
    });
    fireEvent.change(screen.getByLabelText("邮件 Legal 文案"), {
      target: { value: "Copyright 2026 Stacio. All rights reserved." }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存产品" }));

    await waitFor(() => {
      expect(opsClient.updateProduct).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          emailBrand: expect.objectContaining({
            name: "Stacio Ops",
            logoUrl: "https://cdn.example.com/stacio-logo.png",
            senderName: "Stacio Support",
            replyToEmail: "reply@stacio.dev",
            supportUrl: "https://stacio.dev/support",
            footerText: "Stacio Team",
            legalText: "Copyright 2026 Stacio. All rights reserved."
          })
        })
      );
    });
  });

  it("saves current stable and beta versions from product settings", async () => {
    render(<ProductsPage />);

    expect(await screen.findByRole("heading", { name: "产品管理" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "编辑产品" }));
    fireEvent.change(screen.getByLabelText("当前 Stable 版本"), {
      target: { value: "0.14.0" }
    });
    fireEvent.change(screen.getByLabelText("当前 Beta 版本"), {
      target: { value: "0.15.0-Beta" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存产品" }));

    await waitFor(() => {
      expect(opsClient.updateProduct).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          currentStableVersion: "0.14.0",
          currentBetaVersion: "0.15.0-Beta"
        })
      );
    });
  });

  it("saves product data retention policy from product settings", async () => {
    render(<ProductsPage />);

    expect(await screen.findByRole("heading", { name: "产品管理" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "编辑产品" }));
    fireEvent.change(screen.getByLabelText("反馈保留天数"), {
      target: { value: "365" }
    });
    fireEvent.change(screen.getByLabelText("诊断摘要保留天数"), {
      target: { value: "30" }
    });
    fireEvent.change(screen.getByLabelText("审计日志保留天数"), {
      target: { value: "1095" }
    });
    fireEvent.change(screen.getByLabelText("非活跃客户保留天数"), {
      target: { value: "540" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存产品" }));

    await waitFor(() => {
      expect(opsClient.updateProduct).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          dataRetentionPolicy: {
            feedbackRetentionDays: 365,
            diagnosticsRetentionDays: 30,
            auditLogRetentionDays: 1095,
            inactiveCustomerRetentionDays: 540
          }
        })
      );
    });
  });

  it("creates another product and displays its feedback key once", async () => {
    render(<ProductsPage />);

    await screen.findByRole("heading", { name: "产品管理" });
    fireEvent.click(screen.getByRole("button", { name: "新建产品" }));
    fireEvent.change(screen.getByLabelText("Product ID"), {
      target: { value: "portdesk" }
    });
    fireEvent.change(screen.getByLabelText("产品名称"), {
      target: { value: "PortDesk" }
    });
    fireEvent.change(screen.getByLabelText("平台"), {
      target: { value: "macOS" }
    });
    fireEvent.change(screen.getByLabelText("Bundle ID"), {
      target: { value: "com.zerxlab.portdesk" }
    });
    fireEvent.change(screen.getByLabelText("支持邮箱"), {
      target: { value: "support@example.com" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建产品" }));

    await waitFor(() => {
      expect(opsClient.createProduct).toHaveBeenCalledWith(
        expect.objectContaining({
          id: "portdesk",
          name: "PortDesk",
          bundleId: "com.zerxlab.portdesk"
        })
      );
    });
    expect(await screen.findByText("pfk_created_once")).toBeInTheDocument();
    expect(screen.getAllByText(/只显示这一次/).length).toBeGreaterThan(0);
  });

  it("requires typed confirmation before rotating the feedback key", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("ROTATE");
    render(<ProductsPage />);

    await screen.findByRole("heading", { name: "产品管理" });
    fireEvent.click(screen.getByRole("button", { name: "轮换 Feedback Key" }));

    await waitFor(() => {
      expect(opsClient.rotateFeedbackApiKey).toHaveBeenCalledWith("stacio");
    });
    expect(await screen.findByText("pfk_rotated_once")).toBeInTheDocument();
  });
});
