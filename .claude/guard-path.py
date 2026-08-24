#!/usr/bin/env python3
"""PreToolUse guard: refuse file access that lands outside this project.

Reads the hook payload on stdin and emits a PreToolUse decision on stdout.
Policy: a path may resolve inside the project root or the session scratchpad.
Anything that resolves inside $HOME but outside the project is denied.
System paths (/usr, /bin, ...) are left alone so normal tooling keeps working.
"""
import json
import os
import re
import sys

ROOT = os.path.realpath(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME = os.path.realpath(os.path.expanduser("~"))
# Claude 自身のメモリー保存先。ホーム配下だがこのプロジェクト専用のため許可する。
# ディレクトリ名は Claude Code がプロジェクトの絶対パスの "/" と "_" を "-" に
# 置換して作る（例: /Users/x/study/my_app -> -Users-x-study-my-app）。
MEMORY = os.path.realpath(os.path.join(
    HOME, ".claude", "projects",
    ROOT.replace("/", "-").replace("_", "-"), "memory"))

ALLOWED = [ROOT, MEMORY, "/private/tmp/claude-501", "/tmp/claude-501", "/private/var/folders"]

PATH_KEYS = ("file_path", "path", "notebook_path", "edits")
# tokens that look like paths: absolute, ~-rooted, or parent-relative
TOKEN_RE = re.compile(r"""(?:^|[\s=:'"`(])((?:~|\.\.|/)[^\s'"`;|&()<>]*)""")


def under(path, base):
    return path == base or path.startswith(base + os.sep)


def verdict(raw):
    """Return None if acceptable, else a reason string."""
    if not raw or not isinstance(raw, str):
        return None
    expanded = os.path.expanduser(raw)
    resolved = os.path.realpath(os.path.join(ROOT, expanded))
    if any(under(resolved, a) for a in ALLOWED):
        return None
    if under(resolved, HOME):
        return "%s はプロジェクト外（ホーム配下）です → %s" % (raw, resolved)
    return None


def deny(reason):
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason":
                "ガードレールによりブロックしました。" + reason +
                "\nこのプロジェクト (" + ROOT + ") の外は読み書きできません。"
                "必要なら .claude/settings.json のフックを外してください。",
        }
    }))
    sys.exit(0)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # malformed payload: stay out of the way

    tool = data.get("tool_name", "")
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        sys.exit(0)

    if tool == "Bash":
        cmd = ti.get("command", "") or ""
        for token in TOKEN_RE.findall(cmd):
            reason = verdict(token)
            if reason:
                deny(reason)
    else:
        for key in PATH_KEYS:
            val = ti.get(key)
            if isinstance(val, str):
                reason = verdict(val)
                if reason:
                    deny(reason)

    sys.exit(0)


main()
