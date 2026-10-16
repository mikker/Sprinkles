const baseURL = "https://localhost:3133/v3/s/";

async function fetchScripts(domain) {
  try {
    const [global, code] = await Promise.all(
      ["global", domain].map((name) =>
        fetch(baseURL + encodeURIComponent(name) + ".js").then((resp) =>
          resp.text(),
        ),
      ),
    );
    return { global, domain: code };
  } catch (e) {
    return { error: `${e}` };
  }
}

function handleMessage(msg, sender, sendResponse) {
  // Returning a promise keeps the channel open for the async reply
  if (msg.event === "fetch") return fetchScripts(msg.domain);

  try {
    let resp;

    switch (msg.event) {
      case "begin_apply":
        resp = setBadge(null, sender);
        break;
      case "eval_failed":
        resp = setBadge("!", sender);
        break;
      case "request_failed":
        resp = setBadge("!", sender);
        break;
      default:
        break;
    }

    if (resp) sendResponse(resp);
  } catch (e) {
    sendResponse({ error: `${e}` });
  }
}

browser.runtime.onMessage.addListener(handleMessage);

function setBadge(text, sender) {
  const args = {
    text: text,
    tabId: sender.tab.id,
  };

  browser.browserAction.setBadgeText(args);

  return null;
  //  return { badge: args };
}
