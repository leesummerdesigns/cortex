#!/usr/bin/env python3
"""End-to-end test of `cortex serve`: the OAuth + MCP flow a remote client like claude.ai performs.
Usage: scripts/test-bridge.py <cortex-binary> <vault>"""
import base64, hashlib, json, os, secrets, subprocess, sys, tempfile, time, urllib.parse, urllib.request

binary, vault = sys.argv[1], sys.argv[2]
store = os.path.join(tempfile.mkdtemp(), "bridge.json")
env = dict(os.environ, CORTEX_BRIDGE_STORE=store)
port = 7399
proc = subprocess.Popen([binary, "serve", vault, str(port)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
base = f"http://127.0.0.1:{port}"
ok = True

def check(name, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail and not cond else ""))

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)

def req(method, path, data=None, headers=None, form=False):
    body = None
    headers = dict(headers or {})
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    try:
        resp = opener.open(r, timeout=30)
        return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

try:
    for _ in range(50):
        try:
            urllib.request.urlopen(base + "/", timeout=1); break
        except Exception: time.sleep(0.1)

    s, h, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    check("unauthenticated /mcp is rejected with 401 + resource metadata", s == 401 and "resource_metadata" in h.get("WWW-Authenticate", ""), s)

    s, _, b = req("GET", "/.well-known/oauth-protected-resource")
    check("protected-resource metadata", s == 200 and json.loads(b)["authorization_servers"] == [base])
    s, _, b = req("GET", "/.well-known/oauth-authorization-server")
    meta = json.loads(b)
    check("authorization-server metadata (PKCE S256, DCR)", "S256" in meta["code_challenge_methods_supported"] and meta["registration_endpoint"].endswith("/register"))

    redirect = "https://claude.ai/api/mcp/auth_callback"
    s, _, b = req("POST", "/register", {"client_name": "Claude", "redirect_uris": [redirect]})
    client_id = json.loads(b)["client_id"]
    check("dynamic client registration", s == 201 and client_id.startswith("cortex-"))
    s, _, _ = req("POST", "/register", {"client_name": "Evil", "redirect_uris": ["http://evil.example/cb"]})
    check("non-https redirect URIs are refused", s == 400)

    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    q = {"response_type": "code", "client_id": client_id, "redirect_uri": redirect, "code_challenge": challenge,
         "code_challenge_method": "S256", "state": "xyz"}
    s, _, b = req("GET", "/authorize?" + urllib.parse.urlencode(q))
    check("approval page asks for the pairing code", s == 200 and b"pairing_code" in b and b"Claude" in b)

    s, h, b = req("POST", "/authorize", dict(q, pairing_code="WRNG-CODE"), form=True)
    check("wrong pairing code is rejected", s == 200 and b"doesn" in b and "Location" not in h)

    code = json.load(open(store))["pairingCode"]
    s, h, _ = req("POST", "/authorize", dict(q, pairing_code=code.lower()), form=True)
    loc = urllib.parse.urlparse(h.get("Location", ""))
    params = dict(urllib.parse.parse_qsl(loc.query))
    check("right code redirects back with code + state", s == 302 and loc.netloc == "claude.ai" and params.get("state") == "xyz")
    check("pairing code rotates after use", json.load(open(store))["pairingCode"] != code)

    s, _, b = req("POST", "/token", {"grant_type": "authorization_code", "code": params["code"], "redirect_uri": redirect,
                                    "client_id": client_id, "code_verifier": "wrong-verifier"}, form=True)
    check("token exchange with wrong PKCE verifier fails", s == 400)
    # the code is single-use, so the failed attempt consumed it: authorize again
    code = json.load(open(store))["pairingCode"]
    _, h, _ = req("POST", "/authorize", dict(q, pairing_code=code), form=True)
    params = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(h["Location"]).query))
    s, _, b = req("POST", "/token", {"grant_type": "authorization_code", "code": params["code"], "redirect_uri": redirect,
                                    "client_id": client_id, "code_verifier": verifier}, form=True)
    tok = json.loads(b)
    check("token exchange with PKCE", s == 200 and tok["token_type"] == "Bearer" and tok["refresh_token"])
    auth = {"Authorization": "Bearer " + tok["access_token"], "Accept": "application/json, text/event-stream"}

    s, h, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "claude-ai"}, "capabilities": {}}}, auth)
    check("MCP initialize over HTTP", s == 200 and json.loads(b)["result"]["serverInfo"]["name"] == "cortex")
    s, _, _ = req("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, auth)
    check("notifications get 202", s == 202)
    s, _, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, auth)
    names = [t["name"] for t in json.loads(b)["result"]["tools"]]
    check("tools/list", "recall" in names and "get_core" in names, names)
    s, _, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                    "params": {"name": "recall", "arguments": {"query": "Motorrad"}}}, auth)
    text = json.loads(b)["result"]["content"][0]["text"]
    check("recall works remotely and hides private notes", "Triumph" in text and "Geheim" not in text, text[:120])

    s, _, b = req("POST", "/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}, form=True)
    new = json.loads(b)
    check("refresh token issues a new access token", s == 200 and new["access_token"] != tok["access_token"])
    s, _, _ = req("POST", "/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}, form=True)
    check("used refresh token cannot be reused (rotation)", s == 400)

    for i in range(5):
        req("POST", "/authorize", dict(q, pairing_code=f"BAD{i}-XXXX"), form=True)
    s, _, b = req("POST", "/authorize", dict(q, pairing_code=json.load(open(store))["pairingCode"]), form=True)
    check("brute force is rate-limited after 5 wrong codes", b"Too many" in b)
finally:
    proc.terminate()

print("\nALL PASSED" if ok else "\nSOME CHECKS FAILED")
sys.exit(0 if ok else 1)
