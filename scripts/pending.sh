#!/usr/bin/env bash
# Pending reply tracking for nfty messages that expect a user response.
# Records are kept in ~/.claude/nfty/pending/<id>.json
# Lifecycle: created → polling → resolved | expired
#
# Usage:
#   pending.sh create <channel> <reply_url> <ttl_seconds> [--encrypt-key <id>]
#                     [--stopper <pattern>] [--token <tok>]
#     Outputs: the generated pending ID
#
#   pending.sh resolve <id> <reply_message>
#   pending.sh session-end                   # stamp session_end_ts on all active pendings
#   pending.sh list-active                   # print JSON array of active (unexpired) pendings
#   pending.sh cleanup                       # delete expired, resolved pendings
#   pending.sh poll-all                      # poll reply URLs for all active pendings; print found replies
#   pending.sh get <id>                      # print a single pending record

set -euo pipefail

PENDING_DIR="${HOME}/.claude/nfty/pending"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLY_POLL_SH="${PLUGIN_ROOT}/scripts/reply-poll.sh"

_init() {
  mkdir -p "$PENDING_DIR"
}

_now_ts() {
  python3 -c "import time; print(int(time.time()))"
}

cmd_create() {
  local channel="${1:-}"
  local reply_url="${2:-}"
  local ttl_seconds="${3:-43200}"
  [ -z "$channel" ]   && { echo "Error: channel required" >&2; exit 1; }
  [ -z "$reply_url" ] && { echo "Error: reply_url required" >&2; exit 1; }

  local encrypt_key="" token="" stopper="" forced_id=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --encrypt-key) encrypt_key="${2:-}"; shift 2 ;;
      --stopper)     stopper="${2:-}";     shift 2 ;;
      --token)       token="${2:-}";       shift 2 ;;
      --id)          forced_id="${2:-}";   shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  _init
  local now
  now=$(_now_ts)
  local id
  if [ -n "$forced_id" ]; then
    id="$forced_id"
  else
    local suffix
    suffix=$(python3 -c "import secrets; print(secrets.token_hex(4))")
    id="nfty_$(date -u +%Y%m%d%H%M%S)_${suffix}"
  fi
  local expires_at=$(( now + ttl_seconds ))

  python3 - "$id" "$channel" "$reply_url" "$ttl_seconds" "$now" "$expires_at" \
            "$encrypt_key" "$token" "$stopper" <<'PYEOF'
import json, sys, os
(id_, channel, reply_url, ttl_seconds, now, expires_at,
 encrypt_key, token, stopper) = sys.argv[1:]
now, expires_at, ttl_seconds = int(now), int(expires_at), int(ttl_seconds)
record = {
    'id': id_,
    'channel': channel,
    'reply_url': reply_url,
    'reply_token': token or None,
    'encrypt_key': encrypt_key or None,
    'stopper': stopper or None,
    'sent_at_ts': now,
    'ttl_seconds': ttl_seconds,
    'expires_at_ts': expires_at,
    'since_ts': now,
    'session_end_ts': None,
    'resolved': False,
    'reply_message': None,
    'reply_received_ts': None,
}
path = os.path.expanduser(f'~/.claude/nfty/pending/{id_}.json')
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    json.dump(record, f, indent=2)
    f.write('\n')
print(id_)
PYEOF
}

cmd_resolve() {
  local id="${1:-}"
  local reply_message="${2:-}"
  [ -z "$id" ] && { echo "Error: id required" >&2; exit 1; }

  local path="${PENDING_DIR}/${id}.json"
  [ ! -f "$path" ] && { echo "Error: pending record $id not found" >&2; exit 1; }

  python3 - "$path" "$reply_message" <<'PYEOF'
import json, sys, time
path, reply_message = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data['resolved'] = True
data['reply_message'] = reply_message
data['reply_received_ts'] = int(time.time())
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Resolved: {data["id"]} → {reply_message!r}')
PYEOF
}

cmd_session_end() {
  _init
  local now
  now=$(_now_ts)

  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    python3 - "$f" "$now" <<'PYEOF'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
data = json.load(open(path))
if not data.get('resolved') and not data.get('session_end_ts'):
    # Update since_ts so next session polls from here
    data['since_ts'] = now
    data['session_end_ts'] = now
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
PYEOF
  done
}

cmd_list_active() {
  _init
  local now
  now=$(_now_ts)

  python3 - "$PENDING_DIR" "$now" <<'PYEOF'
import json, os, sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, k): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)

pending_dir, now = sys.argv[1], int(sys.argv[2])
nz = ZoneInfo('Pacific/Auckland')

def ts_nz(ts):
    dt = datetime.datetime.fromtimestamp(ts, tz=nz)
    return dt.strftime('%Y-%m-%d %H:%M %Z')

def remaining(exp_ts, now):
    secs = exp_ts - now
    if secs <= 0: return 'expired'
    h, rem = divmod(secs, 3600)
    m = rem // 60
    return f'{h}h {m}m remaining' if h else f'{m}m remaining'

active = []
for fname in sorted(os.listdir(pending_dir)):
    if not fname.endswith('.json'):
        continue
    path = os.path.join(pending_dir, fname)
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if not d.get('resolved') and d.get('expires_at_ts', 0) > now:
        active.append(d)

if not active:
    print('No active pending replies.')
    sys.exit(0)

for d in active:
    exp_ts = d.get('expires_at_ts', 0)
    sent_ts = d.get('sent_at_ts', 0)
    print(f"[{d['id']}]")
    print(f"  channel:  {d.get('channel','?')}")
    print(f"  sent:     {ts_nz(sent_ts)}")
    print(f"  expires:  {ts_nz(exp_ts)}  ({remaining(exp_ts, now)})")
    print(f"  status:   {'resolved: ' + repr(d['reply_message']) if d.get('resolved') else 'awaiting reply'}")
    print()
PYEOF
}

cmd_cleanup() {
  _init
  local now
  now=$(_now_ts)

  local removed=0
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    expired=$(python3 - "$f" "$now" <<'PYEOF'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(open(path))
except Exception:
    print('yes')
    sys.exit(0)
if data.get('resolved') or data.get('expires_at_ts', 0) <= now:
    print('yes')
else:
    print('no')
PYEOF
    )
    if [ "$expired" = "yes" ]; then
      rm -f "$f"
      removed=$(( removed + 1 ))
    fi
  done
  echo "Cleaned up $removed expired/resolved pending records"
}

cmd_poll_all() {
  _init
  local now
  now=$(_now_ts)
  local found=0

  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue

    record=$(python3 - "$f" "$now" <<'PYEOF'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
if data.get('resolved') or data.get('expires_at_ts', 0) <= now:
    sys.exit(0)
print(json.dumps(data))
PYEOF
    )
    [ -z "$record" ] && continue

    # Extract fields
    reply_url=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reply_url',''))" <<< "$record")
    since_ts=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('since_ts',''))" <<< "$record")
    encrypt_key=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('encrypt_key') or '')" <<< "$record")
    token=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reply_token') or '')" <<< "$record")
    stopper=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('stopper') or '')" <<< "$record")
    pending_id=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('id',''))" <<< "$record")
    channel=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('channel',''))" <<< "$record")

    [ -z "$reply_url" ] && continue

    poll_args=("$reply_url" "$since_ts")
    [ -n "$token" ]       && poll_args+=(--token "$token")
    [ -n "$encrypt_key" ] && poll_args+=(--encrypt-key "$encrypt_key")
    [ -n "$stopper" ]     && poll_args+=(--stopper "$stopper")

    poll_output=$(bash "$REPLY_POLL_SH" "${poll_args[@]}" 2>/dev/null || true)
    [ -z "$poll_output" ] && continue

    while IFS=$'\t' read -r event corr_id content received_ts; do
      if [ "$event" = "STOP" ]; then
        echo "STOPPER DETECTED for channel \"$channel\" — marking deprecated"
        # Resolve pending and deprecate channel
        bash "${PLUGIN_ROOT}/scripts/pending.sh" resolve "$pending_id" "STOPPER:$content" 2>/dev/null || true
        bash "${PLUGIN_ROOT}/scripts/channels.sh" deprecate "$channel" --no-send 2>/dev/null || true
        found=$(( found + 1 ))
      elif [ "$event" = "REPLY" ]; then
        # Match by correlation ID if present
        if [ -z "$corr_id" ] || [ "$corr_id" = "$pending_id" ]; then
          echo "REPLY for pending $pending_id (channel: $channel): $content"
          bash "${PLUGIN_ROOT}/scripts/pending.sh" resolve "$pending_id" "$content" 2>/dev/null || true
          found=$(( found + 1 ))
        fi
      fi
    done <<< "$poll_output"
  done

  if [ $found -eq 0 ]; then
    echo "No new replies found"
  fi
}

cmd_poll_once() {
  local id="${1:-}"
  [ -z "$id" ] && { echo "Error: pending id required" >&2; exit 1; }
  local path="${PENDING_DIR}/${id}.json"
  [ ! -f "$path" ] && { echo "Error: pending record $id not found" >&2; exit 1; }

  _init
  local now
  now=$(_now_ts)

  local record
  record=$(python3 - "$path" "$now" <<'PYEOF'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
try:
    data = json.load(open(path))
except Exception:
    sys.exit(1)
if data.get('resolved'):
    print('ALREADY_RESOLVED', data.get('reply_message',''))
    sys.exit(0)
if data.get('expires_at_ts', 0) <= now:
    print('EXPIRED')
    sys.exit(0)
import json
print(json.dumps(data))
PYEOF
  )

  # Handle terminal states without polling
  if [[ "$record" == ALREADY_RESOLVED* ]]; then
    reply=$(echo "$record" | cut -d' ' -f2-)
    echo "Already resolved: $reply"
    return 0
  fi
  if [ "$record" = "EXPIRED" ]; then
    echo "Pending record $id has expired — no reply received within the TTL window"
    bash "$PLUGIN_ROOT/scripts/pending.sh" cleanup > /dev/null 2>&1 || true
    return 0
  fi

  reply_url=$(python3  -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reply_url',''))"  <<< "$record")
  since_ts=$(python3   -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('since_ts',''))"   <<< "$record")
  encrypt_key=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('encrypt_key') or '')" <<< "$record")
  token=$(python3      -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reply_token') or '')"  <<< "$record")
  stopper=$(python3    -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('stopper') or '')"      <<< "$record")
  channel=$(python3    -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('channel',''))"         <<< "$record")
  exp_ts=$(python3     -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('expires_at_ts',0))"    <<< "$record")

  [ -z "$reply_url" ] && { echo "Error: no reply URL in pending record" >&2; exit 1; }

  poll_args=("$reply_url" "$since_ts")
  [ -n "$token" ]       && poll_args+=(--token "$token")
  [ -n "$encrypt_key" ] && poll_args+=(--encrypt-key "$encrypt_key")
  [ -n "$stopper" ]     && poll_args+=(--stopper "$stopper")

  poll_output=$(bash "$REPLY_POLL_SH" "${poll_args[@]}" 2>/dev/null || true)

  if [ -z "$poll_output" ]; then
    # Show expiry context so the user knows the window
    expiry_str=$(python3 - "$exp_ts" "$now" <<'PYEOF'
import sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, k): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)
exp_ts, now = int(sys.argv[1]), int(sys.argv[2])
nz = ZoneInfo('Pacific/Auckland')
dt = datetime.datetime.fromtimestamp(exp_ts, tz=nz)
secs = exp_ts - now
if secs > 3600:
    rem = f'{secs // 3600}h {(secs % 3600) // 60}m remaining'
elif secs > 60:
    rem = f'{secs // 60}m remaining'
else:
    rem = f'{secs}s remaining'
print(f'{dt.strftime("%Y-%m-%d %H:%M %Z")} ({rem})')
PYEOF
    )
    echo "No reply yet for $id (channel: $channel)"
    echo "Reply window expires: $expiry_str"
    return 0
  fi

  while IFS=$'\t' read -r event corr_id content received_ts; do
    if [ "$event" = "STOP" ]; then
      echo "STOPPER received on channel \"$channel\" — marking deprecated"
      bash "$PLUGIN_ROOT/scripts/pending.sh" resolve "$id" "STOPPER:$content" 2>/dev/null || true
      bash "$PLUGIN_ROOT/scripts/channels.sh" deprecate "$channel" --no-send 2>/dev/null || true
    elif [ "$event" = "REPLY" ]; then
      if [ -z "$corr_id" ] || [ "$corr_id" = "$id" ]; then
        echo "Reply received: $content"
        bash "$PLUGIN_ROOT/scripts/pending.sh" resolve "$id" "$content" 2>/dev/null || true
      fi
    fi
  done <<< "$poll_output"
}

cmd_get() {
  local id="${1:-}"
  [ -z "$id" ] && { echo "Error: id required" >&2; exit 1; }
  local path="${PENDING_DIR}/${id}.json"
  [ ! -f "$path" ] && { echo "Error: pending record $id not found" >&2; exit 1; }
  cat "$path"
}

case "${1:-}" in
  create)      shift; cmd_create "$@" ;;
  resolve)     cmd_resolve "${2:-}" "${3:-}" ;;
  session-end) cmd_session_end ;;
  list-active) cmd_list_active ;;
  cleanup)     cmd_cleanup ;;
  poll-all)    cmd_poll_all ;;
  poll-once)   cmd_poll_once "${2:-}" ;;
  get)         cmd_get "${2:-}" ;;
  *)
    echo "Usage: pending.sh <create|resolve|session-end|list-active|cleanup|poll-all|poll-once|get>"
    exit 1
    ;;
esac
