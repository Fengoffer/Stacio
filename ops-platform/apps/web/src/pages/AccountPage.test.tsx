// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { AccountPage } from "./AccountPage";

const owner = {
  id: "usr_owner",
  email: "owner@stacio.local",
  name: "Stacio Owner",
  roles: ["owner"],
  permissions: ["*"],
  productIds: []
};

describe("AccountPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "currentUser").mockResolvedValue(owner);
    vi.spyOn(opsClient, "updateCurrentUser").mockResolvedValue({
      user: {
        ...owner,
        email: "admin@stacio.example"
      },
      reauthenticationRequired: true
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("requires the current password and sends a credential update before reauthentication", async () => {
    const onReauthenticationRequired = vi.fn();
    render(<AccountPage onReauthenticationRequired={onReauthenticationRequired} />);

    expect(await screen.findByLabelText("登录邮箱")).toHaveValue("owner@stacio.local");
    fireEvent.change(screen.getByLabelText("登录邮箱"), {
      target: { value: "admin@stacio.example" }
    });
    fireEvent.change(screen.getByLabelText("当前密码"), {
      target: { value: "change-me-now" }
    });
    fireEvent.change(screen.getByLabelText("新密码"), {
      target: { value: "updated-owner-password" }
    });
    fireEvent.change(screen.getByLabelText("确认新密码"), {
      target: { value: "updated-owner-password" }
    });
    fireEvent.click(screen.getByRole("button", { name: "保存账号信息" }));

    await waitFor(() => {
      expect(opsClient.updateCurrentUser).toHaveBeenCalledWith({
        name: "Stacio Owner",
        email: "admin@stacio.example",
        currentPassword: "change-me-now",
        newPassword: "updated-owner-password"
      });
      expect(onReauthenticationRequired).toHaveBeenCalledTimes(1);
    });
  });
});
