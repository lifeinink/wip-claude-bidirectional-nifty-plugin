#!/usr/bin/env python3
"""
nfty plugin installer for Claude Code.

Usage:
  python3 install.py            # install / verify installation (idempotent)
  python3 install.py --update   # pull latest from origin, then re-verify

What this does:
  1. Creates ~/.claude/plugins/nfty → <this directory> symlink
  2. Adds nfty script paths to Claude Code's settings.json allowlist so scripts
     run without permission prompts
  3. Checks that the `cryptography` pip package is available (required for
     AES-256-GCM encryption)
"""

import json
import subprocess
import sys
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent
PLUGIN_LINK = Path.home() / ".claude" / "plugins" / "nfty"
SETTINGS_FILE = Path.home() / ".claude" / "settings.json"

# Bash permission patterns that cover all nfty script invocations.
# Uses the symlink path so they work regardless of where the repo lives.
ALLOW_PATTERNS = [
    f"Bash(bash {PLUGIN_LINK}/scripts/send.sh*)",
    f"Bash(bash {PLUGIN_LINK}/scripts/channels.sh*)",
    f"Bash(bash {PLUGIN_LINK}/scripts/pending.sh*)",
    f"Bash(bash {PLUGIN_LINK}/scripts/encrypt.sh*)",
    f"Bash(bash {PLUGIN_LINK}/scripts/reply-poll.sh*)",
    f"Bash(bash {PLUGIN_LINK}/hooks/scripts/session-start.sh*)",
    f"Bash(bash {PLUGIN_LINK}/hooks/scripts/session-end.sh*)",
]


def ok(msg):
    print(f"  \033[32m✓\033[0m {msg}")


def warn(msg):
    print(f"  \033[33m!\033[0m {msg}")


def err(msg):
    print(f"  \033[31m✗\033[0m {msg}")


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


# ── 0. Update (optional) ──────────────────────────────────────────────────────

if "--update" in sys.argv:
    print("\n── Step 0: Pull latest from origin")
    # Check this is actually a git repo
    if not (PLUGIN_DIR / ".git").exists():
        err("Plugin directory is not a git repo — cannot update automatically")
        sys.exit(1)

    fetch = run(["git", "-C", str(PLUGIN_DIR), "fetch", "origin"])
    if fetch.returncode != 0:
        err(f"git fetch failed: {fetch.stderr.strip()}")
        sys.exit(1)

    # Count commits we're behind
    behind = run(
        ["git", "-C", str(PLUGIN_DIR), "rev-list", "HEAD..origin/main", "--count"]
    )
    count = behind.stdout.strip()

    if count == "0":
        ok("Already up to date")
    else:
        pull = run(["git", "-C", str(PLUGIN_DIR), "pull", "--ff-only", "origin", "main"])
        if pull.returncode == 0:
            ok(f"Pulled {count} new commit(s)")
            # Show what changed
            log = run(
                ["git", "-C", str(PLUGIN_DIR), "log", f"HEAD~{count}..HEAD", "--oneline"]
            )
            for line in log.stdout.strip().splitlines():
                print(f"    {line}")
        else:
            err("git pull --ff-only failed (local changes may be blocking it)")
            print(f"    {pull.stderr.strip()}")
            sys.exit(1)


# ── 1. Symlink ────────────────────────────────────────────────────────────────

print("\n── Step 1: Plugin symlink")
PLUGIN_LINK.parent.mkdir(parents=True, exist_ok=True)

if PLUGIN_LINK.is_symlink():
    target = PLUGIN_LINK.resolve()
    if target == PLUGIN_DIR:
        ok(f"{PLUGIN_LINK} → {PLUGIN_DIR} (already correct)")
    else:
        warn(f"Symlink exists but points to {target}")
        answer = input("    Replace it? [y/N] ").strip().lower()
        if answer == "y":
            PLUGIN_LINK.unlink()
            PLUGIN_LINK.symlink_to(PLUGIN_DIR)
            ok(f"Replaced: {PLUGIN_LINK} → {PLUGIN_DIR}")
        else:
            warn("Skipped — existing symlink kept")
elif PLUGIN_LINK.exists():
    err(f"{PLUGIN_LINK} exists and is not a symlink — please remove it manually")
    sys.exit(1)
else:
    PLUGIN_LINK.symlink_to(PLUGIN_DIR)
    ok(f"Created: {PLUGIN_LINK} → {PLUGIN_DIR}")


# ── 2. settings.json allowlist ────────────────────────────────────────────────

print("\n── Step 2: Claude Code permissions allowlist")

if SETTINGS_FILE.exists():
    with open(SETTINGS_FILE) as f:
        settings = json.load(f)
else:
    settings = {}
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)

permissions = settings.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])

added = []
for pattern in ALLOW_PATTERNS:
    if pattern not in allow:
        allow.append(pattern)
        added.append(pattern)

if added:
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    for p in added:
        ok(f"Added: {p}")
else:
    ok("All patterns already present")


# ── 3. cryptography package ───────────────────────────────────────────────────

print("\n── Step 3: Python cryptography package")

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: F401
    ok("cryptography package available")
except ImportError:
    warn("cryptography not installed — attempting pip install ...")
    result = run([sys.executable, "-m", "pip", "install", "cryptography", "--quiet"])
    if result.returncode == 0:
        ok("Installed successfully")
    else:
        err("pip install failed. Run manually: pip install cryptography")
        print(result.stderr.strip())
        sys.exit(1)


# ── Done ──────────────────────────────────────────────────────────────────────

action = "Update" if "--update" in sys.argv else "Installation"
print(f"""
\033[32m{action} complete.\033[0m

Restart Claude Code (or open a new session) for any changes to take effect.

Next steps:
  /nfty:add <name> https://ntfy.sh/<topic> [--reply] [--mode new]
  /nfty:send <name> "Hello from Claude Code"
  /nfty:help
""")
