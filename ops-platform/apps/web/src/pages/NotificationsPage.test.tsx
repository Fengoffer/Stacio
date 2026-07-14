// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { NotificationsPage } from "./NotificationsPage";

const template = {
  id: "template_feedback_reply",
  type: "feedback_reply",
  subject: "Stacio 回复：{{feedback.title}}",
  status: "Active",
  updatedAt: "2026/07/10",
  htmlTemplate: "<p>{{reply.body}}</p>",
  textTemplate: "{{reply.body}}"
};

const notification = {
  id: "notification_1",
  type: "Feedback Reply",
  recipient: "customer@example.com",
  summary: "feedback.title=登录崩溃",
  status: "Queued",
  priority: "High",
  createdAt: "2026/07/10"
};

const digestNotification = {
  id: "notification_digest",
  type: "Admin Daily Feedback Digest",
  recipient: "ops@example.com",
  summary: "summary=2 条反馈",
  status: "Queued",
  priority: "Normal",
  createdAt: "2026/07/10"
};

const licenseExpiringNotification = {
  id: "notification_expiring",
  type: "Customer License Expiring",
  recipient: "pro@example.com",
  summary: "licenseId: lic_002, expiresAt: 2026-08-09T00:00:00.000Z",
  status: "Queued",
  priority: "Normal",
  createdAt: "2026/07/10"
};

describe("NotificationsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "notificationTemplates").mockResolvedValue([template]);
    vi.spyOn(opsClient, "notifications").mockResolvedValue([notification]);
    vi.spyOn(opsClient, "upsertNotificationTemplate").mockResolvedValue({
      ...template,
      subject: "Stacio 已处理：{{feedback.title}}"
    });
    vi.spyOn(opsClient, "createNotification").mockResolvedValue({
      id: "notification_2",
      type: "Customer License Issued",
      recipient: "licensee@example.com",
      summary: "license.plan=Pro",
      status: "Queued",
      priority: "Normal",
      createdAt: "2026/07/10"
    });
    vi.spyOn(opsClient, "createDailyFeedbackDigest").mockResolvedValue(digestNotification);
    vi.spyOn(opsClient, "createLicenseExpiringReminders").mockResolvedValue({
      scannedCount: 2,
      createdCount: 1,
      skippedCount: 1,
      window: {
        referenceDate: "2026-07-10T00:00:00.000Z",
        days: 30,
        cutoffDate: "2026-08-09T00:00:00.000Z"
      },
      created: [licenseExpiringNotification],
      skipped: [
        {
          licenseId: "lic_003",
          recipient: "team@example.com",
          reason: "already_queued"
        }
      ]
    });
    vi.spyOn(opsClient, "notificationPolicy").mockResolvedValue({
      productId: "stacio",
      quietHoursEnabled: true,
      quietHoursStart: "22:00",
      quietHoursEnd: "08:00",
      quietHoursTimeZone: "Asia/Shanghai",
      updatedAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "updateNotificationPolicy").mockResolvedValue({
      productId: "stacio",
      quietHoursEnabled: true,
      quietHoursStart: "23:00",
      quietHoursEnd: "07:30",
      quietHoursTimeZone: "Asia/Shanghai",
      updatedAt: "2026-07-10T00:00:00.000Z"
    });
    vi.spyOn(opsClient, "previewTemplate").mockResolvedValue({
      subject: "Stacio 已处理：登录崩溃",
      html: "<p>问题已经修复。</p>",
      text: "问题已经修复。"
    });
    vi.spyOn(opsClient, "sendNotification").mockResolvedValue({ id: "job_1" });
    vi.spyOn(opsClient, "notificationDeliveries").mockResolvedValue([
      {
        id: "delivery_1",
        notificationId: "notification_1",
        provider: "smtp",
        attempt: 1,
        status: "Dry Run",
        providerMessageId: undefined,
        error: undefined,
        sentAt: undefined,
        createdAt: "2026/07/10"
      }
    ]);
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("edits a template, creates a notification, previews, and guards real delivery", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("SEND");
    render(<NotificationsPage />);

    expect(await screen.findByText("feedback_reply")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("邮件主题模板"), {
      target: { value: "Stacio 已处理：{{feedback.title}}" }
    });
    fireEvent.change(screen.getByLabelText("HTML 模板"), {
      target: { value: "<p>{{reply.body}}</p>" }
    });
    fireEvent.change(screen.getByLabelText("纯文本模板"), {
      target: { value: "{{reply.body}}" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存邮件模板" }));

    await waitFor(() => {
      expect(opsClient.upsertNotificationTemplate).toHaveBeenCalledWith(
        "stacio",
        "feedback_reply",
        {
          subjectTemplate: "Stacio 已处理：{{feedback.title}}",
          htmlTemplate: "<p>{{reply.body}}</p>",
          textTemplate: "{{reply.body}}",
          status: "active"
        }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "创建通知" }));
    fireEvent.change(screen.getByLabelText("通知类型"), {
      target: { value: "customer_license_issued" }
    });
    fireEvent.change(screen.getByLabelText("收件邮箱"), {
      target: { value: "licensee@example.com" }
    });
    fireEvent.change(screen.getByLabelText("通知优先级"), {
      target: { value: "normal" }
    });
    fireEvent.change(screen.getByLabelText("通知 Payload JSON"), {
      target: { value: "{\"license\":{\"plan\":\"Pro\"}}" }
    });
    fireEvent.click(screen.getByRole("button", { name: "加入通知队列" }));

    await waitFor(() => {
      expect(opsClient.createNotification).toHaveBeenCalledWith(
        "stacio",
        {
          type: "customer_license_issued",
          recipient: "licensee@example.com",
          payload: { license: { plan: "Pro" } },
          priority: "normal",
          status: "queued"
        }
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "预览当前模板" }));
    expect(await screen.findByText("Stacio 已处理：登录崩溃")).toBeInTheDocument();
    await waitFor(() => {
      expect(opsClient.previewTemplate).toHaveBeenCalledWith(expect.objectContaining({ productId: "stacio" }));
    });
    const previewPayload = vi.mocked(opsClient.previewTemplate).mock.calls[0][0];
    expect(previewPayload.payload).not.toHaveProperty("brand");

    fireEvent.click(screen.getByRole("button", { name: "Dry-run customer@example.com" }));
    await waitFor(() => {
      expect(opsClient.sendNotification).toHaveBeenCalledWith(
        "notification_1",
        true,
        "queue",
        "stacio"
      );
    });

    fireEvent.click(screen.getByRole("button", { name: "发送 customer@example.com" }));
    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.sendNotification).toHaveBeenCalledWith(
        "notification_1",
        false,
        "queue",
        "stacio"
      );
    });
  });

  it("loads and displays notification delivery history", async () => {
    render(<NotificationsPage />);

    expect(await screen.findByText("customer@example.com")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "投递历史 customer@example.com" }));

    await waitFor(() => {
      expect(opsClient.notificationDeliveries).toHaveBeenCalledWith(
        "stacio",
        "notification_1"
      );
    });

    expect(await screen.findByText("投递历史")).toBeInTheDocument();
    expect(screen.getByText("Attempt 1")).toBeInTheDocument();
    expect(screen.getByText("Dry Run")).toBeInTheDocument();
    expect(screen.getByText("smtp")).toBeInTheDocument();
  });

  it("creates an admin daily feedback digest notification from the digest shortcut", async () => {
    render(<NotificationsPage />);

    expect(await screen.findByText("feedback_reply")).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("日报收件邮箱"), {
      target: { value: "ops@example.com" }
    });
    fireEvent.click(screen.getByRole("button", { name: "生成反馈日报" }));

    await waitFor(() => {
      expect(opsClient.createDailyFeedbackDigest).toHaveBeenCalledWith(
        "stacio",
        {
          recipient: "ops@example.com"
        }
      );
    });
    expect(await screen.findByText("反馈日报已加入队列")).toBeInTheDocument();
  });

  it("creates customer license expiration reminders from the notification shortcut", async () => {
    render(<NotificationsPage />);

    expect(await screen.findByText("feedback_reply")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "生成 License 到期提醒" }));

    await waitFor(() => {
      expect(opsClient.createLicenseExpiringReminders).toHaveBeenCalledWith(
        "stacio",
        {
          days: 30
        }
      );
    });
    expect(await screen.findByText("License 到期提醒已加入队列：新增 1，跳过 1")).toBeInTheDocument();
    expect(screen.getByText("pro@example.com")).toBeInTheDocument();
  });

  it("loads and updates admin quiet-hours notification policy", async () => {
    render(<NotificationsPage />);

    expect(await screen.findByText("22:00 - 08:00")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("静默开始"), {
      target: { value: "23:00" }
    });
    fireEvent.change(screen.getByLabelText("静默结束"), {
      target: { value: "07:30" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存静默策略" }));

    await waitFor(() => {
      expect(opsClient.updateNotificationPolicy).toHaveBeenCalledWith(
        "stacio",
        {
          quietHoursEnabled: true,
          quietHoursStart: "23:00",
          quietHoursEnd: "07:30",
          quietHoursTimeZone: "Asia/Shanghai"
        }
      );
    });
    expect(await screen.findByText("静默策略已保存")).toBeInTheDocument();
  });

  it("offers an explicit retry action for failed notifications", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("SEND");
    vi.mocked(opsClient.notifications).mockResolvedValue([
      {
        ...notification,
        id: "notification_failed",
        recipient: "failed@example.com",
        status: "Failed"
      }
    ]);

    render(<NotificationsPage />);

    expect(await screen.findByText("failed@example.com")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "重试 failed@example.com" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.sendNotification).toHaveBeenCalledWith(
        "notification_failed",
        false,
        "queue",
        "stacio"
      );
    });
  });
});
