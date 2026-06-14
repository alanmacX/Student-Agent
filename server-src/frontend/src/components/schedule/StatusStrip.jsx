import { useState, useEffect, useCallback } from "react";
import { Server, MessageCircle, Wifi, HardDrive } from "lucide-react";
import { fetchHealthDetail } from "../../api/health";

function metricColor(value, warn = 70, crit = 90) {
  if (value == null) return "bg-gray-400";
  if (value >= crit) return "bg-red-500";
  if (value >= warn) return "bg-yellow-400";
  return "bg-emerald-400";
}

function serviceColor(status) {
  if (status === "alive" || status === "ok" || status === true) return "bg-emerald-400";
  if (status === "unknown") return "bg-gray-400";
  return "bg-red-500";
}

export default function StatusStrip() {
  const [health, setHealth] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const data = await fetchHealthDetail();
      setHealth(data);
    } catch {
      setHealth(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    const handler = (event) => {
      if (!event.detail?.tab || event.detail.tab === "overview") load();
    };
    window.addEventListener("app-refresh", handler);
    return () => window.removeEventListener("app-refresh", handler);
  }, [load]);

  if (loading) {
    return (
      <div className="flex items-center gap-2 px-1 py-1">
        <div className="shimmer h-6 w-full rounded-full" />
      </div>
    );
  }

  if (!health) return null;

  const items = [
    { icon: Server, label: "Backend", color: serviceColor(health.backend), tip: health.backend },
    { icon: MessageCircle, label: "钉钉", color: serviceColor(health.dingtalk?.status), tip: health.dingtalk?.status === "alive" ? `${health.dingtalk.wal_age_minutes}分钟前同步` : health.dingtalk?.status },
    { icon: Wifi, label: "学习通", color: serviceColor(health.chaoxing?.logged_in), tip: health.chaoxing?.logged_in ? "已登录" : "未登录" },
    { icon: HardDrive, label: `磁盘 ${health.disk_percent ?? "?"}%`, color: metricColor(health.disk_percent), tip: `CPU ${health.cpu_percent ?? "?"}% · RAM ${health.ram_percent ?? "?"}%` },
  ];

  return (
    <div className="flex flex-wrap items-center gap-1.5 px-1 py-1">
      {items.map(({ icon: Icon, label, color, tip }) => (
        <div
          key={label}
          title={tip}
          className="flex items-center gap-1.5 rounded-full border border-[var(--border)] bg-[var(--surface)] px-2.5 py-1 text-[11px] text-[var(--text-secondary)]"
        >
          <span className={`h-1.5 w-1.5 rounded-full ${color}`} />
          <Icon size={12} />
          <span className="whitespace-nowrap">{label}</span>
        </div>
      ))}
    </div>
  );
}
