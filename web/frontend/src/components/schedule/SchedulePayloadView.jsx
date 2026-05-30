import { CalendarClock, BookOpen, Bell, MessageSquare, CheckCircle2, AlertTriangle, GraduationCap, Calendar } from "lucide-react";

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
function ActionRow({ item }) {
  const kindIcon = {
    created: <CheckCircle2 size={14} className="text-green-400" />,
    updated: <CalendarClock size={14} className="text-blue-400" />,
    completed: <CheckCircle2 size={14} className="text-emerald-400" />,
    deleted: <AlertTriangle size={14} className="text-red-400" />,
  };
  const icon = kindIcon[item.kind] || <CheckCircle2 size={14} className="text-[var(--accent)]" />;
  return (
    <div className="flex items-center gap-2 px-3 py-2">
      {icon}
      <span className="text-sm text-[var(--text-secondary)]">{item.summary || item.title || JSON.stringify(item)}</span>
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
function MessageRow({ item }) {
  const isHigh = item.importance === "high";
  return (
    <div className="px-3 py-2">
      <div className="flex items-center gap-1.5">
        <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${isHigh ? "bg-orange-400" : "bg-emerald-400"}`} />
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

      <PayloadSection icon={MessageSquare} label="学习通消息" items={messages}>
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
