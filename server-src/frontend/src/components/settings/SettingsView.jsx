import { useState } from "react";
import { Key, Bell, LogIn, Database, MessageCircle } from "lucide-react";
import ProviderSettings from "./ProviderSettings";
import PushSettings from "./PushSettings";
import ChaoxingStatus from "../schedule/ChaoxingStatus";
import DataPanel from "./DataPanel";
import DingTalkStatus from "./DingTalkStatus";

const TABS = [
  { id: "providers", label: "API Keys", mobileLabel: "API", icon: Key },
  { id: "chaoxing", label: "Chaoxing", mobileLabel: "学习通", icon: LogIn },
  { id: "dingtalk", label: "钉钉", mobileLabel: "钉钉", icon: MessageCircle },
  { id: "push", label: "Push", mobileLabel: "推送", icon: Bell },
  { id: "data", label: "数据管理", mobileLabel: "数据", icon: Database },
];

export default function SettingsView() {
  const [tab, setTab] = useState("providers");

  return (
    <div className="relative flex h-full flex-col bg-[var(--panel-bg)] md:flex-row">
      {/* Tab list — floating glass island on mobile, sidebar on desktop */}
      <div className="pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center px-3 pt-3 md:pointer-events-auto md:static md:block md:w-52 md:justify-start md:border-r md:border-[var(--border)] md:bg-[var(--sidebar-bg)] md:px-0 md:py-3">
        <div className="no-scrollbar glass-pill pointer-events-auto inline-flex w-fit max-w-full gap-1 overflow-x-auto rounded-full p-1.5 md:flex md:w-full md:max-w-none md:flex-col md:gap-1 md:rounded-none md:border-0 md:bg-transparent md:p-2 md:shadow-none md:backdrop-blur-none md:space-y-1">
        {TABS.map(({ id, label, mobileLabel, icon: Icon }) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`flex min-h-9 flex-shrink-0 items-center justify-center gap-2 rounded-full px-3.5 text-sm transition md:w-full md:justify-start md:rounded-2xl md:px-4 ${
              tab === id
                ? "bg-[var(--hover-bg)] text-white"
                : "text-[var(--text-secondary)] hover:bg-[var(--surface-2)] hover:text-white"
            }`}
          >
            <Icon size={16} />
            <span className="hidden md:inline">{label}</span>
          </button>
        ))}
        </div>
      </div>

      {/* Content */}
      <div className="min-h-0 flex-1 overflow-y-auto px-4 pt-[72px] pb-36 md:p-6">
        {tab === "providers" && <ProviderSettings />}
        {tab === "chaoxing" && <ChaoxingStatus />}
        {tab === "dingtalk" && <DingTalkStatus />}
        {tab === "push" && <PushSettings />}
        {tab === "data" && <DataPanel />}
      </div>
    </div>
  );
}
