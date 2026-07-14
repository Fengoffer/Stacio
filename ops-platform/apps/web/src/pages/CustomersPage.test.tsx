// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { CustomersPage } from "./CustomersPage";

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
  }
];

const primaryCustomer = {
  id: "cust_primary",
  productId: "stacio",
  email: "primary@example.com",
  name: "Primary Customer",
  company: "Example Labs",
  status: "active",
  riskFlag: false,
  createdAt: "2026-07-10T00:00:00.000Z",
  updatedAt: "2026-07-10T00:00:00.000Z"
};

const duplicateCustomer = {
  ...primaryCustomer,
  id: "cust_duplicate",
  email: "duplicate@example.com",
  name: "Duplicate Customer"
};

describe("CustomersPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue(products);
    vi.spyOn(opsClient, "customers").mockResolvedValue([
      primaryCustomer,
      duplicateCustomer
    ]);
    vi.spyOn(opsClient, "createCustomer").mockResolvedValue({
      ...primaryCustomer,
      id: "cust_created",
      email: "new@example.com",
      name: "New Customer"
    });
    vi.spyOn(opsClient, "updateCustomer").mockResolvedValue({
      ...primaryCustomer,
      riskFlag: true
    });
    vi.spyOn(opsClient, "customerDetail").mockResolvedValue({
      customer: primaryCustomer,
      licenses: [],
      feedback: [],
      notifications: [
        {
          id: "notification_failed_1",
          type: "Customer Feedback Reply",
          status: "Failed",
          createdAt: "2026/07/10",
          deliveries: [
            {
              id: "delivery_failed_1",
              notificationId: "notification_failed_1",
              provider: "smtp",
              attempt: 2,
              status: "Failed",
              error: "Mailbox unavailable",
              sentAt: undefined,
              createdAt: "2026/07/10"
            }
          ]
        }
      ],
      notes: [],
      activationCount: 1,
      activations: [
        {
          id: "act_customer_macbook",
          licenseId: "lic_primary",
          anonymousDeviceId: "device_customer_macbook",
          machineFingerprintHash: "sha256_customer_device",
          firstSeenAt: "2026-07-09T00:00:00.000Z",
          lastSeenAt: "2026-07-10T00:00:00.000Z",
          riskSignals: {},
          createdAt: "2026-07-09T00:00:00.000Z",
          updatedAt: "2026-07-10T00:00:00.000Z"
        }
      ],
      auditLogs: [
        {
          id: "audit_customer_updated",
          actorType: "user",
          actorId: "usr_development_owner",
          action: "customer.updated",
          targetType: "customer",
          targetId: "cust_primary",
          createdAt: "2026-07-10T01:00:00.000Z"
        }
      ]
    });
    vi.spyOn(opsClient, "addCustomerNote").mockResolvedValue({
      id: "note_1",
      customerId: "cust_primary",
      body: "High-touch onboarding customer.",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "mergeCustomer").mockResolvedValue({
      source: {
        ...duplicateCustomer,
        status: "merged",
        mergedIntoId: "cust_primary"
      },
      target: primaryCustomer
    });
    vi.spyOn(opsClient, "createLicense").mockResolvedValue({
      license: {
        id: "lic_customer_1",
        productId: "stacio",
        customerId: "cust_primary",
        customerName: "Primary Customer",
        customerEmail: "primary@example.com",
        username: "Primary Customer",
        plan: "team",
        status: "active",
        seats: 3,
        devices: 0,
        maxDevices: 6,
        entitlements: ["team_features", "beta_channel"],
        offlineGraceDays: 30,
        expiresAt: "2027-07-10T00:00:00.000Z",
        createdAt: "2026-07-10T00:00:00.000Z",
        updatedAt: "2026-07-10T00:00:00.000Z"
      },
      licenseKey: "STACIO-CUSTOMER-ONE-TIME-KEY",
      revealPolicy: "one_time"
    });
    vi.spyOn(opsClient, "createNotification").mockResolvedValue({
      id: "notification_customer_1",
      type: "Customer Feedback Reply",
      recipient: "primary@example.com",
      summary: "message=Thanks for the update.",
      status: "Queued",
      priority: "Normal",
      createdAt: "2026/07/10"
    });
    vi.spyOn(opsClient, "sendNotification").mockResolvedValue({ id: "job_customer_mail_1" });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates, flags, annotates, and merges customers", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("MERGE");
    render(<CustomersPage />);

    expect(await screen.findByRole("heading", { name: "客户管理" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "新建客户" }));
    fireEvent.change(screen.getByLabelText("客户邮箱"), {
      target: { value: "new@example.com" }
    });
    fireEvent.change(screen.getByLabelText("客户名称"), {
      target: { value: "New Customer" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存客户" }));
    await waitFor(() => {
      expect(opsClient.createCustomer).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          email: "new@example.com",
          name: "New Customer"
        })
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "标记风险 Primary Customer" }));
    await waitFor(() => {
      expect(opsClient.updateCustomer).toHaveBeenCalledWith(
        "stacio",
        "cust_primary",
        { riskFlag: true }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "查看 Primary Customer" }));
    expect(await screen.findByRole("heading", { name: "Primary Customer" })).toBeInTheDocument();
    expect(screen.getByText("device_customer_macbook")).toBeInTheDocument();
    expect(screen.getByText("sha256_customer_device")).toBeInTheDocument();
    expect(screen.getByText("notification_failed_1")).toBeInTheDocument();
    expect(screen.getByText(/尝试 2/)).toBeInTheDocument();
    expect(screen.getByText(/smtp/)).toBeInTheDocument();
    expect(screen.getByText(/Mailbox unavailable/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "客户审计事件" })).toBeInTheDocument();
    expect(screen.getByText("customer.updated")).toBeInTheDocument();
    expect(screen.getByText(/user/)).toBeInTheDocument();
    expect(screen.getByText(/cust_primary/)).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("内部备注"), {
      target: { value: "High-touch onboarding customer." }
    });
    fireEvent.click(screen.getByRole("button", { name: "添加备注" }));
    await waitFor(() => {
      expect(opsClient.addCustomerNote).toHaveBeenCalledWith(
        "stacio",
        "cust_primary",
        "High-touch onboarding customer."
      );
    });

    fireEvent.change(screen.getByLabelText("合并到客户"), {
      target: { value: "cust_primary" }
    });
    fireEvent.click(screen.getByRole("button", { name: "合并 Duplicate Customer" }));
    await waitFor(() => {
      expect(opsClient.mergeCustomer).toHaveBeenCalledWith(
        "stacio",
        "cust_duplicate",
        "cust_primary"
      );
    });
  });

  it("issues a customer-bound license from the customer detail panel", async () => {
    render(<CustomersPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看 Primary Customer" }));
    expect(await screen.findByRole("heading", { name: "Primary Customer" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "分配 License" }));
    expect(await screen.findByRole("heading", { name: "给客户发放 License" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("客户 License 套餐"), {
      target: { value: "team" }
    });
    fireEvent.change(screen.getByLabelText("客户 License 席位数"), {
      target: { value: "3" }
    });
    fireEvent.change(screen.getByLabelText("客户 License 最大设备数"), {
      target: { value: "6" }
    });
    fireEvent.change(screen.getByLabelText("客户 License 离线宽限天数"), {
      target: { value: "30" }
    });
    fireEvent.change(screen.getByLabelText("客户 License 到期时间"), {
      target: { value: "2027-07-10T00:00" }
    });
    fireEvent.change(screen.getByLabelText("客户 License Entitlements"), {
      target: { value: "team_features, beta_channel" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建客户 License" }));

    await waitFor(() => {
      expect(opsClient.createLicense).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          customerName: "Primary Customer",
          customerEmail: "primary@example.com",
          username: "Primary Customer",
          plan: "team",
          seats: 3,
          maxDevices: 6,
          offlineGraceDays: 30,
          entitlements: ["team_features", "beta_channel"]
        })
      );
    });
    expect(await screen.findByText("STACIO-CUSTOMER-ONE-TIME-KEY")).toBeInTheDocument();
    expect(screen.getByText("lic_customer_1")).toBeInTheDocument();
  });

  it("creates and manually sends a customer-visible email from the customer detail panel", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("SEND");
    render(<CustomersPage />);

    fireEvent.click(await screen.findByRole("button", { name: "查看 Primary Customer" }));
    expect(await screen.findByRole("heading", { name: "Primary Customer" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "发送邮件" }));
    expect(await screen.findByRole("heading", { name: "给客户发送邮件" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("客户邮件类型"), {
      target: { value: "customer_feedback_reply" }
    });
    fireEvent.change(screen.getByLabelText("客户邮件优先级"), {
      target: { value: "normal" }
    });
    fireEvent.change(screen.getByLabelText("客户邮件 Payload JSON"), {
      target: { value: "{\"message\":\"Thanks for the update.\"}" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建并发送客户邮件" }));

    await waitFor(() => {
      expect(opsClient.createNotification).toHaveBeenCalledWith(
        "stacio",
        {
          type: "customer_feedback_reply",
          recipient: "primary@example.com",
          priority: "normal",
          status: "queued",
          payload: {
            customer: {
              id: "cust_primary",
              name: "Primary Customer",
              email: "primary@example.com"
            },
            message: "Thanks for the update."
          }
        }
      );
    });
    expect(window.prompt).toHaveBeenCalledWith(
      "将向 primary@example.com 发送客户可见邮件。请输入 SEND 确认。"
    );
    expect(opsClient.sendNotification).toHaveBeenCalledWith(
      "notification_customer_1",
      false,
      "queue",
      "stacio"
    );
    expect(await screen.findAllByText("notification_customer_1")).toHaveLength(2);
  });
});
