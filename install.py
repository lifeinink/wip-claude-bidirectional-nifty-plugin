#!/usr/bin/env python3
"""
nfty plugin installer for Claude Code.

Usage:
  python3 install.py            # install / verify installation (idempotent)
  python3 install.py --update   # pull latest from origin, then re-verify

What this does:
  1. Creates a private marketplace directory with marketplace.json so Claude
     Code can discover and install the plugin
  2. Registers the marketplace in known_marketplaces.json
  3. Adds script paths to Claude Code's settings.json allowlist so scripts
     run without permission prompts
  4. Checks that the `cryptography` pip package is available

After running this script, complete the installation inside Claude Code:
  /plugin marketplace add ~/.claude/plugins/marketplaces/nfty-private
  /plugin install nfty@nfty-private
"""

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent
CLAUDE_DIR = Path.home() / ".claude"
MARKETPLACE_DIR = CLAUDE_DIR / "plugins" / "marketplaces" / "nfty-private"
PLUGIN_LINK = MARKETPLACE_DIR / "plugins" / "nfty"
KNOWN_MARKETPLACES = CLAUDE_DIR / "plugins" / "known_marketplaces.json"
SETTINGS_FILE = CLAUDE_DIR / "settings.json"

# Bash permission patterns that cover all nfty script invocations.
# Uses the marketplace plugin path so they work regardless of where the repo lives.
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
    if not (PLUGIN_DIR / ".git").exists():
        err("Plugin directory is not a git repo — cannot update automatically")
        sys.exit(1)

    fetch = run(["git", "-C", str(PLUGIN_DIR), "fetch", "origin"])
    if fetch.returncode != 0:
        err(f"git fetch failed: {fetch.stderr.strip()}")
        sys.exit(1)

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
            log = run(
                ["git", "-C", str(PLUGIN_DIR), "log", f"HEAD~{count}..HEAD", "--oneline"]
            )
            for line in log.stdout.strip().splitlines():
                print(f"    {line}")
        else:
            err("git pull --ff-only failed (local changes may be blocking it)")
            print(f"    {pull.stderr.strip()}")
            sys.exit(1)


# ── 1. Marketplace registration ───────────────────────────────────────────────

print("\n── Step 1: Plugin marketplace registration")
PLUGIN_LINK.parent.mkdir(parents=True, exist_ok=True)

# Create marketplace.json (what Claude Code reads to discover installable plugins)
marketplace_json_dir = MARKETPLACE_DIR / ".claude-plugin"
marketplace_json_path = marketplace_json_dir / "marketplace.json"
marketplace_json_dir.mkdir(parents=True, exist_ok=True)
marketplace_data = {
    "name": "nfty-private",
    "owner": {"name": "nfty plugin"},
    "plugins": [
        {
            "name": "nfty",
            "source": "./plugins/nfty",
            "description": "Bidirectional ntfy.sh push notifications for Claude Code — "
                           "channel store, reply tracking, encryption, NZ-timezone scheduled delivery",
        }
    ],
}
existing_mj = json.loads(marketplace_json_path.read_text()) if marketplace_json_path.exists() else {}
if existing_mj.get("plugins") == marketplace_data["plugins"]:
    ok("marketplace.json already correct")
else:
    marketplace_json_path.write_text(json.dumps(marketplace_data, indent=2) + "\n")
    ok(f"Created: {marketplace_json_path}")

# Symlink our repo into the marketplace plugins directory
if PLUGIN_LINK.is_symlink():
    target = PLUGIN_LINK.resolve()
    if target == PLUGIN_DIR:
        ok(f"Plugin symlink correct: {PLUGIN_LINK} → {PLUGIN_DIR}")
    else:
        warn(f"Symlink points to {target}, re-pointing to {PLUGIN_DIR}")
        PLUGIN_LINK.unlink()
        PLUGIN_LINK.symlink_to(PLUGIN_DIR)
        ok(f"Updated: {PLUGIN_LINK} → {PLUGIN_DIR}")
elif PLUGIN_LINK.exists():
    err(f"{PLUGIN_LINK} exists and is not a symlink — please remove it manually")
    sys.exit(1)
else:
    PLUGIN_LINK.symlink_to(PLUGIN_DIR)
    ok(f"Created: {PLUGIN_LINK} → {PLUGIN_DIR}")

# Register the marketplace in known_marketplaces.json
KNOWN_MARKETPLACES.parent.mkdir(parents=True, exist_ok=True)
if KNOWN_MARKETPLACES.exists():
    with open(KNOWN_MARKETPLACES) as f:
        known = json.load(f)
else:
    known = {}

now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
mkt_entry = {
    "source": {"source": "directory", "path": str(MARKETPLACE_DIR)},
    "installLocation": str(MARKETPLACE_DIR),
    "lastUpdated": now_iso,
}

if known.get("nfty-private", {}).get("installLocation") == str(MARKETPLACE_DIR):
    ok("Marketplace already registered")
else:
    known["nfty-private"] = mkt_entry
    with open(KNOWN_MARKETPLACES, "w") as f:
        json.dump(known, f, indent=2)
        f.write("\n")
    ok(f"Registered marketplace: nfty-private → {MARKETPLACE_DIR}")


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

\033[1mFinal step — run these two commands inside Claude Code:\033[0m

  /plugin marketplace add {MARKETPLACE_DIR}
  /plugin install nfty@nfty-private

Then run \033[1m/reload-plugins\033[0m and your \033[1m/nfty:*\033[0m commands will be available.
(You only need to do this once — the plugin persists across sessions.)
""")
