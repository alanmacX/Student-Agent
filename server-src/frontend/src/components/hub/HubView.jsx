import { useState, useEffect, useCallback } from "react";
import { Lightbulb, StickyNote, Clock, Trash2, Plus, ExternalLink } from "lucide-react";
import { fetchReminders } from "../../api/reminders";
import TokenStats from "./TokenStats";

const STORAGE_KEY = "hub_quick_notes";

function loadNotes() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY)) || [];
  } catch {
    return [];
  }
}

function saveNotes(notes) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
}

export default function HubView() {
  const [notes, setNotes] = useState(loadNotes);
  const [input, setInput] = useState("");
  const [reminders, setReminders] = useState([]);
  const [remLoading, setRemLoading] = useState(true);

  // Fetch reminders
  const loadReminders = useCallback(async () => {
    try {
      const data = await fetchReminders();
      setReminders(data);
    } catch {
      // ignore
    } finally {
      setRemLoading(false);
    }
  }, []);

  useEffect(() => { loadReminders(); }, [loadReminders]);

  const addNote = () => {
    const text = input.trim();
    if (!text) return;
    const updated = [{ id: Date.now(), text, created: new Date().toISOString() }, ...notes];
    setNotes(updated);
    saveNotes(updated);
    setInput("");
  };

  const deleteNote = (id) => {
    const updated = notes.filter((n) => n.id !== id);
    setNotes(updated);
    saveNotes(updated);
  };

  const activeReminders = reminders.filter((r) => !r.isCompleted);
  const importantReminders = activeReminders.filter((r) => r.isImportant);
  const upcomingReminders = activeReminders
    .filter((r) => r.dueDate && new Date(r.dueDate) > new Date())
    .sort((a, b) => new Date(a.dueDate) - new Date(b.dueDate))
    .slice(0, 5);

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)]">
      {/* Floating header */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 mx-auto flex w-full max-w-3xl items-center justify-between gap-2 px-3 pt-3 md:px-6">
        <div className="glass-pill pointer-events-auto flex min-h-[48px] items-center rounded-full px-5 py-2">
          <Lightbulb size={16} className="mr-2 text-yellow-400" />
          <h2 className="text-sm font-semibold text-white">Hub</h2>
        </div>
      </div>

      {/* Scrollable content */}
      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-[72px] pb-36 md:pb-4 md:px-6">
        <div className="mx-auto max-w-3xl space-y-4 stagger">

          {/* Quick Capture */}
          <section className="surface-card animate-rise p-4">
            <div className="mb-3 flex items-center gap-2">
              <StickyNote size={14} className="text-[var(--accent)]" />
              <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
                快速记录
              </h3>
            </div>
            <div className="flex gap-2">
              <input
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && addNote()}
                placeholder="记下你的想法..."
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

          {/* Reminders Overview */}
          <section className="surface-card animate-rise p-4" style={{ animationDelay: "80ms" }}>
            <div className="mb-3 flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Clock size={14} className="text-orange-400" />
                <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
                  提醒事项
                </h3>
              </div>
              <a
                href="#settings"
                onClick={(e) => {
                  e.preventDefault();
                  window.location.hash = "settings";
                }}
                className="flex items-center gap-1 text-[10px] text-[var(--text-tertiary)] hover:text-[var(--accent)]"
              >
                查看全部 <ExternalLink size={10} />
              </a>
            </div>

            {remLoading ? (
              <div className="shimmer h-10 rounded-xl" />
            ) : activeReminders.length === 0 ? (
              <p className="py-4 text-center text-sm text-[var(--text-tertiary)]">暂无提醒事项</p>
            ) : (
              <>
                {/* Stats */}
                <div className="mb-3 flex gap-3">
                  {[
                    { label: "待完成", value: activeReminders.length, color: "text-white" },
                    { label: "重要", value: importantReminders.length, color: "text-yellow-400" },
                  ].map(({ label, value, color }) => (
                    <div key={label} className="flex-1 rounded-xl border border-[var(--border)] bg-[var(--surface)] px-3 py-1.5 text-center">
                      <p className={`text-base font-bold tabular-nums ${color}`}>{value}</p>
                      <p className="text-[10px] text-[var(--text-tertiary)]">{label}</p>
                    </div>
                  ))}
                </div>
                {/* Upcoming list */}
                {upcomingReminders.length > 0 && (
                  <div className="space-y-1">
                    {upcomingReminders.map((r) => (
                      <div key={r.id} className="flex items-center gap-2 rounded-lg px-2 py-1 text-sm">
                        <span className={`h-1.5 w-1.5 rounded-full ${r.isImportant ? "bg-yellow-400" : "bg-[var(--text-tertiary)]"}`} />
                        <span className="flex-1 truncate text-[var(--text-secondary)]">{r.title}</span>
                        <span className="text-[10px] tabular-nums text-[var(--text-tertiary)]">
                          {new Date(r.dueDate).toLocaleDateString("zh-CN", { month: "short", day: "numeric" })}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </>
            )}
          </section>

          {/* Token Usage */}
          <section className="surface-card animate-rise p-4" style={{ animationDelay: "160ms" }}>
            <div className="mb-3 flex items-center gap-2">
              <Lightbulb size={14} className="text-emerald-400" />
              <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
                Token 消耗
              </h3>
            </div>
            <TokenStats />
          </section>

          {/* Extension Slots */}
          {[1, 2].map((i) => (
            <section
              key={i}
              className="animate-rise rounded-2xl border border-dashed border-[var(--border)] p-6 text-center"
              style={{ animationDelay: `${200 + i * 80}ms` }}
            >
              <p className="text-sm text-[var(--text-tertiary)] opacity-40">Future extension</p>
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}
