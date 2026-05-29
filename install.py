#!/usr/bin/env python3
"""
nfty plugin installer for Claude Code.

What this does:
  1. Creates ~/.claude/plugins/nfty → <this directory> symlink
  2. Adds nfty script paths to Claude Code's settings.json allowlist so scripts
     run without permission prompts
  3. Checks that the `cryptography` pip package is available (required for
     AES-256-GCM encryption)

Safe to re-run — all steps are idempotent.
"""

import json
import os
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


def step(msg):
    print(f"  {msg}")


def ok(msg):
    print(f"  \033[32m✓\033[0m {msg}")


def warn(msg):
    print(f"  \033[33m!\033[0m {msg}")


def err(msg):
    print(f"  \033[31m✗\033[0m {msg}")


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
    result = subprocess.run(
        [sys.executable, "-m", "pip", "install", "cryptography", "--quiet"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        ok("Installed successfully")
    else:
        err("pip install failed. Run manually: pip install cryptography")
        print(result.stderr.strip())
        sys.exit(1)


# ── Done ──────────────────────────────────────────────────────────────────────

print(f"""
\033[32mInstallation complete.\033[0m

Restart Claude Code (or open a new session) for hooks and slash commands to activate.

Next steps:
  /nfty:add <name> https://ntfy.sh/<topic> [--reply] [--mode new]
  /nfty:send <name> "Hello from Claude Code"
  /nfty:help
""")
