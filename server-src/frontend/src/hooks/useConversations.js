import { useState, useEffect, useCallback } from "react";
import { fetchConversations, createConversation, deleteConversation } from "../api/conversations";

export function useConversations() {
  const [conversations, setConversations] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const data = await fetchConversations();
      setConversations(data);
    } catch (e) {
      console.error("Failed to load conversations:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const create = useCallback(async (data) => {
    const conv = await createConversation(data);
    setConversations((prev) => [conv, ...prev]);
    return conv;
  }, []);

  const remove = useCallback(async (id) => {
    await deleteConversation(id);
    setConversations((prev) => prev.filter((c) => c.id !== id));
  }, []);

  return { conversations, loading, refresh, create, remove };
}
