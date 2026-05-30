import { apiFetch } from "./client";

export const getChaoxingStatus = () => apiFetch("/api/chaoxing/status");

export const requestOtp = (phone) =>
  apiFetch("/api/chaoxing/login", { method: "POST", body: JSON.stringify({ phone }) });

export const verifyOtp = (phone, code) =>
  apiFetch("/api/chaoxing/verify", { method: "POST", body: JSON.stringify({ phone, code }) });

export const chaoxingLogout = () =>
  apiFetch("/api/chaoxing/logout", { method: "POST" });

export const startQrLogin = () =>
  apiFetch("/api/chaoxing/qr/start", { method: "POST" });

export const pollQrLogin = (uuid, enc) =>
  apiFetch("/api/chaoxing/qr/poll", {
    method: "POST",
    body: JSON.stringify({ uuid, enc }),
  });

export const fetchChaoxingCourses = () => apiFetch("/api/chaoxing/courses");

export const fetchChaoxingAssignments = () => apiFetch("/api/chaoxing/assignments");

export const fetchChaoxingMemory = () => apiFetch("/api/chaoxing/memory");

export const syncChaoxingMemory = () =>
  apiFetch("/api/chaoxing/memory/sync", { method: "POST" });

export const archiveMemoryEntry = (id) =>
  apiFetch(`/api/chaoxing/memory/${id}/archive`, { method: "POST" });

export const getMutedConversations = () => apiFetch("/api/chaoxing/muted-conversations");

export const setMutedConversations = (muted) =>
  apiFetch("/api/chaoxing/muted-conversations", {
    method: "PUT",
    body: JSON.stringify({ muted }),
  });
