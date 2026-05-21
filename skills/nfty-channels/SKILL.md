---
name: nfty-channels
description: List all stored ntfy.sh channels in the nfty channel store. Use this skill when the user runs /nfty:channels or asks to see stored ntfy channels.
argument-hint: ""
allowed-tools: [Bash]
---

Run the following command and display the results to the user:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" list
```

If no channels are stored yet, tell the user they can add one with:
```
/nfty:add <name> <url> [description] [--token <token>] [--mode new|existing]
```

Example:
```
/nfty:add my-alerts https://ntfy.sh/my_topic_abc123 "General alerts"
```

The `*` in the output marks the default channel (used when no channel is specified in `/nfty:send`).
