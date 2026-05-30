import { useEffect, useState } from "react";
import { Bell, BellOff, Save, Send } from "lucide-react";
import { usePush } from "../../hooks/usePush";
import { getNotificationRules, sendTestPush, updateNotificationRules } from "../../api/push";

export default function PushSettings() {
  const { supported, permission, subscribed, subscribe, unsubscribe } = usePush();
  const [testing, setTesting] = useState(false);
  const [error, setError] = useState("");
  const [rules, setRules] = useState("");
  const [savingRules, setSavingRules] = useState(false);
  const [rulesSaved, setRulesSaved] = useState(false);

  useEffect(() => {
    getNotificationRules()
      .then((data) => setRules(data.value || ""))
      .catch(console.error);
  }, []);

  const handleToggle = async () => {
    setError("");
    try {
      if (subscribed) {
        await unsubscribe();
      } else {
        const result = await subscribe();
        if (result?.error) setError(errorMessage(result.error));
      }
    } catch (e) {
      setError(e.message || "订阅推送失败。");
    }
  };

  const handleTest = async () => {
    setError("");
    setTesting(true);
    try {
      await sendTestPush();
    } catch (e) {
      console.error("Test push failed:", e);
      setError(e.message || "测试推送发送失败。");
    } finally {
      setTesting(false);
    }
  };

  const handleSaveRules = async () => {
    setSavingRules(true);
    setRulesSaved(false);
    try {
      await updateNotificationRules(rules);
      setRulesSaved(true);
      setTimeout(() => setRulesSaved(false), 2000);
    } catch (e) {
      setError(e.message || "保存推送规则失败。");
    } finally {
      setSavingRules(false);
    }
  };

  return (
    <div className="stagger max-w-2xl space-y-5">
      <h2 className="text-lg font-semibold text-white">Push Notifications</h2>

      {!supported ? (
        <div className="ui-card p-5">
          <p className="text-sm leading-6 text-[var(--text-secondary)]">
            Push notifications are not supported in this browser. On iOS, you need to add this app
            to your Home Screen first.
          </p>
        </div>
      ) : (
        <div className="space-y-4">
          {error && (
            <div className="rounded-2xl border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">
              {error}
            </div>
          )}
          <div className="flex items-center justify-between ui-card px-4 py-3.5">
            <div className="flex items-center gap-3">
              {subscribed ? <Bell size={18} className="text-[var(--accent-soft)]" /> : <BellOff size={18} className="text-[var(--text-tertiary)]" />}
              <div>
                <p className="text-sm text-white">Push Notifications</p>
                <p className="text-xs text-[var(--text-tertiary)]">
                  {subscribed ? "Active" : permission === "denied" ? "Permission denied" : "Not subscribed"}
                </p>
              </div>
            </div>
            <button
              onClick={handleToggle}
              disabled={permission === "denied"}
              className={`min-h-10 rounded-2xl px-3 text-sm transition-colors ${
                subscribed
                  ? "bg-[var(--hover-bg)] hover:bg-[var(--hover-bg-strong)]"
                  : "bg-[var(--accent)] text-white hover:bg-[var(--accent-strong)]"
              } disabled:opacity-50`}
            >
              {subscribed ? "Disable" : "Enable"}
            </button>
          </div>

          {subscribed && (
            <button
              onClick={handleTest}
              disabled={testing}
              className="flex min-h-11 items-center gap-2 rounded-2xl border border-[var(--border)] bg-[var(--surface)] px-4 text-sm transition-colors hover:bg-[var(--hover-bg)]"
            >
              <Send size={14} />
              {testing ? "Sending..." : "Send Test Notification"}
            </button>
          )}
        </div>
      )}

      <div className="ui-card space-y-3 p-5">
        <div>
          <h3 className="text-sm font-semibold text-white">Notification Rules</h3>
          <p className="mt-1 text-xs leading-relaxed text-[var(--text-tertiary)]">
            学习通 memory 产生新条目后，后台会按这段规则判断是否安排未来推送。
          </p>
        </div>
        <textarea
          value={rules}
          onChange={(e) => setRules(e.target.value)}
          className="min-h-56 w-full resize-y rounded-2xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm leading-6 text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
        <button
          onClick={handleSaveRules}
          disabled={savingRules}
          className="flex min-h-10 items-center gap-2 rounded-2xl bg-[var(--accent)] px-4 text-sm font-semibold text-white transition hover:bg-[var(--accent-strong)] disabled:opacity-60"
        >
          <Save size={14} />
          {rulesSaved ? "已保存" : savingRules ? "Saving..." : "Save Rules"}
        </button>
      </div>
    </div>
  );
}

function errorMessage(code) {
  return {
    not_supported: "当前浏览器不支持 Web Push。iOS 需要先添加到主屏幕再打开。",
    denied: "浏览器通知权限被拒绝了，需要在浏览器/系统设置里重新允许。",
    missing_vapid_key: "服务端缺少 VAPID public key，无法创建推送订阅。",
  }[code] || "订阅推送失败。";
}
