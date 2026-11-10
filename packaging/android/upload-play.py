#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Uploads an app bundle to a Google Play track (internal testing by default).

    PLAY_SERVICE_ACCOUNT_JSON='{...}' \\
        packaging/android/upload-play.py build/packages/citusmail-<version>.aab

Uses the Google Play Developer API with a service account key, and only
Python's standard library plus the openssl command (to sign the token
request), so no third-party code ever sees the key. The private key is
written to a file only readable by this user, and removed at the end.

Settings (environment):
  PLAY_SERVICE_ACCOUNT_JSON  the service account's JSON key (required)
  PLAY_PACKAGE               default com.fluminaris.citusmail
  PLAY_TRACK                 default internal
  PLAY_RELEASE_NAME          shown in Play Console, default the bundle's name
  PLAY_RELEASE_STATUS        completed (default) or draft. While the app has
                             never been published, Google only accepts
                             draft releases; this script then retries as a
                             draft by itself.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"


class PlayError(Exception):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def request(method, url, token=None, body=None, content_type="application/json"):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = content_type
        if content_type == "application/json":
            body = json.dumps(body).encode()
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            pass
        raise PlayError(f"{method} {url.split('?')[0]}: HTTP {e.code}: {detail}") from None
    return json.loads(text) if text else {}


def access_token(account: dict) -> str:
    """A token for the service account (OAuth 2.0 JWT bearer grant)."""
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(
        json.dumps(
            {
                "iss": account["client_email"],
                "scope": SCOPE,
                "aud": account["token_uri"],
                "iat": now,
                "exp": now + 3600,
            }
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode()
    fd, key_path = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(account["private_key"])
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input,
            capture_output=True,
            check=True,
        ).stdout
    finally:
        os.remove(key_path)
    assertion = f"{header}.{claims}.{b64url(signature)}"
    body = urllib.parse.urlencode(
        {"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}
    ).encode()
    return request(
        "POST", account["token_uri"], body=body, content_type="application/x-www-form-urlencoded"
    )["access_token"]


def publish(token, package, bundle, track, name, status):
    edit = request("POST", f"{API}/{package}/edits", token, body={})["id"]
    base = f"{API}/{package}/edits/{edit}"
    try:
        with open(bundle, "rb") as f:
            uploaded = request(
                "POST",
                f"{UPLOAD}/{package}/edits/{edit}/bundles?uploadType=media",
                token,
                body=f.read(),
                content_type="application/octet-stream",
            )
        code = str(uploaded["versionCode"])
        print(f"Uploaded {os.path.basename(bundle)} as version code {code}")
        release = {"name": name, "versionCodes": [code], "status": status}
        request("PUT", f"{base}/tracks/{track}", token, body={"track": track, "releases": [release]})
        request("POST", f"{base}:commit", token)
    except PlayError:
        # Leave nothing half done in Play Console.
        try:
            request("DELETE", base, token)
        except PlayError:
            pass
        raise
    return code


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <bundle.aab>")
    bundle = sys.argv[1]
    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not raw:
        sys.exit("PLAY_SERVICE_ACCOUNT_JSON is not set")
    try:
        account = json.loads(raw)
        account["client_email"], account["private_key"], account["token_uri"]
    except (ValueError, KeyError):
        sys.exit("PLAY_SERVICE_ACCOUNT_JSON isn't a service account's JSON key")
    package = os.environ.get("PLAY_PACKAGE") or "com.fluminaris.citusmail"
    track = os.environ.get("PLAY_TRACK") or "internal"
    name = os.environ.get("PLAY_RELEASE_NAME") or os.path.basename(bundle)
    status = os.environ.get("PLAY_RELEASE_STATUS") or "completed"

    token = access_token(account)
    try:
        code = publish(token, package, bundle, track, name, status)
    except PlayError as e:
        if status != "draft" and "draft" in str(e).lower():
            print("The app isn't published yet, so Google only takes a draft: retrying as a draft.")
            status = "draft"
            code = publish(token, package, bundle, track, name, status)
        else:
            sys.exit(str(e))
    print(f"Version code {code} is on the {track} track ({status}).")
    if status == "draft":
        print("Roll it out in Play Console: Testing > Internal testing.")


if __name__ == "__main__":
    try:
        main()
    except PlayError as e:
        sys.exit(str(e))
