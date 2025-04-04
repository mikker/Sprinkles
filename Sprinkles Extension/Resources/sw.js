const minimumBuildNumber = 105;

chrome.runtime.onInstalled.addListener(() => {
  reload();
});

chrome.action.onClicked.addListener(() => {
  reload();
});

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
      await register(domain, code);
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
  const res = await fetch(`https://localhost:3133/domains.json`);
  return res.json();
}

async function registerGlobal() {
  const code = await fetchScript("global");
  register("*", code);
}

async function fetchScript(domain) {
  const res = await fetch(`https://localhost:3133/s/${domain}.js`);
  const code = await res.text();
  return code;
}

async function register(domain, code) {
  console.log(`Registering user script for ${domain}`);
  const matches = [`*://${domain}/*`];
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
