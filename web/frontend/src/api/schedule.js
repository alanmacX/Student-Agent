import { apiFetch } from "./client";

export const fetchScheduleMessages = () => apiFetch("/api/schedule/messages");

export const clearScheduleMessages = () =>
  apiFetch("/api/schedule/messages", { method: "DELETE" });

export const fetchScheduleSidebar = () => apiFetch("/api/schedule/sidebar");

export const refreshBriefing = () =>
  apiFetch("/api/schedule/refresh-briefing", { method: "POST" });

export const importCourses = (semesterStart, courses) =>
  apiFetch("/api/schedule/courses/import", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ semester_start: semesterStart, courses }),
  });
