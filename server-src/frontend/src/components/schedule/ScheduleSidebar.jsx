import { useState, useEffect } from "react";
import { ClipboardList, Brain, RefreshCw, ChevronDown, ChevronRight, Clock, Activity, Wifi, WifiOff } from "lucide-react";
import { fetchScheduleSidebar } from "../../api/schedule";
import { syncChaoxingMemory } from "../../api/chaoxing";
import MemoryDetailDrawer from "./MemoryDetailDrawer";

export default function ScheduleSidebar({ mobile = false }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [syncing, setSyncing] = useState(false);
  const [collapsed, setCollapsed] = useState({});
  const [selectedMemory, setSelectedMemory] = useState(null);

  const refresh = async () => {
    setLoading(true);
    try {
      setData(await fetchScheduleSidebar());
    } catch (e) {
      console.error("Failed to load sidebar:", e);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { refresh(); }, []);

  const handleSyncMemory = async () => {
    setSyncing(true);
    try {
      await syncChaoxingMemory();
      await refresh();
    } catch (e) {
      console.error("Memory sync failed:", e);
    } finally {
      setSyncing(false);
    }
  };

  const toggle = (key) => setCollapsed((p) => ({ ...p, [key]: !p[key] }));

  if (loading) {
    return (
      <div className={`bg-[var(--sidebar-bg)] p-3 ${mobile ? "h-full" : "h-full w-80 border-l border-[var(--border)]"}`}>
        <div className="space-y-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-24 rounded-[20px] border border-[var(--border)] bg-[var(--surface)] shimmer" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <>
    <div className={`h-full space-y-3 overflow-y-auto bg-[var(--sidebar-bg)] p-3 ${mobile ? "" : "w-80 border-l border-[var(--border)]"}`}>

      {/* Memory Insights */}
      <Section
        sectionKey="memory"
        icon={Brain}
        title="Memory"
        count={data?.memory_insights?.length}
        collapsed={collapsed}
        onToggle={toggle}
        action={
          <button
            onClick={handleSyncMemory}
            disabled={syncing}
            className="rounded p-1 text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
            title="同步 Memory"
          >
            <RefreshCw size={12} className={syncing ? "animate-spin" : ""} />
          </button>
        }
      >
        {data?.memory_insights?.length ? (
          data.memory_insights.map((m) => (
            <button
              key={m.id}
              onClick={() => setSelectedMemory(m)}
              title={m.title}
              className="w-full text-left px-3 py-2.5 border-b border-[var(--border)] last:border-0 hover:bg-[var(--hover-bg)] transition-colors"
            >
              <div className="flex items-center gap-2">
                <span className={`h-2 w-2 shrink-0 rounded-full ${m.importance === "high" ? "bg-red-500 shadow-[0_0_5px_rgba(239,68,68,0.5)]" : "bg-yellow-500"}`} />
                <p className="text-[13px] font-medium text-[var(--text-secondary)] truncate">{m.title}</p>
              </div>
              {m.summary && <p className="ml-4 mt-0.5 text-xs text-[var(--text-tertiary)] line-clamp-2 leading-relaxed">{m.summary}</p>}
              {m.action_hint && <p className="ml-4 mt-1 text-xs text-[var(--accent-soft)] leading-relaxed">{m.action_hint}</p>}
            </button>
          ))
        ) : (
          <p className="px-3 py-2 text-xs text-[var(--text-tertiary)]">暂无 Memory</p>
        )}
      </Section>

      {/* System Status */}
      <Section
        sectionKey="status"
        icon={Activity}
        title="系统状态"
        collapsed={collapsed}
        onToggle={toggle}
      >
        <div className="px-3 py-2 space-y-2">
          <StatusRow
            icon={data?.chaoxing_logged_in ? <Wifi size={12} className="text-green-400" /> : <WifiOff size={12} className="text-red-400" />}
            label="学习通"
            value={data?.chaoxing_logged_in ? "已连接" : "未连接"}
            color={data?.chaoxing_logged_in ? "text-green-400" : "text-red-400"}
          />
          <StatusRow
            icon={<Brain size={12} className="text-purple-400" />}
            label="Memory"
            value={`${data?.memory_insights?.length || 0} 条活跃`}
          />
          <StatusRow
            icon={<ClipboardList size={12} className="text-pink-400" />}
            label="待交作业"
            value={`${(data?.assignments || []).filter((a) => a.status === "未交" || a.status === "未提交").length} 项`}
          />
          <StatusRow
            icon={<Clock size={12} className="text-blue-400" />}
            label="课程"
            value={`${(data?.local_courses || []).length} 门`}
          />
        </div>
      </Section>
    </div>

    {/* Memory detail drawer */}
    {selectedMemory && (
      <MemoryDetailDrawer
        memory={selectedMemory}
        onClose={() => setSelectedMemory(null)}
        onArchived={(id) => {
          setData((prev) => {
            if (!prev) return prev;
            return {
              ...prev,
              memory_insights: (prev.memory_insights || []).filter((m) => m.id !== id),
            };
          });
        }}
      />
    )}
    </>
  );
}

function StatusRow({ icon, label, value, color }) {
  return (
    <div className="flex items-center justify-between">
      <span className="flex items-center gap-1.5 text-xs text-[var(--text-tertiary)]">
        {icon}
        {label}
      </span>
      <span className={`text-xs font-medium ${color || "text-[var(--text-secondary)]"}`}>{value}</span>
    </div>
  );
}

function Section({ sectionKey, icon: Icon, title, count, collapsed, onToggle, action, children }) {
  const isCollapsed = collapsed[sectionKey];
  return (
    <section className="overflow-hidden rounded-[16px] border border-[var(--border)] bg-[var(--surface-2)]">
      <button
        onClick={() => onToggle(sectionKey)}
        className="flex w-full items-center justify-between rounded-t-[20px] px-3.5 py-3 transition-colors hover:bg-[var(--hover-bg)]"
      >
        <div className="flex items-center gap-2">
          <Icon size={13} className="text-[var(--text-tertiary)]" />
          <span className="text-[11px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">{title}</span>
          {count > 0 && (
            <span className="rounded-full bg-[var(--surface-2)] px-1.5 py-0.5 text-[10px] font-medium text-[var(--text-tertiary)]">
              {count}
            </span>
          )}
        </div>
        <div className="flex items-center gap-1">
          {action && <span onClick={(e) => e.stopPropagation()}>{action}</span>}
          {isCollapsed ? <ChevronRight size={12} className="text-[var(--text-tertiary)]" /> : <ChevronDown size={12} className="text-[var(--text-tertiary)]" />}
        </div>
      </button>
      {!isCollapsed && children}
    </section>
  );
}
