---
name: nfty-send
description: Construct and send an ntfy.sh notification. Use this skill when the user runs /nfty:send or asks to send an ntfy notification, push notification, or ntfy alert.
argument-hint: [channel] [message] [--title text] [--priority 1-5] [--at "YYYY-MM-DD HH:MM"] [--tags tag1,tag2] [--with-reply "A,B"] [--check-at "YYYY-MM-DD HH:MM"] [--markdown] [--action-view "Label" "url"] [--action-broadcast "Label"]
allowed-tools: [Bash]
---

Construct a `send.sh` invocation from the user's arguments and run it.

## Argument handling

The user may provide arguments in natural language or flag form. Interpret them flexibly:

- If no channel is specified, omit `-c` and `send.sh` will use the store's default channel.
- If the message contains markdown (bold, code blocks, lists), add `--markdown` automatically unless the user said plain text.
- If `--at` is provided, it is in **New Zealand local time** (Pacific/Auckland). Pass it through as-is — `send.sh` handles the UTC conversion.
- If the user says "urgent", "critical", or "emergency", map to `--priority 5`.
- If the user says "high priority", map to `--priority 4`.
- If the user says "low priority" or "quiet", map to `--priority 2`.
- If the user says "ask me" / "let me decide" / "wait for my reply", add `--with-reply`.
- If the user provides choices like "approve or reject", add `--with-reply "Approve,Reject"`.

## Command to run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" \
  [-c <channel-name-or-url>] \
  -m "<message>" \
  [-t "<title>"] \
  [-p <priority>] \
  [--tags <tag1,tag2>] \
  [--at "<YYYY-MM-DD HH:MM>"] \
  [--markdown] \
  [--attach <url>] \
  [--icon <url>] \
  [--email <addr>] \
  [--no-cache] \
  [--with-reply ["Choice1,Choice2,..."]] \
  [--check-at "<YYYY-MM-DD HH:MM>"] \
  [--action-view "<Label>" "<url>"] \
  [--action-broadcast "<Label>" [intent=...] [extras.key=val]] \
  [--action-http "<Label>" "<url>" [method=POST]] \
  [--action-open-session "<url>"]
```

## Reply tracking (`--with-reply`)

When `--with-reply` is specified:
1. The channel must have a reply topic enabled (via `/nfty:reply enable <name>`)
2. Each choice becomes an HTTP action button that posts `NFTY_REPLY:<id>:<choice>` to the reply topic
3. A pending record is saved at `~/.claude/nfty/pending/` with a 12h TTL
4. At the next `SessionStart`, pending records are polled — any replies found are surfaced to the user
5. Expired records (beyond ntfy's message TTL) are automatically cleaned up

If the reply is pre-encrypted (channel has `encrypt_key`), the reply body is also pre-encrypted
at send time and baked into the action button. The ntfy server never sees plaintext.

## Action buttons

Up to 3 total (including any auto-added by `--with-reply`).

```bash
# Open a URL when tapped
--action-view "Open dashboard" "https://grafana.example.com/d/abc"

# Open the current Claude Code session (cloud/web)
--action-open-session "https://claude.ai/code/sessions/YOUR_SESSION_ID"

# Send an Android broadcast intent (ntfy app or other Android receiver)
--action-broadcast "Snooze" extras.snooze_duration=10min

# HTTP callback (webhook, approve/reject)
--action-http "Approve" "https://myserver.com/webhooks/approve" method=PUT
```

## After sending

- On success: report delivery confirmation, pending ID if reply tracking enabled
- If `--at` used: confirm NZ time and mention server-side delivery
- If `--with-reply` used: explicitly tell the user when the automatic reply pickup happens:
  > "Reply tracking is active (ID: nfty_…). I'll pick up your reply automatically at the
  > next session start. You can also ask me to check anytime, or I can schedule a check
  > at a specific time — reply window closes [expiry NZ time]."
- Do NOT poll again proactively — one check at session start, or when explicitly asked
- On error: show error, suggest `/nfty:channels` to verify config

## `--check-at` — baked-in scheduled poll

Use `--check-at "YYYY-MM-DD HH:MM"` (NZ time) alongside `--with-reply` to do three
things automatically:

1. Appends `⏰ Reply checked at HH:MM TZ — tap a button before then.` to the message
   body, so the user sees the deadline **inside the ntfy notification on their device**,
   not just in Claude's chat output.
2. Creates the pending record as usual.
3. Emits `SCHEDULE_POLL_AT: <pending_id> <unix_ts> <human_time>` on stdout.

**When you see `SCHEDULE_POLL_AT` in `send.sh` output**, immediately invoke `/schedule`:

```
/schedule "Poll nfty pending reply and report result.
Run: bash ~/.claude/plugins/nfty/scripts/pending.sh poll-once <pending_id>
Report the outcome to the user." at <human_time NZ>
```

This wires up the full loop — the user sees the check time in the notification,
and Claude automatically wakes at that time to poll. No manual follow-up needed.

Example full invocation:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" \
  -c alerts \
  -m "Proceed with production deploy?" \
  -t "Deploy gate" -p 4 \
  --with-reply "Approve,Reject" \
  --check-at "2026-05-23 15:00"
```

Notification body the user receives:
```
Proceed with production deploy?

⏰ Reply checked at 15:00 NZST, 23 May — tap a button before then.
```

## Schedule-then-Poll pattern (manual version)

When `--check-at` wasn't used but the user specifies a time after the fact:
```
/schedule "Poll nfty pending <id> once and report the result. Run:
  bash ~/.claude/plugins/nfty/scripts/pending.sh poll-once <id>" at <NZ time>
```

Always tell the user the full picture after any `--with-reply` send:
> "Sent (pending: `nfty_…`, window closes [expiry NZ]).
> Options: tap + `/nfty:check` now · scheduled check at [time] · auto at next session start"

If the reply IS needed before proceeding, be explicit:
> "I won't continue with [action] until approved. I'll check when you ask,
> or schedule it — window closes [expiry NZ time]."

## Examples

```bash
# Ask user to approve/reject — creates reply tracking record
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" -c alerts \
  -m "Deploy to production ready. Proceed?" -t "Deploy gate" -p 4 \
  --with-reply "Approve,Reject,Snooze"

# Long task completed with session open button
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" -c work \
  -m "Migration complete — 10,432 records processed" -t "✅ Done" \
  --action-open-session "https://claude.ai/code/sessions/abc123"

# Scheduled NZ time
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" -c alerts \
  -m "Reminder: daily backup" --at "2026-06-02 08:00"

# Android broadcast to dismiss from ntfy app
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" -m "New task" \
  --action-broadcast "Dismiss" intent=io.heckel.ntfy.DISMISS
```
