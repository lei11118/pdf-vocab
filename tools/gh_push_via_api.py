#!/usr/bin/env python3
"""通过 GitHub REST API(api.github.com)推送本地当前 commit(支持多个连续 commit)。

用途:github.com:443 的 git 通道被墙/不通、而 api.github.com 正常时的备用推送通道
(本机网络环境下常见)。为尽量保持哈希一致,commit 的 author/committer 字符串与
本地一致;若成功且提示"哈希一致",则远端与本地完全同步。

v2(2026-10):gh api 调用带**瞬断重试**(拨号失败/连接重置/边缘 401/5xx 均退避重试);
blob 上传带**持久缓存**(tools/.blobcache.json),网络中断后重跑可快速续传。

用法:
  python gh_push_via_api.py [owner/repo] [branch]
环境变量:GH_BIN(gh 可执行文件路径,默认 "gh")

前置:gh CLI 已登录;在 git 仓库目录内运行。
流程:算出远端 head..HEAD 的 commit 列表(要求远端 head 是 HEAD 的祖先),
逐个上传 blob(按内容缓存)→ 建 tree → 建 commit(父=上一个)→ 更新远端 ref。
"""
import base64
import json
import os
import subprocess
import sys
import time

GH = os.environ.get("GH_BIN", "gh")
CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".blobcache.json")

# 视为"瞬断"可重试的错误特征(网络抖动/边缘节点错误/凭据瞬时故障)
TRANSIENT_MARKERS = (
    "dial tcp",
    "Bad credentials",
    "timed out",
    "timeout",
    "connection reset",
    "connection refused",
    "unexpected EOF",
    "EOF",
    "502",
    "503",
    "504",
)
# 明显"永久性"错误(出现即不重试)
FATAL_MARKERS = ("Validation Failed", "HTTP 422", "HTTP 404", "Not Found")


def git(*args):
    p = subprocess.run(["git", *args], capture_output=True)
    if p.returncode != 0:
        raise SystemExit(f"git 命令失败:{' '.join(args)}\n{p.stderr.decode('utf-8', 'replace')}")
    return p.stdout


def gh_api(method, path, payload=None):
    last_err = ""
    for attempt in range(6):
        cmd = [GH, "api", "--method", method, path]
        if payload is not None:
            cmd += ["--input", "-"]
            p = subprocess.run(cmd, input=json.dumps(payload).encode(), capture_output=True)
        else:
            p = subprocess.run(cmd, capture_output=True)
        if p.returncode == 0:
            out = p.stdout.decode().strip()
            return json.loads(out) if out else {}
        stderr = p.stderr.decode("utf-8", "replace")
        last_err = stderr.strip()
        if not any(k in stderr for k in FATAL_MARKERS) and attempt < 5:
            wait = 3 * (attempt + 1)
            head = last_err.splitlines()[0] if last_err else ""
            print(f"  ↻ 瞬断,{wait}s 后重试({method} {path}):{head[:90]}")
            time.sleep(wait)
            continue
        raise SystemExit(f"gh api 失败:{method} {path}\n{stderr}")
    raise SystemExit(f"gh api 失败(重试耗尽):{method} {path}\n{last_err}")


def commit_meta(csha):
    parts = (
        git("log", "-1", "--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI", csha)
        .decode()
        .strip()
        .split("\x00")
    )
    return {
        "author": {"name": parts[0], "email": parts[1], "date": parts[2]},
        "committer": {"name": parts[3], "email": parts[4], "date": parts[5]},
        "message": git("log", "-1", "--format=%B", csha).decode(),
    }


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "lei11118/pdf-vocab"
    branch = sys.argv[2] if len(sys.argv) > 2 else "main"

    head = git("rev-parse", "HEAD").decode().strip()
    r = gh_api("GET", f"repos/{repo}/git/ref/heads/{branch}")
    remote_head = r["object"]["sha"]
    print(f"local head  = {head}")
    print(f"remote head = {remote_head}")
    if remote_head == head:
        print("远端已是该 commit,无需推送。")
        return

    chk = subprocess.run(["git", "merge-base", "--is-ancestor", remote_head, "HEAD"], capture_output=True)
    if chk.returncode != 0:
        # 远端曾被 API 镜像推送(哈希与本地不同、非字符串祖先)时,退回"内容式单提交":
        # 把本地 HEAD 的完整内容作为一个新 commit 挂到远端 head 之后(远端历史只前进,不改写)。
        print("⚠️ 远端 head 不是本地 HEAD 的祖先(可能曾走 API 镜像推送);改用内容式单提交模式。")
        commit_list = [head]
    else:
        commit_list = git("rev-list", "--reverse", f"{remote_head}..HEAD").decode().split()
    print(f"待推送 commit:{len(commit_list)} 个")

    # blob 缓存(本地 blob sha -> 远端新 blob sha):支持断点续传
    blob_cache = {}
    if os.path.exists(CACHE_PATH):
        try:
            with open(CACHE_PATH) as f:
                blob_cache = json.load(f)
            print(f"(blob 缓存:{len(blob_cache)} 条)")
        except Exception:
            blob_cache = {}

    parent = remote_head
    for csha in commit_list:
        meta = commit_meta(csha)
        tree_entries = []
        raw = git("ls-tree", "-r", "-z", "--full-tree", csha)
        entries = [e for e in raw.split(b"\x00") if e]
        done = 0
        for entry in entries:
            entry_meta, path = entry.split(b"\t", 1)
            mode, _type, bsha = entry_meta.decode().split(" ")
            if bsha in blob_cache:
                new_sha = blob_cache[bsha]
            else:
                content = git("cat-file", "blob", bsha)
                new_sha = gh_api(
                    "POST",
                    f"repos/{repo}/git/blobs",
                    {"content": base64.b64encode(content).decode(), "encoding": "base64"},
                )["sha"]
                blob_cache[bsha] = new_sha
                try:
                    with open(CACHE_PATH, "w") as f:
                        json.dump(blob_cache, f)
                except Exception:
                    pass
            done += 1
            if done % 10 == 0:
                print(f"  blob {done}/{len(entries)}")
            tree_entries.append(
                {
                    "path": path.decode("utf-8", "surrogateescape"),
                    "mode": mode,
                    "type": "blob",
                    "sha": new_sha,
                }
            )

        tree = gh_api("POST", f"repos/{repo}/git/trees", {"tree": tree_entries})
        local_tree = git("rev-parse", f"{csha}^{{tree}}").decode().strip()
        mark = "✓" if tree["sha"] == local_tree else f"(本地 {local_tree[:8]},内容仍完整)"
        commit = gh_api(
            "POST",
            f"repos/{repo}/git/commits",
            {
                "message": meta["message"],
                "tree": tree["sha"],
                "parents": [parent],
                "author": meta["author"],
                "committer": meta["committer"],
            },
        )
        print(f"commit {csha[:8]} -> {commit['sha'][:8]}  tree {tree['sha'][:8]} {mark}")
        parent = commit["sha"]

    # PATCH ref:若因"已在目标位置"报错则核对后放行
    try:
        gh_api("PATCH", f"repos/{repo}/git/refs/heads/{branch}", {"sha": parent, "force": False})
    except SystemExit:
        cur = gh_api("GET", f"repos/{repo}/git/ref/heads/{branch}")["object"]["sha"]
        if cur != parent:
            raise
    final = gh_api("GET", f"repos/{repo}/git/ref/heads/{branch}")["object"]["sha"]
    if final == head:
        print(f"✅ 推送完成(共 {len(commit_list)} 个 commit),远端 sha 与本地 HEAD 完全一致:{head}")
    else:
        print(f"⚠️ 已推送但最终哈希不同:远端 {final} / 本地 {head}")
        print("   github.com 通道恢复后建议:git fetch origin && git reset --soft origin/main && git commit 以校准历史。")
    # 推送成功后清理 blob 缓存
    try:
        os.remove(CACHE_PATH)
    except Exception:
        pass


if __name__ == "__main__":
    main()
