import { useState } from "react";
import { CalendarClock, BookOpen, Bell, MessageSquare, CheckCircle2, AlertTriangle, GraduationCap, Calendar, ChevronRight, ChevronDown, Trash2, Pencil, Plus } from "lucide-react";

// Friendly label + icon per mutation tool, so the action row reads like
// "创建提醒 · 数学作业" instead of dumping the raw {tool,arguments,result} JSON.
const ACTION_META = {
  create_reminder:               { label: "创建提醒", icon: Plus,         tone: "text-green-400" },
  update_reminder:               { label: "修改提醒", icon: Pencil,       tone: "text-blue-400" },
  complete_reminder:             { label: "完成提醒", icon: CheckCircle2,  tone: "text-emerald-400" },
  delete_reminder:               { label: "删除提醒", icon: Trash2,        tone: "text-red-400" },
  create_calendar_event:         { label: "创建日历事件", icon: Plus,      tone: "text-green-400" },
  update_calendar_event:         { label: "修改日历事件", icon: Pencil,    tone: "text-blue-400" },
  delete_calendar_event:         { label: "删除日历事件", icon: Trash2,    tone: "text-red-400" },
  schedule_notification:         { label: "安排通知", icon: Bell,          tone: "text-green-400" },
  cancel_scheduled_notification: { label: "取消通知", icon: Bell,          tone: "text-red-400" },
  set_push_config:               { label: "更新推送设置", icon: Bell,      tone: "text-blue-400" },
};

// Pull a short human-readable summary out of the tool arguments.
function actionSummary(args) {
  if (!args || typeof args !== "object") return "";
  return args.title || args.summary || args.content || args.message || args.text || args.query || args.id || "";
}

// ── Section header ─────────────────────────────────────────────────────────
function SectionHeader({ icon: Icon, label, count }) {
  return (
    <div className="flex items-center gap-1.5 px-1 mb-1">
      {Icon && <Icon size={12} className="text-[var(--text-tertiary)]" />}
      <span className="text-[11px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">{label}</span>
      {count > 0 && (
        <span className="rounded-full bg-[var(--surface-2)] px-1.5 py-0.5 text-[10px] font-medium text-[var(--text-tertiary)]">
          {count}
        </span>
      )}
    </div>
  );
}

// ── Action row ─────────────────────────────────────────────────────────────
// Backend emits actions as { tool, arguments, result }. Show a tidy one-line
// summary; tuck the full arguments/result behind a click instead of dumping raw
// JSON into the bubble.
function ActionRow({ item }) {
  const [open, setOpen] = useState(false);

  // Legacy/simple shape that already carries a summary — render as before.
  if (item.tool === undefined) {
    return (
      <div className="flex items-center gap-2 px-3 py-2">
        <CheckCircle2 size={14} className="text-[var(--accent)]" />
        <span className="text-sm text-[var(--text-secondary)]">{item.summary || item.title || ""}</span>
      </div>
    );
  }

  const meta = ACTION_META[item.tool] || { label: item.tool, icon: CheckCircle2, tone: "text-[var(--accent)]" };
  const Icon = meta.icon;
  const summary = actionSummary(item.arguments);
  const failed = item.result && typeof item.result === "object" && item.result.ok === false;
  const detail = JSON.stringify({ arguments: item.arguments, result: item.result }, null, 2);

  return (
    <div>
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-2 px-3 py-2 text-left transition-colors hover:bg-[var(--hover-bg)]"
      >
        {failed ? <AlertTriangle size={14} className="shrink-0 text-red-400" /> : <Icon size={14} className={`shrink-0 ${meta.tone}`} />}
        <span className="min-w-0 flex-1 truncate text-sm text-[var(--text-secondary)]">
          <span className="font-medium text-white">{meta.label}</span>
          {summary && <span className="text-[var(--text-tertiary)]"> · {summary}</span>}
          {failed && <span className="text-red-400"> · 失败</span>}
        </span>
        {open ? <ChevronDown size={13} className="shrink-0 text-[var(--text-tertiary)]" /> : <ChevronRight size={13} className="shrink-0 text-[var(--text-tertiary)]" />}
      </button>
      {open && (
        <pre className="mx-3 mb-2 max-h-60 overflow-auto rounded-lg bg-[var(--input-bg)] p-2 text-[11px] leading-4 text-[var(--text-tertiary)]">
{detail}
        </pre>
      )}
    </div>
  );
}

// ── Course row ─────────────────────────────────────────────────────────────
function CourseRow({ item }) {
  const time = item.start_at
    ? new Date(item.start_at).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
    : "";
  const end = item.end_at
    ? new Date(item.end_at).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
    : "";
  return (
    <div className="flex items-start gap-2 px-3 py-2">
      <GraduationCap size={14} className="mt-0.5 shrink-0 text-teal-400" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-white truncate">{item.title || item.name}</p>
        <p className="text-xs text-[var(--text-tertiary)] truncate">
          {[item.location, time && end ? `${time}-${end}` : time].filter(Boolean).join(" · ")}
        </p>
      </div>
    </div>
  );
}

// ── Chaoxing assignment row ────────────────────────────────────────────────
function AssignmentRow({ item }) {
  const due = item.dueDate ? formatDueDate(item.dueDate) : null;
  const color = dueDateColor(item.dueDate);
  return (
    <div className="flex items-start gap-2 px-3 py-2">
      <BookOpen size={14} className="mt-0.5 shrink-0 text-pink-400" />
      <div className="min-w-0 flex-1">
        <p className="text-sm text-[var(--text-secondary)] truncate">{item.title}</p>
        <div className="flex items-center gap-2 mt-0.5">
          <span className="text-xs text-[var(--text-tertiary)] truncate">{item.courseName}</span>
          {due && (
            <span className={`ml-auto shrink-0 text-[11px] font-medium ${color}`}>{due}</span>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Chaoxing message row ───────────────────────────────────────────────────
const SOURCE_BADGE = {
  chaoxing: { label: "学习通", cls: "bg-sky-500/15 text-sky-300" },
  dingtalk: { label: "钉钉", cls: "bg-blue-500/15 text-blue-300" },
  user: { label: "手动", cls: "bg-zinc-500/15 text-zinc-300" },
  user_told: { label: "手动", cls: "bg-zinc-500/15 text-zinc-300" },
  automation: { label: "系统", cls: "bg-violet-500/15 text-violet-300" },
};

function MessageRow({ item }) {
  const isHigh = item.importance === "high";
  const badge = SOURCE_BADGE[item.source_type] || { label: item.source_type || "消息", cls: "bg-zinc-500/15 text-zinc-300" };
  return (
    <div className="px-3 py-2">
      <div className="flex items-center gap-1.5">
        <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${isHigh ? "bg-orange-400" : "bg-emerald-400"}`} />
        <span className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${badge.cls}`}>{badge.label}</span>
        <p className="text-sm font-medium text-white truncate">{item.title}</p>
      </div>
      {item.summary && (
        <p className="ml-3 mt-0.5 text-xs text-[var(--text-tertiary)] line-clamp-2">{item.summary}</p>
      )}
      {item.action_hint && (
        <p className="ml-3 mt-0.5 text-xs text-[var(--accent-soft)]">{item.action_hint}</p>
      )}
    </div>
  );
}

// ── Reminder row ───────────────────────────────────────────────────────────
function ReminderRow({ item }) {
  const due = item.dueDate || item.due_at;
  return (
    <div className="flex items-start gap-2 px-3 py-2">
      <CheckCircle2 size={14} className={`mt-0.5 shrink-0 ${item.isImportant ? "text-yellow-400" : "text-emerald-400"}`} />
      <div className="min-w-0 flex-1">
        <p className="text-sm text-[var(--text-secondary)] truncate">{item.title}</p>
        {due && (
          <p className="text-xs text-[var(--text-tertiary)] mt-0.5">
            {new Date(due).toLocaleDateString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })}
          </p>
        )}
      </div>
    </div>
  );
}

// ── Event row ──────────────────────────────────────────────────────────────
function EventRow({ item }) {
  const start = item.start_at ? new Date(item.start_at) : null;
  const time = start ? start.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" }) : "";
  return (
    <div className="flex items-start gap-2 px-3 py-2">
      <Calendar size={14} className="mt-0.5 shrink-0 text-blue-400" />
      <div className="min-w-0 flex-1">
        <p className="text-sm text-[var(--text-secondary)] truncate">{item.title}</p>
        <p className="text-xs text-[var(--text-tertiary)] mt-0.5">
          {[time, item.location].filter(Boolean).join(" · ")}
        </p>
      </div>
    </div>
  );
}

// ── Section wrapper ────────────────────────────────────────────────────────
function PayloadSection({ icon, label, items, children }) {
  if (!items || items.length === 0) return null;
  return (
    <div className="mb-2">
      <SectionHeader icon={icon} label={label} count={items.length} />
      <div className="rounded-xl border border-[var(--border)] bg-[var(--surface)] overflow-hidden">
        {children}
      </div>
    </div>
  );
}

// ── Main payload view ──────────────────────────────────────────────────────
export default function SchedulePayloadView({ payload }) {
  if (!payload) return null;

  const actions = payload.actions || [];
  const courses = payload.courses || [];
  const assignments = payload.chaoxing_assignments || [];
  const messages = payload.chaoxing_messages || [];
  const reminders = (payload.reminders || []).filter((r) => !r.isCompleted);
  const events = payload.events || [];

  const totalItems = actions.length + courses.length + assignments.length + messages.length + reminders.length + events.length;
  if (totalItems === 0) return null;

  return (
    <div className="mt-2 max-w-[620px] space-y-1">
      <PayloadSection icon={CheckCircle2} label="操作" items={actions}>
        {actions.map((item, i) => (
          <div key={i} className={i < actions.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <ActionRow item={item} />
          </div>
        ))}
      </PayloadSection>

      <PayloadSection icon={GraduationCap} label="课程表" items={courses}>
        {courses.map((item, i) => (
          <div key={item.id || i} className={i < courses.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <CourseRow item={item} />
          </div>
        ))}
      </PayloadSection>

      <PayloadSection icon={BookOpen} label="学习通 DDL" items={assignments}>
        {assignments.map((item, i) => (
          <div key={item.id || i} className={i < assignments.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <AssignmentRow item={item} />
          </div>
        ))}
      </PayloadSection>

      <PayloadSection icon={MessageSquare} label="消息记忆" items={messages}>
        {messages.map((item, i) => (
          <div key={item.id || i} className={i < messages.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <MessageRow item={item} />
          </div>
        ))}
      </PayloadSection>

      <PayloadSection icon={Bell} label="提醒事项" items={reminders}>
        {reminders.map((item, i) => (
          <div key={item.id || i} className={i < reminders.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <ReminderRow item={item} />
          </div>
        ))}
      </PayloadSection>

      <PayloadSection icon={Calendar} label="日历事件" items={events}>
        {events.map((item, i) => (
          <div key={item.id || i} className={i < events.length - 1 ? "border-b border-[var(--border)]" : ""}>
            <EventRow item={item} />
          </div>
        ))}
      </PayloadSection>
    </div>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────
function formatDueDate(isoStr) {
  const diff = new Date(isoStr).getTime() - Date.now();
  const abs = Math.abs(diff);
  const hours = Math.floor(abs / 3600000);
  const days = Math.floor(hours / 24);
  if (diff < 0) {
    return days > 0 ? `逾期 ${days}天` : `逾期 ${hours}h`;
  }
  if (days > 0) return `${days}天后`;
  if (hours > 0) return `${hours}h 后`;
  const mins = Math.floor(abs / 60000);
  return `${mins}min 后`;
}

function dueDateColor(dueDate) {
  if (!dueDate) return "text-[var(--text-tertiary)]";
  const diff = new Date(dueDate).getTime() - Date.now();
  if (diff < 0) return "text-red-400";
  if (diff < 24 * 3600 * 1000) return "text-orange-400";
  if (diff < 72 * 3600 * 1000) return "text-yellow-400";
  return "text-[var(--text-tertiary)]";
}
