import { useState } from "react";
import { Lightbulb, StickyNote, Plus, Trash2 } from "lucide-react";
import RemindersPanel from "../settings/RemindersPanel";

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

          {/* Reminders — full panel migrated from Settings */}
          <section className="surface-card animate-rise p-4" style={{ animationDelay: "80ms" }}>
            <RemindersPanel />
          </section>

        </div>
      </div>
    </div>
  );
}
