import { MessageSquare, Calendar, Settings, Bell, RefreshCw, Lightbulb } from "lucide-react";
import { useState } from "react";

const TABS = [
  { id: "overview", label: "总览", icon: Calendar },
  { id: "agent", label: "Agent", icon: MessageSquare },
  { id: "hub", label: "Hub", icon: Lightbulb },
  { id: "notifications", label: "通知", icon: Bell },
  { id: "settings", label: "设置", icon: Settings },
];

export default function TabBar({ active, onChange, onRefresh }) {
  const [refreshing, setRefreshing] = useState(false);

  const handleRefresh = async () => {
    if (refreshing) return;
    setRefreshing(true);
    try {
      await onRefresh?.();
    } finally {
      setTimeout(() => setRefreshing(false), 800);
    }
  };

  return (
    <div
      className="md:hidden"
      style={{
        position: "fixed",
        bottom: "calc(env(safe-area-inset-bottom) + 6px)",
        left: "50%",
        transform: "translateX(-50%)",
        zIndex: 50,
        display: "flex",
        alignItems: "center",
        gap: "8px",
      }}
    >
      {/* Main tab pill */}
      <nav
        className="glass-tab"
        style={{
          display: "flex",
          alignItems: "center",
          gap: "3px",
          padding: "6px 8px",
          borderRadius: "999px",
        }}
      >
        {TABS.map(({ id, label, icon: Icon }) => {
          const isActive = active === id;
          return (
            <button
              key={id}
              onClick={() => onChange(id)}
              style={{ transition: "all 0.42s var(--ease-spring)", position: "relative", zIndex: 1 }}
              className={`flex items-center gap-1.5 rounded-full px-3.5 py-2.5 text-[13px] font-semibold ${
                isActive
                  ? "bg-[var(--accent)] text-white shadow-lg scale-[1.03]"
                  : "text-[var(--text-tertiary)] hover:text-white hover:bg-[var(--hover-bg)] active:scale-95"
              }`}
            >
              <Icon size={20} strokeWidth={isActive ? 2.5 : 2} />
              {isActive && (
                <span className="animate-fade" style={{ maxWidth: "4.5rem", overflow: "hidden", whiteSpace: "nowrap" }}>
                  {label}
                </span>
              )}
            </button>
          );
        })}
      </nav>

      {/* Refresh — its own aligned circle */}
      <button
        onClick={handleRefresh}
        disabled={refreshing}
        title="刷新"
        style={{
          transition: "transform 0.42s var(--ease-spring), border-color 0.2s",
        }}
        className="glass-tab grid h-[52px] w-[52px] place-items-center rounded-full text-[var(--text-secondary)] hover:text-white hover:scale-105 active:scale-90 disabled:opacity-40"
      >
        <RefreshCw size={18} className={refreshing ? "animate-spin" : ""} strokeWidth={2} style={{ position: "relative", zIndex: 1 }} />
      </button>
    </div>
  );
}
