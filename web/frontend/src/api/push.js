import { apiFetch } from "./client";

export const getVapidKey = () => apiFetch("/api/push/vapid-public-key");

export const subscribeToServer = (data) =>
  apiFetch("/api/push/subscribe", { method: "POST", body: JSON.stringify(data) });

export const unsubscribeFromServer = (data) =>
  apiFetch("/api/push/subscribe", { method: "DELETE", body: JSON.stringify(data) });

export const sendTestPush = () =>
  apiFetch("/api/push/test", { method: "POST" });

export const getNotificationRules = () =>
  apiFetch("/api/settings/notification-rules");

export const updateNotificationRules = (value) =>
  apiFetch("/api/settings/notification-rules", {
    method: "PUT",
    body: JSON.stringify({ value }),
  });
