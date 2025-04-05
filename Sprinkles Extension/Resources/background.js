function handleMessage(msg, sender, sendResponse) {
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
    windowId: sender.tab.windowId,
  };

  browser.browserAction.setBadgeText(args);

  return null;
  //  return { badge: args };
}
