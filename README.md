# nfty — ntfy.sh Plugin for Claude Code

Bidirectional push notifications between Claude Code sessions and any [ntfy.sh](https://ntfy.sh) topic.
Send alerts from Claude, tap action buttons on your phone, and have Claude pick up your reply — across sessions, with end-to-end encryption.

## Features

- **Channel store** — named ntfy topics with auth tokens, encryption keys, and reply channels
- **Send notifications** — title, priority, tags, markdown, scheduled delivery in NZ local time
- **Action buttons** — view URL, Android broadcast intent, HTTP callback (up to 3 per message)
- **Reply tracking** — action buttons post choices back to Claude; replies survive session restarts
- **AES-256-GCM encryption** — ntfy-compatible end-to-end encryption; the ntfy server never sees plaintext
- **Scheduled reply polls** — `--check-at` bakes the check time into the notification and auto-wires a `/schedule`
- **Session hooks** — `SessionStart` picks up any replies received while offline; `SessionEnd` stamps timestamps for clean handoff
- **Stopper messages** — deprecate a channel from any device; any polling instance auto-deregisters
- **Auto-notify** — ask Claude to ping you when a long task finishes

## Requirements

- `curl`
- `python3` 3.9+
- `cryptography` pip package — required for AES-256-GCM encryption (`pip install cryptography`)

## Installation

```bash
git clone https://github.com/lifeinink/wip-claude-bidirectional-nifty-plugin nfty_plugin
cd nfty_plugin
python3 install.py
```

The installer:
1. Creates `~/.claude/plugins/nfty → <repo>` symlink so Claude Code discovers the plugin
2. Adds the plugin's script paths to Claude Code's `settings.json` allowlist so scripts run without permission prompts
3. Checks / installs the `cryptography` package

Restart Claude Code (or open a new session) after running the installer.

To update to the latest version on any machine where the plugin is installed:

```bash
python3 ~/.claude/plugins/nfty/install.py --update
```

This pulls from `origin/main`, then re-runs the allowlist check in case new scripts were added.

### Using the plugin across multiple projects

The plugin is installed **globally** — the symlink lives at `~/.claude/plugins/nfty` and is available in every Claude Code session on that machine, regardless of which project is open. No per-project setup is needed.

To use it in another project:
1. Open a Claude Code session in that project (the plugin is already loaded)
2. Run `/nfty:channels` to confirm your channels are visible
3. Use `/nfty:send`, `/nfty:check`, etc. as normal

Channels, secrets, and pending records all live under `~/.claude/` and are shared across all projects.

### Debug channel (optional but recommended for multi-project use)

The debug channel lets you see errors from any instance in real time — useful when the plugin is running in a background project you're not watching:

```
/nfty:debug set https://ntfy.sh/your_private_debug_topic
/nfty:debug test
```

Once set, any script error (encryption failure, channel not found, poll timeout) will POST to that topic automatically from every project.

### Manual installation

If you prefer to set things up by hand:

```bash
# 1. Symlink the plugin
ln -s /path/to/nfty_plugin ~/.claude/plugins/nfty

# 2. Install the cryptography package
pip install cryptography

# 3. Add to ~/.claude/settings.json so scripts run without prompts
#    (add under permissions.allow — see install.py for the exact patterns)
```

## Quick Start

```
# Add a channel (--mode new warns if the topic is already in use)
/nfty:add alerts https://ntfy.sh/your_unique_topic "Work alerts" --mode new

# Send a notification
/nfty:send alerts "Tests passed"

# Schedule for NZ morning — session can close immediately after
/nfty:send alerts "Standup in 5" --at "2026-06-02 08:55"

# Ask for approval with reply buttons
/nfty:send alerts "Deploy to prod?" --with-reply "Approve,Reject"

# Full help
/nfty:help
```

## Slash Commands

| Command | Description |
|---------|-------------|
| `/nfty:help [topic]` | Full help and schema reference |
| `/nfty:channels` | List stored channels |
| `/nfty:add <name> <url> [desc] [--token] [--mode] [--reply] [--encrypt] [--ttl]` | Add channel |
| `/nfty:update <name> <field> <value>` | Update a channel field |
| `/nfty:remove <name>` | Remove a channel |
| `/nfty:send [channel] [message] [options]` | Send notification |
| `/nfty:reply <enable\|disable\|status> <name>` | Manage reply channel |
| `/nfty:check` | On-demand poll of pending replies |
| `/nfty:deprecate <name>` | Send stopper + mark channel deprecated |
| `/nfty:key <set\|list\|check> [key-id]` | Manage encryption key passwords |

## Channel Store

Stored at `~/.claude/channels/nfty/channels.json` — global across projects and Claude Code instances.

```json
{
  "channels": [{
    "name": "alerts",
    "url": "https://ntfy.sh/your_unique_topic",
    "description": "Work alerts",
    "token": null,
    "default": true,
    "reply_url": "https://ntfy.sh/your_unique_topic_r1a2b3c4",
    "encrypt_key": "main",
    "ntfy_ttl": 43200,
    "created": "2026-01-01T00:00:00Z"
  }]
}
```

### `/nfty:add` flags

| Flag | Description |
|------|-------------|
| `--token <tok>` | Bearer token for authenticated topics |
| `--mode new` | Polls topic first; warns if already in use |
| `--mode existing` | Verifies endpoint is reachable before storing |
| `--reply` | Auto-generate an inbound reply topic |
| `--encrypt <key-id>` | Encrypt all messages with this key |
| `--ttl <secs>` | Message retention window (default 43200 = 12h) |

## Send Options

| Flag | Description |
|------|-------------|
| `--title "text"` | Bold notification title |
| `--priority 1-5` | 1=silent … 5=breaks DND |
| `--tags tag1,tag2` | Emoji shortcodes |
| `--at "YYYY-MM-DD HH:MM"` | Scheduled delivery in NZ local time |
| `--with-reply "A,B,C"` | Add reply action buttons; track response across sessions |
| `--check-at "YYYY-MM-DD HH:MM"` | Schedule a reply poll at this NZ time; bakes deadline into notification body |
| `--markdown` | Render body as CommonMark |
| `--ttl <secs>` | Per-send TTL override |
| `--action-view "Label" "url"` | View URL button |
| `--action-broadcast "Label" [intent=…]` | Android broadcast intent button |
| `--action-http "Label" "url" [method=POST]` | HTTP callback button |
| `--action-open-session "url"` | Shorthand: "Open session" view button |

## Reply Tracking

Claude sends a notification with action buttons. Tapping one posts a reply to the channel's inbound topic. Claude picks it up automatically.

```
/nfty:send alerts "Proceed with deploy?" --with-reply "Approve,Reject,Snooze"
```

- Each choice becomes an HTTP action button
- Reply bodies are **pre-encrypted at send time** when `--encrypt` is used — the ntfy server never sees plaintext choices
- Pending records live at `~/.claude/nfty/pending/` with a TTL matching the channel's `ntfy_ttl`
- `SessionStart` hook polls for replies received while offline
- Expired records are cleaned up automatically — no lifecycle leakage

### Cloud vs CLI polling model

| | Cloud Claude Code | CLI Claude Code |
|---|---|---|
| Session-start auto-poll | ✓ (capped at 4s) | ✓ (uncapped) |
| On-demand poll (`/nfty:check`) | ✓ | ✓ |
| Scheduled poll (`/schedule`) | ✓ | ✓ |
| Live watcher (v0.3) | ✗ (5s hook limit) | planned |

The ntfy server's message retention window (e.g. 12h) is independent of the 5-second cloud hook timeout. Replies sent within the window will always be picked up at the next session start or on an explicit `/nfty:check`.

### Scheduled reply poll (`--check-at`)

```
/nfty:send alerts "Approve migration?" \
  --with-reply "Approve,Reject" \
  --check-at "2026-06-02 15:00"
```

This:
1. Appends `⏰ Reply checked at 15:00 NZST, 2 Jun — tap a button before then.` to the notification body so the deadline is visible on your device
2. Emits a `SCHEDULE_POLL_AT` signal that Claude immediately converts to a `/schedule` — no manual follow-up needed

## Encryption

AES-256-GCM, using the same protocol as the ntfy web and Android apps (PBKDF2-SHA256, 50k iterations, 16-byte salt, 12-byte IV). Encryption is **opt-in per send** — the channel stores the key as a credential, but messages are plaintext by default so they're readable in the ntfy app without any password setup.

```
/nfty:key set main                    ← store password once (never stored in plaintext)
/nfty:add alerts https://ntfy.sh/... --encrypt main --reply --mode new
/nfty:send alerts "sensitive message" --encrypt   ← encrypt this send only
```

Keys are stored at `~/.claude/channels/nfty/secrets.json` (chmod 600).

## Channel Deprecation (Stopper)

```
/nfty:deprecate alerts
```

Sends a secret stopper message to the topic. Any plugin instance that polls that topic automatically deregisters it — clean distributed shutdown without coordinating between machines.

## Auto-Notification

Ask Claude naturally:

> "Run the tests and ping me via ntfy when they finish"
> "Do the migration and send me an ntfy — high priority if it fails"

Claude uses the default channel and composes a summary automatically.

## State locations

All runtime state lives outside the plugin directory and is never committed to the repo:

| Path | Contents |
|------|----------|
| `~/.claude/channels/nfty/channels.json` | Channel store |
| `~/.claude/channels/nfty/secrets.json` | Encryption key passwords (chmod 600) |
| `~/.claude/nfty/pending/` | Pending reply records |
| `~/.claude/nfty/audit/` | Non-repudiation audit log (v0.4) |

## Roadmap

See [meta/ROADMAP.md](meta/ROADMAP.md) for planned work:
- **v0.next** — Test harness (unit + interactive phone tests, full cleanup)
- **v0.3** — CLI-only live watcher (`$CLOSE` remote shutdown, background daemon, `PostToolUse` hook)
- **v0.4** — Multi-user channels with Ed25519 non-repudiation and N-of-M approval flows

## Links

- ntfy.sh publishing guide: https://docs.ntfy.sh/publish/
- ntfy.sh emoji tags: https://docs.ntfy.sh/emojis/
- ntfy.sh encryption: https://docs.ntfy.sh/publish/#e2e-encryption
