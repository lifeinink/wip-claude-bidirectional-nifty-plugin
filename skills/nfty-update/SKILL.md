---
name: nfty-update
description: Update a field on a stored ntfy channel. Use this skill when the user runs /nfty:update or asks to change/edit an ntfy channel's URL, description, or token.
argument-hint: <name> <field> <value>
allowed-tools: [Bash]
---

Parse the user's arguments and call `channels.sh update`.

## Argument format

```
/nfty:update <name> <field> <value>
```

Updatable fields: `url`, `description`, `token`

To clear a field, pass an empty string as the value (e.g. `token ""`).

To change the default channel, use `/nfty:channels` to confirm the name then run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" default <name>
```

## Command to run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" update <name> <field> <value>
```

Example:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" update alerts url https://ntfy.sh/new_topic_abc
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" update alerts description "Production alerts"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" update alerts token tk_newtoken456
```

After success, confirm the updated field to the user.
If the user is trying to change the default channel, use the `default` subcommand instead and explain why.
