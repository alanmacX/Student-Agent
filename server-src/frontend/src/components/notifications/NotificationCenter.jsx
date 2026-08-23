import { useState, useEffect, useCallback, useRef } from "react";
import { Bell, Clock, Brain, Star, RefreshCw, Send, History, Activity } from "lucide-react";
import { fetchNotifications, fetchScheduledNotifications, fetchStandbyLog } from "../../api/notifications";
import { relativeTime, dayKey, groupByDay, timeUntil } from "../../lib/time";
import { useVisibilityPoll } from "../../lib/hooks";

const POLL_INTERVAL = 30_000; // 30s

function typeIcon(notifType) {
  if (!notifType) return <Bell size={16} />;
  if (notifType.startsWith("deadline")) return <Clock size={16} className="text-orange-400" />;
  if (notifType.startsWith("memory")) return <Brain size={16} className="text-purple-400" />;
  if (notifType.startsWith("standby") || notifType.startsWith("scheduled")) return <Star size={16} className="text-yellow-400" />;
  return <Bell size={16} className="text-[var(--accent)]" />;
}

function typeLabel(notifType) {
  if (!notifType) return "通知";
  if (notifType.startsWith("deadline")) return "截止提醒";
  if (notifType.startsWith("memory")) return "记忆提醒";
  if (notifType.startsWith("standby")) return "待机提醒";
  if (notifType.startsWith("scheduled")) return "定时通知";
  return notifType;
}

function StatusPill({ label, color }) {
  const colors = {
    gray: "bg-white/10 text-[var(--text-tertiary)] ring-white/10",
    blue: "bg-blue-500/20 text-blue-400 ring-blue-500/25",
    green: "bg-green-500/20 text-green-400 ring-green-500/25",
    orange: "bg-orange-500/20 text-orange-400 ring-orange-500/25",
  };
  return (
    <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-medium ring-1 ${colors[color] || colors.gray}`}>
      {label}
    </span>
  );
}

function NotificationItem({ item }) {
  const title = item.title || typeLabel(item.notif_type);
  const body = item.body || item.notif_type || "";

  return (
    <div className="flex gap-3 px-4 py-3">
      <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-2xl bg-[var(--surface)]">
        {typeIcon(item.notif_type)}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-start justify-between gap-2">
          <p className="truncate text-[15px] font-medium text-white">{title}</p>
          <span className="shrink-0 text-[11px] text-[var(--text-tertiary)]">
            {relativeTime(item.sent_at)}
          </span>
        </div>
        {body && body !== title && (
          <p className="mt-0.5 line-clamp-2 text-[13px] text-[var(--text-secondary)]">{body}</p>
        )}
        <div className="mt-2 flex flex-wrap gap-1">
          <StatusPill label="已发送" color="gray" />
          {item.device_received_at && <StatusPill label="已送达" color="blue" />}
          {item.clicked_at && <StatusPill label="已点击" color="green" />}
          {item.dismissed_at && <StatusPill label="已忽略" color="orange" />}
        </div>
      </div>
    </div>
  );
}

function StatsBar({ notifications }) {
  const total = notifications.length;
  const received = notifications.filter((n) => n.device_received_at).length;
  const clicked = notifications.filter((n) => n.clicked_at).length;

  if (total === 0) return null;

  return (
    <div className="surface-card grid grid-cols-4 gap-3 px-4 py-3 lg:grid-cols-2 xl:grid-cols-4">
      {[
        { label: "总计", value: total, color: "text-white" },
        { label: "已送达", value: received, color: "text-blue-400" },
        { label: "已点击", value: clicked, color: "text-green-400" },
        { label: "送达率", value: total > 0 ? `${Math.round((received / total) * 100)}%` : "—", color: "text-[var(--text-secondary)]" },
      ].map(({ label, value, color }) => (
        <div key={label} className="flex-1 text-center">
          <p className={`text-base font-bold tabular-nums ${color}`}>{value}</p>
          <p className="text-[11px] text-[var(--text-tertiary)]">{label}</p>
        </div>
      ))}
    </div>
  );
}

function SentTab({ groups }) {
  if (groups.length === 0) {
    return (
      <div className="flex h-full items-center justify-center text-[var(--text-tertiary)]">
        <div className="text-center">
          <Bell size={36} className="mx-auto mb-3 opacity-30" />
          <p className="text-sm font-medium text-[var(--text-secondary)]">暂无通知记录</p>
          <p className="mt-1 text-xs">推送通知的历史记录会显示在这里</p>
        </div>
      </div>
    );
  }
  return (
    <div className="stagger mx-auto flex w-full flex-col gap-5">
      {groups.map(({ label, items }) => (
        <div key={label}>
          <p className="mb-1.5 px-1 text-[11px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">
            {label}
          </p>
          <div className="surface-card overflow-hidden">
            {items.map((item, idx) => (
              <div key={item.id} className={idx < items.length - 1 ? "border-b border-[rgba(255,255,255,0.07)]" : ""}>
                <NotificationItem item={item} />
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

function ScheduledTab({ items }) {
  if (items.length === 0) {
    return (
      <div className="flex h-full items-center justify-center text-[var(--text-tertiary)]">
        <div className="text-center">
          <Send size={36} className="mx-auto mb-3 opacity-30" />
          <p className="text-sm font-medium text-[var(--text-secondary)]">暂无待发送通知</p>
          <p className="mt-1 text-xs">系统会自动安排学习通消息和截止提醒的推送</p>
        </div>
      </div>
    );
  }
  return (
    <div className="stagger mx-auto flex w-full flex-col gap-3">
      {items.map((item) => (
        <div key={item.id} className="surface-card px-4 py-3">
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0 flex-1">
              <p className="text-sm font-medium text-white truncate">{item.title || "未命名通知"}</p>
              {item.body && <p className="mt-0.5 text-xs text-[var(--text-tertiary)] line-clamp-2">{item.body}</p>}
            </div>
            <span className="shrink-0 text-[11px] text-[var(--text-tertiary)]">
              {item.scheduled_at ? formatScheduledTime(item.scheduled_at) : ""}
            </span>
          </div>
          <div className="mt-2 flex items-center gap-2">
            <span className="rounded-full bg-blue-500/20 px-2 py-0.5 text-[10px] text-blue-400 ring-1 ring-blue-500/25">
              {item.source_type || "scheduled"}
            </span>
          </div>
        </div>
      ))}
    </div>
  );
}

function StandbyTab({ items }) {
  if (items.length === 0) {
    return (
      <div className="flex h-full items-center justify-center text-[var(--text-tertiary)]">
        <div className="text-center">
          <Activity size={36} className="mx-auto mb-3 opacity-30" />
          <p className="text-sm font-medium text-[var(--text-secondary)]">暂无决策日志</p>
          <p className="mt-1 text-xs">Standby Agent 每 15 分钟检查一次是否需要推送</p>
        </div>
      </div>
    );
  }
  return (
    <div className="stagger mx-auto flex w-full flex-col gap-2">
      {items.map((item) => (
        <div key={item.id} className="surface-card px-4 py-3">
          <div className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-2">
              <DecisionBadge decision={item.decision} />
              <span className="text-xs text-[var(--text-tertiary)]">
                {item.model || "unknown"}
              </span>
            </div>
            <span className="text-[11px] text-[var(--text-tertiary)]">
              {item.created_at ? relativeTime(item.created_at) : ""}
            </span>
          </div>
          {item.reason && (
            <p className="mt-1.5 text-xs text-[var(--text-secondary)] line-clamp-2">{item.reason}</p>
          )}
          <div className="mt-1.5 flex items-center gap-3 text-[10px] text-[var(--text-tertiary)]">
            {item.input_tokens > 0 && <span>输入 {item.input_tokens} tok</span>}
            {item.output_tokens > 0 && <span>输出 {item.output_tokens} tok</span>}
            {item.duration_ms > 0 && <span>{(item.duration_ms / 1000).toFixed(1)}s</span>}
          </div>
        </div>
      ))}
    </div>
  );
}

function DecisionBadge({ decision }) {
  const meta = {
    push: { label: "推送", color: "bg-green-500/20 text-green-400 ring-green-500/25" },
    no_action: { label: "无操作", color: "bg-[var(--surface-2)] text-[var(--text-tertiary)] ring-white/10" },
    skipped_no_change: { label: "跳过", color: "bg-yellow-500/20 text-yellow-400 ring-yellow-500/25" },
    error: { label: "错误", color: "bg-red-500/20 text-red-400 ring-red-500/25" },
  };
  const m = meta[decision] || meta.no_action;
  return (
    <span className={`rounded-full px-2 py-0.5 text-[10px] font-medium ring-1 ${m.color}`}>
      {m.label}
    </span>
  );
}

function formatScheduledTime(isoStr) {
  return timeUntil(isoStr);
}

export default function NotificationCenter() {
  const [activeTab, setActiveTab] = useState("sent");
  const [notifications, setNotifications] = useState([]);
  const [scheduled, setScheduled] = useState([]);
  const [standbyLog, setStandbyLog] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true);
    else setLoading(true);
    setError(null);
    try {
      const [notifResult, schedResult, standbyResult] = await Promise.allSettled([
        fetchNotifications(100),
        fetchScheduledNotifications(50),
        fetchStandbyLog(30),
      ]);
      setNotifications(notifResult.status === "fulfilled" && Array.isArray(notifResult.value) ? notifResult.value : []);
      setScheduled(schedResult.status === "fulfilled" && Array.isArray(schedResult.value) ? schedResult.value : []);
      setStandbyLog(standbyResult.status === "fulfilled" && Array.isArray(standbyResult.value) ? standbyResult.value : []);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
      setRefreshing(false);
      window.dispatchEvent(new CustomEvent("app-refresh-done", { detail: { tab: "notifications" } }));
    }
  }, []);

  // Poll every 30s while visible; auto-pauses when hidden.
  useVisibilityPoll(() => load(true), POLL_INTERVAL);

  useEffect(() => {
    load();
    const onAppRefresh = (event) => {
      if (!event.detail?.tab || event.detail.tab === "notifications") load(true);
    };
    window.addEventListener("app-refresh", onAppRefresh);
    return () => window.removeEventListener("app-refresh", onAppRefresh);
  }, [load]);

  const groups = groupByDay(notifications);

  const tabs = [
    { id: "sent", label: "已发送", icon: History, count: notifications.length },
    { id: "scheduled", label: "待发送", icon: Send, count: scheduled.length },
    { id: "standby", label: "决策日志", icon: Activity, count: standbyLog.length },
  ];

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)]">
      {/* Header — floating island over the scrolling content */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 mx-auto flex w-full max-w-[1500px] items-center justify-between gap-2 px-3 pt-3 md:px-6 xl:px-8">
        <div className="glass-pill pointer-events-auto flex min-h-[48px] items-center rounded-full px-5 py-2">
          <h2 className="text-sm font-semibold text-white">通知</h2>
        </div>
        <button
          onClick={() => load(true)}
          disabled={refreshing}
          className="glass-pill pointer-events-auto grid h-12 w-12 shrink-0 place-items-center rounded-full text-[var(--text-secondary)] transition-all duration-200 ease-[var(--ease-spring)] hover:scale-105 hover:border-[var(--glass-border-bright)] hover:text-white active:scale-90 disabled:opacity-50"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={refreshing ? "animate-spin" : ""} />
        </button>
      </div>

      {/* Scroll body — content flows beneath the floating header */}
      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-36 md:pb-4 md:px-6 xl:px-8">
        <div className="mx-auto grid w-full max-w-[1500px] gap-4 lg:grid-cols-[300px_minmax(0,1fr)] xl:grid-cols-[340px_minmax(0,1fr)]">
          <aside className="min-w-0 space-y-3 lg:sticky lg:top-3 lg:self-start">
            {/* Tabs — glass segmented control */}
            <div className="glass-pill flex gap-1 rounded-full p-1.5 lg:flex-col lg:rounded-2xl">
              {tabs.map(({ id, label, icon: Icon, count }) => (
                <button
                  key={id}
                  onClick={() => setActiveTab(id)}
                  className={`flex flex-1 items-center justify-center gap-1.5 rounded-full px-3 py-2 text-xs font-medium transition-colors duration-200 lg:justify-start lg:rounded-xl lg:px-3.5 ${
                    activeTab === id
                      ? "bg-[var(--hover-bg)] text-white shadow-sm"
                      : "text-[var(--text-tertiary)] hover:text-[var(--text-secondary)]"
                  }`}
                >
                  <Icon size={13} />
                  <span className="hidden sm:inline">{label}</span>
                  {count > 0 && (
                    <span className="rounded-full bg-[var(--surface-2)] px-1.5 py-0.5 text-[10px] lg:ml-auto">{count}</span>
                  )}
                </button>
              ))}
            </div>

            {!loading && !error && activeTab === "sent" && (
              <StatsBar notifications={notifications} />
            )}
          </aside>

          <div className="min-w-0">
            {loading && (
              <div className="flex items-center justify-center py-20 text-[var(--text-tertiary)]">
                <div className="flex items-center gap-2 text-sm">
                  <RefreshCw size={14} className="animate-spin" />
                  加载中...
                </div>
              </div>
            )}

            {!loading && error && (
              <div className="flex items-center justify-center py-20">
                <div className="text-center text-sm text-red-400">
                  <p className="mb-2">加载失败</p>
                  <p className="text-xs text-[var(--text-tertiary)]">{error}</p>
                  <button
                    onClick={() => load()}
                    className="mt-3 rounded-xl border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
                  >
                    重试
                  </button>
                </div>
              </div>
            )}

            {!loading && !error && activeTab === "sent" && <SentTab groups={groups} />}
            {!loading && !error && activeTab === "scheduled" && <ScheduledTab items={scheduled} />}
            {!loading && !error && activeTab === "standby" && <StandbyTab items={standbyLog} />}
          </div>
        </div>
      </div>
    </div>
  );
}
