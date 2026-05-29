---
name: nfty-help
description: Show the nfty plugin's command reference, ntfy.sh message schema, and links to official documentation. Use this skill when the user runs /nfty:help or asks how to use the nfty plugin.
argument-hint: [topic]
allowed-tools: []
---

When this skill is invoked, output the following help reference. Expand any topic the user asked about (e.g. `/nfty:help delay` should show the Delay section in detail).

---

# nfty — ntfy.sh Plugin for Claude Code

Send push notifications to any ntfy.sh topic, with a stored channel registry and NZ-timezone scheduled delivery.

Official docs: https://docs.ntfy.sh/publish/

---

## Slash Commands

| Command | Description |
|---------|-------------|
| `/nfty:help [topic]` | This help. Add a topic for details |
| `/nfty:channels` | List all stored channels |
| `/nfty:add <name> <url> [desc] [--token] [--mode] [--reply] [--encrypt]` | Add a channel |
| `/nfty:update <name> <field> <value>` | Update a channel field |
| `/nfty:remove <name>` | Remove a channel from the store |
| `/nfty:send [channel] [message] [options]` | Construct and send a notification |
| `/nfty:reply <enable\|disable\|status> <name>` | Manage reply channel on a stored channel |
| `/nfty:deprecate <name>` | Send stopper + mark channel as deprecated |
| `/nfty:key <set\|list\|check> [key-id]` | Manage encryption key passwords |

---

## /nfty:send Options

| Flag | Description |
|------|-------------|
| `channel` | Channel name from store, or direct `https://ntfy.sh/topic` URL. Defaults to the store's default channel. |
| `message` | Message body. Supports CommonMark markdown when `--markdown` is set. |
| `--title "text"` | Bold notification title |
| `--priority 1-5` | 1=min 2=low 3=default 4=high 5=urgent |
| `--tags tag1,tag2` | Emoji shortcodes (e.g. `warning,robot`) |
| `--at "YYYY-MM-DD HH:MM"` | Schedule delivery at this **NZ local time** (server-side — session doesn't need to stay running) |
| `--check-at "YYYY-MM-DD HH:MM"` | Schedule a reply poll at this NZ time. Appends `⏰ Reply checked at…` to the notification body so the deadline is visible on the user's device. Requires `--with-reply`. Auto-triggers a `/schedule` via the skill layer. |
| `--markdown` | Render message as CommonMark |
| `--attach <url>` | Attach file by URL |
| `--icon <url>` | Custom notification icon |
| `--email addr@example.com` | Forward to email |
| `--encrypt` | Encrypt this message using the channel's stored key (opt-in; ntfy app must have password configured to decrypt) |
| `--no-cache` | Don't cache on ntfy server |
| `--action-view "Label" "https://url"` | Add a "view URL" action button |
| `--action-broadcast "Label" [intent=...] [extras.key=val]` | Add an Android broadcast intent button |
| `--action-http "Label" "https://url" [method=POST]` | Add an HTTP callback button |

---

## Channel Store

Channels are stored at `~/.claude/channels/nfty/channels.json`. The first channel added becomes the default.

```json
{
  "channels": [{
    "name": "my-alerts",
    "url": "https://ntfy.sh/your_topic_name",
    "description": "General alerts",
    "token": "optional-bearer-token",
    "default": true,
    "created": "2026-01-01T00:00:00Z"
  }]
}
```

### --mode flag (for /nfty:add)

- `--mode new`: checks the topic for existing messages; warns if already in use (protects against accidentally using someone else's topic)
- `--mode existing`: verifies the endpoint is reachable before storing
- Omit for private/authenticated servers where polling may return 401

---

## Priority Levels

| Value | Name | Effect |
|-------|------|--------|
| 1 | min | Silent, no popup |
| 2 | low | Low importance |
| 3 | default | Normal notification |
| 4 | high | High priority, may bypass DND |
| 5 | urgent | Breaks DND, loud sound |

---

## NZ Scheduled Delivery

Specify a delivery time in New Zealand local time:

```
/nfty:send my-channel "Reminder: standup in 5" --at "2026-06-02 09:00"
```

The plugin converts this to UTC using `Pacific/Auckland` (handles NZDT/NZST automatically).
ntfy.sh queues the message server-side — **the sending session can shut down immediately**.

---

## Action Buttons (up to 3)

```
/nfty:send alerts "Deploy ready" \
  --action-view "Open dashboard" "https://grafana.example.com" \
  --action-broadcast "Snooze" extras.snooze=10min \
  --action-http "Approve" "https://myserver.com/approve"
```

Broadcast intents send an Android broadcast to the ntfy app or other receivers.
Useful for interactive workflows and app-to-app communication on Android.

---

## Reply Polling Model (cloud vs CLI)

| | Cloud Claude Code | CLI Claude Code |
|---|---|---|
| Session-start auto-poll | ✓ (capped at 4s) | ✓ (uncapped) |
| Mid-session auto-poll | ✗ | ✗ |
| On-demand poll (`/nfty:check`) | ✓ | ✓ |
| Scheduled poll (`/schedule`) | ✓ | ✓ |
| Live watcher (v0.3) | ✗ (5s hook limit) | planned |

**The reply window (e.g. "12h") is the ntfy server's message retention period — it is
NOT the Claude Code hook timeout.** The 5-second limit only affects how long a hook
can execute, not how long ntfy stores messages. Replies sent within the window will
always be picked up at the next session start or on an explicit `/nfty:check`.

## Reply Tracking (`--with-reply`)

Add action buttons and track the user's response across sessions:

```
/nfty:send alerts "Proceed with deploy?" --with-reply "Approve,Reject,Snooze"
```

- Each choice becomes an HTTP action button on the notification
- Tapping one posts the choice to the reply topic (pre-encrypted if encryption is on)
- The plugin tracks pending replies in `~/.claude/nfty/pending/`
- On next `SessionStart`, any replies received while offline are surfaced automatically
- Pending records expire after 12h (ntfy's default TTL) and are cleaned up — no leakage

## Encryption

Encryption is **opt-in per send** (AES-256-GCM, ntfy-compatible). The channel stores the key as a credential; use `--encrypt` to activate it for a specific message:

```
/nfty:key set main                           ← store password once
/nfty:add alerts https://ntfy.sh/... --encrypt main --reply --mode new
/nfty:send alerts "sensitive message" --encrypt
```

Without `--encrypt`, messages are sent in plaintext even if the channel has a key configured. This lets most notifications be readable in the ntfy app without password setup, while sensitive sends can still be encrypted on demand.

When `--encrypt` is used with `--with-reply`, reply choice bodies are also pre-encrypted — the ntfy server never sees plaintext reply content. The ntfy app must have the channel password configured to decrypt incoming messages.

## Deprecating a Channel (Stopper)

When a topic is being retired or may have been squatted:

```
/nfty:deprecate alerts
```

Sends a secret stopper message to the topic. Any plugin instance that polls that
topic will automatically deregister the channel. Clean distributed shutdown.

## Auto-notification (model-invoked)

Ask Claude to notify you when a task is done:

> "Run the tests and notify me via ntfy when they finish"
> "Do the migration and send me an ntfy when it's complete"

Claude will use the default channel automatically.

---

Full schema reference: https://docs.ntfy.sh/publish/
Emoji tag list: https://docs.ntfy.sh/emojis/
