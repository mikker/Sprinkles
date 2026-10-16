// Offscreen document used only to observe the browser's color scheme, which
// the service worker can't do itself (no window.matchMedia in workers).

const QUERY = "(prefers-color-scheme: dark)";
let lastDark = null;

function isDark() {
  // A fresh matchMedia() reflects the current scheme; a cached MediaQueryList
  // in an offscreen document never fires "change" (nothing is rendered)
  return window.matchMedia(QUERY).matches;
}

function send(force) {
  const dark = isDark();
  if (!force && dark === lastDark) return;
  lastDark = dark;
  chrome.runtime
    .sendMessage({ type: "sprinkles:color-scheme", dark })
    .catch(() => {});
}

window.matchMedia(QUERY).addEventListener("change", () => send(false));
setInterval(() => send(false), 5000);

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "sprinkles:get-color-scheme") return;
  sendResponse({ dark: isDark() });
});

send(true);
