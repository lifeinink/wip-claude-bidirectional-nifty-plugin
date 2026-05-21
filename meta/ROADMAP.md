# nfty Plugin — Roadmap

## v0.2 (implemented)

- Reply channels: auto-generated inbound topics, per-channel, addable/removable
- `--with-reply` on `send.sh`: action buttons + pending record + cross-session polling
- `SessionStart`/`SessionEnd` hooks for reply tracking and cleanup
- Stopper messages: deprecate a channel from any instance
- AES-256-GCM encryption (ntfy-compatible, Python `cryptography` package)
- `--action-open-session` shorthand for "Open session" view button
- Per-channel `ntfy_ttl` (message TTL), `--ttl` override on send
- Reply expiry shown in NZ local time at send and in `pending list-active`

---

## v0.3 — CLI-only Live Watcher (not yet implemented)

**Cloud Claude Code constraint:** hooks on claude.ai/code timeout at 5 seconds.
A background polling daemon cannot be started or sustained by hooks in cloud sessions.
**This feature must only activate when running Claude Code CLI (local/self-hosted).**

Before implementing, the watcher script must:
- Detect the runtime environment and exit immediately if running on cloud Claude Code
  (check for `CLAUDE_CLOUD` env var, or probe for cloud-specific session signals)
- Refuse to start if the session hook timeout is ≤ 5s (a proxy for cloud detection)
- Self-terminate after a configurable session TTL (default: same as `ntfy_ttl`) so it
  cannot run indefinitely if `$CLOSE` is never sent

### Feature description

Channels can be flagged `watched: true` with an optional `watch_secret`.
At `SessionStart`, a background poller starts for each watched channel and runs until:
- `$CLOSE` (or `$CLOSE <secret>` if configured) is posted to the channel by the user
- The session ends (`SessionEnd` hook kills via PID file)
- The watcher TTL expires (no `$CLOSE` needed — automatic shutdown)

A fast `PostToolUse` hook checks a shared messages file after each tool call and surfaces
any new messages to Claude without re-polling (the daemon does the polling, the hook just
reads a file).

Slash commands needed: `/nfty:watch enable|disable <name> [--secret <s>] [--ttl <secs>]`

---

## v0.4 — Multi-user Channels with Non-repudiation

Enable shared channels where multiple users can send replies, with cryptographic proof
of which user sent what — so Claude (or anyone reviewing an audit log) can verify
identity and no party can falsely deny having sent a reply.

### Core model

Each user in the channel's access list has an **Ed25519 keypair**:
- Private key stays on their device (never transmitted)
- Public key registered in the channel config under `users[].pubkey`

Reply bodies are extended to include an identity assertion and signature:

```
NFTY_REPLY:<pending_id>:<choice>:<user_id>:<base64(Ed25519Sign(private_key, pending_id+":"+choice+":"+user_id))>
```

The plugin verifies the signature on receipt using the user's registered public key.
A reply with an unrecognised or invalid signature is rejected and logged.

### Why Ed25519 (not HMAC)

HMAC-based approaches require Claude to hold the signing key, meaning Claude *could* forge
a reply — non-repudiation is impossible. Ed25519 is asymmetric: only the private key holder
can produce a valid signature, and the public key (known to everyone) is enough to verify it.

### Channel store additions

```json
{
  "users": [
    {
      "id": "patrick",
      "pubkey": "base64(ed25519_public_key)",
      "label": "Patrick O'Keeffe"
    }
  ],
  "require_signed_replies": true,
  "min_approvals": 1
}
```

`min_approvals > 1` enables multi-approval flows (N-of-M): the pending record stays
open until the threshold is reached, collecting signed replies from distinct users.

### Audit log

Resolved pendings with `require_signed_replies: true` write a verification record to
`~/.claude/nfty/audit/<pending_id>.json` containing: message, choices, responding users,
timestamps, and the raw signatures — so the decision is attributable and auditable later.

### Key generation

A `channels.sh gen-user-key <user_id>` command generates an Ed25519 keypair, stores the
private key in `~/.claude/channels/nfty/secrets.json` (chmod 600, alongside encryption
keys), and prints the public key for the channel admin to register.

### Dependencies

Requires `cryptography` Python package (already a dependency for AES-256-GCM encryption).
`from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey`

---

# Future Features

This directory is outside the plugin's skill tree and is not loaded by Claude Code.
It records planned v0.2 work so context isn't lost between sessions.

## v0.2 — Action Buttons

ntfy.sh supports up to 3 action buttons per notification:
- `view` — opens a URL
- `broadcast` — sends an Android broadcast intent
- `http` — makes an HTTP callback (useful for approve/reject workflows)

Implementation: add `--action "view|label|url"` flag to `scripts/send.sh`,
repeated up to 3 times. Document the format in `skills/nfty-send/references/ntfy-schema.md`.

ntfy actions reference: https://docs.ntfy.sh/publish/#action-buttons

## v0.2 — Session Reply Hook (Ephemeral)

For async Claude Code sessions (e.g. cloud runs where the terminal isn't watched),
register a temporary hook at session start that polls the ntfy topic for replies
and surfaces them as Claude Code notifications. The hook must self-delete on `SessionEnd`
so it doesn't persist across unrelated sessions.

Sketch:
- `hooks/hooks.json` with a `SessionStart` command-hook that writes a temp hook file
  into `~/.claude/hooks/` and starts a background polling process
- A `SessionEnd` command-hook that kills the poller and removes the temp hook file
- The polling script GETs `https://ntfy.sh/{topic}/json?poll=1&since=<session-start-unix>`
  and surfaces any replies via `claude notification` or writes to stdout

This is useful when Claude is running a long background task and needs to grab the
user's attention asynchronously without requiring the session to stay open.
