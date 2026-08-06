#!/usr/bin/env python3
"""探测 kimi web 的重命名 / 删除接口真身。

结论（0.32.0 实测）：
  - 重命名 = POST /api/v1/sessions/{id}/profile  body {"title": "..."}   ✅
    注意它是**斜杠子资源**，不是冒号动作；:rename / :setTitle 全部 40001。
    该端点最初由浏览器 F12 抓包发现，本脚本负责复现验证。
  - 删除    = 无磁盘接口 ❌（:delete / :remove 40001，DELETE 404）

本脚本起一个干净的 kimi web 实例并在 throwaway 会话上操作，可安全复跑。
token 从启动横幅抓取，不硬编码凭据。

环境变量：
  KIMI_BIN   kimi 可执行文件路径（默认 ~/.kimi-code/bin/kimi.exe）
  KIMI_PORT  探针实例端口（默认 58710，避开常用的 58627）
"""
import json
import os
import subprocess
import time
import re
import urllib.request
import urllib.error

_default_bin = os.path.expanduser("~/.kimi-code/bin/kimi.exe")
KIMI = os.environ.get("KIMI_BIN", _default_bin)
PORT = int(os.environ.get("KIMI_PORT", "58710"))
PROBE_CWD = os.path.expanduser("~")


def req(port, token, method, path, body=None):
    url = f"http://127.0.0.1:{port}{path}"
    data = None
    headers = {"authorization": "Bearer " + token}
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # noqa
        return -1, str(e)


def start_fresh_kimi_web(port):
    p = subprocess.Popen(
        [KIMI, "web", "--port", str(port), "--no-open"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    token = None
    start = time.time()
    while time.time() - start < 45:
        line = p.stdout.readline()
        if "token=" in line or "token" in line.lower():
            m = re.search(r"token=([A-Za-z0-9_\-]+)", line)
            if m:
                token = m.group(1)
                break
    if not token:
        p.terminate()
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
        raise RuntimeError("failed to capture kimi web token")
    time.sleep(2)
    return p, token


def main():
    print(f"=== starting fresh kimi web on port {PORT} ===")
    proc, token = start_fresh_kimi_web(PORT)
    try:
        # create a throwaway session
        st, raw = req(PORT, token, "POST", "/api/v1/sessions", {"title": "RENAME_PROBE", "metadata": {"cwd": PROBE_CWD}})
        print("POST /api/v1/sessions ->", st, raw[:160])
        if st != 200:
            print("!! 建会话失败。若是 50001 storage write failed，"
                  "说明另有 kimi web 实例持有存储写锁——先关掉它再复跑。")
            return
        sid = json.loads(raw)["data"]["id"]
        print("sid:", sid)

        # —— 决定性验证：/profile 才是真正的重命名端点 ——
        print("\n=== [KEY] POST /sessions/{id}/profile （预期成功）===")
        st, raw = req(PORT, token, "POST", f"/api/v1/sessions/{sid}/profile",
                      {"title": "PROFILE_RENAMED"})
        print(f"  POST /profile {{'title':...}} -> {st} {raw[:140]}")
        _, check = req(PORT, token, "GET", f"/api/v1/sessions/{sid}")
        try:
            print("  title after =", json.loads(check)["data"].get("title"))
        except Exception:
            pass
        # 空 body / 非法键的边界（与 :action 一致：必须是对象，且键要认识）
        for label, body in (("empty object", {}), ("unknown key", {"name": "X"})):
            st, raw = req(PORT, token, "POST", f"/api/v1/sessions/{sid}/profile", body)
            print(f"  POST /profile {label:14} -> {st} {raw[:120]}")

        print("\n=== rename probes（以下预期全部失败，证明 /profile 是唯一解）===")
        rename_methods = [
            ("PATCH /sessions/{id}", "PATCH", f"/api/v1/sessions/{sid}", {"title": "PATCH_RENAMED"}),
            ("PUT /sessions/{id}", "PUT", f"/api/v1/sessions/{sid}", {"title": "PUT_RENAMED"}),
            ("POST :rename title", "POST", f"/api/v1/sessions/{sid}:rename", {"title": "ACTION_RENAMED"}),
            ("POST :setTitle", "POST", f"/api/v1/sessions/{sid}:setTitle", {"title": "SETTITLE_RENAMED"}),
            ("POST :update", "POST", f"/api/v1/sessions/{sid}:update", {"title": "UPDATE_RENAMED"}),
            ("POST :setName", "POST", f"/api/v1/sessions/{sid}:setName", {"title": "SETNAME_RENAMED"}),
            ("POST :setMetadata", "POST", f"/api/v1/sessions/{sid}:setMetadata", {"metadata": {"title": "META_RENAMED"}}),
        ]
        for name, method, path, body in rename_methods:
            st, raw = req(PORT, token, method, path, body)
            print(f"  {name:28} -> {st} {raw[:140]}")
            if st == 200:
                # verify title actually changed
                _, check = req(PORT, token, "GET", f"/api/v1/sessions/{sid}")
                try:
                    title = json.loads(check)["data"].get("title")
                    print(f"      title after = {title}")
                except Exception:
                    pass

        print("\n=== delete probes ===")
        delete_methods = [
            ("DELETE /sessions/{id}", "DELETE", f"/api/v1/sessions/{sid}"),
            ("POST :delete", "POST", f"/api/v1/sessions/{sid}:delete", {}),
            ("POST :remove", "POST", f"/api/v1/sessions/{sid}:remove", {}),
        ]
        for name, method, path in delete_methods:
            body = {} if method == "POST" else None
            st, raw = req(PORT, token, method, path, body)
            print(f"  {name:28} -> {st} {raw[:140]}")

        print("\n=== debug RPC probes (session scope, needs runtime load) ===")
        rpcs = [
            f"/api/v1/debug/session/{sid}/session/rename",
            f"/api/v1/debug/session/{sid}/workspace/rename",
            f"/api/v1/debug/session/{sid}/sessions/rename",
            f"/api/v1/debug/session/{sid}/session/delete",
        ]
        for path in rpcs:
            st, raw = req(PORT, token, "POST", path, {"title": "RPC_RENAMED"} if "rename" in path else {})
            print(f"  {path:55} -> {st} {raw[:140]}")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    main()
