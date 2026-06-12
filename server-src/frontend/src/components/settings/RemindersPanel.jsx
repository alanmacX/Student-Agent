import { useState, useEffect, useCallback } from "react";
import {
  Plus, Trash2, Star, StarOff, Check, Clock, RefreshCw, AlarmClock
} from "lucide-react";
import { fetchReminders, createReminder, updateReminder, deleteReminder } from "../../api/reminders";

function dueColor(dueDate) {
  if (!dueDate) return "";
  const diff = new Date(dueDate).getTime() - Date.now();
  if (diff < 0) return "text-red-400";
  if (diff < 24 * 3600 * 1000) return "text-orange-400";
  if (diff < 72 * 3600 * 1000) return "text-yellow-400";
  return "text-[var(--text-tertiary)]";
}

function formatDue(dueDate) {
  if (!dueDate) return null;
  const d = new Date(dueDate);
  const diff = d.getTime() - Date.now();
  const abs = Math.abs(diff);
  const mins = Math.floor(abs / 60000);
  const hours = Math.floor(mins / 60);
  const days = Math.floor(hours / 24);
  if (diff < 0) {
    if (days > 0) return `逾期 ${days} 天`;
    if (hours > 0) return `逾期 ${hours} 小时`;
    return `逾期 ${mins} 分钟`;
  }
  if (days > 0) return `${days} 天后`;
  if (hours > 0) return `${hours} 小时后`;
  if (mins > 0) return `${mins} 分钟后`;
  return "即将";
}

function ReminderItem({ item, onToggle, onDelete, onToggleImportant }) {
  const [confirming, setConfirming] = useState(false);
  const dueFmt = formatDue(item.dueDate);
  const dueCls = dueColor(item.dueDate);

  const handleDelete = () => {
    if (confirming) {
      onDelete(item.id);
    } else {
      setConfirming(true);
      setTimeout(() => setConfirming(false), 2000);
    }
  };

  return (
    <div
      className={`flex items-start gap-3 rounded-2xl border border-[var(--border)] px-3 py-3 transition ${
        item.isCompleted ? "opacity-50" : "bg-[var(--surface)]"
      }`}
    >
      {/* Complete toggle */}
      <button
        onClick={() => onToggle(item)}
        className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border transition ${
          item.isCompleted
            ? "border-green-500 bg-green-500/20 text-green-400"
            : "border-[var(--border)] text-transparent hover:border-[var(--accent)] hover:text-[var(--accent)]"
        }`}
        aria-label={item.isCompleted ? "标为未完成" : "标为完成"}
      >
        <Check size={11} strokeWidth={3} />
      </button>

      {/* Content */}
      <div className="min-w-0 flex-1">
        <p className={`text-sm font-medium ${item.isCompleted ? "line-through text-[var(--text-tertiary)]" : "text-white"}`}>
          {item.title}
        </p>
        <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5">
          {item.listName && item.listName !== "默认" && (
            <span className="text-[11px] text-[var(--text-tertiary)]">{item.listName}</span>
          )}
          {dueFmt && (
            <span className={`flex items-center gap-0.5 text-[11px] ${dueCls}`}>
              <Clock size={10} />
              {dueFmt}
            </span>
          )}
          {item.notes && (
            <span className="text-[11px] text-[var(--text-tertiary)] truncate">{item.notes}</span>
          )}
        </div>
      </div>

      {/* Actions */}
      <div className="flex shrink-0 items-center gap-1">
        <button
          onClick={() => onToggleImportant(item)}
          className={`grid h-7 w-7 place-items-center rounded-full transition hover:bg-[var(--hover-bg)] ${
            item.isImportant ? "text-yellow-400" : "text-[var(--text-tertiary)]"
          }`}
          aria-label={item.isImportant ? "取消重要" : "标为重要"}
        >
          {item.isImportant ? <Star size={13} fill="currentColor" /> : <StarOff size={13} />}
        </button>
        <button
          onClick={handleDelete}
          className={`grid h-7 w-7 place-items-center rounded-full transition hover:bg-[var(--hover-bg)] ${
            confirming ? "text-red-400" : "text-[var(--text-tertiary)]"
          }`}
          aria-label="删除"
        >
          <Trash2 size={13} />
        </button>
      </div>
    </div>
  );
}

function AddReminderForm({ onAdd, onCancel }) {
  const [title, setTitle] = useState("");
  const [dueDate, setDueDate] = useState("");
  const [listName, setListName] = useState("默认");
  const [notes, setNotes] = useState("");
  const [isImportant, setIsImportant] = useState(false);
  const [saving, setSaving] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!title.trim()) return;
    setSaving(true);
    try {
      await onAdd({ title: title.trim(), dueDate: dueDate || null, listName, notes: notes || null, isImportant });
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3 rounded-2xl border border-[var(--accent-ring)] bg-[var(--surface)] p-4">
      <input
        autoFocus
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        placeholder="提醒事项标题…"
        className="w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
      />
      <div className="flex flex-wrap gap-2">
        <input
          type="datetime-local"
          value={dueDate}
          onChange={(e) => setDueDate(e.target.value)}
          className="flex-1 min-w-40 rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm text-white focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
        <input
          value={listName}
          onChange={(e) => setListName(e.target.value)}
          placeholder="列表名"
          className="w-32 rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
        <button
          type="button"
          onClick={() => setIsImportant(!isImportant)}
          className={`flex h-10 w-10 items-center justify-center rounded-xl border transition ${
            isImportant
              ? "border-yellow-500/50 bg-yellow-500/15 text-yellow-400"
              : "border-[var(--border)] text-[var(--text-tertiary)] hover:border-yellow-500/50 hover:text-yellow-400"
          }`}
          title="重要"
        >
          <Star size={15} fill={isImportant ? "currentColor" : "none"} />
        </button>
      </div>
      <input
        value={notes}
        onChange={(e) => setNotes(e.target.value)}
        placeholder="备注（可选）"
        className="w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
      />
      <div className="flex gap-2">
        <button
          type="submit"
          disabled={!title.trim() || saving}
          className="flex min-h-9 flex-1 items-center justify-center gap-2 rounded-2xl bg-[var(--accent)] text-sm font-semibold text-white transition hover:bg-[var(--accent-strong)] disabled:opacity-50"
        >
          {saving ? <RefreshCw size={13} className="animate-spin" /> : <Plus size={14} />}
          添加
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="flex min-h-9 items-center gap-2 rounded-2xl border border-[var(--border)] px-4 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
        >
          取消
        </button>
      </div>
    </form>
  );
}

export default function RemindersPanel() {
  const [reminders, setReminders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showCompleted, setShowCompleted] = useState(false);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchReminders(showCompleted);
      setReminders(Array.isArray(data) ? data : []);
    } catch (e) {
      const message = String(e.message || e);
      setError(message.includes("401") ? "需要访问令牌，保存后会自动重试。" : "提醒事项暂时没拉下来。");
    } finally {
      setLoading(false);
    }
  }, [showCompleted]);

  useEffect(() => {
    load();
    const handler = (event) => {
      if (!event.detail?.tab || event.detail.tab === "hub") load();
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, [load]);

  const handleAdd = async (data) => {
    await createReminder(data);
    setAdding(false);
    await load();
  };

  const handleToggle = async (item) => {
    await updateReminder(item.id, {
      isCompleted: !item.isCompleted,
    });
    await load();
  };

  const handleToggleImportant = async (item) => {
    await updateReminder(item.id, { isImportant: !item.isImportant });
    await load();
  };

  const handleDelete = async (id) => {
    await deleteReminder(id);
    await load();
  };

  const active = reminders.filter((r) => !r.isCompleted);
  const completed = reminders.filter((r) => r.isCompleted);
  const important = active.filter((r) => r.isImportant);
  const rest = active.filter((r) => !r.isImportant).sort((a, b) => {
    if (!a.dueDate && !b.dueDate) return 0;
    if (!a.dueDate) return 1;
    if (!b.dueDate) return -1;
    return new Date(a.dueDate) - new Date(b.dueDate);
  });
  const sorted = [...important, ...rest];

  return (
    <div className="max-w-2xl space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-white">提醒事项</h2>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowCompleted(!showCompleted)}
            className={`rounded-xl border px-3 py-1.5 text-xs transition ${
              showCompleted
                ? "border-[var(--accent-ring)] bg-[var(--accent)]/15 text-[var(--accent-soft)]"
                : "border-[var(--border)] text-[var(--text-tertiary)] hover:border-[var(--border-strong)]"
            }`}
          >
            {showCompleted ? "隐藏已完成" : "显示已完成"}
          </button>
          <button
            onClick={load}
            disabled={loading}
            className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] disabled:opacity-50"
          >
            <RefreshCw size={14} className={loading ? "animate-spin" : ""} />
          </button>
        </div>
      </div>

      {error && (
        <div className="rounded-2xl border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">{error}</div>
      )}

      {/* Stats row */}
      {!loading && (
        <div className="flex gap-3">
          {[
            { label: "待完成", value: active.length, color: "text-white" },
            { label: "重要", value: important.length, color: "text-yellow-400" },
            { label: "今日到期", value: active.filter(r => r.dueDate && new Date(r.dueDate) - Date.now() < 24*3600*1000 && new Date(r.dueDate) > Date.now()).length, color: "text-orange-400" },
            { label: "已完成", value: completed.length, color: "text-green-400" },
          ].map(({ label, value, color }) => (
            <div key={label} className="flex-1 rounded-2xl border border-[var(--border)] bg-[var(--surface)] px-3 py-2 text-center">
              <p className={`text-lg font-bold tabular-nums ${color}`}>{value}</p>
              <p className="text-[11px] text-[var(--text-tertiary)]">{label}</p>
            </div>
          ))}
        </div>
      )}

      {/* Add form */}
      {adding ? (
        <AddReminderForm onAdd={handleAdd} onCancel={() => setAdding(false)} />
      ) : (
        <button
          onClick={() => setAdding(true)}
          className="flex w-full min-h-10 items-center gap-2 rounded-2xl border border-dashed border-[var(--border)] px-4 text-sm text-[var(--text-secondary)] transition hover:border-[var(--accent)] hover:text-[var(--accent)] hover:bg-[var(--hover-bg)]"
        >
          <Plus size={16} />
          新建提醒
        </button>
      )}

      {/* Reminder list */}
      {loading ? (
        <div className="flex items-center gap-2 py-8 text-sm text-[var(--text-tertiary)]">
          <RefreshCw size={14} className="animate-spin" />
          加载中...
        </div>
      ) : sorted.length === 0 && completed.length === 0 ? (
        <div className="py-12 text-center">
          <AlarmClock size={36} className="mx-auto mb-3 text-[var(--text-tertiary)] opacity-30" />
          <p className="text-sm text-[var(--text-secondary)]">暂无提醒事项</p>
          <p className="mt-1 text-xs text-[var(--text-tertiary)]">点击"新建提醒"来添加第一条</p>
        </div>
      ) : (
        <div className="space-y-2">
          {sorted.map((item) => (
            <ReminderItem
              key={item.id}
              item={item}
              onToggle={handleToggle}
              onDelete={handleDelete}
              onToggleImportant={handleToggleImportant}
            />
          ))}
          {showCompleted && completed.length > 0 && (
            <>
              <p className="px-1 pt-2 text-xs font-semibold uppercase tracking-wide text-[var(--text-tertiary)]">
                已完成 ({completed.length})
              </p>
              {completed.map((item) => (
                <ReminderItem
                  key={item.id}
                  item={item}
                  onToggle={handleToggle}
                  onDelete={handleDelete}
                  onToggleImportant={handleToggleImportant}
                />
              ))}
            </>
          )}
        </div>
      )}
    </div>
  );
}
