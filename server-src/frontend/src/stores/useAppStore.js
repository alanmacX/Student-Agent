import { create } from "zustand";

export const useAppStore = create((set) => ({
  tab: "chat",
  setTab: (tab) => set({ tab }),

  selectedConversationId: null,
  setSelectedConversationId: (id) => set({ selectedConversationId: id }),

  isStreaming: false,
  setIsStreaming: (v) => set({ isStreaming: v }),
}));
