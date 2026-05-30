import { useState, useEffect, useCallback, Component } from "react";
import { Calendar, MessageSquare, Settings, Bell } from "lucide-react";
import TabBar from "./components/layout/TabBar";
import ScheduleOverview from "./components/schedule/ScheduleOverview";
import ScheduleView from "./components/schedule/ScheduleView";
import SettingsView from "./components/settings/SettingsView";
import NotificationCenter from "./components/notifications/NotificationCenter";
import DailyPopup from "./components/notifications/DailyPopup";

const VALID_TABS = ["overview", "agent", "notifications", "settings"];

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
  const [tab, setTab] = useState("overview");

  const handleRefresh = useCallback(() => {
    window.location.reload();
  }, []);

  usePullToRefresh(handleRefresh);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
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
    return () => {
      window.removeEventListener("hashchange", handleHashChange);
      navigator.serviceWorker?.removeEventListener?.("message", handleMessage);
    };
  }, []);

  const handleTabChange = useCallback((nextTab) => {
    setTab(nextTab);
    window.history.replaceState(null, "", `#${nextTab}`);
  }, []);

  return (
    <div className="app-shell flex h-[100dvh] flex-col overflow-hidden bg-[var(--app-bg)] text-[var(--text-primary)]">
      <div className="pointer-events-none fixed inset-x-0 top-0 h-px bg-white/15" />

      <div className="flex min-h-0 flex-1 overflow-hidden md:p-3 md:pb-3">
        {/* Main content */}
        <main className="min-w-0 flex-1 overflow-hidden md:rounded-[18px] md:border md:border-white/10 md:bg-[var(--panel-bg)] md:shadow-2xl md:shadow-black/30">
          <ErrorBoundary>
            <div className={tab !== "overview" ? "hidden" : "h-full"}><ScheduleOverview /></div>
            <div className={tab !== "agent" ? "hidden" : "h-full"}><ScheduleView /></div>
            <div className={tab !== "notifications" ? "hidden" : "h-full"}><NotificationCenter /></div>
            <div className={tab !== "settings" ? "hidden" : "h-full"}><SettingsView /></div>
          </ErrorBoundary>
        </main>
      </div>

      {/* Daily briefing popup on PWA open */}
      <DailyPopup />

      {/* Mobile tab bar */}
      <TabBar active={tab} onChange={handleTabChange} onRefresh={handleRefresh} />

      {/* Desktop tab strip - top right */}
      <div className="absolute right-5 top-5 z-10 hidden overflow-hidden rounded-full border border-white/10 bg-black/20 p-1 shadow-lg shadow-black/20 backdrop-blur-xl md:flex">
        {[
          { id: "overview", label: "总览", icon: Calendar },
          { id: "agent", label: "Agent", icon: MessageSquare },
          { id: "notifications", label: "通知", icon: Bell },
          { id: "settings", label: "设置", icon: Settings },
        ].map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            onClick={() => handleTabChange(id)}
            className={`flex h-9 items-center gap-2 rounded-full px-3 text-xs font-medium transition ${
              tab === id
                ? "bg-white/14 text-white shadow-sm"
                : "text-[var(--text-tertiary)] hover:bg-white/8 hover:text-white"
            }`}
            title={label}
          >
            <Icon size={18} />
            {id === tab && <span>{label}</span>}
          </button>
        ))}
      </div>
    </div>
  );
}

export default App;
