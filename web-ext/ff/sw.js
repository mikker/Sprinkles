const minimumBuildNumber = 105;

let lastChecksum = null;
let lastCheckTime = 0;
const CHECK_THROTTLE_MS = 1000; // Only check once per second

browser.runtime.onInstalled.addListener(async () => {
  await reload();
});

browser.action.onClicked.addListener(async () => {
  await reload();
});

browser.permissions.onAdded.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
    await reload();
  }
});

browser.permissions.onRemoved.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
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

async function checkForUpdates() {
  try {
    const res = await fetch(`https://localhost:3133/v3/checksum.json`);
    const { checksum } = await res.json();

    if (lastChecksum === null) {
      lastChecksum = checksum;
      return;
    }

    if (checksum !== lastChecksum) {
      console.log("Scripts changed, reloading...");
      lastChecksum = checksum;
      await reload();
    }
  } catch (e) {
    console.error("Failed to check for updates:", e);
  }
}

async function reload() {
  if (!(await browser.permissions.contains({ permissions: ["userScripts"] }))) {
    console.log("userScripts permission not granted");
    browser.runtime.openOptionsPage();
    return;
  }

  await browser.userScripts.unregister();

  const version = await fetchVersion();
  console.log(`Version: ${version.version}, build: ${version.build}`);

  if (version.build < minimumBuildNumber) {
    console.log("Version mismatch");

    browser.action.setBadgeText({ text: "!" });
    browser.action.setBadgeBackgroundColor({ color: "#cc0000" });
    browser.action.setTitle({ title: "Please upgrade Sprinkles to continue" });
    browser.action.onClicked.addListener(() => {
      browser.tabs.create({
        url: `https://getsprinkles.app/troubleshooting?version=${version.version}&build=${version.build}`,
      });
    });

    return;
  }

  await registerGlobal();

  const domains = await fetchList();

  await Promise.all(
    domains.map(async (domain) => {
      console.log(`Fetching user script for ${domain}`);
      const code = await fetchScript(domain);
      const matches = [`*://${domain}/*`, `*://www.${domain}/*`];
      await register(domain, matches, code);
    }),
  );
}

async function fetchVersion() {
  try {
    const res = await fetch(`https://localhost:3133/version.json`);
    return res.json();
  } catch (e) {
    console.error(e);
    return { version: "unknown", build: 0 };
  }
}

async function fetchList() {
  const res = await fetch(`https://localhost:3133/v3/domains.json`);
  return res.json();
}

async function registerGlobal() {
  const code = await fetchScript("global");
  register("global", ["*://*/*"], code);
}

async function fetchScript(domain) {
  const res = await fetch(`https://localhost:3133/v3/s/${domain}.js`);
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
