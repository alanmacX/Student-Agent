import { useState, useEffect, useCallback } from "react";
import { Coins, TrendingUp, MessageSquare, Bot } from "lucide-react";
import { fetchTokenAnalytics } from "../../api/analytics";

const PERIODS = [
  { days: 7, label: "7d" },
  { days: 14, label: "14d" },
  { days: 30, label: "30d" },
];

const SOURCE_COLORS = {
  chat: { bg: "bg-blue-500", label: "对话" },
  schedule: { bg: "bg-emerald-500", label: "Agent" },
  standby: { bg: "bg-orange-400", label: "Standby" },
};

export default function TokenStats() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [period, setPeriod] = useState(7);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const result = await fetchTokenAnalytics(period);
      setData(result);
    } catch {
      setData(null);
    } finally {
      setLoading(false);
    }
  }, [period]);

  useEffect(() => { load(); }, [load]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-10">
        <div className="shimmer h-16 w-full rounded-2xl" />
      </div>
    );
  }

  if (!data || data.daily.length === 0) {
    return (
      <div className="py-8 text-center text-sm text-[var(--text-tertiary)]">
        暂无 Token 使用记录
      </div>
    );
  }

  const { totals, daily } = data;

  // Find max total tokens for bar scaling
  const maxTokens = Math.max(...daily.map(d => d.total.input_tokens + d.total.output_tokens), 1);

  return (
    <div className="space-y-4">
      {/* Period selector */}
      <div className="flex justify-end gap-1">
        {PERIODS.map(({ days, label }) => (
          <button
            key={days}
            onClick={() => setPeriod(days)}
            className={`rounded-full px-3 py-1 text-xs font-medium transition ${
              period === days
                ? "bg-[var(--accent)] text-white"
                : "text-[var(--text-tertiary)] hover:text-white hover:bg-[var(--hover-bg)]"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {/* Stat cards */}
      <div className="flex gap-3">
        {[
          { icon: Coins, label: "总 Tokens", value: (totals.input_tokens + totals.output_tokens).toLocaleString(), color: "text-white" },
          { icon: TrendingUp, label: "预估费用", value: `$${totals.cost_usd.toFixed(4)}`, color: "text-yellow-400" },
          { icon: MessageSquare, label: "输入", value: totals.input_tokens.toLocaleString(), color: "text-blue-400" },
          { icon: Bot, label: "输出", value: totals.output_tokens.toLocaleString(), color: "text-emerald-400" },
        ].map(({ icon: Icon, label, value, color }) => (
          <div key={label} className="flex-1 rounded-2xl border border-[var(--border)] bg-[var(--surface)] px-3 py-2 text-center">
            <Icon size={14} className={`mx-auto mb-1 ${color}`} />
            <p className={`text-sm font-bold tabular-nums ${color}`}>{value}</p>
            <p className="text-[10px] text-[var(--text-tertiary)]">{label}</p>
          </div>
        ))}
      </div>

      {/* Daily bar chart */}
      <div className="space-y-1.5">
        {daily.map((day) => {
          const total = day.total.input_tokens + day.total.output_tokens;
          const pct = (total / maxTokens) * 100;
          return (
            <div key={day.date} className="flex items-center gap-2">
              <span className="w-12 text-right text-[10px] tabular-nums text-[var(--text-tertiary)]">
                {day.date.slice(5)}
              </span>
              <div className="flex-1 h-5 rounded-full bg-[var(--surface)] overflow-hidden flex">
                {(["chat", "schedule", "standby"]).map((src) => {
                  const srcTotal = day[src].input_tokens + day[src].output_tokens;
                  if (!srcTotal) return null;
                  const srcPct = (srcTotal / (total || 1)) * pct;
                  return (
                    <div
                      key={src}
                      className={`h-full ${SOURCE_COLORS[src].bg} opacity-80 transition-all`}
                      style={{ width: `${Math.max(srcPct, 0.5)}%` }}
                      title={`${SOURCE_COLORS[src].label}: ${srcTotal.toLocaleString()} tokens`}
                    />
                  );
                })}
              </div>
              <span className="w-16 text-right text-[10px] tabular-nums text-[var(--text-tertiary)]">
                {total > 0 ? `${(total / 1000).toFixed(1)}k` : "—"}
              </span>
            </div>
          );
        })}
      </div>

      {/* Legend */}
      <div className="flex justify-center gap-4">
        {Object.entries(SOURCE_COLORS).map(([key, { bg, label }]) => (
          <div key={key} className="flex items-center gap-1.5">
            <div className={`h-2.5 w-2.5 rounded-full ${bg}`} />
            <span className="text-[10px] text-[var(--text-tertiary)]">{label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
