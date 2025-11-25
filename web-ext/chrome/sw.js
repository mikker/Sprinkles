const minimumBuildNumber = 105;

let lastChecksum = null;
let lastCheckTime = 0;
const CHECK_THROTTLE_MS = 1000; // Only check once per second

chrome.runtime.onInstalled.addListener(() => {
  reload();
});

chrome.action.onClicked.addListener(() => {
  reload();
});

chrome.webNavigation.onBeforeNavigate.addListener(async (details) => {
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
  await chrome.userScripts.unregister();

  const version = await fetchVersion();
  console.log(`Version: ${version.version}, build: ${version.build}`);

  if (version.build < minimumBuildNumber) {
    console.log("Version mismatch");

    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#cc0000" });
    chrome.action.setTitle({ title: "Please upgrade Sprinkles to continue" });
    chrome.action.onClicked.addListener(() => {
      chrome.tabs.create({
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
      const matches = [`*://${domain}/*`, `*://www\.${domain}/*`];
      await register(domain, matches, code);
    })
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

function setTheme(theme) {
  const iconThemeKey = theme === 'dark' ? 'light' : 'dark';
  fetch(chrome.runtime.getURL('manifest.json'))
    .then(res => res.json())
    .then(manifest => {
      const themeIcons = manifest.action.theme_icons;
      const iconPaths = themeIcons.reduce((iconPathsAccumulator, themeIcon) => iconPathsAccumulator[String(themeIcon.size)] = themeIcon[iconThemeKey]);
      chrome.action.setIcon({ path: iconPaths });
    });
}

chrome.runtime.onMessage.addListener(request => {
  if (request.type === 'themeChange') {
    setTheme(request.theme);
  }
});
