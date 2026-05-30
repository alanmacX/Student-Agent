import { apiFetch } from "./client";

export const fetchReminders = (includeCompleted = false) =>
  apiFetch(`/api/reminders?include_completed=${includeCompleted}`);

export const createReminder = (data) =>
  apiFetch("/api/reminders", { method: "POST", body: JSON.stringify(data) });

export const updateReminder = (id, data) =>
  apiFetch(`/api/reminders/${id}`, { method: "PUT", body: JSON.stringify(data) });

export const deleteReminder = (id) =>
  apiFetch(`/api/reminders/${id}`, { method: "DELETE" });
