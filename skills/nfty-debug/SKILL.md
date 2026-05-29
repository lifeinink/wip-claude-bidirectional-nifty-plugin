---
name: nfty-debug
description: Manage the nfty global debug channel — a single ntfy topic that receives error and warning events from all plugin instances. Use this skill when the user runs /nfty:debug or asks to set up, test, or clear the debug channel.
argument-hint: <set <url> [--token tok] | clear | status | test>
allowed-tools: [Bash]
---

The debug channel is a single global ntfy topic that all plugin scripts post error
events to. It surfaces failures from any Claude Code instance (including other projects)
in real time — encryption errors, channel-not-found, poll timeouts, stoppers detected.

## Commands

### set
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" set-debug <url> [--token <tok>]
```
Stores the debug channel URL globally. All scripts will post errors here from now on.
Suggest the user use a private topic: `https://ntfy.sh/nfty_debug_<random>`.

### clear
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" clear-debug
```

### status
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" get-debug
```
Prints the current debug URL, or empty if not configured.

### test
Send a test message to confirm the debug channel is working:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" debug-send \
  "nfty debug channel test — if you see this, it's working." \
  --title "nfty debug test" --priority 3
```

## After setting

Confirm the URL is reachable and the test notification arrived.
Remind the user that the debug channel fires automatically — no further setup needed.
All errors from any instance (other projects, cloud sessions) will appear there.

## Notes

- `debug-send` is always `|| true` — a debug failure never blocks the main operation
- Priority 2 (low) for informational events, 3 (default) for errors
- The `--context` flag on `debug-send` adds structured detail below the main message
- Debug messages are plaintext (never encrypted) so they're readable without setup
