(function () {
  if (window.__sprinklesApplied) return;
  window.__sprinklesApplied = true;

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

  function apply(scripts) {
    if (!document.body) {
      document.addEventListener("DOMContentLoaded", () => apply(scripts), {
        once: true,
      });
      return;
    }

    dispatch({ event: "begin_apply" });

    // Evaluated separately so an error in one file doesn't stop the other
    const results = scripts.filter(Boolean).map((script) => run(script));
    if (results.length && results.every(Boolean)) dispatch({ event: "ok" });
  }

  // No other locals here, so `var`s in the user's script can't clash with ours
  function run(script) {
    try {
      eval(script);
      return true;
    } catch (error) {
      log("Sprinkles failed running your script", { error });
      dispatch({ event: "eval_failed", error: `${error}` });
      return false;
    }
  }

  function isIgnored(host) {
    return host === "stripe.com" || host.endsWith(".stripe.com");
  }

  async function main() {
    const host = location.hostname.replace(/^www\./, "");

    if (isIgnored(host)) {
      log(`Ignoring host "${host}"`);
      return;
    }

    try {
      // Fetched by the background page so the request carries the extension's origin
      const resp = await browser.runtime.sendMessage({
        event: "fetch",
        domain: host,
      });
      if (!resp || resp.error) throw new Error(resp ? resp.error : "No response");

      apply([resp.global, resp.domain]);
    } catch (error) {
      log("Sprinkles failed requesting your scripts", { error });
      dispatch({ event: "request_failed", error: `${error}` });
    }
  }

  main();
})();
