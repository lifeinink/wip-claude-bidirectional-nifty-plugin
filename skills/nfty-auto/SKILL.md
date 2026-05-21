---
name: nfty-auto
description: Automatically send an ntfy.sh notification when Claude completes a long-running task, when the user asks to be notified on task completion, or when the user says phrases like "notify me when done", "send me an ntfy when finished", "ping me via ntfy", or "alert me when complete".
allowed-tools: [Bash]
---

When this skill is triggered, send a notification to the user's default ntfy channel summarising the completed task.

## Behavior

1. **Identify the task** — use the context of what just completed (test run, build, migration, deploy, etc.)
2. **Determine channel** — use the default channel from the store. If the user specified a channel name in their request, use that instead.
3. **Compose the message** — be concise: what ran, outcome (pass/fail/count), and any key detail.
4. **Choose priority** — use `high` (4) for failures or errors, `default` (3) for success.
5. **Send**

## Command

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/send.sh" \
  [-c <channel>] \
  -m "<summary>" \
  -t "<task name>" \
  [-p <priority>]
```

## Example messages

| Scenario | Title | Message | Priority |
|----------|-------|---------|----------|
| Tests passed | "Tests ✅" | "All 47 tests passed in 12.3s" | 3 |
| Tests failed | "Tests ❌" | "3 of 47 tests failed — see output" | 4 |
| Build complete | "Build done" | "Build succeeded, artifact at dist/" | 3 |
| Migration done | "Migration ✅" | "Applied 3 migrations in 2.1s" | 3 |
| Long task done | "Task complete" | "Finished processing 10,000 records" | 3 |

## Non-blocking behaviour after sending

After sending, do NOT wait or poll. Continue with the next task and interleave
naturally. Good patterns:

**When the reply is optional / informational:**
> "Done — I've sent you a summary via ntfy. Continuing with [next step]."

**When the reply determines the next action:**
> "I've sent the approval request. I'll carry on with [safe preliminary work] and check
> for your reply before [consequential step]. If you've already tapped a button, just ask
> me to check now."

**When there's nothing useful to do while waiting:**
> "Notification sent. I'll wait for your reply — use /nfty:check when you've responded,
> or I'll pick it up at the next session start. Reply window: [expiry NZ time]."

**Scheduling a check:** If the user specifies a time ("check in 20 minutes"):
Use `/schedule` to create a one-shot agent that runs `pending.sh poll-all` at that time.
The scheduled agent can optionally send a follow-up ntfy to confirm the result.

## If no channel is configured

Tell the user no default channel is set and prompt them to add one:
```
/nfty:add <name> https://ntfy.sh/<your_topic>
```
Then offer to retry the notification once they've added a channel.
