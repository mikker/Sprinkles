let attempt = 0;

function log(title, msg) {
  console.groupCollapsed(`%c${title}`, msg && msg.error ? "color:red" : "");
  if (msg && msg.error) console.error(msg.error);
  if (msg && msg.debug) console.debug(msg.debug);
  console.groupEnd();
}

async function dispatch(msg) {
  return browser.runtime.sendMessage(msg).then((resp) => {
    if (resp) {
      if (resp.error) {
        log("Error response", { error: resp });
      } else {
        log("Response", { debug: resp });
      }
    }
  });
}

function apply(script) {
  dispatch({ event: "begin_apply" });

  if (!script) return;

  if (!document.body) {
    attempt++;
    if (attempt >= 5) return;

    setTimeout(function () {
      apply(script);
    }, 200);
    return;
  }

  try {
    eval(script);
    dispatch({ event: "ok" });
  } catch (error) {
    log("Sprinkles failed running your script", { error });
    dispatch({ event: "eval_failed", error: `${error}` });
  }
}

const ignoreList = [/stripe/];

async function main() {
  const host = location.hostname.replace(/^www\./, "");

  for (const re of ignoreList) {
    if (re.test(host)) {
      log(`Ignoring host "${host}"`);
      return;
    }
  }

  const filename = host + ".js";

  try {
    const js = await fetch("https://localhost:3133/s/" + filename).then(
      (resp) => resp.text()
    );
    apply(js);
  } catch (error) {
    log("Sprinkles failed requesting your scripts", { error });
    dispatch({ event: "request_failed", error: `${error}` });
  }
}

main();
