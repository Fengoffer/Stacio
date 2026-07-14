import { useEffect, useState, type FormEvent } from "react";
import { opsClient, type CurrentUserRecord } from "../api/client";

interface AccountPageProps {
  onReauthenticationRequired: () => void;
}

export function AccountPage({ onReauthenticationRequired }: AccountPageProps) {
  const [user, setUser] = useState<CurrentUserRecord | null>(null);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    let mounted = true;
    void opsClient
      .currentUser()
      .then((nextUser) => {
        if (!mounted) {
          return;
        }
        setUser(nextUser);
        setName(nextUser.name);
        setEmail(nextUser.email);
        setError("");
      })
      .catch((nextError: unknown) => {
        if (mounted) {
          setError(nextError instanceof Error ? nextError.message : "账号信息加载失败");
        }
      })
      .finally(() => {
        if (mounted) {
          setLoading(false);
        }
      });
    return () => {
      mounted = false;
    };
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    setError("");
    if (newPassword && newPassword !== confirmPassword) {
      setError("两次输入的新密码不一致");
      return;
    }

    setSaving(true);
    try {
      const result = await opsClient.updateCurrentUser({
        name: name.trim(),
        email: email.trim(),
        currentPassword,
        ...(newPassword ? { newPassword } : {})
      });
      setCurrentPassword("");
      setNewPassword("");
      setConfirmPassword("");
      if (result.reauthenticationRequired) {
        onReauthenticationRequired();
        return;
      }
      setUser(result.user);
      setName(result.user.name);
      setEmail(result.user.email);
      setMessage("账号信息已保存");
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "账号信息保存失败");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="page">
      <div className="page-heading">
        <div>
          <p className="eyebrow">Account</p>
          <h1>我的账号</h1>
          <p>修改登录资料或更新密码。修改邮箱或密码后需要重新登录。</p>
        </div>
      </div>

      {error ? <div className="error-banner" role="alert">{error}</div> : null}
      {message ? <p className="action-message">{message}</p> : null}

      <form className="panel product-form account-form" onSubmit={(event) => void submit(event)}>
        <div className="panel-header">
          <div>
            <h2>账号资料</h2>
            <p>{loading ? "正在加载账号信息" : user?.roles.join(" / ") || "-"}</p>
          </div>
        </div>
        <div className="form-grid">
          <label>
            <span>姓名</span>
            <input
              aria-label="姓名"
              disabled={loading || saving}
              onChange={(event) => setName(event.target.value)}
              required
              value={name}
            />
          </label>
          <label>
            <span>登录邮箱</span>
            <input
              aria-label="登录邮箱"
              disabled={loading || saving}
              onChange={(event) => setEmail(event.target.value)}
              required
              type="email"
              value={email}
            />
          </label>
          <label className="form-grid-wide">
            <span>当前密码</span>
            <input
              aria-label="当前密码"
              autoComplete="current-password"
              disabled={loading || saving}
              onChange={(event) => setCurrentPassword(event.target.value)}
              required
              type="password"
              value={currentPassword}
            />
          </label>
          <label>
            <span>新密码</span>
            <input
              aria-label="新密码"
              autoComplete="new-password"
              disabled={loading || saving}
              minLength={8}
              onChange={(event) => setNewPassword(event.target.value)}
              placeholder="留空则不修改"
              type="password"
              value={newPassword}
            />
          </label>
          <label>
            <span>确认新密码</span>
            <input
              aria-label="确认新密码"
              autoComplete="new-password"
              disabled={loading || saving}
              minLength={8}
              onChange={(event) => setConfirmPassword(event.target.value)}
              placeholder="再次输入新密码"
              type="password"
              value={confirmPassword}
            />
          </label>
        </div>
        <div className="form-actions">
          <button className="primary-button" disabled={loading || saving} type="submit">
            {saving ? "保存中" : "保存账号信息"}
          </button>
        </div>
      </form>
    </div>
  );
}
