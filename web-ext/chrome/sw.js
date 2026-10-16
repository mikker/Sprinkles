const minimumBuildNumber = 105;
const server = "https://localhost:3133";

let lastCheckTime = 0;
const CHECK_THROTTLE_MS = 1000; // Only check once per second

chrome.runtime.onInstalled.addListener(() => {
  reload();
  syncToolbarIcon();
});

chrome.runtime.onStartup.addListener(() => {
  syncToolbarIcon();
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type !== "sprinkles:color-scheme") return;
  setToolbarIcon(message.dark);
});

chrome.action.onClicked.addListener(async () => {
  if (!isUserScriptsAvailable()) {
    chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` });
    return;
  }

  const result = await reload();

  if (result.status === "outdated") {
    const { version, build } = result.version;
    chrome.tabs.create({
      url: `https://getsprinkles.app/troubleshooting?version=${version}&build=${build}`,
    });
  }
});

// chrome.userScripts is unavailable until the user turns on both Developer mode
// and "Allow User Scripts" for the extension in chrome://extensions
function isUserScriptsAvailable() {
  try {
    chrome.userScripts.getScripts();
    return true;
  } catch {
    return false;
  }
}

chrome.webNavigation.onBeforeNavigate.addListener(async (details) => {
  // Skip iframe navigations
  if (details.frameId !== 0) return;

  // Only check once per CHECK_THROTTLE_MS (1s)
  const now = Date.now();
  if (now - lastCheckTime < CHECK_THROTTLE_MS) return;

  lastCheckTime = now;
  await checkForUpdates();
});

// The worker is stopped when idle, so the checksum of the last applied scripts
// lives in storage. Nothing stored means nothing applied yet, so reload.
async function checkForUpdates() {
  if (!isUserScriptsAvailable()) return;

  try {
    const { checksum } = await fetchJSON("/v3/checksum.json");
    const { lastChecksum } = await chrome.storage.local.get("lastChecksum");

    if (checksum !== lastChecksum) {
      console.log("Scripts changed, reloading...");
      await reload();
    }
  } catch (e) {
    console.error("Failed to check for updates:", e);
  }
}

// Only one reload runs at a time. Calls made while one is running share a
// single follow-up run.
let currentReload = null;
let queuedReload = null;

function reload() {
  if (!currentReload) {
    currentReload = performReload()
      .catch((e) => {
        console.error("Failed to reload user scripts:", e);
        return { status: "error" };
      })
      .finally(() => {
        currentReload = null;
      });
    return currentReload;
  }

  if (!queuedReload) {
    queuedReload = currentReload.then(() => {
      queuedReload = null;
      return reload();
    });
  }

  return queuedReload;
}

// Resolves to { status }: "ok", "disabled", "offline", "outdated" or "error".
async function performReload() {
  if (!isUserScriptsAvailable()) {
    console.log(
      'User scripts not allowed. Enable Developer mode and "Allow User Scripts" for Sprinkles in chrome://extensions.',
    );

    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#cc0000" });
    chrome.action.setTitle({
      title:
        'Sprinkles needs Developer mode and "Allow User Scripts" enabled. Click to open settings, then click again to reload.',
    });

    return { status: "disabled" };
  }

  // Fetch everything before touching the registered scripts, so they stay in
  // place when the app isn't running.
  let checksum, scripts;

  try {
    const version = await fetchJSON("/version.json");
    console.log(`Version: ${version.version}, build: ${version.build}`);

    if (version.build < minimumBuildNumber) {
      console.log("Version mismatch");

      chrome.action.setBadgeText({ text: "!" });
      chrome.action.setBadgeBackgroundColor({ color: "#cc0000" });
      chrome.action.setTitle({ title: "Please upgrade Sprinkles to continue" });

      return { status: "outdated", version };
    }

    ({ checksum } = await fetchJSON("/v3/checksum.json"));

    // Skip dotfiles like macOS ._ metadata files
    const domains = (await fetchJSON("/v3/domains.json")).filter(
      (domain) => !domain.startsWith("."),
    );

    scripts = await Promise.all(
      ["global", ...domains].map(async (domain) => {
        console.log(`Fetching user script for ${domain}`);
        return { domain, code: await fetchScript(domain) };
      }),
    );
  } catch (e) {
    console.error("Sprinkles app not running?", e);
    chrome.action.setTitle({
      title: "Sprinkles app not running. Click to retry.",
    });
    return { status: "offline" };
  }

  try {
    await chrome.userScripts.unregister();
  } catch (e) {
    console.error("Failed to unregister user scripts:", e);
    return { status: "error" };
  }

  const results = await Promise.allSettled(
    scripts.map(({ domain, code }) => {
      const matches =
        domain === "global"
          ? ["*://*/*"]
          : [`*://${domain}/*`, `*://www.${domain}/*`];
      return register(domain, matches, code);
    }),
  );

  results.forEach((result, i) => {
    if (result.status === "rejected") {
      console.error(
        `Failed to register user script for ${scripts[i].domain}:`,
        result.reason,
      );
    }
  });

  await chrome.storage.local.set({ lastChecksum: checksum });

  chrome.action.setBadgeText({ text: "" });
  chrome.action.setTitle({ title: "Reload user scripts" });

  return { status: "ok" };
}

async function fetchJSON(path) {
  const res = await fetch(`${server}${path}`);
  if (!res.ok) throw new Error(`${path} responded ${res.status}`);
  return res.json();
}

async function fetchScript(domain) {
  const res = await fetch(`${server}/v3/s/${domain}.js`);
  const code = await res.text();
  return code;
}

async function register(domain, matches, code) {
  console.log(`Registering user script for ${domain}`);
  await chrome.userScripts.register([
    {
      id: `user-script-${domain}`,
      matches,
      js: [{ code }],
      runAt: "document_idle",
      world: "MAIN",
    },
  ]);
}

// Chrome has no manifest-level theme icons, so an offscreen document watches
// prefers-color-scheme and reports back. Service workers restart often, so
// this also runs at the top level of the worker.

const OFFSCREEN_URL = "offscreen.html";
let creatingOffscreen = null;

async function hasOffscreenDocument() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ["OFFSCREEN_DOCUMENT"],
    documentUrls: [chrome.runtime.getURL(OFFSCREEN_URL)],
  });
  return contexts.length > 0;
}

async function ensureOffscreenDocument() {
  if (await hasOffscreenDocument()) return;

  if (!creatingOffscreen) {
    creatingOffscreen = chrome.offscreen
      .createDocument({
        url: OFFSCREEN_URL,
        reasons: ["MATCH_MEDIA"],
        justification: "Match the toolbar icon to the browser's color scheme",
      })
      .catch((e) => {
        // Another context may have created it in the meantime
        if (!String(e?.message).includes("single offscreen")) throw e;
      })
      .finally(() => {
        creatingOffscreen = null;
      });
  }

  await creatingOffscreen;
}

async function syncToolbarIcon() {
  try {
    await ensureOffscreenDocument();
    const response = await chrome.runtime.sendMessage({
      type: "sprinkles:get-color-scheme",
    });
    if (response) setToolbarIcon(response.dark);
  } catch (e) {
    console.error("Failed to sync toolbar icon:", e);
  }
}

function setToolbarIcon(dark) {
  const suffix = dark ? "-dark" : "";
  chrome.action.setIcon({
    path: {
      16: `images/toolbar-icon${suffix}-16.png`,
      32: `images/toolbar-icon${suffix}-32.png`,
    },
  });
}

syncToolbarIcon();
