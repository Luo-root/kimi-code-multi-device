"""探测 POST /api/v1/sessions/{id}/export 需要的请求体。

用法：先启动一个干净的 kimi web，再运行本脚本。
  kimi web --no-open --port 58699
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

_default_bin = os.path.expanduser("~/.kimi-code/bin/kimi.exe")
KIMI = os.environ.get("KIMI_BIN", _default_bin)
PORT = int(os.environ.get("KIMI_PORT", "58699"))


def start_web():
    p = subprocess.Popen(
        [KIMI, "web", "--no-open", "--port", str(PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    start = time.time()
    while time.time() - start < 40:
        line = p.stdout.readline()
        if not line:
            break
        m = re.search(r"token=([^\s\"']+)", line)
        if m:
            return p, m.group(1)
    p.kill()
    raise SystemExit("未能从横幅抓到 token")


def req(method, path, token, body=None, raw_out=False):
    url = f"http://127.0.0.1:{PORT}{path}"
    headers = {"authorization": "Bearer " + token}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            payload = resp.read()
            ctype = resp.headers.get("content-type", "")
            disp = resp.headers.get("content-disposition", "")
            if raw_out and "zip" in ctype:
                return resp.status, f"<zip {len(payload)} bytes> ctype={ctype} disp={disp}"
            return resp.status, payload.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa
        return -1, str(e)


proc, token = start_web()
print("token:", token[:10], "...")
time.sleep(1.5)

try:
    st, raw = req("GET", "/api/v1/sessions", token)
    sid = json.loads(raw)["data"]["items"][0]["id"]
    print("session:", sid, "\n")

    candidates = [
        ("{} 空对象", {}),
        ("includeGlobalLog", {"includeGlobalLog": False}),
        ("options 包裹", {"options": {}}),
        ("format zip", {"format": "zip"}),
        ("完整猜测", {"includeGlobalLog": False, "includeDesktopLog": False}),
    ]
    for name, body in candidates:
        st, out = req("POST", f"/api/v1/sessions/{sid}/export", token, body, raw_out=True)
        print(f"  {name:18} -> {st} {out[:200]}")
finally:
    proc.kill()
    print("\nkimi web 已关闭")
