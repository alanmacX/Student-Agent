import { useState } from "react";
import { RefreshCw } from "lucide-react";
import { NAV_ITEMS } from "./navItems";

export default function DesktopNavRail({ active, onChange, onRefresh }) {
  const [refreshing, setRefreshing] = useState(false);

  const refresh = async () => {
    if (refreshing) return;
    setRefreshing(true);
    try {
      await onRefresh?.();
    } finally {
      setTimeout(() => setRefreshing(false), 800);
    }
  };

  return (
    <aside className="desktop-nav-rail" aria-label="桌面导航">
      <nav className="desktop-nav-rail__group" aria-label="主导航">
        {NAV_ITEMS.map(({ id, label, icon: Icon }) => {
          const isActive = active === id;
          return (
            <button
              key={id}
              type="button"
              onClick={() => onChange(id)}
              title={label}
              aria-current={isActive ? "page" : undefined}
              className={`desktop-nav-button ${isActive ? "is-active" : ""}`}
            >
              <Icon size={20} strokeWidth={isActive ? 2.45 : 2} />
              <span className="desktop-nav-label">{label}</span>
            </button>
          );
        })}
      </nav>

      <button
        type="button"
        onClick={refresh}
        disabled={refreshing}
        title="刷新当前页"
        className="desktop-nav-button desktop-nav-action"
        aria-label="刷新当前页"
      >
        <RefreshCw size={19} className={refreshing ? "animate-spin" : ""} />
        <span className="desktop-nav-label">刷新</span>
      </button>
    </aside>
  );
}
