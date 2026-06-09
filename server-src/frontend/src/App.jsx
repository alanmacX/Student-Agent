import { useState, useEffect, useCallback, Component } from "react";
import { Calendar, MessageSquare, Settings, Bell, Lightbulb } from "lucide-react";
import TabBar from "./components/layout/TabBar";
import ScheduleOverview from "./components/schedule/ScheduleOverview";
import ScheduleView from "./components/schedule/ScheduleView";
import SettingsView from "./components/settings/SettingsView";
import NotificationCenter from "./components/notifications/NotificationCenter";
import HubView from "./components/hub/HubView";
import DailyPopup from "./components/notifications/DailyPopup";

const VALID_TABS = ["overview", "agent", "hub", "notifications", "settings"];

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

  const TABS = [
    { id: "overview",      label: "总览", icon: Calendar },
    { id: "agent",         label: "Agent", icon: MessageSquare },
    { id: "hub",           label: "Hub",  icon: Lightbulb },
    { id: "notifications", label: "通知", icon: Bell },
    { id: "settings",      label: "设置", icon: Settings },
  ];

  return (
    <div className="app-shell flex h-[100dvh] flex-col overflow-hidden bg-[var(--app-bg)] text-[var(--text-primary)]">

      {/* ── Desktop: outer shell with padding ─────────────────────────── */}
      <div className="hidden md:flex min-h-0 flex-1 overflow-hidden p-3">
        {/* Rounded card that contains BOTH the header and the content */}
        <div className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-[18px] border border-white/10 bg-[var(--panel-bg)] shadow-2xl shadow-black/30">

          {/* Tab bar — visionOS-style floating glass pill, centered. Lives in
              the header row (normal flow) so it never overlaps content, but
              shares the mobile bottom-bar's glass material + accent-active look. */}
          <header className="flex h-[60px] shrink-0 items-center justify-center border-b border-[var(--border)] px-3">
            <nav className="glass-tab flex items-center gap-1 rounded-full p-1.5">
              {TABS.map(({ id, label, icon: Icon }) => {
                const isActive = tab === id;
                return (
                  <button
                    key={id}
                    onClick={() => handleTabChange(id)}
                    style={{ transition: "all 0.42s var(--ease-spring)" }}
                    className={`flex items-center gap-2 rounded-full px-4 py-2 text-[13px] ${
                      isActive
                        ? "bg-[var(--accent)] font-semibold text-white shadow-lg shadow-[color:var(--accent-ring)] scale-[1.04]"
                        : "font-medium text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)] hover:text-white active:scale-95"
                    }`}
                  >
                    <Icon size={17} strokeWidth={isActive ? 2.4 : 1.9} />
                    <span>{label}</span>
                  </button>
                );
              })}
            </nav>
          </header>

          {/* Tab content */}
          <div className="min-h-0 flex-1 overflow-hidden">
            <ErrorBoundary>
              <div className={tab !== "overview"      ? "hidden" : "h-full"}><ScheduleOverview /></div>
              <div className={tab !== "agent"         ? "hidden" : "h-full"}><ScheduleView /></div>
              <div className={tab !== "hub"           ? "hidden" : "h-full"}><HubView /></div>
              <div className={tab !== "notifications" ? "hidden" : "h-full"}><NotificationCenter /></div>
              <div className={tab !== "settings"      ? "hidden" : "h-full"}><SettingsView /></div>
            </ErrorBoundary>
          </div>
        </div>
      </div>

      {/* ── Mobile: full-screen, no padding ───────────────────────────── */}
      <div className="flex min-h-0 flex-1 overflow-hidden md:hidden">
        <main className="min-w-0 flex-1 overflow-hidden">
          <ErrorBoundary>
            <div className={tab !== "overview"      ? "hidden" : "h-full"}><ScheduleOverview /></div>
            <div className={tab !== "agent"         ? "hidden" : "h-full"}><ScheduleView /></div>
            <div className={tab !== "hub"           ? "hidden" : "h-full"}><HubView /></div>
            <div className={tab !== "notifications" ? "hidden" : "h-full"}><NotificationCenter /></div>
            <div className={tab !== "settings"      ? "hidden" : "h-full"}><SettingsView /></div>
          </ErrorBoundary>
        </main>
      </div>

      <DailyPopup />
      <TabBar active={tab} onChange={handleTabChange} onRefresh={handleRefresh} />
    </div>
  );
}

export default App;
