---
name: nfty-add
description: Add a new ntfy.sh channel to the nfty channel store. Use this skill when the user runs /nfty:add or asks to add/register an ntfy channel.
argument-hint: <name> <url> [description] [--token <token>] [--mode new|existing]
allowed-tools: [Bash]
---

Parse the user's arguments and call `channels.sh add` with the appropriate flags.

## Argument format

```
/nfty:add <name> <url> [description] [--token <tok>] [--mode new|existing]
          [--reply] [--encrypt <key-id>]
```

- `name` — short identifier used in other commands (e.g. `alerts`, `my-server`)
- `url` — full ntfy topic URL (e.g. `https://ntfy.sh/my_topic_xyz`)
- `description` — optional human-readable note (quote if it contains spaces)
- `--token` — optional Bearer auth token for protected topics
- `--mode new` — verifies both outbound (and inbound if `--reply`) topics have no existing messages
- `--mode existing` — verifies outbound is reachable; generates new inbound if `--reply`
- Omit `--mode` for private/self-hosted servers where polling may return 401
- `--reply` — auto-generate a reply channel (inbound topic) for this channel
- `--encrypt <key-id>` — encrypt all messages with this key (set key first with `/nfty:key set <id>`)

**Note:** new outbound + existing inbound is not allowed (ambiguous ownership). To add reply
capability to an existing channel, use `/nfty:reply enable <name>`.

## Command to run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" add <name> <url> [description] \
  [--token <tok>] [--mode new|existing] [--reply] [--encrypt <key-id>]
```

Example invocations:
```bash
# New topic, check it's unused, with reply and encryption
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" add alerts https://ntfy.sh/my_alert_topic "Work alerts" \
  --mode new --reply --encrypt main

# Known existing topic, verify reachable
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" add home https://ntfy.sh/home_xyz --mode existing

# Protected topic with auth token
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" add secure https://ntfy.sh/private_abc --token tk_mytoken123
```

After success, tell the user which channel was added, whether it became the default, the reply topic URL (if generated), and how to send a test message:
```
/nfty:send <name> "Test notification"
```
