import { create } from "zustand";

export const useChaoxingStore = create((set) => ({
  isLoggedIn: false,
  uid: null,
  username: null,
  setStatus: (status) => set(status),
}));
