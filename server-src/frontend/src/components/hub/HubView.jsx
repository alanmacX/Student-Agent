import { useEffect, useMemo, useRef, useState } from "react";
import {
  Activity,
  AlertTriangle,
  ArrowUpRight,
  CalendarDays,
  CheckCircle2,
  Circle,
  Clock3,
  Gauge,
  Lightbulb,
  ListChecks,
  Plus,
  RefreshCw,
  ShieldCheck,
  Sparkles,
  StickyNote,
  TimerReset,
  Trash2,
} from "lucide-react";
import { apiFetch } from "../../api/client";
import RemindersPanel from "../settings/RemindersPanel";

export default function HubView() {
  const [notes, setNotes] = useState([]);
  const [input, setInput] = useState("");
  const [dashboard, setDashboard] = useState(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [dashboardError, setDashboardError] = useState("");
  const dashboardRef = useRef(null);

  const refreshDashboard = async ({ soft = false } = {}) => {
    const hasDashboard = dashboardRef.current !== null;
    if (soft || hasDashboard) setRefreshing(true);
    else setLoading(true);
    setDashboardError("");
    try {
      const next = await apiFetch("/api/dashboard/today");
      dashboardRef.current = next;
      setDashboard(next);
    } catch (e) {
      console.error("Failed to load dashboard:", e);
      setDashboardError("今天的面板暂时没拉下来。");
    } finally {
      setLoading(false);
      setRefreshing(false);
      window.dispatchEvent(new CustomEvent("app-refresh-done", { detail: { tab: "hub" } }));
    }
  };

  const loadIdeas = async () => {
    try {
      setNotes(await apiFetch("/api/ideas"));
    } catch (e) {
      console.error("Failed to load ideas:", e);
    }
  };

  const addNote = async () => {
    const text = input.trim();
    if (!text) return;
    setInput("");
    try {
      const created = await apiFetch("/api/ideas", { method: "POST", body: JSON.stringify({ text }) });
      if (created?.id) setNotes((prev) => [created, ...prev]);
    } catch (e) {
      console.error("Failed to save idea:", e);
    }
  };

  const deleteNote = async (id) => {
    setNotes((prev) => prev.filter((n) => n.id !== id));
    try {
      await apiFetch(`/api/ideas/${id}`, { method: "DELETE" });
    } catch (e) {
      console.error("Failed to delete idea:", e);
    }
  };

  useEffect(() => {
    refreshDashboard();
    loadIdeas();
    const handler = (event) => {
      if (event.detail?.tab && event.detail.tab !== "hub") return;
      refreshDashboard({ soft: true });
      loadIdeas();
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, []);

  const timeline = useMemo(() => buildTimeline(dashboard), [dashboard]);
  const actions = useMemo(() => buildActions(dashboard), [dashboard]);
  // "下一件事" = the next thing that hasn't passed yet. A class in session still
  // counts (compare against end_at); a finished one is skipped. Fall back to an
  // overdue item if nothing is upcoming, but never to an already-ended event.
  const nextItem = useMemo(() => {
    const nowMs = Date.now();
    const notPast = (item) => {
      const raw = item.end_at || item.start_at || item.due_at || item.sort_at;
      if (!raw) return true;
      const t = new Date(raw).getTime();
      return Number.isNaN(t) || t >= nowMs;
    };
    return (
      timeline.find((item) => !item.overdue && notPast(item)) ||
      timeline.find((item) => item.overdue) ||
      null
    );
  }, [timeline]);

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)]">
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 mx-auto flex w-full max-w-[1680px] items-center justify-between gap-2 px-3 pt-3 md:px-6 xl:px-8">
        <div className="glass-pill pointer-events-auto flex min-h-[48px] items-center rounded-full px-5 py-2">
          <Lightbulb size={16} className="mr-2 text-yellow-400" />
          <h2 className="text-sm font-semibold text-white">Hub</h2>
        </div>
        <button
          onClick={() => refreshDashboard({ soft: true })}
          className="glass-pill pointer-events-auto grid h-12 w-12 place-items-center rounded-full text-[var(--text-secondary)] hover:text-white"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={loading || refreshing ? "animate-spin" : ""} />
        </button>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-36 md:px-6 md:pb-6 xl:px-8">
        <div className="mx-auto max-w-[1680px] space-y-4 stagger">
          <CommandBand data={dashboard} loading={loading} refreshing={refreshing} error={dashboardError} nextItem={nextItem} />

          <div className="grid items-start gap-4 xl:grid-cols-[310px_minmax(0,1fr)_380px] 2xl:grid-cols-[340px_minmax(0,1fr)_420px]">
            <div className="min-w-0 space-y-4">
              <TodayPanel data={dashboard} nextItem={nextItem} />
              <BudgetPanel budget={dashboard?.budget} />
              <HealthPanel data={dashboard} />
            </div>

            <div className="min-w-0 space-y-4">
              <ActionPanel items={actions} loading={loading} />
              <TimelinePanel items={timeline} loading={loading} />
              <LongRangePanel items={dashboard?.longterm || []} />
            </div>

            <div className="min-w-0 space-y-4">
              <CapturePanel input={input} setInput={setInput} addNote={addNote} notes={notes} deleteNote={deleteNote} />
              <AuditPanel items={dashboard?.agent_audit || []} />
              <section className="surface-card animate-rise p-4" style={{ animationDelay: "110ms" }}>
                <RemindersPanel />
              </section>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function CommandBand({ data, loading, refreshing, error, nextItem }) {
  const counts = data?.counts || {};
  const tiles = [
    { label: "课程", value: counts.courses_today ?? "-", icon: CalendarDays },
    { label: "逾期", value: counts.overdue_reminders ?? "-", icon: AlertTriangle, danger: Number(counts.overdue_reminders || 0) > 0 },
    { label: "活跃", value: counts.active_memory ?? "-", icon: ListChecks },
    { label: "待发", value: counts.upcoming_notifications ?? "-", icon: TimerReset },
  ];
  return (
    <section className="surface-card animate-rise overflow-hidden">
      <div className="grid gap-0 lg:grid-cols-[minmax(0,1fr)_minmax(420px,0.9fr)]">
        <div className="p-4 md:p-5">
          <div className="flex flex-wrap items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-[var(--surface)] px-3 py-1 text-xs text-[var(--text-secondary)]">
              <Activity size={13} className="text-[var(--accent-soft)]" />
              {formatDateTitle(data?.now || data?.date)}
            </span>
            {refreshing && <span className="text-xs text-[var(--text-tertiary)]">刷新中</span>}
            {loading && <span className="text-xs text-[var(--text-tertiary)]">加载中</span>}
          </div>
          <div className="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
            {tiles.map(({ label, value, icon: Icon, danger }) => (
              <div key={label} className="min-w-0 border-t border-[var(--border)] pt-3">
                <div className="flex items-center gap-2 text-[var(--text-tertiary)]">
                  <Icon size={14} className={danger ? "text-red-400" : "text-[var(--accent-soft)]"} />
                  <span className="text-xs">{label}</span>
                </div>
                <p className={`mt-1 text-2xl font-semibold tabular-nums ${danger ? "text-red-300" : "text-white"}`}>{value}</p>
              </div>
            ))}
          </div>
          {error && <p className="mt-4 rounded-xl bg-red-500/10 px-3 py-2 text-xs text-red-300">{error}</p>}
        </div>
        <div className="border-t border-[var(--border)] p-4 md:p-5 lg:border-l lg:border-t-0">
          <SectionTitle icon={Clock3} label="下一件事" />
          {nextItem ? (
            <div className="mt-3">
              <p className="text-base font-semibold text-white">{nextItem.title}</p>
              <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-[var(--text-tertiary)]">
                <span>{formatWhen(nextItem.start_at || nextItem.due_at)}</span>
                {nextItem.location && <span>{nextItem.location}</span>}
                {nextItem.source && <span>{sourceLabel(nextItem.source)}</span>}
              </div>
              {(nextItem.detail || nextItem.overdue) && (
                <p className={`mt-3 text-sm ${nextItem.overdue ? "text-red-300" : "text-[var(--text-secondary)]"}`}>
                  {nextItem.overdue ? formatOverdue(nextItem) : nextItem.detail}
                </p>
              )}
            </div>
          ) : (
            <p className="mt-3 text-sm text-[var(--text-tertiary)]">今天没有排进来的事项。</p>
          )}
        </div>
      </div>
    </section>
  );
}

function TodayPanel({ data, nextItem }) {
  const events = (data?.plan || []).filter((item) => item.kind === "event").slice(0, 4);
  return (
    <section className="surface-card animate-rise p-4">
      <SectionTitle icon={CalendarDays} label="今天" />
      <div className="mt-3 space-y-3">
        {events.length ? events.map((item) => (
          <CompactEvent key={item.key} item={item} />
        )) : (
          <p className="text-sm text-[var(--text-tertiary)]">今天没有课程或日历事件。</p>
        )}
      </div>
      {nextItem && (
        <div className="mt-4 border-t border-[var(--border)] pt-3">
          <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">Focus</p>
          <p className="mt-1 line-clamp-2 text-sm font-medium text-white">{nextItem.title}</p>
        </div>
      )}
    </section>
  );
}

function BudgetPanel({ budget }) {
  const used = budget?.used_tokens || 0;
  const limit = budget?.daily_token_budget || 0;
  const pct = limit ? Math.min(100, Math.round((used / limit) * 100)) : 0;
  return (
    <section className="surface-card animate-rise p-4" style={{ animationDelay: "35ms" }}>
      <SectionTitle icon={Gauge} label="预算" />
      <div className="mt-3 flex items-end justify-between gap-3">
        <div>
          <p className="text-2xl font-semibold text-white tabular-nums">{pct}%</p>
          <p className="mt-1 text-xs text-[var(--text-tertiary)]">{used.toLocaleString()} / {limit.toLocaleString()} tokens</p>
        </div>
        <span className="text-xs text-[var(--text-tertiary)]">{budget?.day || ""}</span>
      </div>
      <div className="mt-3 h-2 overflow-hidden rounded-full bg-white/10">
        <div className="h-full rounded-full bg-[var(--accent)]" style={{ width: `${pct}%` }} />
      </div>
    </section>
  );
}

function HealthPanel({ data }) {
  const stale = data?.briefing_stale;
  return (
    <section className="surface-card animate-rise p-4" style={{ animationDelay: "55ms" }}>
      <SectionTitle icon={ShieldCheck} label="状态" />
      <div className="mt-3 space-y-2 text-sm">
        <StatusLine label="Dashboard Hash" value={data?.dashboard_hash || "-"} />
        <StatusLine label="Briefing" value={stale ? "刷新中" : "已缓存"} tone={stale ? "warn" : "ok"} />
        <StatusLine label="通知反馈" value={formatFeedback(data?.feedback)} />
      </div>
    </section>
  );
}

function ActionPanel({ items, loading }) {
  return (
    <section className="surface-card animate-rise p-4">
      <div className="flex items-center justify-between gap-3">
        <SectionTitle icon={Sparkles} label="行动项" />
        {loading && <RefreshCw size={14} className="animate-spin text-[var(--text-tertiary)]" />}
      </div>
      <div className="mt-3 grid gap-2 lg:grid-cols-2">
        {items.length ? items.slice(0, 6).map((item) => (
          <ActionItem key={item.key} item={item} />
        )) : (
          <p className="text-sm text-[var(--text-tertiary)]">没有需要马上处理的事项。</p>
        )}
      </div>
    </section>
  );
}

function TimelinePanel({ items, loading }) {
  return (
    <section className="surface-card animate-rise p-4" style={{ animationDelay: "45ms" }}>
      <div className="flex items-center justify-between gap-3">
        <SectionTitle icon={Clock3} label="时间线" />
        {loading && <RefreshCw size={14} className="animate-spin text-[var(--text-tertiary)]" />}
      </div>
      <div className="mt-3 divide-y divide-[var(--border)]">
        {items.length ? items.slice(0, 14).map((item) => (
          <TimelineRow key={item.key} item={item} />
        )) : (
          <p className="py-3 text-sm text-[var(--text-tertiary)]">暂无时间线事项。</p>
        )}
      </div>
    </section>
  );
}

function LongRangePanel({ items }) {
  if (!items?.length) return null;
  return (
    <section className="surface-card animate-rise p-4" style={{ animationDelay: "70ms" }}>
      <SectionTitle icon={ArrowUpRight} label="稍后" />
      <div className="mt-3 grid gap-2 md:grid-cols-2 xl:grid-cols-3">
        {items.slice(0, 6).map((item) => (
          <div key={item.key} className="border-t border-[var(--border)] pt-2">
            <p className="truncate text-sm font-medium text-white">{item.title}</p>
            <p className="mt-1 text-xs text-[var(--text-tertiary)]">{formatWhen(item.start_at || item.due_at)}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function CapturePanel({ input, setInput, addNote, notes, deleteNote }) {
  return (
    <section className="surface-card animate-rise p-4">
      <SectionTitle icon={StickyNote} label="点子" />
      <div className="mt-3 flex gap-2">
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && addNote()}
          placeholder="记个点子…"
          className="glass-input min-h-10 min-w-0 flex-1 rounded-xl px-3 text-sm"
        />
        <button
          onClick={addNote}
          disabled={!input.trim()}
          aria-label="添加点子"
          className="grid h-10 w-10 place-items-center rounded-xl bg-[var(--accent)] text-white transition hover:opacity-90 disabled:opacity-30"
        >
          <Plus size={16} />
        </button>
      </div>
      {notes.length > 0 && (
        <div className="mt-3 divide-y divide-[var(--border)]">
          {notes.slice(0, 6).map((note) => (
            <div key={note.id} className="group flex items-start gap-2 py-2">
              <p className="min-w-0 flex-1 whitespace-pre-wrap text-sm text-[var(--text-secondary)]">{note.text}</p>
              <button
                onClick={() => deleteNote(note.id)}
                className="grid h-7 w-7 shrink-0 place-items-center rounded-full text-[var(--text-tertiary)] opacity-0 transition hover:bg-[var(--hover-bg)] hover:text-red-400 group-hover:opacity-100"
                aria-label="删除点子"
              >
                <Trash2 size={13} />
              </button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function AuditPanel({ items }) {
  return (
    <section className="surface-card animate-rise p-4" style={{ animationDelay: "80ms" }}>
      <SectionTitle icon={ShieldCheck} label="执行记录" />
      <div className="mt-3 divide-y divide-[var(--border)]">
        {items?.length ? items.slice(0, 6).map((item) => (
          <div key={item.id} className="py-2">
            <div className="flex items-center justify-between gap-2">
              <p className="truncate text-sm font-medium text-white">{item.tool_name}</p>
              <span className="shrink-0 text-[11px] text-[var(--text-tertiary)]">{formatWhen(item.created_at)}</span>
            </div>
            <p className="mt-0.5 line-clamp-2 text-xs text-[var(--text-tertiary)]">{item.result_summary}</p>
          </div>
        )) : (
          <p className="py-2 text-sm text-[var(--text-tertiary)]">还没有新的执行记录。</p>
        )}
      </div>
    </section>
  );
}

function SectionTitle({ icon: Icon, label, tone = "accent" }) {
  return (
    <div className="flex items-center gap-2">
      <Icon size={14} className={tone === "danger" ? "text-red-400" : "text-[var(--accent)]"} />
      <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
        {label}
      </h3>
    </div>
  );
}

function CompactEvent({ item }) {
  return (
    <div className="border-t border-[var(--border)] pt-3">
      <div className="flex items-center justify-between gap-2">
        <p className="truncate text-sm font-semibold text-white">{item.title}</p>
        <span className="shrink-0 text-xs text-[var(--text-tertiary)]">{formatTimeRange(item)}</span>
      </div>
      {(item.location || item.detail) && <p className="mt-1 truncate text-xs text-[var(--text-tertiary)]">{item.location || item.detail}</p>}
    </div>
  );
}

function ActionItem({ item }) {
  const high = item.urgency === "high" || item.importance === "high" || item.overdue;
  return (
    <div className="min-w-0 border-t border-[var(--border)] pt-3">
      <div className="flex items-start gap-2">
        {high ? <AlertTriangle size={15} className="mt-0.5 shrink-0 text-orange-400" /> : <CheckCircle2 size={15} className="mt-0.5 shrink-0 text-[var(--accent-soft)]" />}
        <div className="min-w-0">
          <p className="line-clamp-2 text-sm font-semibold text-white">{item.title}</p>
          {(item.detail || item.when) && <p className="mt-1 line-clamp-2 text-xs text-[var(--text-tertiary)]">{item.detail || item.when}</p>}
          {item.when && item.detail && <p className="mt-1 text-[11px] text-[var(--text-tertiary)]">{item.when}</p>}
        </div>
      </div>
    </div>
  );
}

function TimelineRow({ item }) {
  const time = item.overdue ? formatOverdue(item) : formatWhen(item.start_at || item.due_at);
  const strong = item.overdue || item.importance === "high";
  return (
    <div className="grid gap-3 py-3 sm:grid-cols-[96px_minmax(0,1fr)_110px]">
      <div className={`text-xs font-medium ${item.overdue ? "text-red-300" : "text-[var(--text-tertiary)]"}`}>{time}</div>
      <div className="min-w-0">
        <div className="flex items-start gap-2">
          <Circle size={9} className={`mt-1.5 shrink-0 ${strong ? "fill-current text-orange-400" : "text-[var(--accent-soft)]"}`} />
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-white">{item.title}</p>
            {(item.detail || item.location) && <p className="mt-0.5 truncate text-xs text-[var(--text-tertiary)]">{item.detail || item.location}</p>}
          </div>
        </div>
      </div>
      <div className="text-left text-xs text-[var(--text-tertiary)] sm:text-right">{sourceLabel(item.source)}</div>
    </div>
  );
}

function StatusLine({ label, value, tone }) {
  const color = tone === "warn" ? "text-yellow-300" : tone === "ok" ? "text-green-300" : "text-[var(--text-secondary)]";
  return (
    <div className="flex items-center justify-between gap-3 border-t border-[var(--border)] pt-2">
      <span className="text-[var(--text-tertiary)]">{label}</span>
      <span className={`max-w-[58%] truncate font-medium ${color}`}>{value}</span>
    </div>
  );
}

function buildTimeline(data) {
  if (!data) return [];
  const items = [
    ...(data.overdue || []),
    ...(data.plan || []),
    ...(data.upcoming || []),
  ];
  return items
    .filter(Boolean)
    .sort((a, b) => {
      if (a.overdue && !b.overdue) return -1;
      if (!a.overdue && b.overdue) return 1;
      return timeValue(a) - timeValue(b);
    });
}

function buildActions(data) {
  if (!data) return [];
  const llmTodos = (data.briefing?.todos || []).map((todo, index) => ({
    key: `brief:${index}:${todo.title}`,
    title: todo.title,
    detail: todo.detail,
    when: todo.when,
    urgency: todo.urgency,
  }));
  const urgentData = [
    ...(data.overdue || []),
    ...(data.plan || []).filter((item) => item.importance === "high"),
    ...(data.upcoming || []).filter((item) => item.importance === "high"),
  ];
  const mapped = urgentData.map((item) => ({
    key: item.key,
    title: item.title,
    detail: item.detail || item.location,
    when: item.overdue ? formatOverdue(item) : formatWhen(item.start_at || item.due_at),
    urgency: item.overdue || item.importance === "high" ? "high" : "medium",
    importance: item.importance,
    overdue: item.overdue,
  }));
  return dedupeByTitle([...mapped, ...llmTodos]).slice(0, 8);
}

function dedupeByTitle(items) {
  const seen = new Set();
  return items.filter((item) => {
    const key = (item.title || "").trim();
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function timeValue(item) {
  const raw = item?.sort_at || item?.start_at || item?.due_at || "";
  const time = new Date(raw).getTime();
  return Number.isNaN(time) ? Number.MAX_SAFE_INTEGER : time;
}

function formatDateTitle(value) {
  if (!value) return "今日";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 10);
  return date.toLocaleDateString("zh-CN", { month: "long", day: "numeric", weekday: "long" });
}

function formatWhen(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 16);
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  const diff = date.getTime() - now.getTime();
  if (diff > 0 && diff <= 7 * 24 * 60 * 60 * 1000) {
    return `还剩${Math.ceil(diff / (24 * 60 * 60 * 1000))}天`;
  }
  return date.toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function formatTimeRange(item) {
  if (!item?.start_at) return "";
  const start = new Date(item.start_at);
  const end = item.end_at ? new Date(item.end_at) : null;
  if (Number.isNaN(start.getTime())) return String(item.start_at).slice(11, 16);
  const startText = start.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  if (!end || Number.isNaN(end.getTime())) return startText;
  return `${startText}-${end.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}`;
}

function formatOverdue(item) {
  const days = Number.isFinite(Number(item?.overdue_days)) ? Number(item.overdue_days) : 0;
  if (days <= 0) return "刚逾期";
  return `逾期${days}天`;
}

function sourceLabel(source) {
  return {
    course: "课程",
    event: "日历",
    reminder: "提醒",
    memory: "消息",
    assignment: "学习通",
    scheduled: "推送",
  }[source] || source || "";
}

function formatFeedback(feedback) {
  if (!feedback || typeof feedback !== "object") return "-";
  const entries = Object.entries(feedback);
  if (!entries.length) return "无";
  return entries.map(([key, value]) => `${key}:${value}`).join(" ");
}
