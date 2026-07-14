// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { LicensesPage } from "./LicensesPage";

const activeLicense = {
  id: "license_1",
  customer: "Ada",
  email: "ada@example.com",
  plan: "Pro",
  status: "Active",
  devices: "1/2",
  expires: "2027/7/10"
};

describe("LicensesPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "licenses").mockResolvedValue([activeLicense]);
    vi.spyOn(opsClient, "createLicense").mockResolvedValue({
      license: {
        id: "license_2",
        productId: "stacio",
        customerName: "Grace",
        customerEmail: "grace@example.com",
        username: "grace",
        plan: "team",
        status: "active",
        seats: 5,
        maxDevices: 10,
        devices: 0,
        entitlements: ["team_features", "beta_channel"],
        offlineGraceDays: 30,
        expiresAt: "2027-07-10T00:00:00.000Z",
        createdAt: "2026-07-10T00:00:00.000Z",
        updatedAt: "2026-07-10T00:00:00.000Z"
      },
      licenseKey: "STACIO-TEAM-ONE-TIME-KEY",
      revealPolicy: "one_time"
    });
    vi.spyOn(opsClient, "batchCreateLicenses").mockResolvedValue([
      {
        license: {
          id: "license_batch_1",
          productId: "stacio",
          customerName: "Team One",
          customerEmail: "team-one@example.com",
          username: "team-one",
          plan: "team",
          status: "active",
          seats: 1,
          devices: 0,
          maxDevices: 3,
          entitlements: ["team_features"],
          offlineGraceDays: 30,
          expiresAt: "2027-07-10T00:00:00.000Z",
          createdAt: "2026-07-10T00:00:00.000Z"
        },
        licenseKey: "STACIO-BATCH-ONE",
        revealPolicy: "one_time"
      },
      {
        license: {
          id: "license_batch_2",
          productId: "stacio",
          customerName: "Team Two",
          customerEmail: "team-two@example.com",
          username: "team-two",
          plan: "team",
          status: "active",
          seats: 1,
          devices: 0,
          maxDevices: 3,
          entitlements: ["team_features"],
          offlineGraceDays: 30,
          expiresAt: "2027-07-10T00:00:00.000Z",
          createdAt: "2026-07-10T00:00:00.000Z"
        },
        licenseKey: "STACIO-BATCH-TWO",
        revealPolicy: "one_time"
      }
    ]);
    vi.spyOn(opsClient, "updateLicense").mockResolvedValue({ id: "license_1" });
    vi.spyOn(opsClient, "resetLicenseActivations").mockResolvedValue({ id: "license_1" });
    vi.spyOn(opsClient, "licenseDetail").mockResolvedValue({
      license: {
        id: "license_1",
        productId: "stacio",
        customerName: "Ada",
        customerEmail: "ada@example.com",
        username: "ada",
        plan: "pro",
        status: "active",
        seats: 1,
        devices: 1,
        maxDevices: 2,
        entitlements: ["pro_features", "beta_channel"],
        offlineGraceDays: 14,
        expiresAt: "2027-07-10T00:00:00.000Z",
        createdAt: "2026-07-10T00:00:00.000Z",
        updatedAt: "2026-07-10T00:00:00.000Z"
      },
      customer: {
        id: "cust_1",
        productId: "stacio",
        name: "Ada",
        email: "ada@example.com",
        status: "active",
        riskFlag: false,
        createdAt: "2026-07-10T00:00:00.000Z",
        updatedAt: "2026-07-10T00:00:00.000Z"
      },
      activations: [
        {
          id: "act_1",
          licenseId: "license_1",
          anonymousDeviceId: "device_paid",
          firstSeenAt: "2026-07-10T00:00:00.000Z",
          lastSeenAt: "2026-07-10T01:00:00.000Z",
          riskSignals: {},
          createdAt: "2026-07-10T00:00:00.000Z",
          updatedAt: "2026-07-10T01:00:00.000Z"
        }
      ],
      validationLogs: [
        {
          id: "log_1",
          licenseId: "license_1",
          productId: "stacio",
          result: "valid",
          appVersion: "0.13.2-Beta",
          buildNumber: "12",
          createdAt: "2026-07-10T01:00:00.000Z"
        }
      ],
      auditLogs: [
        {
          id: "audit_1",
          action: "license.created",
          targetType: "license",
          targetId: "license_1",
          createdAt: "2026-07-10T00:00:00.000Z"
        }
      ]
    });
    vi.spyOn(opsClient, "createNotification").mockResolvedValue({
      id: "notification_license_1",
      type: "Customer License Issued",
      recipient: "grace@example.com",
      summary: "Grace team license",
      status: "Queued",
      priority: "Normal",
      createdAt: "2026/7/10"
    });
    vi.spyOn(opsClient, "sendNotification").mockResolvedValue({ id: "job_notification_1" });
    vi.spyOn(opsClient, "sendLicenseEmail").mockResolvedValue({
      notification: {
        id: "notification_license_1",
        type: "Customer License Issued",
        recipient: "grace@example.com",
        summary: "Grace team license",
        status: "Queued",
        priority: "Normal",
        createdAt: "2026/7/10"
      },
      job: {
        id: "job_notification_1",
        name: "notification.send"
      }
    });
    vi.spyOn(opsClient, "batchSendLicenseEmails").mockResolvedValue({
      requestedCount: 2,
      queuedCount: 2,
      skippedCount: 0,
      queued: [
        {
          licenseId: "license_batch_1",
          recipient: "team-one@example.com",
          notification: {
            id: "notification_batch_1",
            type: "Customer License Issued",
            recipient: "team-one@example.com",
            summary: "Team One license",
            status: "Queued",
            priority: "Normal",
            createdAt: "2026/7/10"
          },
          job: { id: "job_batch_1", name: "notification.send" }
        },
        {
          licenseId: "license_batch_2",
          recipient: "team-two@example.com",
          notification: {
            id: "notification_batch_2",
            type: "Customer License Issued",
            recipient: "team-two@example.com",
            summary: "Team Two license",
            status: "Queued",
            priority: "Normal",
            createdAt: "2026/7/10"
          },
          job: { id: "job_batch_2", name: "notification.send" }
        }
      ],
      skipped: []
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates a license, reveals its key once, and supports guarded lifecycle actions", async () => {
    vi.spyOn(window, "prompt").mockImplementation((message) => {
      if ((message ?? "").includes("发送")) return "SEND";
      if ((message ?? "").includes("撤销")) return "REVOKE";
      if ((message ?? "").includes("重置")) return "RESET";
      return "SUSPEND";
    });
    render(<LicensesPage />);

    expect(await screen.findByText("Ada")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "生成许可证" }));
    fireEvent.change(screen.getByLabelText("客户名称"), {
      target: { value: "Grace" }
    });
    fireEvent.change(screen.getByLabelText("客户邮箱"), {
      target: { value: "grace@example.com" }
    });
    fireEvent.change(screen.getByLabelText("用户名"), {
      target: { value: "grace" }
    });
    fireEvent.change(screen.getByLabelText("套餐"), {
      target: { value: "team" }
    });
    fireEvent.change(screen.getByLabelText("席位数"), {
      target: { value: "5" }
    });
    fireEvent.change(screen.getByLabelText("最大设备数"), {
      target: { value: "10" }
    });
    fireEvent.change(screen.getByLabelText("离线宽限天数"), {
      target: { value: "30" }
    });
    fireEvent.change(screen.getByLabelText("到期时间"), {
      target: { value: "2027-07-10T00:00" }
    });
    fireEvent.change(screen.getByLabelText("Entitlements"), {
      target: { value: "team_features, beta_channel" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建并生成密钥" }));

    await waitFor(() => {
      expect(opsClient.createLicense).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          customerName: "Grace",
          customerEmail: "grace@example.com",
          username: "grace",
          plan: "team",
          seats: 5,
          maxDevices: 10,
          offlineGraceDays: 30,
          entitlements: ["team_features", "beta_channel"]
        })
      );
    });
    expect(await screen.findByText("STACIO-TEAM-ONE-TIME-KEY")).toBeInTheDocument();
    expect(screen.getByText(/只会完整显示这一次/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "发送许可证邮件" }));
    await waitFor(() => {
      expect(opsClient.sendLicenseEmail).toHaveBeenCalledWith(
        "license_2",
        {
          licenseKey: "STACIO-TEAM-ONE-TIME-KEY",
          confirmation: "SEND"
        },
        "stacio"
      );
    });
    expect(opsClient.createNotification).not.toHaveBeenCalledWith(
      "stacio",
      expect.objectContaining({
        type: "customer_license_issued",
        recipient: "grace@example.com",
        priority: "normal",
        payload: expect.objectContaining({
          licenseKey: "STACIO-TEAM-ONE-TIME-KEY"
        })
      })
    );
    expect(opsClient.sendNotification).not.toHaveBeenCalledWith("notification_license_1", false, "queue", "stacio");

    fireEvent.click(screen.getByRole("button", { name: "重置设备 Ada" }));
    await waitFor(() => {
      expect(opsClient.resetLicenseActivations).toHaveBeenCalledWith(
        "license_1",
        "RESET",
        "stacio"
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "暂停 Ada" }));
    await waitFor(() => {
      expect(opsClient.updateLicense).toHaveBeenCalledWith(
        "license_1",
        { status: "suspended", confirmation: "SUSPEND" },
        "stacio"
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "撤销 Ada" }));
    await waitFor(() => {
      expect(opsClient.updateLicense).toHaveBeenCalledWith(
        "license_1",
        { status: "revoked", confirmation: "REVOKE" },
        "stacio"
      );
    });
  });

  it("batch creates licenses from identity rows and reveals generated keys once", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("SEND");
    render(<LicensesPage />);

    expect(await screen.findByText("Ada")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "批量生成" }));
    fireEvent.change(screen.getByLabelText("批量客户"), {
      target: {
        value: "Team One,team-one@example.com,team-one\nTeam Two,team-two@example.com,team-two"
      }
    });
    fireEvent.change(screen.getByLabelText("批量套餐"), {
      target: { value: "team" }
    });
    fireEvent.change(screen.getByLabelText("批量最大设备数"), {
      target: { value: "3" }
    });
    fireEvent.change(screen.getByLabelText("批量离线宽限天数"), {
      target: { value: "30" }
    });
    fireEvent.change(screen.getByLabelText("批量到期时间"), {
      target: { value: "2027-07-10T00:00" }
    });
    fireEvent.change(screen.getByLabelText("批量 Entitlements"), {
      target: { value: "team_features" }
    });
    fireEvent.click(screen.getByRole("button", { name: "批量创建许可证" }));

    await waitFor(() => {
      expect(opsClient.batchCreateLicenses).toHaveBeenCalledWith(
        "stacio",
        expect.objectContaining({
          recipients: [
            {
              customerName: "Team One",
              customerEmail: "team-one@example.com",
              username: "team-one"
            },
            {
              customerName: "Team Two",
              customerEmail: "team-two@example.com",
              username: "team-two"
            }
          ],
          plan: "team",
          maxDevices: 3,
          offlineGraceDays: 30,
          entitlements: ["team_features"]
        })
      );
    });
    expect(await screen.findByText("STACIO-BATCH-ONE")).toBeInTheDocument();
    expect(screen.getByText("STACIO-BATCH-TWO")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "发送全部许可证邮件" }));
    await waitFor(() => {
      expect(opsClient.batchSendLicenseEmails).toHaveBeenCalledWith(
        "stacio",
        [
          {
            licenseId: "license_batch_1",
            licenseKey: "STACIO-BATCH-ONE"
          },
          {
            licenseId: "license_batch_2",
            licenseKey: "STACIO-BATCH-TWO"
          }
        ],
        "SEND"
      );
    });
  });

  it("edits license commercial terms without lifecycle confirmation", async () => {
    const promptSpy = vi.spyOn(window, "prompt").mockReturnValue("");
    render(<LicensesPage />);

    expect(await screen.findByText("Ada")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "编辑授权 Ada" }));
    fireEvent.change(screen.getByLabelText("授权套餐"), {
      target: { value: "internal" }
    });
    fireEvent.change(screen.getByLabelText("授权席位数"), {
      target: { value: "3" }
    });
    fireEvent.change(screen.getByLabelText("授权最大设备数"), {
      target: { value: "6" }
    });
    fireEvent.change(screen.getByLabelText("授权离线宽限天数"), {
      target: { value: "90" }
    });
    fireEvent.change(screen.getByLabelText("授权到期时间"), {
      target: { value: "2028-07-10T00:00" }
    });
    fireEvent.change(screen.getByLabelText("授权 Entitlements"), {
      target: { value: "internal_features, beta_channel" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存授权变更" }));

    await waitFor(() => {
      expect(opsClient.updateLicense).toHaveBeenCalledWith(
        "license_1",
        expect.objectContaining({
          plan: "internal",
          seats: 3,
          maxDevices: 6,
          offlineGraceDays: 90,
          expiresAt: new Date("2028-07-10T00:00").toISOString(),
          entitlements: ["internal_features", "beta_channel"]
        }),
        "stacio"
      );
    });
    expect(promptSpy).not.toHaveBeenCalled();
  });

  it("opens license detail with activations, validation history, and audit logs", async () => {
    render(<LicensesPage />);

    expect(await screen.findByText("Ada")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "查看详情 Ada" }));

    await waitFor(() => {
      expect(opsClient.licenseDetail).toHaveBeenCalledWith("license_1", "stacio");
    });
    const detail = await screen.findByRole("region", { name: "License 详情" });
    expect(within(detail).getByText("ada@example.com")).toBeInTheDocument();
    expect(within(detail).getByText("device_paid")).toBeInTheDocument();
    expect(within(detail).getByText("0.13.2-Beta / 12")).toBeInTheDocument();
    expect(within(detail).getByText("license.created")).toBeInTheDocument();
  });

  it("performs guarded lifecycle actions from the license detail panel", async () => {
    vi.spyOn(window, "prompt").mockImplementation((message) => {
      if ((message ?? "").includes("重置")) return "RESET";
      if ((message ?? "").includes("撤销")) return "REVOKE";
      return "SUSPEND";
    });
    render(<LicensesPage />);

    expect(await screen.findByText("Ada")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "查看详情 Ada" }));
    const detail = await screen.findByRole("region", { name: "License 详情" });

    expect(within(detail).getByText("客户资料")).toBeInTheDocument();
    expect(within(detail).getByText("active")).toBeInTheDocument();

    fireEvent.click(within(detail).getByRole("button", { name: "重置详情设备 Ada" }));
    await waitFor(() => {
      expect(opsClient.resetLicenseActivations).toHaveBeenCalledWith(
        "license_1",
        "RESET",
        "stacio"
      );
    });

    fireEvent.click(within(detail).getByRole("button", { name: "暂停详情 Ada" }));
    await waitFor(() => {
      expect(opsClient.updateLicense).toHaveBeenCalledWith(
        "license_1",
        { status: "suspended", confirmation: "SUSPEND" },
        "stacio"
      );
    });

    fireEvent.click(within(detail).getByRole("button", { name: "撤销详情 Ada" }));
    await waitFor(() => {
      expect(opsClient.updateLicense).toHaveBeenCalledWith(
        "license_1",
        { status: "revoked", confirmation: "REVOKE" },
        "stacio"
      );
    });
  });
});
