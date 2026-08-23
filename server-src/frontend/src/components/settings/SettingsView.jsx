import { useState, useEffect } from "react";
import { Key, Bell, LogIn, Database, MessageCircle, Coins, GraduationCap } from "lucide-react";
import ProviderSettings from "./ProviderSettings";
import PushSettings from "./PushSettings";
import ChaoxingStatus from "../schedule/ChaoxingStatus";
import DataPanel from "./DataPanel";
import DingTalkStatus from "./DingTalkStatus";
import TokenStats from "../hub/TokenStats";
import ZjutSettings from "./ZjutSettings";

const TABS = [
  { id: "providers", label: "API Keys", mobileLabel: "API", icon: Key },
  { id: "zjut", label: "正方教务", mobileLabel: "教务", icon: GraduationCap },
  { id: "chaoxing", label: "Chaoxing", mobileLabel: "学习通", icon: LogIn },
  { id: "dingtalk", label: "钉钉", mobileLabel: "钉钉", icon: MessageCircle },
  { id: "push", label: "Push", mobileLabel: "推送", icon: Bell },
  { id: "tokens", label: "用量统计", mobileLabel: "用量", icon: Coins },
  { id: "data", label: "数据管理", mobileLabel: "数据", icon: Database },
];

export default function SettingsView() {
  const [tab, setTab] = useState("providers");

  // Nothing to fetch on pull-to-refresh (settings are form-driven); report
  // completion immediately so the global spinner doesn't wait out its 5s
  // safety timeout on this tab.
  useEffect(() => {
    const handler = (event) => {
      if (!event.detail?.tab || event.detail.tab === "settings") {
        window.dispatchEvent(new CustomEvent("app-refresh-done", { detail: { tab: "settings" } }));
      }
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, []);

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)] md:flex-row md:gap-4 md:p-4 lg:gap-5 lg:p-6">
      {/* Tab list — floating glass island on mobile, glass card on desktop.
          No hard sidebar border/fill — matches the notifications tab. */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center px-3 pt-3 md:pointer-events-auto md:static md:block md:w-52 md:shrink-0 md:px-0 md:pt-0">
        <div className="no-scrollbar glass-pill pointer-events-auto inline-flex w-fit max-w-full gap-1 overflow-x-auto rounded-full p-1.5 md:sticky md:top-0 md:flex md:w-full md:max-w-none md:flex-col md:gap-1 md:rounded-2xl md:p-2">
        {TABS.map(({ id, label, mobileLabel, icon: Icon }) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`flex min-h-9 flex-shrink-0 items-center justify-center gap-2 rounded-full px-3.5 text-sm transition-colors duration-200 md:w-full md:justify-start md:rounded-xl md:px-3.5 md:py-2 ${
              tab === id
                ? "bg-[var(--hover-bg)] text-white shadow-sm"
                : "text-[var(--text-tertiary)] hover:text-white hover:bg-[var(--surface-2)]"
            }`}
          >
            <Icon size={16} />
            <span className="hidden md:inline">{label}</span>
          </button>
        ))}
        </div>
      </div>

      {/* Content */}
      <div className="min-h-0 flex-1 overflow-y-auto px-4 pt-[72px] pb-36 md:p-0 md:pt-0">
        {tab === "providers" && <ProviderSettings />}
        {tab === "zjut" && <ZjutSettings />}
        {tab === "chaoxing" && <ChaoxingStatus />}
        {tab === "dingtalk" && <DingTalkStatus />}
        {tab === "push" && <PushSettings />}
        {tab === "tokens" && <TokenStats />}
        {tab === "data" && <DataPanel />}
      </div>
    </div>
  );
}
