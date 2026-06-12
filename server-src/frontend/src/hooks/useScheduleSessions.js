import { useState, useEffect, useCallback } from "react";
import { apiFetch } from "../api/client";

const AUTO_NEW_SESSION_HOURS = 12;

export function useScheduleSessions() {
  const [sessions, setSessions] = useState([]);
  const [loading, setLoading] = useState(true);

  const fetchSessions = useCallback(async () => {
    try {
      const data = await apiFetch("/api/schedule/sessions");
      setSessions(data);
      return data;
    } catch (e) {
      console.error("[useScheduleSessions] fetch error:", e);
      return [];
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSessions();
  }, [fetchSessions]);

  const createSession = useCallback(async (title = "新对话") => {
    try {
      const session = await apiFetch("/api/schedule/sessions", {
        method: "POST",
        body: JSON.stringify({ title }),
      });
      setSessions((prev) => [session, ...prev]);
      return session;
    } catch (e) {
      console.error("[useScheduleSessions] create error:", e);
      return null;
    }
  }, []);

  const initSession = useCallback(async () => {
    const list = await fetchSessions();
    setSessions(list);
    setLoading(false);
    if (!list.length) {
      const s = await createSession("新对话");
      return s?.id || null;
    }
    const latest = list[0]; // already sorted by updated_at DESC
    const lastActive = new Date(
      latest.updated_at.endsWith("Z") || /[+-]\d{2}:\d{2}$/.test(latest.updated_at)
        ? latest.updated_at
        : latest.updated_at + "Z"
    );
    const hoursAgo = (Date.now() - lastActive.getTime()) / 3_600_000;
    if (hoursAgo > AUTO_NEW_SESSION_HOURS) {
      const s = await createSession("新对话");
      return s?.id || latest.id;
    }
    return latest.id;
  }, [fetchSessions, createSession]);

  const deleteSession = useCallback(async (id) => {
    try {
      await apiFetch(`/api/schedule/sessions/${id}`, { method: "DELETE" });
      setSessions((prev) => prev.filter((s) => s.id !== id));
    } catch (e) {
      console.error("[useScheduleSessions] delete error:", e);
    }
  }, []);

  const renameSession = useCallback(async (id, title) => {
    try {
      await apiFetch(`/api/schedule/sessions/${id}`, {
        method: "PATCH",
        body: JSON.stringify({ title }),
      });
      setSessions((prev) => prev.map((s) => (s.id === id ? { ...s, title } : s)));
    } catch (e) {
      console.error("[useScheduleSessions] rename error:", e);
    }
  }, []);

  const refreshSessions = useCallback(() => {
    fetchSessions();
  }, [fetchSessions]);

  return {
    sessions,
    loading,
    createSession,
    deleteSession,
    renameSession,
    refreshSessions,
    initSession,
  };
}
