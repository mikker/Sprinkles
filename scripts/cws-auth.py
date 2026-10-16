#!/usr/bin/env python3
"""One-time Chrome Web Store authorization: turns an OAuth client into the CWS_REFRESH_TOKEN for .env.

    CWS_CLIENT_ID=... CWS_CLIENT_SECRET=... scripts/cws-auth.py [--no-browser]

Opens Google's consent page in your browser (sign in with the account that owns the Chrome Web Store
item), catches the redirect on localhost and prints the .env line. See RELEASING.md for the OAuth client.
"""
import http.server
import json
import os
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser

client_id = os.environ.get("CWS_CLIENT_ID") or sys.exit("Set CWS_CLIENT_ID and CWS_CLIENT_SECRET")
client_secret = os.environ.get("CWS_CLIENT_SECRET") or sys.exit("Set CWS_CLIENT_SECRET")
state = secrets.token_urlsafe(16)
code = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        ok = q.get("state", [None])[0] == state and "code" in q
        if ok:
            code["value"] = q["code"][0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<p>Sprinkles: authorized, you can close this tab.</p>" if ok else b"<p>Missing code or bad state.</p>")

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
redirect = f"http://127.0.0.1:{server.server_port}"
url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "client_id": client_id, "redirect_uri": redirect, "response_type": "code",
    "scope": "https://www.googleapis.com/auth/chromewebstore", "access_type": "offline", "prompt": "consent", "state": state})
if "--no-browser" in sys.argv:
    print("Open this URL in a browser signed in to the Chrome Web Store account:\n" + url, flush=True)
else:
    print("Opening", url, flush=True)
    webbrowser.open(url)
while "value" not in code:
    server.handle_request()

data = urllib.parse.urlencode({"code": code["value"], "client_id": client_id, "client_secret": client_secret,
                               "redirect_uri": redirect, "grant_type": "authorization_code"}).encode()
with urllib.request.urlopen(urllib.request.Request("https://oauth2.googleapis.com/token", data=data)) as resp:
    token = json.load(resp)
if "refresh_token" not in token:
    sys.exit(f"No refresh token in the response: {token}")
print("\nAdd to .env:\n")
print(f"CWS_REFRESH_TOKEN={token['refresh_token']}")
