---
name: nfty-reply
description: Enable or disable the reply channel on a stored ntfy channel, or check pending replies. Use when the user runs /nfty:reply or asks to enable/disable reply tracking on an ntfy channel.
argument-hint: <enable|disable|status> <channel-name> [--mode new|existing-inbound <url>]
allowed-tools: [Bash]
---

Manage the reply capability of a stored nfty channel.

## Commands

### Enable reply on a channel

```bash
# Generate a new inbound reply topic automatically
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" enable-reply <name> --mode new

# Use an existing inbound topic
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" enable-reply <name> --mode existing-inbound "https://ntfy.sh/existing_reply_topic"
```

**Allowed modes:**
| Scenario | Mode |
|----------|------|
| Fresh channel, both topics new | Use `add --reply --mode new` at creation time |
| Existing outbound + new inbound | `enable-reply <name> --mode new` |
| Existing outbound + existing inbound | `enable-reply <name> --mode existing-inbound <url>` |
| New outbound + existing inbound | **Not allowed** — ambiguous ownership |

### Disable reply

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" disable-reply <name>
```

This stops reply tracking for future messages. Existing pending records are unaffected.

### Check pending replies (status)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending.sh" list-active
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending.sh" poll-all
```

## After enabling

Tell the user:
- What their reply topic URL is (run `channels.sh get <name>` and show the reply.url)
- That sending with `--with-reply` will now auto-add action buttons
- Example: `/nfty:send <name> "Approve or reject?" --with-reply "Approve,Reject"`
