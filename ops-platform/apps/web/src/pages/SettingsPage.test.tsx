// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { SettingsPage } from "./SettingsPage";

const summary = {
  productId: "stacio",
  persistence: "postgres",
  smtpConfigured: true,
  objectStorageConfigured: true,
  redisConfigured: true,
  bootstrapOwnerConfigured: true,
  roleCount: 4,
  userCount: 1,
  apiKeyCount: 1,
  policy: {
    otaRequiresManualConfirmation: true,
    agentDangerousActionsBlocked: true,
    licenseOfflineGraceDays: 14
  }
};

const operatorUser = {
  id: "usr_operator",
  email: "operator@example.com",
  name: "Support Operator",
  status: "Active",
  roles: ["operator"],
  permissions: ["feedback:read"],
  productIds: ["stacio"],
  role: "operator",
  productScope: "stacio",
  createdAt: "2026/07/10"
};

const agentKey = {
  id: "agent_key_existing",
  name: "Codex feedback triage",
  keyPrefix: "agent_abcd1234",
  productIds: ["stacio"],
  productScope: "stacio",
  scopes: ["feedback:read"],
  scopeSummary: "feedback:read",
  status: "Active",
  createdAt: "2026/07/10"
};

const disabledOperatorUser = {
  ...operatorUser,
  id: "usr_disabled_operator",
  email: "disabled-operator@example.com",
  status: "Disabled"
};

const disabledAgentKey = {
  ...agentKey,
  id: "agent_key_disabled",
  name: "Disabled Codex key",
  status: "Disabled"
};

describe("SettingsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "settingsSummary").mockResolvedValue(summary);
    vi.spyOn(opsClient, "adminRoles").mockResolvedValue([
      {
        id: "role_operator",
        name: "operator",
        description: "Triage feedback",
        permissions: ["feedback:read"]
      }
    ]);
    vi.spyOn(opsClient, "adminUsers").mockResolvedValue([operatorUser]);
    vi.spyOn(opsClient, "createAdminUser").mockResolvedValue(operatorUser);
    vi.spyOn(opsClient, "updateAdminUser").mockResolvedValue({
      ...operatorUser,
      status: "Disabled"
    });
    vi.spyOn(opsClient, "agentApiKeys").mockResolvedValue([agentKey]);
    vi.spyOn(opsClient, "createAgentApiKey").mockResolvedValue({
      ...agentKey,
      id: "agent_key_created",
      oneTimeKey: "agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    });
    vi.spyOn(opsClient, "updateAgentApiKey").mockResolvedValue({
      ...agentKey,
      status: "Disabled"
    });
    vi.spyOn(opsClient, "rotateAgentApiKey").mockResolvedValue({
      ...agentKey,
      keyPrefix: "agent_bbbbbbbbb",
      oneTimeKey: "agent_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("creates and disables admin users from system settings", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("DISABLE");
    render(<SettingsPage />);

    expect(await screen.findByText("operator@example.com")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "新建后台用户" }));
    fireEvent.change(screen.getByLabelText("用户邮箱"), {
      target: { value: "operator@example.com" }
    });
    fireEvent.change(screen.getByLabelText("用户姓名"), {
      target: { value: "Support Operator" }
    });
    fireEvent.change(screen.getByLabelText("初始密码"), {
      target: { value: "operator-password" }
    });
    fireEvent.change(screen.getByLabelText("用户角色"), {
      target: { value: "operator" }
    });
    fireEvent.change(screen.getByLabelText("产品范围"), {
      target: { value: "stacio" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建后台用户" }));

    await waitFor(() => {
      expect(opsClient.createAdminUser).toHaveBeenCalledWith({
        email: "operator@example.com",
        name: "Support Operator",
        password: "operator-password",
        role: "operator",
        productIds: ["stacio"]
      });
    });

    fireEvent.click(screen.getByRole("button", { name: "停用 operator@example.com" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.updateAdminUser).toHaveBeenCalledWith("usr_operator", {
        status: "disabled",
        confirmation: "DISABLE"
      });
    });
  });

  it("enables disabled admin users from system settings", async () => {
    vi.mocked(opsClient.adminUsers).mockResolvedValue([disabledOperatorUser]);
    vi.mocked(opsClient.updateAdminUser).mockResolvedValue({
      ...disabledOperatorUser,
      status: "Active"
    });
    vi.spyOn(window, "prompt").mockReturnValue("ENABLE");
    render(<SettingsPage />);

    expect(await screen.findByText("disabled-operator@example.com")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "启用 disabled-operator@example.com" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.updateAdminUser).toHaveBeenCalledWith("usr_disabled_operator", {
        status: "active",
        confirmation: "ENABLE"
      });
    });
  });

  it("generates scoped Agent API key JSON for Docker environment configuration", async () => {
    render(<SettingsPage />);

    expect(await screen.findByText("operator@example.com")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "生成 Agent Key 配置" }));
    fireEvent.change(screen.getByLabelText("Agent Key ID"), {
      target: { value: "codex-triage" }
    });
    fireEvent.change(screen.getByLabelText("Agent Key 名称"), {
      target: { value: "Codex feedback triage" }
    });
    fireEvent.change(screen.getByLabelText("Agent 产品范围"), {
      target: { value: "stacio" }
    });
    fireEvent.change(screen.getByLabelText("Agent Scope 模板"), {
      target: { value: "feedback_triage" }
    });
    fireEvent.click(screen.getByRole("button", { name: "生成配置" }));

    const output = screen.getByLabelText("AGENT_API_KEYS_JSON") as HTMLTextAreaElement;
    const parsed = JSON.parse(output.value);
    expect(parsed).toEqual([
      expect.objectContaining({
        id: "codex-triage",
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: expect.arrayContaining([
          "feedback:read",
          "feedback:write_analysis",
          "feedback:write_draft",
          "issues:read",
          "actions:propose"
        ])
      })
    ]);
    expect(parsed[0].key).toMatch(/^agent_[a-f0-9]{48}$/);
  });

  it("creates and disables persisted Agent API keys from system settings", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("DISABLE");
    render(<SettingsPage />);

    expect(await screen.findByText("Codex feedback triage")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "新建 Agent Key" }));
    fireEvent.change(screen.getByLabelText("后台 Agent Key 名称"), {
      target: { value: "Codex feedback triage" }
    });
    fireEvent.change(screen.getByLabelText("后台 Agent 产品范围"), {
      target: { value: "stacio" }
    });
    fireEvent.change(screen.getByLabelText("后台 Agent Scopes"), {
      target: { value: "feedback:read, actions:propose" }
    });
    fireEvent.click(screen.getByRole("button", { name: "创建 Agent Key" }));

    await waitFor(() => {
      expect(opsClient.createAgentApiKey).toHaveBeenCalledWith({
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: ["feedback:read", "actions:propose"]
      });
    });
    expect(screen.getByText("agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "停用 Agent Key Codex feedback triage" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.updateAgentApiKey).toHaveBeenCalledWith("agent_key_existing", {
        status: "disabled",
        confirmation: "DISABLE"
      });
    });
  });

  it("enables disabled persisted Agent API keys from system settings", async () => {
    vi.mocked(opsClient.agentApiKeys).mockResolvedValue([disabledAgentKey]);
    vi.mocked(opsClient.updateAgentApiKey).mockResolvedValue({
      ...disabledAgentKey,
      status: "Active"
    });
    vi.spyOn(window, "prompt").mockReturnValue("ENABLE");
    render(<SettingsPage />);

    expect(await screen.findByText("Disabled Codex key")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "启用 Agent Key Disabled Codex key" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.updateAgentApiKey).toHaveBeenCalledWith("agent_key_disabled", {
        status: "active",
        confirmation: "ENABLE"
      });
    });
  });

  it("rotates persisted Agent API keys from system settings", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("ROTATE");
    render(<SettingsPage />);

    expect(await screen.findByText("Codex feedback triage")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "轮换 Agent Key Codex feedback triage" }));

    await waitFor(() => {
      expect(window.prompt).toHaveBeenCalled();
      expect(opsClient.rotateAgentApiKey).toHaveBeenCalledWith("agent_key_existing", {
        confirmation: "ROTATE"
      });
    });
    expect(screen.getByText("agent_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")).toBeInTheDocument();
  });

  it("shows role permission inventory for admin access review", async () => {
    render(<SettingsPage />);

    expect(await screen.findByText("角色权限")).toBeInTheDocument();
    expect(screen.getAllByText("operator").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("Triage feedback")).toBeInTheDocument();
    expect(screen.getAllByText("feedback:read").length).toBeGreaterThanOrEqual(1);
  });

  it("surfaces settings loading failures to operators", async () => {
    vi.mocked(opsClient.settingsSummary).mockRejectedValue(new Error("Settings unavailable"));

    render(<SettingsPage />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Settings unavailable");
  });
});
