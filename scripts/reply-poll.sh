#!/usr/bin/env bash
# Poll an ntfy reply topic for messages since a given Unix timestamp.
# Detects stopper messages and handles decryption.
#
# Usage:
#   reply-poll.sh <reply_url> <since_ts> [--token <tok>] [--encrypt-key <key-id>]
#                 [--stopper <pattern>]
#
# Outputs (tab-separated, one line per relevant message):
#   REPLY  <msg_id_or_none>  <content>  <received_ts>
#   STOP   <content>         <received_ts>
#
# Exit codes: 0 = ok (may have no output), 1 = error

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENCRYPT_SH="${PLUGIN_ROOT}/scripts/encrypt.sh"

reply_url="${1:-}"
since_ts="${2:-}"
[ -z "$reply_url" ] && { echo "Error: reply_url required" >&2; exit 1; }
[ -z "$since_ts" ]  && { echo "Error: since_ts required" >&2; exit 1; }

token=""
encrypt_key=""
stopper_pattern=""

shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --token)       token="${2:-}";          shift 2 ;;
    --encrypt-key) encrypt_key="${2:-}";    shift 2 ;;
    --stopper)     stopper_pattern="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Build the poll URL
poll_url="${reply_url}/json?poll=1&since=${since_ts}&limit=20"

curl_args=(-sf --max-time 3)
[ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")

raw_response=$(curl "${curl_args[@]}" "$poll_url" 2>/dev/null || true)
[ -z "$raw_response" ] && exit 0

# ntfy returns one JSON object per line in the response body
while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Parse message fields with Python
  result=$(python3 - "$line" "$encrypt_key" "$stopper_pattern" "$ENCRYPT_SH" <<'PYEOF'
import json, sys, subprocess, os

line, encrypt_key, stopper_pattern, enc_sh = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    msg = json.loads(line)
except json.JSONDecodeError:
    sys.exit(0)

event = msg.get('event', '')
if event not in ('message', ''):
    sys.exit(0)

body = msg.get('message', '')
received_ts = msg.get('time', 0)
msg_id = msg.get('id', '')

# Attempt decryption if key is provided
if encrypt_key and body:
    try:
        result = subprocess.run(
            ['bash', enc_sh, 'decrypt', encrypt_key, body],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            body = result.stdout
    except Exception:
        pass  # Leave body as-is if decryption fails

body = body.strip()

# Stopper check
if stopper_pattern and body == stopper_pattern:
    print(f'STOP\t{body}\t{received_ts}')
    sys.exit(0)

# Reply correlation ID check: "NFTY_REPLY:<pending_id>:<choice>"
if body.startswith('NFTY_REPLY:'):
    parts = body.split(':', 2)
    pending_id = parts[1] if len(parts) > 1 else ''
    choice = parts[2] if len(parts) > 2 else body
    print(f'REPLY\t{pending_id}\t{choice}\t{received_ts}')
else:
    # Freeform reply (user manually sent a message to reply topic)
    print(f'REPLY\t\t{body}\t{received_ts}')
PYEOF
  )
  [ -n "$result" ] && echo "$result"
done <<< "$raw_response"
