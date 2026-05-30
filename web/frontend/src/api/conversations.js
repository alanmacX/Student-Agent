import { apiFetch } from "./client";

export const fetchConversations = () => apiFetch("/api/conversations");

export const createConversation = (data) =>
  apiFetch("/api/conversations", { method: "POST", body: JSON.stringify(data) });

export const getConversation = (id) => apiFetch(`/api/conversations/${id}`);

export const updateConversation = (id, data) =>
  apiFetch(`/api/conversations/${id}`, { method: "PUT", body: JSON.stringify(data) });

export const deleteConversation = (id) =>
  apiFetch(`/api/conversations/${id}`, { method: "DELETE" });

export const fetchMessages = (convId) => apiFetch(`/api/conversations/${convId}/messages`);
