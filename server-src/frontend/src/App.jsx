import { useState, useEffect, useCallback, Component } from "react";
import { KeyRound } from "lucide-react";
import DesktopNavRail from "./components/layout/DesktopNavRail";
import TabBar from "./components/layout/TabBar";
import ScheduleOverview from "./components/schedule/ScheduleOverview";
import ScheduleView from "./components/schedule/ScheduleView";
import SettingsView from "./components/settings/SettingsView";
import NotificationCenter from "./components/notifications/NotificationCenter";
import HubView from "./components/hub/HubView";
import DailyPopup from "./components/notifications/DailyPopup";
import { broadcastAccessToken, setAccessToken } from "./api/client";

const VALID_TABS = ["overview", "agent", "hub", "notifications", "settings"];

function initialTabFromLocation() {
  const params = new URLSearchParams(window.location.search);
  const queryTab = params.get("tab");
  const hashTab = window.location.hash.replace("#", "");
  if (VALID_TABS.includes(hashTab)) return hashTab;
  if (VALID_TABS.includes(queryTab)) return queryTab;
  if (queryTab === "chat") return "agent";
  return "overview";
}

class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error) {
    return { error };
  }
  componentDidCatch(error, info) {
    console.error("[ErrorBoundary]", error, info.componentStack);
  }
  render() {
    if (this.state.error) {
      return (
        <div className="flex h-full flex-col items-center justify-center gap-4 p-6 text-center">
          <p className="text-lg font-semibold text-[var(--text-primary)]">页面出错了</p>
          <p className="max-w-sm text-sm text-[var(--text-tertiary)]">
            {this.state.error.message || "发生未知错误"}
          </p>
          <button
            onClick={() => { this.setState({ error: null }); window.location.reload(); }}
            className="rounded-full bg-[var(--accent)] px-5 py-2 text-sm font-semibold text-white transition hover:opacity-90"
          >
            重新加载
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

function usePullToRefresh(onRefresh) {
  useEffect(() => {
    let startY = 0;
    let pulling = false;

    const onTouchStart = (e) => {
      // Only start a pull gesture when the touch begins near the very top
      // of the viewport. This prevents normal scrolling/swiping from
      // accidentally triggering a full page reload.
      if (e.touches[0].clientY > 60) return;

      // Also require the inner scroll container to actually be at the top.
      // In this flex layout the scrolling element is <main>'s child, not
      // window, so window.scrollY is unreliable.
      const scroller = document.querySelector(".app-shell .overflow-y-auto");
      if (scroller && scroller.scrollTop > 0) return;

      startY = e.touches[0].clientY;
      pulling = true;
    };

    const onTouchMove = (e) => {
      if (!pulling) return;
      // If the user moved upward (dy negative = swipe up), cancel the pull.
      const dy = e.touches[0].clientY - startY;
      if (dy < 0) pulling = false;
    };

    const onTouchEnd = (e) => {
      if (!pulling) return;
      const dy = e.changedTouches[0].clientY - startY;
      // Require a deliberate downward pull of at least 110px.
      if (dy > 110) {
        onRefresh();
      }
      pulling = false;
    };

    document.addEventListener("touchstart", onTouchStart, { passive: true });
    document.addEventListener("touchmove", onTouchMove, { passive: true });
    document.addEventListener("touchend", onTouchEnd, { passive: true });
    return () => {
      document.removeEventListener("touchstart", onTouchStart);
      document.removeEventListener("touchmove", onTouchMove);
      document.removeEventListener("touchend", onTouchEnd);
    };
  }, [onRefresh]);
}

function App() {
  const [tab, setTab] = useState(initialTabFromLocation);
  const [mountedTabs, setMountedTabs] = useState(() => new Set([initialTabFromLocation()]));
  const [tokenRequired, setTokenRequired] = useState(false);

  const handleRefresh = useCallback(() => {
    window.dispatchEvent(new CustomEvent("app-refresh", { detail: { tab } }));
  }, [tab]);

  usePullToRefresh(handleRefresh);

  useEffect(() => {
    setMountedTabs((prev) => {
      if (prev.has(tab)) return prev;
      const next = new Set(prev);
      next.add(tab);
      return next;
    });
  }, [tab]);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const tokenFromUrl = params.get("token");
    if (tokenFromUrl) {
      setAccessToken(tokenFromUrl);
      params.delete("token");
      const next = `${window.location.pathname}${params.toString() ? `?${params}` : ""}${window.location.hash}`;
      window.history.replaceState(null, "", next);
    } else {
      broadcastAccessToken();
    }
    const initialTab = params.get("tab");
    if (VALID_TABS.includes(initialTab)) {
      setTab(initialTab);
    } else if (initialTab === "schedule") {
      setTab("overview");
    } else if (initialTab === "chat") {
      setTab("agent");
    }

    const hashTab = window.location.hash.replace("#", "");
    if (VALID_TABS.includes(hashTab)) {
      setTab(hashTab);
    }

    const handleHashChange = () => {
      const next = window.location.hash.replace("#", "");
      if (VALID_TABS.includes(next)) {
        setTab(next);
      }
    };
    window.addEventListener("hashchange", handleHashChange);

    const handleMessage = (event) => {
      if (event.data?.type !== "navigate") return;
      const nextUrl = new URL(event.data.url, window.location.origin);
      const nextTab = nextUrl.searchParams.get("tab");
      if (VALID_TABS.includes(nextTab)) {
        setTab(nextTab);
      } else if (nextTab === "schedule") {
        setTab("overview");
      }
    };
    navigator.serviceWorker?.addEventListener?.("message", handleMessage);
    const handleTokenRequired = () => setTokenRequired(true);
    window.addEventListener("access-token-required", handleTokenRequired);
    return () => {
      window.removeEventListener("hashchange", handleHashChange);
      navigator.serviceWorker?.removeEventListener?.("message", handleMessage);
      window.removeEventListener("access-token-required", handleTokenRequired);
    };
  }, []);

  const handleTabChange = useCallback((nextTab) => {
    setTab(nextTab);
    window.history.replaceState(null, "", `#${nextTab}`);
  }, []);

  return (
    <div className="app-shell flex h-[100dvh] flex-col overflow-hidden bg-[var(--app-bg)] text-[var(--text-primary)]">
      <div className="pointer-events-none fixed inset-x-0 top-0 h-px bg-white/15" />

      <div className="flex min-h-0 flex-1 overflow-hidden md:p-3 md:pb-3 md:pl-[104px]">
        {/* Main content */}
        <main className="min-w-0 flex-1 overflow-hidden md:rounded-[26px] md:border md:border-[var(--glass-border)] md:bg-[var(--panel-bg)] md:shadow-2xl md:shadow-black/20">
          <ErrorBoundary>
            {mountedTabs.has("overview") && <div className={tab !== "overview" ? "hidden" : "h-full"}><ScheduleOverview /></div>}
            {mountedTabs.has("agent") && <div className={tab !== "agent" ? "hidden" : "h-full"}><ScheduleView /></div>}
            {mountedTabs.has("hub") && <div className={tab !== "hub" ? "hidden" : "h-full"}><HubView /></div>}
            {mountedTabs.has("notifications") && <div className={tab !== "notifications" ? "hidden" : "h-full"}><NotificationCenter /></div>}
            {mountedTabs.has("settings") && <div className={tab !== "settings" ? "hidden" : "h-full"}><SettingsView /></div>}
          </ErrorBoundary>
        </main>
      </div>

      {/* Daily briefing popup on PWA open */}
      <DailyPopup />

      <TabBar active={tab} onChange={handleTabChange} onRefresh={handleRefresh} />
      <DesktopNavRail active={tab} onChange={handleTabChange} onRefresh={handleRefresh} />
      {tokenRequired && <AccessTokenDialog onClose={() => setTokenRequired(false)} />}
    </div>
  );
}

function AccessTokenDialog({ onClose }) {
  const [value, setValue] = useState("");
  const save = () => {
    setAccessToken(value);
    onClose();
    window.dispatchEvent(new Event("app-refresh"));
  };
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/55 px-4 backdrop-blur-md">
      <div className="w-full max-w-sm rounded-2xl border border-white/10 bg-[var(--panel-bg)] p-5 shadow-2xl">
        <div className="mb-4 flex items-center gap-2">
          <KeyRound size={18} className="text-[var(--accent-soft)]" />
          <p className="text-sm font-semibold text-white">访问令牌</p>
        </div>
        <input
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && save()}
          type="password"
          autoFocus
          placeholder="输入 ACCESS_TOKEN"
          className="glass-input min-h-11 w-full rounded-xl px-3 text-sm"
        />
        <div className="mt-4 flex justify-end gap-2">
          <button
            onClick={onClose}
            className="rounded-xl border border-[var(--border)] px-4 py-2 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
          >
            取消
          </button>
          <button
            onClick={save}
            disabled={!value.trim()}
            className="rounded-xl bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white disabled:opacity-40"
          >
            保存
          </button>
        </div>
      </div>
    </div>
  );
}

export default App;
