// ── Browser-compat shims ───────────────────────────────────────────────────
// Array.prototype.findLastIndex is Safari 15.4+ / Chrome 97+. The PWA targets
// older iPhones; a ReferenceError here white-screens the whole app.

export function findLastIndex(arr, predicate) {
  if (typeof arr.findLastIndex === "function") return arr.findLastIndex(predicate);
  for (let i = arr.length - 1; i >= 0; i -= 1) {
    if (predicate(arr[i], i, arr)) return i;
  }
  return -1;
}
