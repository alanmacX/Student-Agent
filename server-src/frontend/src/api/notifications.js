import { apiFetch } from "./client";

export const fetchNotifications = (limit = 50) =>
  apiFetch(`/api/notifications?limit=${limit}`);

export const fetchScheduledNotifications = (limit = 50) =>
  apiFetch(`/api/notifications/scheduled?limit=${limit}`);

export const fetchStandbyLog = (limit = 30) =>
  apiFetch(`/api/notifications/standby-log?limit=${limit}`);

export const fetchDailyPopup = () => apiFetch("/api/notifications/daily-popup");
