// Offscreen document used only to observe the browser's color scheme, which
// the service worker can't do itself (no window.matchMedia in workers).

const query = window.matchMedia("(prefers-color-scheme: dark)");

function send() {
  chrome.runtime
    .sendMessage({ type: "sprinkles:color-scheme", dark: query.matches })
    .catch(() => {});
}

query.addEventListener("change", send);

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "sprinkles:get-color-scheme") return;
  sendResponse({ dark: query.matches });
});

send();
