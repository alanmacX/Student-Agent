import { useEffect, useState } from "react";
import { Activity, AlertTriangle, CalendarDays, CalendarRange, CheckCircle2, Clock, Lightbulb, Plus, RefreshCw, ShieldCheck, StickyNote, Trash2 } from "lucide-react";
import { apiFetch } from "../../api/client";
import RemindersPanel from "../settings/RemindersPanel";

export default function HubView() {
  const [notes, setNotes] = useState([]);
  const [input, setInput] = useState("");
  const [dashboard, setDashboard] = useState(null);
  const [loading, setLoading] = useState(true);
  const [dashboardError, setDashboardError] = useState("");

  const refreshDashboard = async () => {
    setLoading(true);
    setDashboardError("");
    try {
      setDashboard(await apiFetch("/api/dashboard/today"));
    } catch (e) {
      console.error("Failed to load dashboard:", e);
      setDashboardError("今天的面板暂时没拉下来。");
    } finally {
      setLoading(false);
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
      refreshDashboard();
      loadIdeas();
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, []);

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)]">
      {/* Floating header */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 mx-auto flex w-full max-w-7xl items-center justify-between gap-2 px-3 pt-3 md:px-6">
        <div className="glass-pill pointer-events-auto flex min-h-[48px] items-center rounded-full px-5 py-2">
          <Lightbulb size={16} className="mr-2 text-yellow-400" />
          <h2 className="text-sm font-semibold text-white">Hub</h2>
        </div>
        <button
          onClick={refreshDashboard}
          className="glass-pill pointer-events-auto grid h-12 w-12 place-items-center rounded-full text-[var(--text-secondary)] hover:text-white"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={loading ? "animate-spin" : ""} />
        </button>
      </div>

      {/* Scrollable content */}
      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-36 md:pb-4 md:px-6">
        <div className="mx-auto max-w-7xl space-y-4 stagger">
          <DashboardSummary data={dashboard} loading={loading} error={dashboardError} />

          <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1.35fr)_minmax(360px,0.85fr)] xl:grid-cols-[minmax(0,1.5fr)_minmax(400px,0.9fr)]">
            <div className="min-w-0 space-y-4">
              <section className="surface-card animate-rise p-4">
                <SectionTitle icon={AlertTriangle} label="逾期" tone="danger" />
                <ItemList items={dashboard?.overdue || []} empty="没有逾期事项。" variant="overdue" />
              </section>

              <section className="surface-card animate-rise p-4" style={{ animationDelay: "45ms" }}>
                <SectionTitle icon={CalendarDays} label="今天" />
                <ItemList items={dashboard?.plan || []} empty="今天没有排进来的事项。" limit={12} />
              </section>

              <section className="surface-card animate-rise p-4" style={{ animationDelay: "60ms" }}>
                <SectionTitle icon={Clock} label="接下来" />
                <ItemList items={dashboard?.upcoming || []} empty="未来一周暂时没有待发提醒。" limit={12} />
              </section>

              <section className="surface-card animate-rise p-4" style={{ animationDelay: "90ms" }}>
                <SectionTitle icon={CalendarRange} label="长期" />
                <ItemList items={dashboard?.longterm || []} empty="未来 90 天暂无较远的安排。" limit={10} />
              </section>
            </div>

            <div className="min-w-0 space-y-4">
              <section className="surface-card animate-rise p-4" style={{ animationDelay: "120ms" }}>
                <SectionTitle icon={ShieldCheck} label="最近执行" />
                <AuditList items={dashboard?.agent_audit || []} />
              </section>

              {/* Quick Capture */}
              <section className="surface-card animate-rise p-4" style={{ animationDelay: "120ms" }}>
                <div className="mb-3 flex items-center gap-2">
                  <StickyNote size={14} className="text-[var(--accent)]" />
                  <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
                    点子库
                  </h3>
                </div>
                <div className="flex gap-2">
                  <input
                    value={input}
                    onChange={(e) => setInput(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && addNote()}
                    placeholder="记个点子，想要时再来看…"
                    className="glass-input flex-1 rounded-xl px-3 py-2 text-sm"
                  />
                  <button
                    onClick={addNote}
                    disabled={!input.trim()}
                    className="rounded-xl bg-[var(--accent)] px-3 py-2 text-sm font-medium text-white transition hover:opacity-90 disabled:opacity-30"
                  >
                    <Plus size={16} />
                  </button>
                </div>
                {notes.length > 0 && (
                  <div className="mt-3 space-y-1.5">
                    {notes.map((note) => (
                      <div
                        key={note.id}
                        className="group flex items-start gap-2 rounded-xl px-2 py-1.5 transition hover:bg-[var(--hover-bg)]"
                      >
                        <p className="flex-1 text-sm text-[var(--text-secondary)] whitespace-pre-wrap">{note.text}</p>
                        <button
                          onClick={() => deleteNote(note.id)}
                          className="mt-0.5 opacity-0 transition group-hover:opacity-100"
                        >
                          <Trash2 size={13} className="text-[var(--text-tertiary)] hover:text-red-400" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </section>

              {/* Reminders — full panel migrated from Settings */}
              <section className="surface-card animate-rise p-4" style={{ animationDelay: "150ms" }}>
                <RemindersPanel />
              </section>
            </div>
          </div>

        </div>
      </div>
    </div>
  );
}

function DashboardSummary({ data, loading, error }) {
  const budget = data?.budget;
  const used = budget?.used_tokens || 0;
  const limit = budget?.daily_token_budget || 0;
  const pct = limit ? Math.min(100, Math.round((used / limit) * 100)) : 0;
  const stats = [
    { label: "今日课程", value: data?.counts?.courses_today ?? "-" },
    { label: "逾期", value: data?.counts?.overdue_reminders ?? "-" },
    { label: "活跃事项", value: data?.counts?.active_memory ?? "-" },
    { label: "待发推送", value: data?.counts?.upcoming_notifications ?? "-" },
  ];
  return (
    <section className="surface-card animate-rise p-4">
      <div className="flex items-center justify-between gap-3">
        <SectionTitle icon={Activity} label={data?.date || "今日"} />
        {loading && <RefreshCw size={14} className="animate-spin text-[var(--text-tertiary)]" />}
      </div>
      {error && <p className="mt-3 rounded-xl bg-red-500/10 px-3 py-2 text-xs text-red-300">{error}</p>}
      <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
        {stats.map((s) => (
          <div key={s.label} className="rounded-xl bg-[var(--surface)] px-3 py-2">
            <p className="text-[11px] text-[var(--text-tertiary)]">{s.label}</p>
            <p className="mt-1 text-lg font-semibold text-white">{s.value}</p>
          </div>
        ))}
      </div>
      <div className="mt-3">
        <div className="mb-1 flex justify-between text-[11px] text-[var(--text-tertiary)]">
          <span>Token Budget</span>
          <span>{used.toLocaleString()} / {limit.toLocaleString()}</span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-white/10">
          <div className="h-full rounded-full bg-[var(--accent)]" style={{ width: `${pct}%` }} />
        </div>
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

function ItemList({ items, empty, variant = "default", limit = 8 }) {
  if (!items?.length) {
    return <p className="mt-3 text-sm text-[var(--text-tertiary)]">{empty}</p>;
  }
  return (
    <div className="mt-3 space-y-2">
      {items.slice(0, limit).map((item) => (
        <div
          key={item.key}
          className={`flex gap-3 rounded-xl px-3 py-2.5 ${
            variant === "overdue"
              ? "border border-red-500/25 bg-red-500/10"
              : "bg-[var(--surface)]"
          }`}
        >
          <CheckCircle2 size={15} className={`mt-0.5 shrink-0 ${item.overdue ? "text-red-400" : item.importance === "high" ? "text-orange-400" : "text-[var(--accent-soft)]"}`} />
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <p className="min-w-0 flex-1 truncate text-sm font-medium text-white">{item.title}</p>
              <span className={`shrink-0 text-[11px] ${item.overdue ? "font-semibold text-red-300" : "text-[var(--text-tertiary)]"}`}>
                {item.overdue ? formatOverdue(item) : formatWhen(item.start_at || item.due_at)}
              </span>
            </div>
            {(item.detail || item.location) && (
              <p className="mt-0.5 truncate text-xs text-[var(--text-tertiary)]">{item.detail || item.location}</p>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

function AuditList({ items }) {
  if (!items?.length) return <p className="mt-3 text-sm text-[var(--text-tertiary)]">还没有新的执行记录。</p>;
  return (
    <div className="mt-3 space-y-2">
      {items.slice(0, 6).map((item) => (
        <div key={item.id} className="rounded-xl bg-[var(--surface)] px-3 py-2">
          <div className="flex items-center justify-between gap-2">
            <p className="truncate text-sm font-medium text-white">{item.tool_name}</p>
            <span className="shrink-0 text-[11px] text-[var(--text-tertiary)]">{formatWhen(item.created_at)}</span>
          </div>
          <p className="mt-0.5 truncate text-xs text-[var(--text-tertiary)]">{item.result_summary}</p>
        </div>
      ))}
    </div>
  );
}

function formatWhen(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 16);
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) {
    return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  }
  const diff = date.getTime() - now.getTime();
  if (diff > 0 && diff <= 7 * 24 * 60 * 60 * 1000) {
    return `还剩${Math.ceil(diff / (24 * 60 * 60 * 1000))}天`;
  }
  return date.toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function formatOverdue(item) {
  const days = Number.isFinite(Number(item?.overdue_days)) ? Number(item.overdue_days) : 0;
  if (days <= 0) return "刚逾期";
  return `逾期${days}天`;
}
