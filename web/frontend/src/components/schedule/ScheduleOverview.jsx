import { useEffect, useMemo, useRef, useState } from "react";
import { RefreshCw, Sparkles, BookOpen, CalendarClock, ChevronDown, MapPin } from "lucide-react";
import { fetchScheduleSidebar, refreshBriefing } from "../../api/schedule";

const WEEKDAYS = [
  { label: "周一", value: 1 },
  { label: "周二", value: 2 },
  { label: "周三", value: 3 },
  { label: "周四", value: 4 },
  { label: "周五", value: 5 },
  { label: "周六", value: 6 },
  { label: "周日", value: 0 },
];

// Must match the backend period schedule in
// web/backend/app/services/schedule_store.py (PERIOD_START / PERIOD_END),
// otherwise imported courses land in the wrong rows.
const PERIODS = [
  { id: 1, label: "1", start: "08:00", end: "08:45" },
  { id: 2, label: "2", start: "08:55", end: "09:40" },
  { id: 3, label: "3", start: "10:00", end: "10:45" },
  { id: 4, label: "4", start: "10:55", end: "11:40" },
  { id: 5, label: "5", start: "14:00", end: "14:45" },
  { id: 6, label: "6", start: "14:55", end: "15:40" },
  { id: 7, label: "7", start: "16:00", end: "16:45" },
  { id: 8, label: "8", start: "16:55", end: "17:40" },
  { id: 9, label: "9", start: "19:00", end: "19:45" },
  { id: 10, label: "10", start: "19:55", end: "20:40" },
  { id: 11, label: "11", start: "20:50", end: "21:35" },
  { id: 12, label: "12", start: "21:45", end: "22:30" },
];

export default function ScheduleOverview() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [refreshingBriefing, setRefreshingBriefing] = useState(false);
  const pollRef = useRef(null);

  const refresh = async () => {
    setLoading(true);
    try {
      const d = await fetchScheduleSidebar();
      setData(d);
      // If no briefing yet, kick off generation and poll for it.
      if (!d?.briefing?.text) {
        startBriefingPoll();
      }
    } catch (e) {
      console.error("Failed to load schedule overview:", e);
    } finally {
      setLoading(false);
    }
  };

  const startBriefingPoll = async () => {
    if (pollRef.current) return;
    try {
      await refreshBriefing();
    } catch (e) {
      /* ignore */
    }
    let tries = 0;
    pollRef.current = setInterval(async () => {
      tries += 1;
      try {
        const d = await fetchScheduleSidebar();
        if (d?.briefing?.text || tries > 10) {
          setData(d);
          clearInterval(pollRef.current);
          pollRef.current = null;
        }
      } catch (e) {
        /* ignore */
      }
    }, 3000);
  };

  const handleRefreshBriefing = async () => {
    setRefreshingBriefing(true);
    try {
      const result = await refreshBriefing();
      if (result?.briefing) {
        setData((prev) => prev ? { ...prev, briefing: result.briefing } : prev);
      }
    } catch (e) {
      console.error("Failed to refresh briefing:", e);
    } finally {
      setRefreshingBriefing(false);
    }
  };

  useEffect(() => {
    refresh();
    const handler = () => refresh();
    window.addEventListener("app-refresh", handler);
    return () => {
      window.removeEventListener("app-refresh", handler);
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, []);

  // Only locally-imported courses carry real weekly schedule times. The chaoxing
  // "enrolled" list (data.courses) has no times — it can't render on the grid and
  // would only inflate the count, so it's intentionally excluded here.
  const courses = useMemo(() => data?.local_courses || [], [data]);

  const nowMs = Date.now();
  const pendingAssignments = useMemo(
    () =>
      (data?.assignments || []).filter((a) => {
        if (a.status !== "未交" && a.status !== "未提交") return false;
        if (!a.dueDate) return false;
        if (new Date(a.dueDate).getTime() < nowMs) return false;
        return true;
      }),
    [data, nowMs]
  );

  return (
    <div className="h-full overflow-y-auto bg-[var(--panel-bg)]">
      {/* Header — island, width-matched to content */}
      <div className="sticky top-0 z-10 mx-auto flex w-full max-w-3xl items-center justify-between gap-2 px-3 pt-3 pb-1 lg:px-6">
        <div className="glass-pill flex min-h-[48px] items-center rounded-full px-5 py-2">
          <h1 className="text-sm font-semibold text-white">日程总览</h1>
        </div>
        <button
          onClick={refresh}
          className="glass-pill grid h-12 w-12 shrink-0 place-items-center rounded-full text-[var(--text-secondary)] transition-all duration-200 ease-[var(--ease-spring)] hover:scale-105 hover:border-[var(--glass-border-bright)] hover:text-white active:scale-90"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={loading ? "animate-spin" : ""} />
        </button>
      </div>

      <div className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-3 pb-40 md:pb-6 lg:p-6 lg:pb-10">
        <TodayCard
          data={data}
          loading={loading}
          pendingCount={pendingAssignments.length}
          onRefreshBriefing={handleRefreshBriefing}
          refreshingBriefing={refreshingBriefing}
        />

        <ScheduleSection courses={courses} events={data?.week_events || data?.events || []} />
      </div>
    </div>
  );
}

// ── Today card: big hero + LLM-decided todo list, all in one ──────────────────
function TodayCard({ data, loading, pendingCount, onRefreshBriefing, refreshingBriefing }) {
  const now = new Date();
  const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  const weekdayName = weekdays[now.getDay()];
  const dateStr = now.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });

  const briefing = data?.briefing;
  const briefingText = briefing?.text;
  // Still on the way: no briefing object yet, or actively loading the first one.
  const generating = !briefingText && (loading || data === null || !briefing);

  // Prefer the LLM-decided todos; gracefully fall back to rule-ranked insights.
  const todos = useMemo(() => {
    const llm = briefing?.todos;
    if (Array.isArray(llm) && llm.length) return llm;
    return (data?.memory_insights || []).slice(0, 5).map(insightToTodo);
  }, [briefing, data]);

  return (
    <div
      className="animate-rise overflow-hidden rounded-[32px] p-6 md:p-7"
      style={{
        background:
          "linear-gradient(150deg, #0a84ff 0%, #0071e3 52%, #0058c4 100%)",
        border: "1px solid rgba(255,255,255,0.18)",
        boxShadow:
          "0 18px 48px rgba(0,80,200,0.38), 0 1px 0 rgba(255,255,255,0.22) inset",
      }}
    >
      {/* Date row */}
      <div className="flex items-start justify-between">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-white/75">
            {weekdayName}
          </p>
          <p className="mt-0.5 text-[34px] font-bold leading-none tracking-tight text-white">{dateStr}</p>
        </div>
        <div className="ml-3 mt-0.5 flex items-center gap-2">
          <button
            onClick={onRefreshBriefing}
            disabled={refreshingBriefing || generating}
            className="grid h-9 w-9 shrink-0 place-items-center rounded-[14px] bg-white/10 text-white/70 shadow-[inset_0_1px_0_rgba(255,255,255,0.28),inset_0_0_0_0.5px_rgba(255,255,255,0.12)] backdrop-blur-md transition-all hover:bg-white/20 hover:text-white active:scale-90 disabled:opacity-40"
            aria-label="重新生成摘要"
          >
            <RefreshCw size={14} className={refreshingBriefing ? "animate-spin" : ""} />
          </button>
          <div className="grid h-11 w-11 shrink-0 place-items-center rounded-[18px] bg-white/15 shadow-[inset_0_1px_0_rgba(255,255,255,0.35),inset_0_0_0_0.5px_rgba(255,255,255,0.15)] backdrop-blur-md">
            <Sparkles size={21} className={`text-white ${generating ? "animate-pulse-soft" : ""}`} />
          </div>
        </div>
      </div>

      {/* Natural-language briefing */}
      <div className="mt-5 min-h-[52px]">
        {generating ? (
          <OnTheWay />
        ) : (
          <p key={briefingText} className="animate-fade text-[16px] leading-relaxed text-white/90">
            {briefingText || "今天没有特别紧急的事项，放轻松。"}
          </p>
        )}
      </div>

      {/* Quick stat chip */}
      {!generating && pendingCount > 0 && (
        <div className="mt-4 flex flex-wrap gap-2">
          <span className="flex items-center gap-1.5 rounded-full bg-orange-500/15 px-3.5 py-1.5 text-[12px] font-semibold text-orange-400 ring-1 ring-orange-500/25">
            <BookOpen size={12} />
            {pendingCount} 个作业待交
          </span>
        </div>
      )}

      {/* LLM-decided todo list — lives inside the card */}
      {!generating && todos.length > 0 && (
        <div className="mt-5 space-y-2">
          <p className="px-1 text-[11px] font-semibold uppercase tracking-[0.16em] text-white/60">
            该先做这些
          </p>
          {todos.map((t, idx) => (
            <TodoRow key={`${t.title}-${idx}`} todo={t} delay={idx * 60} />
          ))}
        </div>
      )}
    </div>
  );
}

const URGENCY = {
  high: { dot: "bg-orange-400", ring: "ring-orange-400/30", glow: "shadow-[0_0_0_3px_rgba(251,146,60,0.12)]" },
  medium: { dot: "bg-[var(--accent-soft)]", ring: "ring-[var(--accent)]/25", glow: "" },
  low: { dot: "bg-white/40", ring: "ring-white/10", glow: "" },
};

function TodoRow({ todo, delay }) {
  const [open, setOpen] = useState(false);
  const u = URGENCY[todo.urgency] || URGENCY.medium;
  const hasDetail = Boolean(todo.detail);

  return (
    <button
      type="button"
      onClick={() => hasDetail && setOpen((v) => !v)}
      className={`animate-rise group flex w-full items-start gap-3 rounded-[20px] bg-white/[0.05] px-4 py-3 text-left ring-1 ${u.ring} ${u.glow} transition-all duration-200 ease-[var(--ease-spring)] hover:bg-white/[0.09] active:scale-[0.985]`}
      style={{ animationDelay: `${delay}ms` }}
    >
      <span className="mt-[7px] flex shrink-0">
        <span className={`h-2 w-2 rounded-full ${u.dot} ${todo.urgency === "high" ? "animate-pulse-soft" : ""}`} />
      </span>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <p className="min-w-0 flex-1 truncate text-[15px] font-semibold leading-snug text-white">
            {todo.title}
          </p>
          {todo.when && (
            <span className="shrink-0 rounded-full bg-white/10 px-2.5 py-0.5 text-[11px] font-medium text-white/75">
              {todo.when}
            </span>
          )}
          {hasDetail && (
            <ChevronDown
              size={15}
              className={`shrink-0 text-white/40 transition-transform duration-200 ${open ? "rotate-180" : ""}`}
            />
          )}
        </div>
        {todo.detail && (
          <p
            className={`overflow-hidden text-[13px] leading-relaxed text-white/65 transition-all duration-300 ease-[var(--ease-smooth)] ${
              open ? "mt-1.5 max-h-40 opacity-100" : "mt-0.5 max-h-[1.6em] truncate opacity-80"
            }`}
          >
            {todo.detail}
          </p>
        )}
      </div>
    </button>
  );
}

// "在来的路上" — shown while the briefing is being generated.
function OnTheWay() {
  return (
    <div className="flex items-center gap-2.5 text-[15px] text-white/85">
      <span className="flex items-center gap-1">
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className="dot-breathe inline-block h-1.5 w-1.5 rounded-full bg-white/80"
            style={{ animationDelay: `${i * 0.22}s` }}
          />
        ))}
      </span>
      <span className="animate-fade">今天的重点在来的路上…</span>
    </div>
  );
}

const KIND_LABEL = { assignment: "作业", course: "课程变动", reminder: "提醒", message: "通知" };

// Map a rule-ranked memory insight into the LLM-todo shape (fallback only).
function insightToTodo(item) {
  const kind = item.kind || "message";
  const dateRaw = item.date_hint || item.expires_at;
  const when = dateRaw
    ? new Date(dateRaw).toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" })
    : "";
  const detail = [item.summary || KIND_LABEL[kind], item.action_hint].filter(Boolean).join(" · ");
  return {
    title: item.title,
    detail,
    when,
    urgency: item.importance === "high" ? "high" : "medium",
  };
}

function ScheduleSection({ courses, events }) {
  const [weekStart, weekEnd] = currentWeekRange();
  const thisWeekCount = useMemo(() => {
    const names = new Set();
    for (const c of courses) {
      const t = new Date(c.startDate).getTime();
      if (!Number.isNaN(t) && t >= weekStart && t < weekEnd) names.add(c.title || c.name);
    }
    return names.size;
  }, [courses, weekStart, weekEnd]);

  return (
    <section className="animate-rise surface-card min-w-0 p-3 md:p-4" style={{ animationDelay: "120ms" }}>
      <div className="mb-3 flex items-center justify-between px-1">
        <div className="flex items-center gap-2">
          <CalendarClock size={14} className="text-[var(--text-tertiary)]" />
          <h2 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">本周课表</h2>
        </div>
        <span className="text-[11px] text-[var(--text-tertiary)]">
          {courses.length > 0 ? `${thisWeekCount} 门课` : "未导入"}
        </span>
      </div>
      {courses.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-12 text-center text-[var(--text-tertiary)]">
          <p className="text-sm">课程表未导入</p>
          <p className="mt-1 text-xs">在 Agent 页面发送 JSON 课程数据即可导入</p>
        </div>
      ) : (
        <>
          <div className="md:hidden"><DayList courses={courses} events={events} /></div>
          <div className="hidden md:block"><WeekTable courses={courses} events={events} /></div>
        </>
      )}
    </section>
  );
}

// Monday 00:00 of the current week .. next Monday 00:00 (local time).
function currentWeekRange() {
  const now = new Date();
  const day = now.getDay(); // 0=Sun..6=Sat
  const mondayOffset = (day + 6) % 7; // days since Monday
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - mondayOffset);
  const end = new Date(start.getTime() + 7 * 24 * 60 * 60 * 1000);
  return [start.getTime(), end.getTime()];
}

// ── Mobile day-list: grouped by weekday, no horizontal scroll ─────────────
function DayList({ courses, events }) {
  const [weekStart, weekEnd] = currentWeekRange();
  const today = new Date().getDay(); // 0=Sun..6=Sat

  const items = useMemo(() => {
    const weekItems = [
      ...courses
        .filter((e) => { const t = new Date(e.startDate).getTime(); return !Number.isNaN(t) && t >= weekStart && t < weekEnd; })
        .map((event) => ({ event, kind: "course" })),
      ...events
        .filter((e) => { const t = new Date(e.startDate).getTime(); return !Number.isNaN(t) && t >= weekStart && t < weekEnd; })
        .map((event) => ({ event, kind: event.kind || "event" })),
    ];
    // Group by weekday (Mon=1 .. Sun=0)
    const grouped = {};
    for (const item of weekItems) {
      const wd = new Date(item.event.startDate).getDay(); // 0=Sun
      if (!grouped[wd]) grouped[wd] = [];
      grouped[wd].push(item);
    }
    // Sort within each day by start time
    for (const wd of Object.keys(grouped)) {
      grouped[wd].sort((a, b) => new Date(a.event.startDate) - new Date(b.event.startDate));
    }
    return grouped;
  }, [courses, events, weekStart, weekEnd]);

  // Render Mon..Sun, skipping empty days
  const dayOrder = [1, 2, 3, 4, 5, 6, 0];
  const hasAny = dayOrder.some((wd) => items[wd]?.length > 0);
  if (!hasAny) return null;

  return (
    <div className="space-y-3">
      {dayOrder.map((wd) => {
        const dayItems = items[wd];
        if (!dayItems?.length) return null;
        const isToday = wd === today;
        return (
          <div key={wd}>
            <div className={`mb-1.5 flex items-center gap-2 px-1 ${isToday ? "" : ""}`}>
              <span className={`text-xs font-semibold ${isToday ? "text-[var(--accent)]" : "text-[var(--text-tertiary)]"}`}>
                {WEEKDAYS.find((d) => d.value === wd)?.label}
              </span>
              {isToday && <span className="rounded-full bg-[var(--accent)]/15 px-2 py-0.5 text-[10px] font-semibold text-[var(--accent)]">今天</span>}
            </div>
            <div className="space-y-1">
              {dayItems.map(({ event, kind }) => (
                <div
                  key={`${kind}-${event.id}`}
                  className={`flex items-center gap-3 rounded-2xl px-3.5 py-2.5 transition active:scale-[0.98] ${
                    kind === "course"
                      ? "bg-emerald-500/10 ring-1 ring-emerald-500/20"
                      : "bg-[var(--accent)]/10 ring-1 ring-[var(--accent)]/20"
                  }`}
                >
                  <div className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate text-[13px] font-semibold text-[var(--text-primary)]">
                      {event.title || event.name}
                    </span>
                    {(event.location || event.startDate) && (
                      <span className="mt-0.5 flex items-center gap-1 text-[11px] text-[var(--text-tertiary)]">
                        {event.location && <MapPin size={10} className="shrink-0" />}
                        {event.location || formatTime(event.startDate)}
                      </span>
                    )}
                  </div>
                  <span className="shrink-0 text-[11px] font-medium text-[var(--text-tertiary)]">
                    {formatTime(event.startDate)}
                  </span>
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function WeekTable({ courses, events }) {
  const [weekStart, weekEnd] = currentWeekRange();
  // The backend returns multiple weeks of courses (a ±2-week window). Restrict
  // to the current week so each slot shows one instance, not one per week.
  const inThisWeek = (event) => {
    const t = new Date(event.startDate).getTime();
    return !Number.isNaN(t) && t >= weekStart && t < weekEnd;
  };
  const items = [
    ...courses.filter(inThisWeek).map((event) => ({ event, kind: "course" })),
    ...events.filter(inThisWeek).map((event) => ({ event, kind: event.kind || "event" })),
  ];
  return (
    <div className="overflow-x-auto">
      <div className="min-w-[760px] overflow-hidden rounded-2xl border border-[var(--border)]">
        <div className="grid grid-cols-[38px_repeat(7,minmax(94px,1fr))] border-b border-[var(--border)] bg-[var(--deep-bg)]">
          <Cell muted>节</Cell>
          {WEEKDAYS.map((day) => <Cell key={day.value} muted>{day.label}</Cell>)}
        </div>
        {PERIODS.map((period) => (
          <div key={period.id} className="grid min-h-[64px] grid-cols-[38px_repeat(7,minmax(94px,1fr))] border-b border-[var(--border)] last:border-b-0">
            <Cell muted>{period.label}</Cell>
            {WEEKDAYS.map((day) => (
              <div key={day.value} className="min-h-[64px] border-l border-[var(--border)] p-1.5">
                {itemsForCell(items, day.value, period).slice(0, 2).map(({ event, kind }) => (
                  <div key={`${kind}-${event.id}`} className={`mb-1 rounded-xl px-2 py-1.5 transition duration-150 ease-[var(--ease-spring)] hover:scale-[1.03] active:scale-95 ${kind === "course" ? "bg-emerald-500/85" : "bg-[var(--accent)]/85"}`}>
                    <p className="line-clamp-2 text-xs font-semibold leading-4 text-white">{event.title || event.name}</p>
                    <p className="truncate text-[11px] text-white/80">{event.location || formatTime(event.startDate)}</p>
                  </div>
                ))}
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

function Cell({ children, muted }) {
  return <div className={`grid min-h-9 place-items-center text-xs font-semibold ${muted ? "text-[var(--text-tertiary)]" : "text-white"}`}>{children}</div>;
}

// Assign each item to the single period row whose START time is closest to the
// item's start time (within 25 min). Matching against the period's full span
// caused items to appear in two adjacent rows.
function itemsForCell(items, weekday, period) {
  return items.filter(({ event }) => {
    const start = new Date(event.startDate);
    if (Number.isNaN(start.getTime()) || start.getDay() !== weekday) return false;
    const minutes = start.getHours() * 60 + start.getMinutes();
    return Math.abs(minutes - toMinutes(period.start)) <= 25;
  });
}

function toMinutes(value) {
  const [h, m] = value.split(":").map(Number);
  return h * 60 + m;
}

function formatTime(value) {
  if (!value) return "";
  return new Date(value).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
}
