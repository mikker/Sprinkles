const minimumBuildNumber = 105;
const server = "https://localhost:3133";

let lastCheckTime = 0;
const CHECK_THROTTLE_MS = 1000; // Only check once per second

browser.runtime.onInstalled.addListener(async () => {
  await reload();
});

browser.action.onClicked.addListener(async () => {
  const result = await reload();

  if (result.status === "outdated") {
    const { version, build } = result.version;
    browser.tabs.create({
      url: `https://getsprinkles.app/troubleshooting?version=${version}&build=${build}`,
    });
  }
});

browser.permissions.onAdded.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
    await reload();
  }
});

browser.permissions.onRemoved.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
    await browser.storage.local.remove("lastChecksum");
    await browser.userScripts.unregister();
  }
});

browser.webNavigation.onBeforeNavigate.addListener(async (details) => {
  // Skip iframe navigations
  if (details.frameId !== 0) return;

  // Only check once per CHECK_THROTTLE_MS (1s)
  const now = Date.now();
  if (now - lastCheckTime < CHECK_THROTTLE_MS) return;

  lastCheckTime = now;
  await checkForUpdates();
});

// The event page is unloaded when idle, so the checksum of the last applied
// scripts lives in storage. Nothing stored means nothing applied yet, so reload.
async function checkForUpdates() {
  // Don't pop the options page on every navigation
  if (!(await browser.permissions.contains({ permissions: ["userScripts"] }))) {
    return;
  }

  try {
    const { checksum } = await fetchJSON("/v3/checksum.json");
    const { lastChecksum } = await browser.storage.local.get("lastChecksum");

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
  if (!(await browser.permissions.contains({ permissions: ["userScripts"] }))) {
    console.log("userScripts permission not granted");
    browser.runtime.openOptionsPage();
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

      browser.action.setBadgeText({ text: "!" });
      browser.action.setBadgeBackgroundColor({ color: "#cc0000" });
      browser.action.setTitle({ title: "Please upgrade Sprinkles to continue" });

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
    browser.action.setTitle({
      title: "Sprinkles app not running. Click to retry.",
    });
    return { status: "offline" };
  }

  try {
    await browser.userScripts.unregister();
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

  await browser.storage.local.set({ lastChecksum: checksum });

  browser.action.setBadgeText({ text: "" });
  browser.action.setTitle({ title: "Reload user scripts" });

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
  await browser.userScripts.register([
    {
      id: `user-script-${domain}`,
      matches,
      js: [{ code }],
      runAt: "document_idle",
      world: "MAIN",
    },
  ]);
}
