# nfty — ntfy.sh Plugin for Claude Code

Send push notifications from Claude Code sessions to any [ntfy.sh](https://ntfy.sh) topic,
with a named channel registry and NZ-timezone scheduled delivery.

## Features

- **Channel store** — save ntfy topic URLs with names, descriptions, and optional auth tokens
- **Send notifications** — title, priority, tags, markdown, file attachments, email forward
- **Scheduled delivery** — specify delivery time in NZ local time; ntfy.sh handles it server-side (session doesn't need to stay running)
- **Action buttons** — view URL, Android broadcast intent, HTTP callback (up to 3 per message)
- **Auto-notify** — ask Claude to ping you when a task finishes
- **CRUD commands** — add, list, update, remove channels via slash commands

## Requirements

- `curl` — for HTTP requests
- `python3` (3.9+) — for JSON manipulation and NZ timezone conversion

## Installation

```bash
ln -s /path/to/nfty_plugin ~/.claude/plugins/nfty
```

Then restart Claude Code or open a new session.

## Quick Start

```
# Add your ntfy.sh topic as a channel
/nfty:add alerts https://ntfy.sh/your_unique_topic_name "Work alerts" --mode new

# Send a notification
/nfty:send alerts "Hello from Claude Code"

# Schedule for NZ morning
/nfty:send alerts "Daily standup in 5 minutes" --at "2026-06-02 08:55"

# See all commands
/nfty:help
```

## Slash Commands

| Command | Description |
|---------|-------------|
| `/nfty:help` | Full help, schema reference, docs link |
| `/nfty:channels` | List stored channels |
| `/nfty:add <name> <url> [desc] [--token tok] [--mode new\|existing]` | Add channel |
| `/nfty:update <name> <field> <value>` | Update channel field |
| `/nfty:remove <name>` | Remove channel |
| `/nfty:send [channel] [message] [options]` | Send notification |

## Channel Store

Stored at `~/.claude/channels/nfty/channels.json` — global across all projects and Claude Code instances.

### --mode flag (for /nfty:add)

- `--mode new` — polls the topic for existing messages; warns if the topic is already active (avoids accidentally attaching to someone else's public topic)
- `--mode existing` — verifies the endpoint responds before storing
- Omit for private/authenticated servers

## Scheduled Delivery (NZ Time)

```
/nfty:send alerts "Reminder: check logs" --at "2026-06-15 09:30"
```

Times are in **New Zealand local time** (NZDT/NZST handled automatically via `Pacific/Auckland`).
Once sent, ntfy.sh queues the message server-side — close your terminal, shut down the instance, doesn't matter.

## Action Buttons

```
/nfty:send work "Deploy ready for review" \
  --action-view "Open PR" "https://github.com/org/repo/pull/42" \
  --action-broadcast "Dismiss" intent=io.heckel.ntfy.DISMISS \
  --action-http "Approve" "https://myserver.com/deploy/approve"
```

- `--action-view` — opens a URL when the button is tapped
- `--action-broadcast` — sends an Android broadcast intent (app-to-app on Android)
- `--action-http` — makes an HTTP callback (webhooks, approve/reject flows)

## Auto-Notification

Ask Claude to notify you when a task is done:

> "Run the migration and send me an ntfy when it's complete"
> "Run tests in the background and ping me via ntfy"

Claude uses the default channel and composes a summary automatically.

## Documentation

- ntfy.sh publishing guide: https://docs.ntfy.sh/publish/
- ntfy.sh emoji tags: https://docs.ntfy.sh/emojis/
- ntfy.sh action buttons: https://docs.ntfy.sh/publish/#action-buttons
- Future features: [meta/ROADMAP.md](meta/ROADMAP.md)
