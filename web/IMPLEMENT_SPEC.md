# ChatBot — Feature Implementation Spec

> **给 Coding Agent 用。逐模块实现，改完本地验证，然后 rsync + docker compose build + recreate 部署。**
>
> 部署命令见文末。所有路径都是本地开发机路径（/Users/macalan/Documents/chatbot/web/）。

---

## 环境速查

```
本地前端：  /Users/macalan/Documents/chatbot/web/frontend/
本地后端：  /Users/macalan/Documents/chatbot/web/backend/app/
服务器：    ssh aliyun-root "..."
数据库：    /data/chatbot.db（容器内）
```

---

## Bug 1 — 通知中心时间显示错误（差 8 小时）

### 根因

`notification_log.sent_at` 由 `datetime.utcnow().isoformat()` 写入，格式是
`"2026-05-27T14:03:00"`（无时区后缀）。

JavaScript 的 `new Date("2026-05-27T14:03:00")` **将无后缀的 datetime 字符串解析为本地时间**（CST = UTC+8），导致比实际 UTC 时间多 8 小时——22:03 CST 发出的通知，显示成"8 小时前"。

### 修复文件

`frontend/src/components/notifications/NotificationCenter.jsx`

### 修复方案

在文件顶部添加工具函数 `parseUTC`，所有用到 `new Date(isoStr)` 的地方改用它：

```js
// 在文件顶部（imports 之后）添加
function parseUTC(isoStr) {
  if (!isoStr) return null;
  // 没有时区后缀的字符串一律当 UTC 处理（服务器存的就是 UTC）
  const hastz = isoStr.endsWith('Z') || /[+-]\d{2}:\d{2}$/.test(isoStr);
  return new Date(hastz ? isoStr : isoStr + 'Z');
}
```

然后修改这两个函数：

```js
function relativeTime(isoStr) {
  if (!isoStr) return "";
  const d = parseUTC(isoStr);
  if (!d) return "";
  const diff = Date.now() - d.getTime();
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
  if (!d) return "未知日期";
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return "今天";
  if (d.toDateString() === yesterday.toDateString()) return "昨天";
  return d.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });
}
```

### 验证

刷新通知页，刚才发的通知应显示"刚刚"或几分钟前，不是"8 小时前"。

---

## Bug 2 — 学习通作业没有完成状态

### 根因

`chaoxing_service.py` 的 `_parse_assignments_html` 已经解析出 `status` 字段
（`"未提交"` / `"已提交"` / `"已截止"`），但前端完全忽略了它——sidebar 和
overview 都把所有作业一起展示，没有过滤也没有标记。

### 修复文件

`frontend/src/components/schedule/ScheduleSidebar.jsx`

### 修复方案

**1. 给 `ScheduleSidebar.jsx` 的作业列表加状态筛选和徽章**

把 `assignments` 计算和渲染部分替换如下：

```jsx
// 替换现有的 assignments 计算（约第 70 行）
const [showCompleted, setShowCompleted] = useState(false);

const allAssignments = (data?.assignments || []).slice().sort((a, b) => {
  if (!a.dueDate && !b.dueDate) return 0;
  if (!a.dueDate) return 1;
  if (!b.dueDate) return -1;
  return new Date(a.dueDate) - new Date(b.dueDate);
});

const assignments = showCompleted
  ? allAssignments
  : allAssignments.filter((a) => a.status !== "已提交");

const completedCount = allAssignments.filter((a) => a.status === "已提交").length;
```

**2. Section 的 action 区域加切换按钮（在作业 Section 的 action prop 处）**

```jsx
action={
  completedCount > 0 && (
    <button
      onClick={() => setShowCompleted((v) => !v)}
      className="rounded px-1.5 py-0.5 text-[10px] text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
    >
      {showCompleted ? "隐藏已交" : `+${completedCount} 已交`}
    </button>
  )
}
```

**3. 每条作业加状态徽章（替换现有 map 渲染）**

```jsx
assignments.map((a) => {
  const color = deadlineColor(a.dueDate);
  const countdown = formatCountdown(a.dueDate);
  const isDone = a.status === "已提交";
  const isOverdue = a.status === "已截止";
  return (
    <div
      key={a.id}
      className={`px-3 py-2 border-b border-[var(--border)] last:border-0 ${isDone ? "opacity-50" : ""}`}
    >
      <div className="flex items-start gap-2">
        <p className={`flex-1 text-sm leading-5 ${isDone ? "line-through text-[var(--text-tertiary)]" : "text-[var(--text-secondary)]"}`}>
          {a.title}
        </p>
        {isDone && (
          <span className="shrink-0 rounded-full bg-green-500/20 px-1.5 py-0.5 text-[10px] font-medium text-green-400">
            已交
          </span>
        )}
        {isOverdue && !isDone && (
          <span className="shrink-0 rounded-full bg-red-500/20 px-1.5 py-0.5 text-[10px] font-medium text-red-400">
            已截止
          </span>
        )}
      </div>
      <div className="mt-0.5 flex items-center gap-2">
        <span className="text-xs text-[var(--text-tertiary)] truncate">{a.courseName}</span>
        {countdown && !isDone && (
          <span className={`ml-auto flex shrink-0 items-center gap-0.5 text-[11px] font-medium ${color}`}>
            <Clock size={10} />
            {countdown}
          </span>
        )}
      </div>
    </div>
  );
})
```

**4. 同步修复 `ScheduleOverview.jsx` 的 `buildAttention`**

在 `buildAttention` 里过滤掉已提交作业（约第 174 行）：

```js
// 修改 assignments 的 map 行，加 filter：
...(data?.assignments || [])
  .filter((a) => a.status !== "已提交")  // 只显示未完成
  .map((a) => ({
    id: `a-${a.id}`,
    title: a.title,
    detail: `学习通 · ${a.courseName || ""} · 截止 ${a.dueDate || "未知"}`,
    date: a.dueDate,
  })),
```

### 验证

Sidebar 的作业列表默认只显示"未提交"，已交的作业带删除线 + 隐藏。点击"+ N 已交"展开。

---

## Feature 3 — Dashboard 第一页（ScheduleOverview）重写

### 根因

当前 Overview 在数据稀少时完全是空状态：

1. `mapChaoxingCourse` 的 `startDate: ""` → 学习通课程永远不会显示在周表格里
2. 周表格里没有"今天"高亮，没有"当前周"概念
3. 没有学习通登录状态提示——未登录时整页空白
4. "今日事务"摘要是硬编码字符串，没有实际数据
5. 没有快速操作入口

### 修复文件

- `frontend/src/components/schedule/ScheduleOverview.jsx`（全面升级）
- `backend/app/routers/schedule.py`（sidebar API 添加 `chaoxing_logged_in` 字段）

### 修复方案

#### 后端：sidebar API 加 chaoxing 状态

在 `schedule.py` 的 `get_schedule_sidebar` 函数末尾，把 return 改为：

```python
return {
    "courses": courses,
    "local_courses": courses_local,
    "events": events,
    "week_events": events,
    "reminders": reminders,
    "assignments": assignments,
    "memory_insights": memory_insights,
    "chaoxing_logged_in": chaoxing_svc.is_logged_in,  # 新增
}
```

#### 前端：ScheduleOverview.jsx 重写

把整个文件替换成下面的版本。关键改动：

1. **"今天"头部卡片**：日期、星期、学期第N周（从 config 算）
2. **学习通状态卡**：未登录时显示提示，已登录显示作业数
3. **WeekTable 只用 `local_courses`**（有正确 startDate 的）；chaoxing 课程单独列出
4. **今天列高亮**
5. **各 section 的空状态有引导文字**

```jsx
import { useEffect, useMemo, useState, useCallback } from "react";
import {
  CalendarClock, CheckCircle2, Clock, RefreshCw, Sparkles,
  AlertCircle, ChevronLeft, ChevronRight, BookOpen,
} from "lucide-react";
import { fetchScheduleSidebar } from "../../api/schedule";

// ── Time constants ────────────────────────────────────────────────────────────
const WEEKDAYS = [
  { label: "周一", value: 1 },
  { label: "周二", value: 2 },
  { label: "周三", value: 3 },
  { label: "周四", value: 4 },
  { label: "周五", value: 5 },
  { label: "周六", value: 6 },
  { label: "周日", value: 0 },
];

const PERIODS = [
  { id: 1, label: "1", start: "08:00", end: "08:45" },
  { id: 2, label: "2", start: "08:50", end: "09:35" },
  { id: 3, label: "3", start: "09:50", end: "10:35" },
  { id: 4, label: "4", start: "10:40", end: "11:25" },
  { id: 5, label: "5", start: "11:30", end: "12:15" },
  { id: 6, label: "6", start: "13:30", end: "14:15" },
  { id: 7, label: "7", start: "14:20", end: "15:05" },
  { id: 8, label: "8", start: "15:20", end: "16:05" },
  { id: 9, label: "9", start: "16:10", end: "16:55" },
  { id: 10, label: "10", start: "18:30", end: "19:15" },
  { id: 11, label: "11", start: "19:20", end: "20:05" },
  { id: 12, label: "12", start: "20:10", end: "20:55" },
];

function toMinutes(value) {
  const [h, m] = value.split(":").map(Number);
  return h * 60 + m;
}

// ── Semester week calculation ─────────────────────────────────────────────────
// Returns current week number (1-based) given semester start Monday.
// Falls back to null if semester_start not set.
function getSemesterWeek(semesterStart) {
  if (!semesterStart) return null;
  const start = new Date(semesterStart);
  const now = new Date();
  const diffMs = now - start;
  if (diffMs < 0) return null;
  return Math.floor(diffMs / (7 * 24 * 60 * 60 * 1000)) + 1;
}

// Return Monday of the week that contains `date`.
function getMondayOf(date) {
  const d = new Date(date);
  const day = d.getDay(); // 0=Sun
  const diff = day === 0 ? -6 : 1 - day;
  d.setDate(d.getDate() + diff);
  d.setHours(0, 0, 0, 0);
  return d;
}

// ── Settings API (semester start persisted in backend settings table) ─────────
async function fetchScheduleConfig() {
  try {
    const r = await fetch("/api/schedule/config");
    if (r.ok) return await r.json();
  } catch (_) {}
  return { semester_start: null };
}

// ── Main component ────────────────────────────────────────────────────────────
export default function ScheduleOverview() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [config, setConfig] = useState({ semester_start: null });

  // viewMonday: the Monday of the currently displayed week
  const [viewMonday, setViewMonday] = useState(() => getMondayOf(new Date()));

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [sidebarData, cfg] = await Promise.all([
        fetchScheduleSidebar(),
        fetchScheduleConfig(),
      ]);
      setData(sidebarData);
      setConfig(cfg);
    } catch (e) {
      console.error("Failed to load schedule overview:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  // Navigate weeks
  const prevWeek = () => setViewMonday((d) => {
    const n = new Date(d);
    n.setDate(n.getDate() - 7);
    return n;
  });
  const nextWeek = () => setViewMonday((d) => {
    const n = new Date(d);
    n.setDate(n.getDate() + 7);
    return n;
  });
  const goToday = () => setViewMonday(getMondayOf(new Date()));

  const semesterWeek = getSemesterWeek(config.semester_start);

  // Only use local_courses (they have proper startDate)
  const courses = useMemo(() => data?.local_courses || [], [data]);

  const attention = useMemo(() => buildAttention(data), [data]);

  // Format date range for the week header
  const viewSunday = useMemo(() => {
    const d = new Date(viewMonday);
    d.setDate(d.getDate() + 6);
    return d;
  }, [viewMonday]);

  const isThisWeek = useMemo(
    () => getMondayOf(new Date()).getTime() === viewMonday.getTime(),
    [viewMonday]
  );

  return (
    <div className="h-full overflow-y-auto bg-[var(--panel-bg)] pb-[calc(env(safe-area-inset-bottom)+5rem)]">
      {/* ── Header ── */}
      <header className="sticky top-0 z-10 flex min-h-[56px] items-center justify-between border-b border-[var(--border)] bg-[var(--bar-bg)] px-4 backdrop-blur-xl">
        <div>
          <h1 className="text-sm font-semibold text-white">日程总览</h1>
          {semesterWeek && (
            <p className="text-xs text-[var(--text-tertiary)]">第 {semesterWeek} 周</p>
          )}
        </div>
        <button
          onClick={refresh}
          disabled={loading}
          className="grid h-10 w-10 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] disabled:opacity-50"
          aria-label="刷新"
        >
          <RefreshCw size={16} className={loading ? "animate-spin" : ""} />
        </button>
      </header>

      <div className="grid gap-4 p-4 lg:grid-cols-[340px_minmax(0,1fr)] lg:p-6">
        {/* ── Left column: today card + attention ── */}
        <section className="space-y-4">
          {/* Today card */}
          <TodayCard data={data} attention={attention} />

          {/* Chaoxing status */}
          {data && !data.chaoxing_logged_in && (
            <div className="flex items-start gap-3 rounded-[18px] border border-orange-500/30 bg-orange-500/10 p-4">
              <AlertCircle size={18} className="mt-0.5 shrink-0 text-orange-400" />
              <div>
                <p className="text-sm font-medium text-white">学习通未连接</p>
                <p className="mt-0.5 text-xs text-[var(--text-tertiary)]">
                  在设置中登录学习通，即可同步作业截止时间和课程信息。
                </p>
              </div>
            </div>
          )}

          <OverviewSection title="现在/今天最该注意" icon={Clock} items={attention.primary} emptyHint="暂无紧急事项" />
          <OverviewSection title="未来 48 小时" icon={CalendarClock} items={attention.upcoming} emptyHint="近两天没有安排" />
          <OverviewSection
            title="服务器提醒事项"
            icon={CheckCircle2}
            items={(data?.reminders || []).slice(0, 6).map(reminderItem)}
            emptyHint="暂无提醒，在 Agent 中添加"
          />

          {/* Chaoxing courses list (no time info → can't go in grid) */}
          {(data?.courses || []).length > 0 && (
            <section className="rounded-[18px] border border-[var(--border)] bg-[var(--surface)] p-4">
              <div className="mb-3 flex items-center gap-2 text-[var(--text-secondary)]">
                <BookOpen size={16} />
                <h2 className="text-sm font-semibold text-white">学习通课程</h2>
              </div>
              <div className="space-y-1.5">
                {(data.courses || []).slice(0, 8).map((c) => (
                  <div key={c.id} className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
                    <p className="truncate text-sm text-white">{c.name}</p>
                    {c.teacher && (
                      <p className="mt-0.5 truncate text-xs text-[var(--text-tertiary)]">{c.teacher}</p>
                    )}
                  </div>
                ))}
              </div>
            </section>
          )}
        </section>

        {/* ── Right column: weekly grid ── */}
        <section className="min-w-0 rounded-[18px] border border-[var(--border)] bg-[var(--surface)] p-3">
          {/* Week navigation */}
          <div className="mb-3 flex items-center justify-between px-1">
            <h2 className="text-base font-semibold text-white">
              {formatWeekRange(viewMonday, viewSunday)}
            </h2>
            <div className="flex items-center gap-1">
              {!isThisWeek && (
                <button
                  onClick={goToday}
                  className="rounded-lg border border-[var(--border)] px-2 py-1 text-xs text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
                >
                  本周
                </button>
              )}
              <button
                onClick={prevWeek}
                className="grid h-7 w-7 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
              >
                <ChevronLeft size={16} />
              </button>
              <button
                onClick={nextWeek}
                className="grid h-7 w-7 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
              >
                <ChevronRight size={16} />
              </button>
            </div>
          </div>

          {courses.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12 text-center">
              <CalendarClock size={36} className="mb-3 text-[var(--text-tertiary)] opacity-40" />
              <p className="text-sm font-medium text-[var(--text-secondary)]">暂无课程表</p>
              <p className="mt-1 text-xs text-[var(--text-tertiary)]">
                在 Agent 中说"帮我导入课程表"，即可生成周视图
              </p>
            </div>
          ) : (
            <WeekTable
              courses={courses}
              events={data?.week_events || []}
              viewMonday={viewMonday}
            />
          )}
        </section>
      </div>
    </div>
  );
}

// ── Today card ────────────────────────────────────────────────────────────────
function TodayCard({ data, attention }) {
  const now = new Date();
  const weekdayName = now.toLocaleDateString("zh-CN", { weekday: "long" });
  const dateStr = now.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });

  const pendingAssignments = (data?.assignments || []).filter(
    (a) => a.status !== "已提交"
  ).length;
  const urgentCount = attention.primary.length;

  return (
    <div className="rounded-[18px] border border-[var(--border)] bg-[var(--surface)] p-4">
      <div className="flex items-start justify-between">
        <div>
          <p className="text-xs font-medium text-[var(--text-tertiary)]">{weekdayName}</p>
          <p className="mt-0.5 text-2xl font-bold text-white">{dateStr}</p>
        </div>
        <Sparkles size={20} className="mt-1 text-[var(--accent-soft)]" />
      </div>
      <div className="mt-3 flex gap-2 text-sm">
        {urgentCount > 0 && (
          <span className="rounded-lg bg-red-500/15 px-2 py-1 text-xs font-medium text-red-400">
            {urgentCount} 项紧急
          </span>
        )}
        {pendingAssignments > 0 && (
          <span className="rounded-lg bg-orange-500/15 px-2 py-1 text-xs font-medium text-orange-400">
            {pendingAssignments} 个作业待交
          </span>
        )}
        {urgentCount === 0 && pendingAssignments === 0 && (
          <span className="text-xs text-[var(--text-tertiary)]">今天没有紧急事项</span>
        )}
      </div>
    </div>
  );
}

// ── Section component ─────────────────────────────────────────────────────────
function OverviewSection({ title, icon: Icon, items, emptyHint }) {
  return (
    <section className="rounded-[18px] border border-[var(--border)] bg-[var(--surface)] p-4">
      <div className="mb-3 flex items-center gap-2 text-[var(--text-secondary)]">
        <Icon size={16} />
        <h2 className="text-sm font-semibold text-white">{title}</h2>
      </div>
      {items?.length ? (
        <div className="space-y-2">
          {items.map((item) => (
            <div key={item.id} className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
              <p className="truncate text-sm font-medium text-white">{item.title}</p>
              <p className="mt-0.5 truncate text-xs text-[var(--text-tertiary)]">{item.detail}</p>
            </div>
          ))}
        </div>
      ) : (
        <p className="text-xs text-[var(--text-tertiary)]">{emptyHint || "暂无"}</p>
      )}
    </section>
  );
}

// ── Week table ────────────────────────────────────────────────────────────────
function WeekTable({ courses, events, viewMonday }) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  // Compute the date for each weekday column based on viewMonday
  const weekDates = WEEKDAYS.map((day, i) => {
    const d = new Date(viewMonday);
    d.setDate(d.getDate() + i); // Mon=0, Tue=1, ..., Sun=6
    return d;
  });

  const items = [
    ...courses.map((c) => ({ event: c, kind: "course" })),
    ...events.map((e) => ({ event: e, kind: e.kind || "event" })),
  ];

  return (
    <div className="overflow-x-auto">
      <div className="min-w-[640px] overflow-hidden rounded-2xl border border-[var(--border)]">
        {/* Header row */}
        <div className="grid border-b border-[var(--border)] bg-[var(--deep-bg)]"
          style={{ gridTemplateColumns: "38px repeat(7, minmax(80px, 1fr))" }}>
          <Cell muted>节</Cell>
          {weekDates.map((d, i) => {
            const isToday = d.getTime() === today.getTime();
            return (
              <div
                key={i}
                className={`grid min-h-9 place-items-center text-xs font-semibold ${isToday ? "text-[var(--accent)]" : "text-[var(--text-tertiary)]"}`}
              >
                <span>{WEEKDAYS[i].label}</span>
                <span className={`text-[10px] ${isToday ? "font-bold" : "font-normal"}`}>
                  {d.getDate()}
                </span>
              </div>
            );
          })}
        </div>

        {/* Period rows */}
        {PERIODS.map((period) => (
          <div
            key={period.id}
            className="grid min-h-[60px] border-b border-[var(--border)] last:border-b-0"
            style={{ gridTemplateColumns: "38px repeat(7, minmax(80px, 1fr))" }}
          >
            <Cell muted>{period.label}</Cell>
            {weekDates.map((colDate, i) => {
              const isToday = colDate.getTime() === today.getTime();
              return (
                <div
                  key={i}
                  className={`min-h-[60px] border-l border-[var(--border)] p-1 ${isToday ? "bg-[var(--accent)]/5" : ""}`}
                >
                  {itemsForCell(items, colDate, period).slice(0, 2).map(({ event, kind }) => (
                    <div
                      key={`${kind}-${event.id}`}
                      className={`mb-1 rounded-lg px-1.5 py-1 ${
                        kind === "course" ? "bg-emerald-500/80" : "bg-[var(--accent)]/80"
                      }`}
                    >
                      <p className="line-clamp-2 text-[11px] font-semibold leading-4 text-white">
                        {event.title || event.name}
                      </p>
                      {(event.location) && (
                        <p className="truncate text-[10px] text-white/75">{event.location}</p>
                      )}
                    </div>
                  ))}
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}

function Cell({ children, muted }) {
  return (
    <div className={`grid min-h-9 place-items-center text-xs font-semibold ${muted ? "text-[var(--text-tertiary)]" : "text-white"}`}>
      {children}
    </div>
  );
}

// Match a course/event to a cell by actual date (not weekday) and time
function itemsForCell(items, colDate, period) {
  const periodStartMin = toMinutes(period.start);
  const periodEndMin = toMinutes(period.end);
  return items.filter(({ event }) => {
    if (!event.startDate) return false;
    const start = new Date(event.startDate);
    if (Number.isNaN(start.getTime())) return false;
    // Match by exact date (year-month-day)
    const eventDate = new Date(start);
    eventDate.setHours(0, 0, 0, 0);
    if (eventDate.getTime() !== colDate.getTime()) return false;
    const mins = start.getHours() * 60 + start.getMinutes();
    return mins >= periodStartMin - 20 && mins <= periodEndMin + 20;
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function buildAttention(data) {
  const now = Date.now();
  const items = [
    ...(data?.assignments || [])
      .filter((a) => a.status !== "已提交")
      .map((a) => ({
        id: `a-${a.id}`,
        title: a.title,
        detail: `学习通 · ${a.courseName || ""} · 截止 ${a.dueDate || "未知"}`,
        date: a.dueDate,
      })),
    ...(data?.reminders || []).map(reminderItem),
    ...(data?.memory_insights || []).map((m) => ({
      id: `m-${m.id}`,
      title: m.title,
      detail: m.action_hint || m.summary,
      date: m.expires_at,
      importance: m.importance,
    })),
  ];
  const primary = items
    .filter((item) => {
      const t = item.date ? new Date(item.date).getTime() : null;
      return item.importance === "high" || (t && t <= now + 24 * 60 * 60 * 1000);
    })
    .slice(0, 5);
  const upcoming = items
    .filter((item) => {
      const t = item.date ? new Date(item.date).getTime() : null;
      return t && t > now + 24 * 60 * 60 * 1000 && t <= now + 48 * 60 * 60 * 1000;
    })
    .slice(0, 6);
  return { primary, upcoming };
}

function reminderItem(reminder) {
  return {
    id: `r-${reminder.id}`,
    title: reminder.title,
    detail: `提醒 · ${reminder.listName || "默认"} · ${reminder.dueDate ? formatDate(reminder.dueDate) : "无截止"}`,
    date: reminder.dueDate,
    importance: reminder.isImportant ? "high" : "medium",
  };
}

function formatDate(value) {
  return new Date(value).toLocaleString("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatWeekRange(monday, sunday) {
  const fmt = (d) => d.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
  return `${fmt(monday)} — ${fmt(sunday)}`;
}
```

#### 后端：新增 `/api/schedule/config` 端点

在 `backend/app/routers/schedule.py` 头部 imports 后，新增两个端点（加在 `/sessions` 之前）：

```python
import json as _json

@router.get("/config")
async def get_schedule_config():
    """Return schedule view config (semester_start, etc.)."""
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_config'"
        )).fetchone()
    if row:
        try:
            return _json.loads(row[0])
        except Exception:
            pass
    return {"semester_start": None}


@router.patch("/config")
async def update_schedule_config(request: Request):
    """Update schedule view config fields."""
    body = await request.json()
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_config'"
        )).fetchone()
        current = {}
        if row:
            try:
                current = _json.loads(row[0])
            except Exception:
                pass
        current.update({k: v for k, v in body.items() if k in ("semester_start", "week_count", "show_weekend")})
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('schedule_config', ?)",
            (_json.dumps(current),),
        )
        await db.commit()
    return {"ok": True, "config": current}
```

### 验证

1. Dashboard 有今天日期卡
2. 课程表如果没有导入数据，显示"在 Agent 中说帮我导入课程表"空状态
3. 未登录学习通时，出现橙色提示卡
4. 已导入课程后，周表格正确渲染，今天列有淡蓝色背景
5. 点击 ← → 可以切换周

---

## Feature 4 — 课程表动态调控（Agent 控制视图）

### 目标

用户可以对 Agent 说：
- "帮我设置学期开始时间是 9 月 1 日"
- "显示第 3 周的课表"
- "现在是第几周"

Agent 通过工具修改后端 `schedule_config`，前端重新加载后反映变化。

### 修复文件

`backend/app/services/schedule_agent.py`

### 修复方案

在 `schedule_agent.py` 的工具列表里新增 `set_schedule_config` 工具定义，并在 `_execute_schedule_tool` 里处理它。

**1. 工具定义（加到 `_TOOL_DEFS` 列表里）**

```python
{
    "name": "set_schedule_config",
    "description": "设置学期开始日期或切换当前显示的周次。用于更新课表视图。",
    "input_schema": {
        "type": "object",
        "properties": {
            "semester_start": {
                "type": "string",
                "description": "学期第一周的周一日期，格式 YYYY-MM-DD，例如 '2025-09-01'",
            },
            "week_offset": {
                "type": "integer",
                "description": "从今天算起，偏移多少周。0=本周，1=下周，-1=上周。设置 semester_start 时不需要填。",
            },
        },
    },
},
```

**2. 工具执行（在 `_execute_schedule_tool` 的 if/elif 链末尾加）**

```python
elif name == "set_schedule_config":
    import aiohttp
    semester_start = args.get("semester_start")
    patch = {}
    if semester_start:
        patch["semester_start"] = semester_start
    if patch:
        async with aiosqlite.connect(db_path) as db:
            row = await (await db.execute(
                "SELECT value FROM settings WHERE key='schedule_config'"
            )).fetchone()
            current = {}
            if row:
                try:
                    current = json.loads(row[0])
                except Exception:
                    pass
            current.update(patch)
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('schedule_config', ?)",
                (json.dumps(current),),
            )
            await db.commit()
    
    # Compute current week if semester_start is set
    msg_parts = []
    if semester_start:
        msg_parts.append(f"已设置学期开始时间为 {semester_start}。")
    
    # Calculate what week it is now
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_config'"
        )).fetchone()
    cfg = {}
    if row:
        try:
            cfg = json.loads(row[0])
        except Exception:
            pass
    ss = cfg.get("semester_start")
    if ss:
        from datetime import datetime as _dt
        try:
            start = _dt.strptime(ss, "%Y-%m-%d")
            week_num = ((_dt.now() - start).days // 7) + 1
            msg_parts.append(f"当前是第 {week_num} 周。")
        except Exception:
            pass
    
    return json.dumps({"ok": True, "message": " ".join(msg_parts) or "配置已更新。"})
```

**3. 在 system prompt 里加一段说明（在 `_build_system_prompt` 函数里，工具列表描述后面加）**

```python
"""
- set_schedule_config: 设置学期开始日期（semester_start，格式 YYYY-MM-DD），
  让课表能显示"第几周"。用户提到"学期开始"、"第一周"、"开学"时主动设置。
  设置后告知用户当前是第几周。
"""
```

### 验证

对 Agent 说"学期第一周是 2025 年 9 月 1 日"，Agent 调用工具，回复"已设置，当前是第 X 周"。
刷新 Overview，头部显示"第 X 周"。

---

## 部署命令

每次改完代码后执行：

```bash
# 后端改动
rsync -az --exclude='__pycache__' --exclude='*.pyc' -e ssh \
  /Users/macalan/Documents/chatbot/web/backend/app/ \
  aliyun-root:/opt/chatbot/backend/app/
ssh aliyun-root "cd /opt/chatbot && docker compose build backend && docker compose up -d --force-recreate backend"

# 前端改动
rsync -az --exclude='node_modules' --exclude='dist' -e ssh \
  /Users/macalan/Documents/chatbot/web/frontend/ \
  aliyun-root:/opt/chatbot/frontend/
ssh aliyun-root "cd /opt/chatbot && docker compose build frontend && docker compose up -d --force-recreate frontend"

# 验证
ssh aliyun-root "docker logs chatbot-backend-1 --tail 10 2>&1"
# 应看到 "Application startup complete." 无 ERROR
```

---

## 实现顺序建议

| 顺序 | 模块 | 难度 | 影响 |
|------|------|------|------|
| 1 | Bug 1（时间戳） | 低 | 立即可见 |
| 2 | Bug 2（作业状态） | 低 | 立即可见 |
| 3 | Feature 3（Dashboard）—— 后端先 | 中 | 需要前后端配合 |
| 4 | Feature 3（Dashboard）—— 前端 | 中 | |
| 5 | Feature 4（Agent 调控） | 中 | 依赖 Feature 3 |

每个改完验证后再做下一个。
