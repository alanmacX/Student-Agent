import { useEffect, useState } from "react";
import { Sparkles, Moon, X } from "lucide-react";
import { fetchDailyPopup } from "../../api/notifications";

const SEEN_KEY = "daily-popup-seen-id";

export default function DailyPopup() {
  const [popup, setPopup] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetchDailyPopup();
        const p = res?.popup;
        if (!p || !p.id) return;
        if (localStorage.getItem(SEEN_KEY) === String(p.id)) return;
        if (!cancelled) setPopup(p);
      } catch {
        /* ignore */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (!popup) return null;

  const isEvening = popup.notif_type === "daily_summary_evening";
  const Icon = isEvening ? Moon : Sparkles;
  const tag = isEvening ? "晚间总结" : "今日简报";

  const dismiss = () => {
    localStorage.setItem(SEEN_KEY, String(popup.id));
    setPopup(null);
  };

  return (
    <div
      className="fixed inset-0 z-[100] flex items-end justify-center p-4 md:items-center"
      style={{ background: "var(--overlay-bg)", backdropFilter: "blur(6px)" }}
      onClick={dismiss}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="animate-rise w-full max-w-sm overflow-hidden rounded-[28px] p-6"
        style={{
          background:
            "linear-gradient(155deg, rgba(10,132,255,0.28) 0%, rgba(10,132,255,0.08) 55%, rgba(10,132,255,0.02) 100%)",
          border: "1px solid rgba(10,132,255,0.32)",
          boxShadow: "0 24px 60px rgba(0,0,0,0.45), 0 1px 0 rgba(255,255,255,0.08) inset",
        }}
      >
        <div className="flex items-start justify-between">
          <span className="flex items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-[11px] font-semibold tracking-wide text-[var(--accent-soft)]">
            <Icon size={13} />
            {tag}
          </span>
          <button
            onClick={dismiss}
            className="grid h-8 w-8 place-items-center rounded-full text-white/60 transition hover:bg-white/10 hover:text-white active:scale-90"
            aria-label="关闭"
          >
            <X size={16} />
          </button>
        </div>
        <p className="mt-4 text-[20px] font-bold leading-snug text-white">{popup.title}</p>
        {popup.body && popup.body !== popup.title && (
          <p className="mt-2 text-[15px] leading-relaxed text-white/85">{popup.body}</p>
        )}
        <button
          onClick={dismiss}
          className="mt-5 w-full rounded-2xl bg-[var(--accent)] py-3 text-[15px] font-semibold text-white shadow-lg transition active:scale-[0.98]"
        >
          知道了
        </button>
      </div>
    </div>
  );
}
