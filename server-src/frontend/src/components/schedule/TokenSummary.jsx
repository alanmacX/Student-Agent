import { useState, useEffect, useCallback } from "react";
import { Coins, TrendingUp, TrendingDown, Minus } from "lucide-react";
import { fetchTokenAnalytics } from "../../api/analytics";

export default function TokenSummary() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const result = await fetchTokenAnalytics(2);
      setData(result);
    } catch {
      setData(null);
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
        <div className="shimmer h-10 w-full rounded-2xl" />
      </div>
    );
  }

  if (!data) return null;

  const { today, yesterday } = data;
  const todayTotal = today.input_tokens + today.output_tokens;
  const yestTotal = yesterday.input_tokens + yesterday.output_tokens;
  const delta = yestTotal > 0 ? ((todayTotal - yestTotal) / yestTotal) * 100 : 0;
  const deltaRounded = Math.round(delta);

  const DeltaIcon = delta > 5 ? TrendingUp : delta < -5 ? TrendingDown : Minus;
  const deltaColor = delta > 5 ? "text-orange-400" : delta < -5 ? "text-emerald-400" : "text-[var(--text-tertiary)]";

  return (
    <div className="flex items-center gap-3 rounded-2xl border border-[var(--border)] bg-[var(--surface)] px-4 py-2.5">
      <Coins size={16} className="text-[var(--accent)]" />
      <div className="flex-1 min-w-0">
        <p className="text-xs text-[var(--text-tertiary)]">今日 Token</p>
        <p className="text-sm font-bold tabular-nums text-white">
          {todayTotal > 0 ? todayTotal.toLocaleString() : "—"}
        </p>
      </div>
      <div className="text-right">
        <p className="text-xs text-[var(--text-tertiary)]">费用</p>
        <p className="text-sm font-bold tabular-nums text-yellow-400">
          ${today.cost_usd.toFixed(4)}
        </p>
        {(today.cache_hit_tokens || today.cache_miss_tokens) ? (
          <p className="text-[10px] tabular-nums text-[var(--text-tertiary)]">
            hit {(today.cache_hit_tokens || 0).toLocaleString()}
          </p>
        ) : null}
      </div>
      {yestTotal > 0 && todayTotal > 0 && (
        <div className={`flex items-center gap-0.5 ${deltaColor}`}>
          <DeltaIcon size={13} />
          <span className="text-xs font-medium tabular-nums">{deltaRounded}%</span>
        </div>
      )}
    </div>
  );
}
