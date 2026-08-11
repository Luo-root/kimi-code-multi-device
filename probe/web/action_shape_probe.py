#!/usr/bin/env python3
"""确认 REST :action 的落地细节：
1. 不带 --debug-endpoints 是否也能用 :action（决定 relay 能否简化配置）
2. :archive / :restore / :fork 的完整请求/响应 shape
3. /export 的 content-type、文件名、返回形态（JSON 还是二进制流）
"""
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request

_default_bin = os.path.expanduser("~/.kimi-code/bin/kimi.exe")
KIMI = os.environ.get("KIMI_BIN", _default_bin)
PORT = 58711


def raw_req(method, path, token, body=None, port=PORT):
    """返回 (status, headers, bytes)，不做解码，便于观察二进制响应。"""
    url = f"http://127.0.0.1:{port}{path}"
    data = None
    headers = {"authorization": "Bearer " + token}
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:  # noqa
        return -1, {}, str(e).encode()


def show(tag, st, hdrs, body):
    ct = hdrs.get("Content-Type", hdrs.get("content-type", "?"))
    cd = hdrs.get("Content-Disposition", hdrs.get("content-disposition", ""))
    try:
        txt = body.decode("utf-8")[:200]
    except Exception:
        txt = f"<binary {len(body)} bytes> head={body[:16]!r}"
    print(f"  {tag:24} -> {st} ct={ct} {cd}")
    print(f"      {txt}")


# --- 关键实验：不带 --debug-endpoints 启动 ---
print(f"=== 启动 kimi web（**不带** --debug-endpoints）on {PORT} ===")
p = subprocess.Popen(
    [KIMI, "web", "--port", str(PORT), "--no-open"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, encoding="utf-8", errors="replace",
)
tok = None
start = time.time()
while time.time() - start < 40:
    line = p.stdout.readline()
    if not line:
        break
    if "token=" in line:
        m = re.search(r"token=([^\s\"']+)", line)
        if m:
            tok = m.group(1)
            break
print("token:", (tok or "NONE")[:10])
if not tok:
    p.kill()
    raise SystemExit("拿不到 token")
time.sleep(2)

st, h, b = raw_req("GET", "/api/v1/sessions", tok)
items = json.loads(b.decode())["data"]["items"]
target = next((i for i in items if i.get("message_count", 0) == 0 and not i.get("busy")), items[-1])
sid = target["id"]
print(f"会话数={len(items)}  实验对象={sid} archived={target.get('archived')}")

print("\n=== 无 --debug-endpoints 下的 :action ===")
st, h, b = raw_req("POST", f"/api/v1/sessions/{sid}:archive", tok, {})
show(":archive", st, h, b)
st, h, b = raw_req("POST", f"/api/v1/sessions/{sid}:restore", tok, {})
show(":restore", st, h, b)

print("\n=== 校验 archived 状态真的翻转 ===")
st, h, b = raw_req("GET", "/api/v1/sessions", tok)
cur = next((i for i in json.loads(b.decode())["data"]["items"] if i["id"] == sid), None)
print("  restore 后 archived =", cur.get("archived") if cur else "会话消失")

print("\n=== :fork 完整响应 ===")
st, h, b = raw_req("POST", f"/api/v1/sessions/{sid}:fork", tok, {})
try:
    o = json.loads(b.decode())
    print("  code=", o.get("code"), " 新会话 id=", (o.get("data") or {}).get("id"))
    print("  data keys:", list((o.get("data") or {}).keys()))
except Exception as e:
    print("  parse err", e, b[:200])

print("\n=== /export 形态（GET 与 POST 各试）===")
for m in ("GET", "POST"):
    st, h, b = raw_req(m, f"/api/v1/sessions/{sid}/export", tok, {} if m == "POST" else None)
    show(f"{m} /export", st, h, b)

print("\n=== 调试 RPC 在无 --debug-endpoints 时是否 404（对照）===")
st, h, b = raw_req("POST", f"/api/v1/debug/session/{sid}/sessionMetadata/setTitle", tok, ["X"])
show("debug rpc", st, h, b)

p.terminate()
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print("\ndone")
