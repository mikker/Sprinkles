#!/usr/bin/env python3
"""Upload and publish the Chrome and Firefox extensions from dist/, with only the standard library.

    scripts/extensions-publish.py [chrome|firefox|all] [--notes FILE] [--dry-run]

A version that is already on a store is skipped, so this is safe to rerun. Needs in .env (see RELEASING.md):
  CWS_CLIENT_ID, CWS_CLIENT_SECRET, CWS_REFRESH_TOKEN   Chrome Web Store (scripts/cws-auth.py makes the token)
  AMO_JWT_ISSUER, AMO_JWT_SECRET                         addons.mozilla.org API key
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

CWS_ITEM_ID = "knknjjghhkppgfkkclcdefohkfdnhfan"
AMO_ADDON_ID = "{588f4ebd-9540-4f57-943d-04c682e96db9}"
AMO_API = "https://addons.mozilla.org/api/v5"
CHROME_ZIP = "dist/chrome-extension.zip"
FIREFOX_ZIP = "dist/firefox-extension.zip"


def die(msg):
    sys.exit(f"error: {msg}")


def env(name):
    return os.environ.get(name) or die(f"{name} is not set (see RELEASING.md)")


def http(method, url, headers=None, data=None, ok=(200, 201, 202)):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body.strip().startswith(b"{") or body.strip().startswith(b"[") else body)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        if e.code in ok:
            return e.code, body
        raise RuntimeError(f"{method} {url} -> {e.code}: {json.dumps(body)[:800] if not isinstance(body, str) else body[:800]}")


def zip_version(path):
    with zipfile.ZipFile(path) as z:
        return json.loads(z.read("manifest.json"))["version"]


def plain_notes(path):
    """CHANGELOG markdown as plain text for store release notes."""
    if not path:
        return None
    out = []
    for line in open(path).read().splitlines():
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line).replace("`", "")
        if line.startswith("### "):
            out += ["", line[4:]]
        elif not line.startswith("## "):
            out.append(line)
    return "\n".join(out).strip()


# Chrome Web Store ----------------------------------------------------------------------------------------

def cws_token():
    data = urllib.parse.urlencode({"client_id": env("CWS_CLIENT_ID"), "client_secret": env("CWS_CLIENT_SECRET"),
                                   "refresh_token": env("CWS_REFRESH_TOKEN"), "grant_type": "refresh_token"}).encode()
    _, body = http("POST", "https://oauth2.googleapis.com/token", {"Content-Type": "application/x-www-form-urlencoded"}, data)
    return body["access_token"]


def publish_chrome(zip_path, dry_run):
    version = zip_version(zip_path)
    if dry_run:
        print(f"[dry run] Chrome: would upload {zip_path} ({version}) to item {CWS_ITEM_ID} and publish")
        return
    headers = {"Authorization": f"Bearer {cws_token()}", "x-goog-api-version": "2"}
    _, item = http("GET", f"https://www.googleapis.com/chromewebstore/v1.1/items/{CWS_ITEM_ID}?projection=DRAFT", headers)
    current = item.get("crxVersion")
    if current == version:
        print(f"==> Chrome: {version} is already uploaded (draft state {item.get('uploadState')}); not uploading again")
    else:
        print(f"==> Chrome: uploading {version} (store draft is {current})")
        _, result = http("PUT", f"https://www.googleapis.com/upload/chromewebstore/v1.1/items/{CWS_ITEM_ID}",
                         {**headers, "Content-Type": "application/zip"}, open(zip_path, "rb").read())
        if result.get("uploadState") != "SUCCESS":
            die(f"Chrome upload failed: {json.dumps(result.get('itemError') or result)}")
    try:
        _, published = http("POST", f"https://www.googleapis.com/chromewebstore/v1.1/items/{CWS_ITEM_ID}/publish",
                            {**headers, "Content-Length": "0"}, b"")
    except RuntimeError as e:
        if "in review" in str(e):
            print(f"==> Chrome: {version} is already in review; nothing to do")
            return
        raise
    status = published.get("status", [])
    detail = "; ".join(published.get("statusDetail", []))
    if any(s in ("OK", "ITEM_PENDING_REVIEW", "PUBLISHED_WITH_FRICTION_WARNING") for s in status):
        print(f"==> Chrome: {version} submitted ({', '.join(status)}) {detail}")
    elif "ITEM_NOT_UPDATABLE" in status or "NOT_AUTHORIZED" in status:
        die(f"Chrome publish refused: {', '.join(status)} {detail}")
    else:
        print(f"==> Chrome: publish returned {', '.join(status) or published} {detail}")


# addons.mozilla.org --------------------------------------------------------------------------------------

def amo_headers():
    now = int(time.time())
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iss": env("AMO_JWT_ISSUER"), "jti": str(uuid.uuid4()), "iat": now, "exp": now + 240}).encode())
    sig = b64(hmac.new(env("AMO_JWT_SECRET").encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return {"Authorization": f"JWT {header}.{payload}.{sig}"}


def multipart(fields, file_field, filename, content):
    boundary = "----sprinkles" + uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\n"
             f"Content-Type: application/zip\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", body


def publish_firefox(zip_path, notes, dry_run):
    version = zip_version(zip_path)
    if dry_run:
        print(f"[dry run] Firefox: would upload {zip_path} ({version}) for {AMO_ADDON_ID} and create a listed version")
        return
    addon = urllib.parse.quote(AMO_ADDON_ID, safe="")
    _, existing = http("GET", f"{AMO_API}/addons/addon/{addon}/versions/?filter=all_with_unlisted&page_size=50", amo_headers())
    if any(v.get("version") == version for v in existing.get("results", [])):
        print(f"==> Firefox: {version} already exists on addons.mozilla.org; nothing to do")
        return
    print(f"==> Firefox: uploading {version}")
    ctype, body = http_body = multipart({"channel": "listed"}, "upload", os.path.basename(zip_path), open(zip_path, "rb").read())
    _, upload = http("POST", f"{AMO_API}/addons/upload/", {**amo_headers(), "Content-Type": ctype}, body)
    uid = upload["uuid"]
    deadline = time.time() + 600
    while not upload.get("processed"):
        if time.time() > deadline:
            die("Firefox: validation did not finish in 10 minutes")
        time.sleep(10)
        _, upload = http("GET", f"{AMO_API}/addons/upload/{uid}/", amo_headers())
    if not upload.get("valid"):
        messages = [m.get("message") for m in (upload.get("validation") or {}).get("messages", []) if m.get("type") == "error"]
        die("Firefox: validation failed: " + "; ".join(messages or ["see " + upload.get("url", "")]))
    payload = {"upload": uid}
    if notes:
        payload["release_notes"] = {"en-US": notes}
    _, created = http("POST", f"{AMO_API}/addons/addon/{addon}/versions/",
                      {**amo_headers(), "Content-Type": "application/json"}, json.dumps(payload).encode())
    file_status = (created.get("file") or {}).get("status")
    print(f"==> Firefox: {created.get('version', version)} submitted for review (file status {file_status})")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("store", nargs="?", default="all", choices=["chrome", "firefox", "all"])
    p.add_argument("--notes", help="CHANGELOG section to use as the AMO release notes")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    for path in (CHROME_ZIP, FIREFOX_ZIP):
        os.path.exists(path) or die(f"{path} is missing; run scripts/release-ext.sh first")
    notes = plain_notes(args.notes)
    failed = False
    for store in (["chrome", "firefox"] if args.store == "all" else [args.store]):
        try:
            if store == "chrome":
                publish_chrome(CHROME_ZIP, args.dry_run)
            else:
                publish_firefox(FIREFOX_ZIP, notes, args.dry_run)
        except (RuntimeError, SystemExit) as e:
            print(f"error: {store}: {e}", file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
