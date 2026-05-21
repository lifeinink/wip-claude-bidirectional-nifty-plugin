---
name: nfty-key
description: Manage encryption keys for the nfty plugin. Use when the user runs /nfty:key or asks to set up, update, or list encryption passwords for ntfy channels.
argument-hint: <set|list|check> [key-id]
allowed-tools: [Bash]
---

Manage ntfy-compatible AES-256-GCM encryption keys used by the nfty plugin.

Keys are stored in `~/.claude/channels/nfty/secrets.json` (chmod 600).
Each channel can reference a key by ID. Multiple channels can share one key.

## ntfy Encryption Protocol

The plugin implements the same encryption protocol as the ntfy web app and Android app:
- Key derivation: PBKDF2(password, random-salt-16b, 50000 iterations, SHA-256) → 32-byte key
- Encryption: AES-256-GCM with a random 12-byte IV
- Format: base64(salt[16] + iv[12] + ciphertext + auth-tag[16])

Requires the Python `cryptography` package. Install if needed: `pip install cryptography`

## Commands

### Check encryption availability

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/encrypt.sh" check
```

### Set (or update) a key password

This is interactive — prompts for the password twice (not echoed to terminal):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/encrypt.sh" set-key <key-id>
```

Recommended key IDs: `main` (shared across channels), or per-channel names like `work`, `home`.

### List stored key IDs

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/encrypt.sh" list-keys
```

### Assign an encryption key to a channel

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/channels.sh" update <channel-name> encrypt_key <key-id>
```

## Setting up encryption on a new channel

```
/nfty:key set main          ← set the password
/nfty:add alerts https://ntfy.sh/my_topic --encrypt main --reply --mode new
```

All messages sent to that channel will be encrypted before leaving this device.
The ntfy app will show them as encrypted unless the app also knows the password.

## Key sharing vs per-channel keys

- **Shared key** (`main`): simpler, one password for all channels. Good for personal use.
- **Per-channel key**: stronger isolation — a compromised key only affects one channel.

There is no mechanism to rotate keys (changing a key means all historical messages
cannot be decrypted with the new key). To rotate, create a new channel with a new key
and deprecate the old one.
