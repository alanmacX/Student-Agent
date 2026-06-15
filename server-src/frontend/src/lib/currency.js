// Currency display preference. Costs are computed in USD everywhere on the
// backend (pricing sources are USD); this only controls how they're shown.
// Default is CNY since we recommend DeepSeek (billed in RMB). The preference is
// cached in localStorage for instant render and synced to the server settings
// KV so it follows the user across devices.
import { create } from "zustand";
import { apiFetch } from "../api/client";

const DEFAULTS = { currency: "CNY", rate: 7.2 };

function load() {
  try {
    const c = localStorage.getItem("display_currency");
    const r = parseFloat(localStorage.getItem("usd_to_cny_rate"));
    return {
      currency: c === "USD" || c === "CNY" ? c : DEFAULTS.currency,
      rate: Number.isFinite(r) && r > 0 ? r : DEFAULTS.rate,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

export const useCurrency = create((set, get) => ({
  ...load(),

  setCurrency: (currency) => {
    set({ currency });
    try { localStorage.setItem("display_currency", currency); } catch {}
    apiFetch("/api/settings", { method: "PUT", body: JSON.stringify({ settings: { display_currency: currency } }) }).catch(() => {});
  },

  setRate: (rate) => {
    const r = parseFloat(rate);
    if (!Number.isFinite(r) || r <= 0) return;
    set({ rate: r });
    try { localStorage.setItem("usd_to_cny_rate", String(r)); } catch {}
    apiFetch("/api/settings", { method: "PUT", body: JSON.stringify({ settings: { usd_to_cny_rate: r } }) }).catch(() => {});
  },

  // Hydrate from the server once on app start (server wins if it has a value).
  hydrate: async () => {
    try {
      const s = await apiFetch("/api/settings");
      const patch = {};
      if (s.display_currency === "USD" || s.display_currency === "CNY") patch.currency = s.display_currency;
      const r = parseFloat(s.usd_to_cny_rate);
      if (Number.isFinite(r) && r > 0) patch.rate = r;
      if (Object.keys(patch).length) {
        set(patch);
        if (patch.currency) localStorage.setItem("display_currency", patch.currency);
        if (patch.rate) localStorage.setItem("usd_to_cny_rate", String(patch.rate));
      }
    } catch {}
  },
}));

// Format a USD cost in the user's chosen currency. `digits` controls decimals.
export function formatCost(usd, digits = 4) {
  const { currency, rate } = useCurrency.getState();
  const v = Number(usd) || 0;
  if (currency === "CNY") return `¥${(v * rate).toFixed(digits)}`;
  return `$${v.toFixed(digits)}`;
}
