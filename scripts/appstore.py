#!/usr/bin/env python3
"""App Store Connect steps for a Sprinkles release, with only the standard library and `openssl`.

    scripts/appstore.py builds [--version X.Y]          recent builds and their processing state
    scripts/appstore.py prepare X.Y --notes FILE [--build N] [--wait]
                                                        create the version if needed, set What's New,
                                                        attach the (processed) build
    scripts/appstore.py submit X.Y                      submit the version for review
    scripts/appstore.py status [X.Y]                    version states and the latest review submission

Needs ASC_KEY_ID and ASC_ISSUER_ID (an App Manager key; see RELEASING.md) and the key file at
ASC_KEY_PATH or ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8. ASC_APP_ID defaults to Sprinkles'.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.brnbw.Sprinkles"
DEFAULT_APP_ID = "1500209074"
PLATFORM = "MAC_OS"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature (SEQUENCE of two INTEGERs) to the raw r||s form JWTs use."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\0")
        out += value.rjust(32, b"\0")
        i += 2 + n
    return out


_token = None


def token() -> str:
    global _token
    if _token and _token[1] > time.time() + 60:
        return _token[0]
    key_id = os.environ.get("ASC_KEY_ID") or sys.exit("Set ASC_KEY_ID and ASC_ISSUER_ID (see RELEASING.md)")
    issuer = os.environ.get("ASC_ISSUER_ID") or sys.exit("Set ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_KEY_PATH") or os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not os.path.exists(key_path):
        sys.exit(f"API key file not found: {key_path}")
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    _token = (f"{header}.{payload}.{b64url(der_to_raw(der))}", now + 1200)
    return _token[0]


def request(method: str, path: str, params=None, body=None):
    url = path if path.startswith("http") else API + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            errors = json.loads(detail).get("errors", [])
            detail = "; ".join(f'{x.get("title")}: {x.get("detail")}' for x in errors) or detail
        except ValueError:
            pass
        sys.exit(f"{method} {path} failed ({e.code}): {detail}")


def get(path, **params):
    return request("GET", path, params)


def app_id() -> str:
    if os.environ.get("ASC_APP_ID"):
        return os.environ["ASC_APP_ID"]
    apps = get("/apps", **{"filter[bundleId]": BUNDLE_ID}).get("data", [])
    return apps[0]["id"] if apps else DEFAULT_APP_ID


def versions(version=None):
    params = {"filter[platform]": PLATFORM, "limit": 20}
    if version:
        params["filter[versionString]"] = version
    return get(f"/apps/{app_id()}/appStoreVersions", **params).get("data", [])


def version_state(v) -> str:
    a = v["attributes"]
    return a.get("appVersionState") or a.get("appStoreState") or "?"


def builds(version=None, limit=10):
    params = {"filter[app]": app_id(), "sort": "-uploadedDate", "limit": limit, "include": "preReleaseVersion"}
    if version:
        params["filter[preReleaseVersion.version]"] = version
    data = get("/builds", **params)
    included = {(x["type"], x["id"]): x for x in data.get("included", [])}
    out = []
    for b in data.get("data", []):
        pre = b["relationships"].get("preReleaseVersion", {}).get("data")
        marketing = included.get(("preReleaseVersions", pre["id"]), {}).get("attributes", {}).get("version") if pre else None
        out.append({"id": b["id"], "build": b["attributes"]["version"], "version": marketing,
                    "state": b["attributes"]["processingState"], "uploaded": b["attributes"]["uploadedDate"],
                    "expired": b["attributes"].get("expired"),
                    "usesNonExemptEncryption": b["attributes"].get("usesNonExemptEncryption")})
    return out


def whats_new(notes: str) -> str:
    """CHANGELOG markdown as plain App Store text: headings become lines, bullets keep a dash, links lose their URLs."""
    lines = []
    for line in notes.splitlines():
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
        line = line.replace("`", "")
        if line.startswith("### "):
            lines += ["", line[4:].upper()]
        elif line.startswith("## "):
            continue
        else:
            lines.append(line)
    text = "\n".join(lines).strip()
    return text[:4000]


def cmd_builds(args):
    for b in builds(args.version):
        print(f'{b["version"] or "?":>8} ({b["build"]})  {b["state"]:<10}  uploaded {b["uploaded"]}'
              + ("  expired" if b["expired"] else ""))


def cmd_prepare(args):
    notes = whats_new(open(args.notes).read())
    found = versions(args.version)
    if found:
        v = found[0]
        print(f'==> App Store version {args.version} exists ({version_state(v)})')
    else:
        v = request("POST", "/appStoreVersions", body={"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": PLATFORM, "versionString": args.version, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id()}}}}})["data"]
        print(f"==> Created App Store version {args.version}")
    vid = v["id"]

    locs = get(f"/appStoreVersions/{vid}/appStoreVersionLocalizations").get("data", [])
    for loc in locs:
        request("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", body={"data": {
            "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
        print(f'==> What\'s New set for {loc["attributes"]["locale"]}')

    deadline = time.time() + (args.timeout if args.wait else 0)
    while True:
        candidates = [b for b in builds(args.version, limit=20) if not b["expired"]
                      and (not args.build or b["build"] == str(args.build))]
        valid = [b for b in candidates if b["state"] == "VALID"]
        if valid:
            build = valid[0]
            break
        pending = [b for b in candidates if b["state"] == "PROCESSING"]
        if not pending and not candidates:
            if time.time() < deadline:
                print("==> No build for this version yet; waiting for the upload to appear")
            else:
                sys.exit(f"No uploaded build for version {args.version}" + (f" build {args.build}" if args.build else ""))
        elif not pending:
            sys.exit(f"Build is not usable: {candidates[0]['state']}")
        if time.time() >= deadline:
            sys.exit(f"Build {candidates[0]['build'] if candidates else ''} is still processing; rerun with --wait")
        print("==> Waiting for App Store Connect to process the build")
        time.sleep(30)

    if build["usesNonExemptEncryption"] is None:
        request("PATCH", f"/builds/{build['id']}", body={"data": {
            "type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}})
    current = v["relationships"].get("build", {}).get("data") if "relationships" in v else None
    if not current or current.get("id") != build["id"]:
        request("PATCH", f"/appStoreVersions/{vid}/relationships/build",
                body={"data": {"type": "builds", "id": build["id"]}})
    print(f'==> Build {build["build"]} attached to {args.version}')


def cmd_submit(args):
    found = versions(args.version)
    found or sys.exit(f"No App Store version {args.version}; run prepare first")
    v = found[0]
    state = version_state(v)
    if state not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"):
        print(f"==> {args.version} is {state}; nothing to submit")
        return
    subs = get("/reviewSubmissions", **{"filter[app]": app_id(), "filter[platform]": PLATFORM,
                                        "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES", "limit": 5}).get("data", [])
    if subs:
        sub = subs[0]
        print(f'==> Reusing review submission {sub["id"]} ({sub["attributes"]["state"]})')
    else:
        sub = request("POST", "/reviewSubmissions", body={"data": {
            "type": "reviewSubmissions", "attributes": {"platform": PLATFORM},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id()}}}}})["data"]
        print(f'==> Created review submission {sub["id"]}')
    items = get(f"/reviewSubmissions/{sub['id']}/items", include="appStoreVersion").get("data", [])
    has_version = any((i["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == v["id"] for i in items)
    if not has_version:
        request("POST", "/reviewSubmissionItems", body={"data": {
            "type": "reviewSubmissionItems",
            "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
    request("PATCH", f"/reviewSubmissions/{sub['id']}", body={"data": {
        "type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})
    print(f"==> Submitted {args.version} for review")


def cmd_status(args):
    for v in versions(args.version)[:5]:
        a = v["attributes"]
        print(f'{a["versionString"]:>8}  {version_state(v)}  created {a.get("createdDate", "?")[:10]}')
    subs = get("/reviewSubmissions", **{"filter[app]": app_id(), "filter[platform]": PLATFORM, "limit": 3}).get("data", [])
    for s in subs:
        print(f'review submission {s["id"]}: {s["attributes"]["state"]} ({s["attributes"].get("submittedDate") or "not submitted"})')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    b = sub.add_parser("builds"); b.add_argument("--version"); b.set_defaults(fn=cmd_builds)
    pr = sub.add_parser("prepare"); pr.add_argument("version"); pr.add_argument("--notes", required=True)
    pr.add_argument("--build"); pr.add_argument("--wait", action="store_true")
    pr.add_argument("--timeout", type=int, default=1800, help="seconds to wait for processing (default 30 min)")
    pr.set_defaults(fn=cmd_prepare)
    s = sub.add_parser("submit"); s.add_argument("version"); s.set_defaults(fn=cmd_submit)
    st = sub.add_parser("status"); st.add_argument("version", nargs="?"); st.set_defaults(fn=cmd_status)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
