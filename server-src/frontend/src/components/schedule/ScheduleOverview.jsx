import { useEffect, useMemo, useRef, useState } from "react";
import { RefreshCw, Sparkles, BookOpen, CalendarClock, ChevronDown, ChevronLeft, ChevronRight } from "lucide-react";
import { fetchScheduleSidebar, refreshBriefing } from "../../api/schedule";
import StatusStrip from "./StatusStrip";
import TokenSummary from "./TokenSummary";

const WEEKDAYS = [
  { label: "周一", value: 1 },
  { label: "周二", value: 2 },
  { label: "周三", value: 3 },
  { label: "周四", value: 4 },
  { label: "周五", value: 5 },
  { label: "周六", value: 6 },
  { label: "周日", value: 0 },
];
const CHINA_TZ = "Asia/Shanghai";

// Must match backend/app/services/zjut_import.py::PERIOD_TIMES.
const PERIODS = [
  { id: 1, label: "1", start: "08:00", end: "08:45" },
  { id: 2, label: "2", start: "08:55", end: "09:40" },
  { id: 3, label: "3", start: "09:55", end: "10:40" },
  { id: 4, label: "4", start: "10:50", end: "11:35" },
  { id: 5, label: "5", start: "11:35", end: "13:30" },
  { id: 6, label: "6", start: "13:30", end: "14:15" },
  { id: 7, label: "7", start: "14:25", end: "15:10" },
  { id: 8, label: "8", start: "15:25", end: "16:10" },
  { id: 9, label: "9", start: "16:20", end: "17:05" },
  { id: 10, label: "10", start: "18:30", end: "19:15" },
  { id: 11, label: "11", start: "19:25", end: "20:10" },
  { id: 12, label: "12", start: "20:20", end: "21:05" },
];

export default function ScheduleOverview() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [refreshingOverview, setRefreshingOverview] = useState(false);
  const [refreshingBriefing, setRefreshingBriefing] = useState(false);
  const pollRef = useRef(null);
  const dataRef = useRef(null);

  const refresh = async ({ soft = false } = {}) => {
    const hasData = dataRef.current !== null;
    if (soft || hasData) {
      setRefreshingOverview(true);
    } else {
      setLoading(true);
    }
    try {
      const d = await fetchScheduleSidebar();
      dataRef.current = d;
      setData(d);
      // If no briefing yet, kick off generation and poll for it.
      if (!d?.briefing?.text) {
        startBriefingPoll();
      }
    } catch (e) {
      console.error("Failed to load schedule overview:", e);
    } finally {
      setLoading(false);
      setRefreshingOverview(false);
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
          dataRef.current = d;
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
        setData((prev) => {
          const next = prev ? { ...prev, briefing: result.briefing } : prev;
          dataRef.current = next;
          return next;
        });
      }
    } catch (e) {
      console.error("Failed to refresh briefing:", e);
    } finally {
      setRefreshingBriefing(false);
    }
  };

  useEffect(() => {
    refresh();
    const handler = (event) => {
      if (!event.detail?.tab || event.detail.tab === "overview") refresh({ soft: true });
    };
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
      <div className="sticky top-0 z-10 mx-auto flex w-full max-w-[1560px] items-center justify-between gap-2 px-3 pt-3 pb-1 lg:px-6">
        <div className="glass-pill flex min-h-[48px] items-center rounded-full px-5 py-2">
          <h1 className="text-sm font-semibold text-white">日程总览</h1>
        </div>
        <button
          onClick={() => refresh({ soft: true })}
          className="glass-pill grid h-12 w-12 shrink-0 place-items-center rounded-full text-[var(--text-secondary)] transition-all duration-200 ease-[var(--ease-spring)] hover:scale-105 hover:border-[var(--glass-border-bright)] hover:text-white active:scale-90"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={loading || refreshingOverview ? "animate-spin" : ""} />
        </button>
      </div>

      <div className="mx-auto grid w-full max-w-[1560px] grid-cols-1 gap-4 p-3 pb-40 md:pb-6 lg:grid-cols-[minmax(340px,0.72fr)_minmax(700px,1.5fr)] lg:p-6 lg:pb-10 xl:grid-cols-[minmax(380px,0.64fr)_minmax(840px,1.62fr)] 2xl:grid-cols-[minmax(420px,0.58fr)_minmax(980px,1.72fr)]">
        <div className="flex min-w-0 flex-col gap-4">
          <TodayCard
            data={data}
            loading={loading}
            pendingCount={pendingAssignments.length}
            onRefreshBriefing={handleRefreshBriefing}
            refreshingBriefing={refreshingBriefing}
          />
          <StatusStrip />
          <TokenSummary />
        </div>

        <div className="min-w-0">
          <ScheduleSection
            courses={courses}
            events={data?.week_events || data?.events || []}
            term={data?.zjut_term}
            onRefresh={refresh}
            loading={loading || refreshingOverview}
          />
        </div>
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
            className="grid h-9 w-9 shrink-0 place-items-center rounded-[14px] bg-white/10 text-white/70 backdrop-blur-md transition-all hover:bg-white/20 hover:text-white active:scale-90 disabled:opacity-40"
            aria-label="重新生成摘要"
          >
            <RefreshCw size={14} className={refreshingBriefing ? "animate-spin" : ""} />
          </button>
          <div className="grid h-11 w-11 shrink-0 place-items-center rounded-[18px] bg-white/15 backdrop-blur-md">
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
  high: { dot: "bg-orange-400", ring: "ring-orange-400/30" },
  medium: { dot: "bg-[var(--accent-soft)]", ring: "ring-[var(--accent)]/25" },
  low: { dot: "bg-white/40", ring: "ring-white/10" },
};

function TodoRow({ todo, delay }) {
  const [open, setOpen] = useState(false);
  const u = URGENCY[todo.urgency] || URGENCY.medium;
  const hasDetail = Boolean(todo.detail);

  return (
    <button
      type="button"
      onClick={() => hasDetail && setOpen((v) => !v)}
      className={`animate-rise group flex w-full items-start gap-3 rounded-[20px] bg-white/[0.05] px-4 py-3 text-left ring-1 ${u.ring} transition-all duration-200 ease-[var(--ease-spring)] hover:bg-white/[0.09] active:scale-[0.985]`}
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

function ScheduleSection({ courses, events, term, onRefresh, loading }) {
  const [weekOffset, setWeekOffset] = useState(0);
  const selected = useMemo(() => selectedWeek(term, weekOffset), [term, weekOffset]);
  const thisWeekCount = useMemo(() => {
    const names = new Set();
    for (const c of courses) {
      const t = new Date(c.startDate).getTime();
      if (!Number.isNaN(t) && t >= selected.weekStartMs && t < selected.weekEndMs) names.add(c.title || c.name);
    }
    return names.size;
  }, [courses, selected.weekStartMs, selected.weekEndMs]);

  return (
    <section className="animate-rise surface-card min-w-0 p-3 md:p-4" style={{ animationDelay: "120ms" }}>
      <div className="mb-3 flex items-center justify-between px-1">
        <div className="flex items-center gap-2">
          <CalendarClock size={14} className="text-[var(--text-tertiary)]" />
          <h2 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">课程表</h2>
        </div>
        <span className="text-[11px] text-[var(--text-tertiary)]">
          {courses.length > 0 ? `${thisWeekCount} 门课 · ${selected.rangeLabel}` : "未导入"}
        </span>
      </div>
      {courses.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-12 text-center text-[var(--text-tertiary)]">
          <p className="text-sm">课程表未导入</p>
          <p className="mt-1 text-xs">在设置页导入正方教务课表后会显示在这里</p>
        </div>
      ) : (
        <WeekTable
          courses={courses}
          events={events}
          weekStartMs={selected.weekStartMs}
          weekEndMs={selected.weekEndMs}
        />
      )}
      <div className="mt-3 flex items-center justify-between gap-2 border-t border-[var(--border)] pt-3">
        <button
          type="button"
          onClick={() => setWeekOffset((v) => v - 1)}
          className="grid h-10 w-10 place-items-center rounded-xl bg-[var(--surface)] text-[var(--text-secondary)] transition hover:bg-[var(--hover-bg)] hover:text-white active:scale-95"
          aria-label="上一周"
        >
          <ChevronLeft size={17} />
        </button>
        <div className="min-w-0 text-center">
          <p className="text-sm font-semibold text-white">{selected.weekLabel}</p>
          <p className="mt-0.5 text-[11px] text-[var(--text-tertiary)]">{term?.semesterLabel || selected.rangeLabel}</p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={onRefresh}
            className="grid h-10 w-10 place-items-center rounded-xl bg-[var(--surface)] text-[var(--text-secondary)] transition hover:bg-[var(--hover-bg)] hover:text-white active:scale-95"
            aria-label="刷新课表"
          >
            <RefreshCw size={15} className={loading ? "animate-spin" : ""} />
          </button>
          <button
            type="button"
            onClick={() => setWeekOffset((v) => v + 1)}
            className="grid h-10 w-10 place-items-center rounded-xl bg-[var(--surface)] text-[var(--text-secondary)] transition hover:bg-[var(--hover-bg)] hover:text-white active:scale-95"
            aria-label="下一周"
          >
            <ChevronRight size={17} />
          </button>
        </div>
      </div>
    </section>
  );
}

function selectedWeek(term, offset) {
  const current = new Date();
  if (term?.week1Monday) {
    const base = new Date(`${term.week1Monday}T00:00:00+08:00`);
    const currentWeek = term.currentWeek || weekNumberFrom(base, current);
    const weekNumber = Math.max(1, currentWeek + offset);
    const start = new Date(base.getTime() + (weekNumber - 1) * 7 * 24 * 60 * 60 * 1000);
    const end = new Date(start.getTime() + 7 * 24 * 60 * 60 * 1000);
    return {
      weekStartMs: start.getTime(),
      weekEndMs: end.getTime(),
      weekLabel: `第${weekNumber}周`,
      rangeLabel: formatDateRange(start, end),
    };
  }
  const start = startOfLocalWeek(current);
  start.setDate(start.getDate() + offset * 7);
  const end = new Date(start.getTime() + 7 * 24 * 60 * 60 * 1000);
  const weekLabel = offset === 0 ? "本周" : offset > 0 ? `下${offset}周` : `上${Math.abs(offset)}周`;
  return {
    weekStartMs: start.getTime(),
    weekEndMs: end.getTime(),
    weekLabel,
    rangeLabel: formatDateRange(start, end),
  };
}

function weekNumberFrom(base, date) {
  const baseWall = chinaWallDate(base);
  const dateWall = chinaWallDate(date);
  const baseStart = new Date(baseWall.getFullYear(), baseWall.getMonth(), baseWall.getDate());
  const dateStart = new Date(dateWall.getFullYear(), dateWall.getMonth(), dateWall.getDate());
  return Math.max(1, Math.floor((dateStart - baseStart) / (7 * 24 * 60 * 60 * 1000)) + 1);
}

// Monday 00:00 of the current week.
function startOfLocalWeek(value) {
  const now = new Date();
  if (value) now.setTime(value.getTime());
  const day = now.getDay(); // 0=Sun..6=Sat
  const mondayOffset = (day + 6) % 7; // days since Monday
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() - mondayOffset);
}

function formatDateRange(start, end) {
  const lastDay = new Date(end.getTime() - 24 * 60 * 60 * 1000);
  const left = start.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric", timeZone: CHINA_TZ });
  const right = lastDay.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric", timeZone: CHINA_TZ });
  return `${left} - ${right}`;
}

function WeekTable({ courses, events, weekStartMs, weekEndMs }) {
  const inThisWeek = (event) => {
    const t = new Date(event.startDate).getTime();
    return !Number.isNaN(t) && t >= weekStartMs && t < weekEndMs;
  };
  const items = [
    ...courses.filter(inThisWeek).map((event) => ({ event, kind: "course" })),
    ...events.filter(inThisWeek).map((event) => ({ event, kind: event.kind || "event" })),
  ].map(toGridItem).filter(Boolean);

  return (
    <div className="overflow-x-auto pb-1">
      <div
        className="grid min-w-[760px] overflow-hidden rounded-2xl border border-[var(--border)] bg-[var(--deep-bg)]"
        style={{
          gridTemplateColumns: "46px repeat(7, minmax(112px, 1fr))",
          gridTemplateRows: `40px repeat(${PERIODS.length}, 70px)`,
        }}
      >
        <GridHeader style={{ gridColumn: 1, gridRow: 1 }}>节</GridHeader>
        {WEEKDAYS.map((day, idx) => (
          <GridHeader key={day.value} style={{ gridColumn: idx + 2, gridRow: 1 }}>
            {day.label}
          </GridHeader>
        ))}

        {PERIODS.map((period, periodIdx) => (
          <div
            key={period.id}
            className="grid place-items-center border-t border-[var(--border)] text-[11px] font-semibold text-[var(--text-tertiary)]"
            style={{ gridColumn: 1, gridRow: periodIdx + 2 }}
          >
            <span>{period.label}</span>
          </div>
        ))}
        {PERIODS.map((period, periodIdx) => (
          WEEKDAYS.map((day, dayIdx) => (
            <div
              key={`${period.id}-${day.value}`}
              className="border-l border-t border-[var(--border)]"
              style={{ gridColumn: dayIdx + 2, gridRow: periodIdx + 2 }}
            />
          ))
        ))}

        {items.map((item) => (
          <div
            key={`${item.kind}-${item.event.id}`}
            className={`z-[1] m-1 overflow-hidden rounded-xl px-2 py-1.5 shadow-sm ring-1 ring-white/20 transition duration-150 ease-[var(--ease-spring)] hover:scale-[1.02] active:scale-[0.98] ${item.color}`}
            style={{
              gridColumn: item.dayIndex + 2,
              gridRow: `${item.periodIndex + 2} / span ${item.span}`,
            }}
          >
            <p className="line-clamp-2 text-xs font-semibold leading-4 text-white">{item.title}</p>
            <p className="mt-0.5 truncate text-[11px] text-white/85">{item.location || item.teacher || formatTime(item.event.startDate)}</p>
            {item.teacher && item.location && (
              <p className="truncate text-[10px] text-white/70">{item.teacher}</p>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

function GridHeader({ children, style }) {
  return (
    <div
      className="grid place-items-center border-l border-[var(--border)] text-xs font-semibold text-[var(--text-tertiary)] first:border-l-0"
      style={style}
    >
      {children}
    </div>
  );
}

function toGridItem({ event, kind }) {
  const start = new Date(event.startDate);
  const end = new Date(event.endDate || event.startDate);
  if (Number.isNaN(start.getTime())) return null;
  const startWall = chinaWallDate(start);
  const endWall = chinaWallDate(end);
  const dayIndex = WEEKDAYS.findIndex((day) => day.value === startWall.getDay());
  if (dayIndex < 0) return null;
  const periodIndex = periodIndexForStart(startWall);
  if (periodIndex < 0) return null;
  const endIndex = periodIndexForEnd(endWall, periodIndex);
  const meta = parseCourseMeta(event.notes);
  return {
    event,
    kind,
    title: event.title || event.name,
    location: event.location,
    teacher: meta.teacher,
    dayIndex,
    periodIndex,
    span: Math.max(1, endIndex - periodIndex + 1),
    color: kind === "course" ? courseColor(event.title || event.name) : "bg-sky-500/85",
  };
}

function periodIndexForStart(date) {
  const minutes = date.getHours() * 60 + date.getMinutes();
  let bestIdx = -1;
  let bestDelta = Infinity;
  PERIODS.forEach((period, idx) => {
    const delta = Math.abs(minutes - toMinutes(period.start));
    if (delta < bestDelta) {
      bestDelta = delta;
      bestIdx = idx;
    }
  });
  if (bestDelta <= 35) return bestIdx;
  return PERIODS.findIndex((period) => {
    const start = toMinutes(period.start);
    const end = toMinutes(period.end);
    return minutes >= start && minutes < end;
  });
}

function periodIndexForEnd(date, startIndex) {
  if (Number.isNaN(date.getTime())) return startIndex;
  const minutes = date.getHours() * 60 + date.getMinutes();
  let endIndex = startIndex;
  for (let i = startIndex; i < PERIODS.length; i += 1) {
    const periodEnd = toMinutes(PERIODS[i].end);
    if (minutes <= periodEnd + 10) {
      endIndex = i;
      break;
    }
    endIndex = i;
  }
  return endIndex;
}

function parseCourseMeta(notes = "") {
  if (!notes) return {};
  const first = String(notes).split("|").find((part) => part && !part.startsWith("第"));
  if (!first) return {};
  return { teacher: first.replace(/^教师[:：]/, "") };
}

function courseColor(title = "") {
  const colors = [
    "bg-emerald-500/85",
    "bg-cyan-500/85",
    "bg-amber-500/90",
    "bg-rose-500/85",
    "bg-violet-500/85",
    "bg-teal-500/85",
  ];
  let hash = 0;
  for (const ch of title) hash = (hash + ch.charCodeAt(0)) % colors.length;
  return colors[hash];
}

function chinaWallDate(value) {
  return new Date(value.toLocaleString("en-US", { timeZone: CHINA_TZ }));
}

function toMinutes(value) {
  const [h, m] = value.split(":").map(Number);
  return h * 60 + m;
}

function formatTime(value) {
  if (!value) return "";
  return new Date(value).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", timeZone: CHINA_TZ });
}
