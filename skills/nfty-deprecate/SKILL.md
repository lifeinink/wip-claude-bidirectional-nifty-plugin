---
name: nfty-deprecate
description: Deprecate an ntfy channel by sending a stopper message and marking it as deprecated in the store. Use when the user runs /nfty:deprecate or wants to retire/disable a channel permanently.
argument-hint: <channel-name> [--no-send]
allowed-tools: [Bash]
---

Deprecate a stored nfty channel. This:
1. Sends a stopper message to the channel's ntfy topic (so other instances deregister it on next poll)
2. Marks the channel as `deprecated: true` in the store
3. Disables reply if it was enabled

## Command

```bash
# Deprecate and send stopper message to the topic
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" deprecate <name>

# Mark deprecated without sending the stopper (e.g. if topic is already unreachable)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" deprecate <name> --no-send
```

## What a stopper message does

The stopper is a unique secret string stored in the channel config (format: `NFTY_STOP_<name>_<hash>`).
When any nfty plugin instance polls a topic and finds this message, it:
- Refuses to register the channel (during `add --mode existing`)
- Auto-marks an already-registered channel as deprecated
- Resolves any pending replies for that channel

This is useful when:
- A topic has been squatted by someone else
- You're retiring a channel and don't want other sessions to keep using it
- The topic name was accidentally made public

## After deprecating

Tell the user:
- The channel is now marked deprecated and will appear with `[DEPRECATED]` in `/nfty:channels`
- Any running session polling this channel will deregister it when the stopper is found
- They can run `/nfty:remove <name>` to fully delete it from the store
