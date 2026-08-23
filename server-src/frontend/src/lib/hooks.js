// ── Shared small hooks ─────────────────────────────────────────────────────
import { useEffect, useRef, useState, useCallback } from "react";

/**
 * Two-step destructive-action confirmation with auto-reset.
 * First call arms (returns true), second call within the window confirms.
 * Replaces the copy-pasted setTimeout pattern in SessionItem/RemindersPanel.
 */
export function useConfirmArm(timeoutMs = 2000) {
  const [armed, setArmed] = useState(false);
  const timerRef = useRef(null);
  const arm = useCallback(() => {
    setArmed(true);
    clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => setArmed(false), timeoutMs);
  }, [timeoutMs]);
  useEffect(() => () => clearTimeout(timerRef.current), []);
  /** Returns true when the action should execute. */
  const attempt = useCallback(() => {
    if (armed) {
      clearTimeout(timerRef.current);
      setArmed(false);
      return true;
    }
    arm();
    return false;
  }, [armed, arm]);
  return [armed, attempt];
}

/**
 * Interval polling that pauses while `document.hidden` and refreshes once on
 * return to visibility. Replaces the duplicated visibility-poll blocks in
 * ScheduleOverview / NotificationCenter / DingTalkStatus.
 *
 * @param {() => (void|Promise<void>)} fn        poll body
 * @param {number} intervalMs                    tick length
 * @param {{enabled?: boolean, immediate?: boolean}} opts
 */
export function useVisibilityPoll(fn, intervalMs, { enabled = true, immediate = true } = {}) {
  const fnRef = useRef(fn);
  fnRef.current = fn;
  useEffect(() => {
    if (!enabled) return undefined;
    let timer = null;
    const start = () => {
      if (timer) return;
      timer = setInterval(() => fnRef.current(), intervalMs);
    };
    const stop = () => {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
    };
    const onVisibility = () => {
      if (document.hidden) stop();
      else {
        if (immediate) fnRef.current();
        start();
      }
    };
    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [enabled, intervalMs, immediate]);
}
