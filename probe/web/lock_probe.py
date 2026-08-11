#!/usr/bin/env python3
"""决定性实验：50001 storage write failed 到底是不是「多进程抢存储写锁」导致的。

前置：外部已确保只剩下需要的 kimi 进程。本脚本只起 1 个干净的 kimi web，
然后对一个历史会话做 :archive，看是否还 50001。
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
PORT = 58710


def req(method, path, token, body=None, port=PORT):
    url = f"http://127.0.0.1:{port}{path}"
    data = None
    headers = {"authorization": "Bearer " + token}
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # noqa
        return -1, str(e)


print(f"=== 启动干净 kimi web on {PORT} ===")
p = subprocess.Popen(
    [KIMI, "web", "--port", str(PORT), "--debug-endpoints", "--no-open"],
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
    raise SystemExit("拿不到 token，退出")
time.sleep(2)

st, raw = req("GET", "/api/v1/sessions", tok)
items = json.loads(raw)["data"]["items"]
print("会话总数:", len(items))

# 挑一个最老的、空的会话做实验，避免动到正在用的
target = None
for it in items:
    if it.get("message_count", 0) == 0 and not it.get("busy"):
        target = it
        break
target = target or items[-1]
sid = target["id"]
print(f"实验对象: {sid}  title={target.get('title')}  archived={target.get('archived')}")

print("\n=== 只剩 1 个 kimi web 时的写操作 ===")
for act, body in [(":archive", {}), (":restore", {}), (":fork", {})]:
    st, r = req("POST", f"/api/v1/sessions/{sid}{act}", tok, body)
    print(f"  {act:10} -> {st} {r[:130]}")

print("\n=== 建新会话（纯写操作）===")
st, r = req("POST", "/api/v1/sessions", tok,
            {"metadata": {"cwd": "D:/Github-Project/kimi-code-multi-device/code/kimi-code-multi-device"}})
print(f"  POST /sessions -> {st} {r[:180]}")

print("\n=== 导出（读操作，对照）===")
st, r = req("POST", f"/api/v1/sessions/{sid}/export", tok, {})
print(f"  /export -> {st} {r[:180]}")

p.terminate()
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print("\n done")
