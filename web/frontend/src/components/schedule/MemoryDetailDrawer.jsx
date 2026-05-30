import { useState } from "react";
import { X, Archive, Brain, BookOpen, Bell, GraduationCap, Clock, AlertTriangle, Info } from "lucide-react";
import { archiveMemoryEntry } from "../../api/chaoxing";

const KIND_META = {
  assignment: { icon: BookOpen, label: "作业", color: "text-pink-400" },
  course: { icon: GraduationCap, label: "课程变动", color: "text-teal-400" },
  reminder: { icon: Bell, label: "提醒", color: "text-emerald-400" },
  message: { icon: Brain, label: "学习通消息", color: "text-purple-400" },
};

const IMPORTANCE_META = {
  high: { label: "高", color: "bg-red-500/20 text-red-400 ring-red-500/30" },
  medium: { label: "中", color: "bg-yellow-500/20 text-yellow-400 ring-yellow-500/30" },
  low: { label: "低", color: "bg-blue-500/20 text-blue-400 ring-blue-500/30" },
};

export default function MemoryDetailDrawer({ memory, onClose, onArchived }) {
  const [archiving, setArchiving] = useState(false);
  const [error, setError] = useState(null);

  if (!memory) return null;

  const kind = memory.kind || "message";
  const kindInfo = KIND_META[kind] || KIND_META.message;
  const KindIcon = kindInfo.icon;
  const importance = IMPORTANCE_META[memory.importance] || IMPORTANCE_META.medium;

  const handleArchive = async () => {
    setArchiving(true);
    setError(null);
    try {
      await archiveMemoryEntry(memory.id);
      onArchived?.(memory.id);
      onClose?.();
    } catch (e) {
      setError(e.message || "归档失败");
    } finally {
      setArchiving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-[var(--overlay-bg)] backdrop-blur-sm" onClick={onClose}>
      <div
        className="absolute inset-y-0 right-0 flex w-[88vw] max-w-[400px] flex-col border-l border-[var(--border)] bg-[var(--sidebar-bg)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b border-[var(--border)] px-4 py-3">
          <div className="flex items-center gap-2">
            <KindIcon size={16} className={kindInfo.color} />
            <span className="text-sm font-semibold text-white">Memory 详情</span>
          </div>
          <button
            onClick={onClose}
            className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            <X size={16} />
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-4 py-4 space-y-4">
          {/* Title & kind */}
          <div>
            <div className="flex items-center gap-2 mb-2">
              <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ring-1 ${importance.color}`}>
                {importance.label}重要性
              </span>
              <span className="flex items-center gap-1 text-xs text-[var(--text-tertiary)]">
                <KindIcon size={12} className={kindInfo.color} />
                {kindInfo.label}
              </span>
            </div>
            <h3 className="text-lg font-semibold text-white leading-snug">{memory.title}</h3>
          </div>

          {/* Summary */}
          {memory.summary && (
            <div className="rounded-xl border border-[var(--border)] bg-[var(--surface)] p-3">
              <p className="text-xs font-semibold uppercase tracking-widest text-[var(--text-tertiary)] mb-1.5">摘要</p>
              <p className="text-sm text-[var(--text-secondary)] leading-relaxed">{memory.summary}</p>
            </div>
          )}

          {/* Action hint */}
          {memory.action_hint && (
            <div className="rounded-xl border border-[var(--accent)]/20 bg-[var(--accent)]/8 p-3">
              <p className="text-xs font-semibold uppercase tracking-widest text-[var(--accent-soft)] mb-1.5">建议操作</p>
              <p className="text-sm text-[var(--text-secondary)] leading-relaxed">{memory.action_hint}</p>
            </div>
          )}

          {/* Metadata */}
          <div className="rounded-xl border border-[var(--border)] bg-[var(--surface)] p-3 space-y-2">
            <p className="text-xs font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">元数据</p>
            <MetaRow label="ID" value={memory.id} />
            {memory.expires_at && (
              <MetaRow
                label="过期时间"
                value={new Date(memory.expires_at).toLocaleString("zh-CN")}
                icon={<Clock size={12} className="text-[var(--text-tertiary)]" />}
              />
            )}
            {memory.sent_at && (
              <MetaRow
                label="来源时间"
                value={new Date(memory.sent_at).toLocaleString("zh-CN")}
              />
            )}
            {memory.dedupe_key && <MetaRow label="去重键" value={memory.dedupe_key} mono />}
          </div>

          {/* Error */}
          {error && (
            <div className="rounded-xl border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">
              {error}
            </div>
          )}
        </div>

        {/* Footer actions */}
        <div className="border-t border-[var(--border)] px-4 py-3 flex gap-2">
          <button
            onClick={handleArchive}
            disabled={archiving}
            className="flex flex-1 items-center justify-center gap-2 rounded-xl bg-[var(--hover-bg)] px-4 py-2.5 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg-strong)] hover:text-white transition-colors disabled:opacity-50"
          >
            <Archive size={14} />
            {archiving ? "归档中..." : "归档"}
          </button>
        </div>
      </div>
    </div>
  );
}

function MetaRow({ label, value, icon, mono }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-xs text-[var(--text-tertiary)] flex items-center gap-1">
        {icon}
        {label}
      </span>
      <span className={`text-xs text-[var(--text-secondary)] truncate max-w-[200px] ${mono ? "font-mono" : ""}`}>
        {value}
      </span>
    </div>
  );
}
