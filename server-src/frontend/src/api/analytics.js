import { apiFetch } from "./client";

export const fetchTokenAnalytics = (days = 7) =>
  apiFetch(`/api/analytics/tokens?days=${days}`);
