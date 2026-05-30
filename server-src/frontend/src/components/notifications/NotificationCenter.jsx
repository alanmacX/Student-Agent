import { useState, useEffect, useCallback, useRef } from "react";
import { Bell, Clock, Brain, Star, RefreshCw, Send, History, Activity } from "lucide-react";
import { fetchNotifications, fetchScheduledNotifications, fetchStandbyLog } from "../../api/notifications";

function parseUTC(isoStr) {
  if (!isoStr) return new Date(0);
  const s = /[Z+]/.test(isoStr) ? isoStr : isoStr + "Z";
  return new Date(s);
}

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

function relativeTime(isoStr) {
  if (!isoStr) return "";
  const diff = Date.now() - parseUTC(isoStr).getTime();
  const mins = Math.floor(diff / 60000);
  const hours = Math.floor(mins / 60);
  const days = Math.floor(hours / 24);
  if (days > 0) return `${days} 天前`;
  if (hours > 0) return `${hours} 小时前`;
  if (mins > 0) return `${mins} 分钟前`;
  return "刚刚";
}

function dayKey(isoStr) {
  if (!isoStr) return "未知日期";
  const d = parseUTC(isoStr);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return "今天";
  if (d.toDateString() === yesterday.toDateString()) return "昨天";
  return d.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });
}

function groupByDay(notifications) {
  const groups = [];
  const seen = {};
  for (const item of notifications) {
    const key = dayKey(item.sent_at);
    if (!seen[key]) {
      seen[key] = [];
      groups.push({ label: key, items: seen[key] });
    }
    seen[key].push(item);
  }
  return groups;
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
      <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-2xl bg-white/8">
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
    <div className="glass-card flex gap-3 px-4 py-3">
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
    <div className="stagger mx-auto flex w-full max-w-2xl flex-col gap-5">
      {groups.map(({ label, items }) => (
        <div key={label}>
          <p className="mb-1.5 px-1 text-[11px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">
            {label}
          </p>
          <div className="glass-card overflow-hidden">
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
    <div className="stagger mx-auto flex w-full max-w-2xl flex-col gap-3">
      {items.map((item) => (
        <div key={item.id} className="glass-card px-4 py-3">
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
    <div className="stagger mx-auto flex w-full max-w-2xl flex-col gap-2">
      {items.map((item) => (
        <div key={item.id} className="glass-card px-4 py-3">
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
  const diff = parseUTC(isoStr).getTime() - Date.now();
  if (diff < 0) return "已到期";
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return `${mins}min 后`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h 后`;
  const days = Math.floor(hours / 24);
  return `${days}天后`;
}

export default function NotificationCenter() {
  const [activeTab, setActiveTab] = useState("sent");
  const [notifications, setNotifications] = useState([]);
  const [scheduled, setScheduled] = useState([]);
  const [standbyLog, setStandbyLog] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [refreshing, setRefreshing] = useState(false);
  const pollRef = useRef(null);

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
    }
  }, []);

  useEffect(() => {
    load();

    const startPolling = () => {
      pollRef.current = window.setInterval(() => load(true), POLL_INTERVAL);
    };
    const stopPolling = () => {
      if (pollRef.current) {
        window.clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };

    const onVisibilityChange = () => {
      if (document.hidden) {
        stopPolling();
      } else {
        load(true);
        startPolling();
      }
    };

    startPolling();
    document.addEventListener("visibilitychange", onVisibilityChange);
    const onAppRefresh = () => load(true);
    window.addEventListener("app-refresh", onAppRefresh);

    return () => {
      stopPolling();
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("app-refresh", onAppRefresh);
    };
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
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 mx-auto flex w-full max-w-2xl items-center justify-between gap-2 px-3 pt-3 md:px-6">
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
      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-36 md:pb-4 md:px-6">
      {/* Tabs — glass segmented control */}
      <div className="mx-auto w-full max-w-2xl shrink-0">
        <div className="glass-pill flex gap-1 rounded-full p-1.5">
          {tabs.map(({ id, label, icon: Icon, count }) => (
            <button
              key={id}
              onClick={() => setActiveTab(id)}
              className={`flex flex-1 items-center justify-center gap-1.5 rounded-full px-3 py-2 text-xs font-medium transition-colors duration-200 ${
                activeTab === id
                  ? "bg-[var(--hover-bg)] text-white shadow-sm"
                  : "text-[var(--text-tertiary)] hover:text-[var(--text-secondary)]"
              }`}
            >
              <Icon size={13} />
              <span className="hidden sm:inline">{label}</span>
              {count > 0 && (
                <span className="rounded-full bg-[var(--surface-2)] px-1.5 py-0.5 text-[10px]">{count}</span>
              )}
            </button>
          ))}
        </div>
      </div>

      {/* Stats (sent tab only) */}
      {!loading && !error && activeTab === "sent" && (
        <div className="mx-auto w-full max-w-2xl pt-2">
          <StatsBar notifications={notifications} />
        </div>
      )}

      {/* Body */}
      <div className="mx-auto w-full max-w-2xl pt-3">
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
  );
}
