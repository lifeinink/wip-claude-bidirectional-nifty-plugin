---
name: nfty-remove
description: Remove a stored ntfy channel from the nfty channel store. Use this skill when the user runs /nfty:remove or asks to delete/unregister an ntfy channel.
argument-hint: <name>
allowed-tools: [Bash]
---

Parse the channel name from the user's argument and remove it from the store.

## Argument format

```
/nfty:remove <name>
```

## Command to run

First confirm the channel exists by listing it, then remove:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" get <name>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" remove <name>
```

If the channel does not exist, report the error and suggest running `/nfty:channels` to see what's stored.

If the removed channel was the default, `channels.sh` automatically promotes the next channel to default — report this to the user so they know which channel is now default.
