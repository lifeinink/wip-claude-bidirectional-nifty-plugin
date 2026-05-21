---
name: nfty-check
description: Check right now for replies to pending nfty notifications. Use when the user asks to "check for a reply", "see if they responded", "poll ntfy", or "any reply yet?". Also use proactively before taking a consequential action that was pending user approval via ntfy.
argument-hint: [pending-id|channel]
allowed-tools: [Bash]
---

Poll pending nfty reply records once, right now. A single poll returns immediately
(ntfy `?poll=1` is non-blocking). No looping, no busy-waiting.

## Behaviour

1. If a specific pending ID or channel is given, poll only that record.
2. Otherwise poll all active (unexpired, unresolved) pending records.
3. Report results, including the expiry time in NZ for any still-awaiting records.

## Commands

```bash
# Poll all active pending records (fast — one curl call per record)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending.sh" poll-all

# Poll a single record by ID
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending.sh" poll-once <pending-id>

# List what's pending (with expiry times in NZ) without polling
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pending.sh" list-active
```

## On cloud Claude Code (5-second hook limit)

**The reply TTL shown to the user (e.g. "12h window") is the ntfy server retention period —
it is NOT the hook timeout. The 5s limit only constrains how long a hook can run, not
how long ntfy retains messages.**

What this means in practice:
- The `SessionStart` hook polls automatically but is capped at 4s to stay safe on cloud.
  If multiple pending records exist, some may not be polled at session start.
- Within a session, there is no automatic mid-session polling on cloud.
- Use `/nfty:check` when you want a manual poll.
- Use `/schedule` to schedule a one-shot poll at a specific time (see below).

## Guidance for Claude: when to check and when NOT to

**Do NOT:**
- Poll repeatedly in a loop waiting for a reply ("has there been a reply? checking... still no reply... checking again...")
- Proactively poll after every tool call
- Block other work while waiting — there is no blocking wait, only on-demand checks

**DO:**
- Poll once explicitly when asked
- Poll once before taking a consequential action that was pending approval:
  > "Before I deploy, let me check if you've approved the notification I sent."
- After completing a natural unit of work, offer a non-intrusive check:
  > "I've finished the migration. Want me to check if there's been a reply to the approval request?"

## Schedule-then-Poll pattern

The canonical way to check for a reply at a specific time without busy-waiting:

**Step 1 — send with reply tracking:**
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" -c alerts \
  -m "Proceed with deploy?" --with-reply "Approve,Reject"
# Output includes: pending ID and reply window expiry (NZ time)
```

**Step 2 — schedule the poll:**
```
/schedule "Poll nfty pending reply <id> and report the result. Run:
  bash ~/.claude/plugins/nfty/scripts/pending.sh poll-once <id>
If resolved, state the reply. If still awaiting, note the expiry time." at <NZ time>
```

**Step 3 — continue working.** No waiting. The scheduled agent wakes, polls once
(instant), and reports back. Claude is free to do other things in the meantime.

**Optionally:** have the scheduled agent send a follow-up ntfy if a reply was found:
```
/schedule "Poll nfty pending <id>. If resolved, send a confirmation via
  /nfty:send -m 'Reply received: <choice>'. If not, do nothing." at <NZ time>
```

This pattern works identically on cloud and CLI — the scheduled agent is a remote
Claude Code instance that isn't subject to session hook limits.

**Natural phrasing to trigger this pattern:**
> "Check for a reply in 20 minutes"
> "Come back to this in an hour"
> "I'll respond before 3pm"

When you hear these, propose the pattern explicitly: state the pending ID, expiry,
and scheduled check time so the user can see the full picture.

## After a reply is found

Once a pending record is resolved:
1. Report the reply content and which pending ID it resolved
2. Continue with whatever action was waiting on that approval
3. The pending file is automatically cleaned up
