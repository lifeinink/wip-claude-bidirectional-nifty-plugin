#!/usr/bin/env bash
# Send an ntfy.sh notification.
# Resolves channel names from the nfty channel store, converts NZ scheduled
# times to UTC for server-side delayed delivery (no need to keep session running).
# Supports encryption (ntfy-compatible AES-256-GCM) and reply tracking.
#
# Usage:
#   send.sh -c <channel-name-or-url> -m <message> [options]
#
# Options:
#   -c, --channel   <name|url>      Channel name (from store) or direct ntfy URL
#   -m, --message   <text>          Message body (required)
#   -t, --title     <text>          Notification title
#   -p, --priority  <1-5|name>      Priority: min(1) low(2) default(3) high(4) urgent(5)
#       --tags      <t1,t2,...>     Comma-separated tags/emoji shortcodes
#       --at        "YYYY-MM-DD HH:MM"  Schedule delivery at this NZ local time
#       --attach    <url>           URL of file to attach
#       --icon      <url>           Notification icon URL
#       --email     <addr>          Forward notification to email
#       --markdown                  Render message body as CommonMark markdown
#       --no-cache                  Do not cache on ntfy server
#       --with-reply [choices]      Enable reply tracking; choices = comma-separated
#                                   button labels (default: "Acknowledge").
#                                   Adds action buttons to reply topic and creates
#                                   a pending record for cross-session follow-up.
#       --ttl <seconds>             Override the reply window TTL (default: channel's
#                                   ntfy_ttl, fallback 43200 = 12h). Must match the
#                                   ntfy server's actual message retention period.
#       --check-at "YYYY-MM-DD HH:MM"  NZ time when Claude will poll for the reply.
#                                   Appends "⏰ Reply checked at <time>" to the
#                                   message body so the user sees it in the ntfy app.
#                                   Also emits SCHEDULE_POLL_AT on stdout for the
#                                   skill layer to wire up /schedule automatically.
#                                   Requires --with-reply.
#       --action-view       "Label" "url"          View-URL action button
#       --action-http       "Label" "url" [key=val ...]  HTTP callback button
#       --action-broadcast  "Label" [intent=...] [extras.key=val]  Android broadcast
#       --action-open-session <url>  Shorthand: add "Open session" view button
#
# Exit codes: 0 = success, 1 = error

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNELS_SH="${PLUGIN_ROOT}/scripts/channels.sh"
ENCRYPT_SH="${PLUGIN_ROOT}/scripts/encrypt.sh"
PENDING_SH="${PLUGIN_ROOT}/scripts/pending.sh"

channel=""
message=""
title=""
priority=""
tags=""
at_nz=""
attach=""
icon=""
email=""
markdown=false
no_cache=false
with_reply=""         # empty = no reply; non-empty = comma-separated choices
ttl_override=""       # override reply window TTL in seconds
check_at_nz=""        # NZ time to schedule the reply poll (requires --with-reply)
encrypt=false         # opt-in: use channel's encrypt_key to encrypt this send
actions=()

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--channel)   channel="${2:-}";   shift 2 ;;
    -m|--message)   message="${2:-}";   shift 2 ;;
    -t|--title)     title="${2:-}";     shift 2 ;;
    -p|--priority)  priority="${2:-}";  shift 2 ;;
    --tags)         tags="${2:-}";      shift 2 ;;
    --at)           at_nz="${2:-}";     shift 2 ;;
    --attach)       attach="${2:-}";    shift 2 ;;
    --icon)         icon="${2:-}";      shift 2 ;;
    --email)        email="${2:-}";     shift 2 ;;
    --markdown)     markdown=true;      shift ;;
    --no-cache)     no_cache=true;      shift ;;
    --ttl)          ttl_override="${2:-}"; shift 2 ;;
    --check-at)     check_at_nz="${2:-}";  shift 2 ;;
    --encrypt)      encrypt=true;          shift ;;
    --with-reply)
      # Optional comma-separated choices follow if the next arg doesn't start with --
      if [ $# -gt 1 ] && [[ "${2:-}" != --* ]]; then
        with_reply="${2:-}"; shift 2
      else
        with_reply="Acknowledge"; shift
      fi
      ;;
    --action-view)
      _av_label="${2:-}"; _av_url="${3:-}"
      [ -z "$_av_label" ] && { echo "Error: --action-view requires <label> <url>" >&2; exit 1; }
      actions+=("view, $_av_label, $_av_url"); shift 3 ;;
    --action-http)
      _ah_label="${2:-}"; _ah_url="${3:-}"
      [ -z "$_ah_label" ] && { echo "Error: --action-http requires <label> <url>" >&2; exit 1; }
      shift 3
      _ah_extras=""
      while [ $# -gt 0 ] && [[ "$1" == method=* || "$1" == body=* || "$1" == headers.* ]]; do
        _ah_extras="${_ah_extras:+$_ah_extras, }$1"; shift
      done
      actions+=("http, $_ah_label, $_ah_url${_ah_extras:+, $_ah_extras}") ;;
    --action-broadcast)
      _ab_label="${2:-}"
      [ -z "$_ab_label" ] && { echo "Error: --action-broadcast requires <label>" >&2; exit 1; }
      shift 2
      _ab_extras=""
      while [ $# -gt 0 ] && [[ "$1" == intent=* || "$1" == extras.* ]]; do
        _ab_extras="${_ab_extras:+$_ab_extras, }$1"; shift
      done
      actions+=("broadcast, $_ab_label${_ab_extras:+, $_ab_extras}") ;;
    --action-open-session)
      _sess_url="${2:-}"
      [ -z "$_sess_url" ] && { echo "Error: --action-open-session requires <url>" >&2; exit 1; }
      actions+=("view, Open session, $_sess_url"); shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -z "$message" ] && { echo "Error: --message is required" >&2; exit 1; }

# Resolve channel → url, token, encrypt_key, reply_url, reply_token, reply_enc_key
if [ -z "$channel" ]; then
  resolved=$(bash "$CHANNELS_SH" resolve "" 2>/dev/null) || {
    echo "Error: no channel specified and no default channel in store." >&2
    echo "Run: /nfty:add <name> <url>" >&2
    exit 1
  }
else
  resolved=$(bash "$CHANNELS_SH" resolve "$channel" 2>/dev/null) || {
    echo "Error: channel \"$channel\" not found. Run /nfty:channels to see stored channels." >&2
    exit 1
  }
fi

ntfy_url=$(          echo "$resolved" | sed -n '1p')
ntfy_token=$(        echo "$resolved" | sed -n '2p')
ntfy_enc_key=$(      echo "$resolved" | sed -n '3p')
ntfy_reply_url=$(    echo "$resolved" | sed -n '4p')
ntfy_reply_token=$(  echo "$resolved" | sed -n '5p')
ntfy_reply_enc_key=$(echo "$resolved" | sed -n '6p')
ntfy_channel_ttl=$(  echo "$resolved" | sed -n '7p')
ntfy_channel_ttl="${ntfy_channel_ttl:-43200}"

# Effective TTL: per-send override wins, else channel TTL, else 12h default
effective_ttl="${ttl_override:-$ntfy_channel_ttl}"

[ -z "$ntfy_url" ] && { echo "Error: could not resolve channel URL" >&2; exit 1; }

# --- Reply tracking setup ---
pending_id=""
if [ -n "$with_reply" ]; then
  [ -z "$ntfy_reply_url" ] && {
    echo "Error: channel has no reply topic. Run /nfty:reply enable <name> first." >&2; exit 1
  }

  # Generate pending ID for correlation
  pending_id=$(python3 -c "
import time, secrets
print('nfty_' + time.strftime('%Y%m%d%H%M%S', time.gmtime()) + '_' + secrets.token_hex(4))
")

  # Build reply action buttons (one per choice)
  IFS=',' read -ra choices <<< "$with_reply"
  for choice in "${choices[@]}"; do
    choice="${choice# }"; choice="${choice% }"
    reply_body="NFTY_REPLY:${pending_id}:${choice}"

    # Pre-encrypt the reply body if --encrypt and reply topic has a key
    if $encrypt && [ -n "$ntfy_reply_enc_key" ]; then
      reply_body=$(bash "$ENCRYPT_SH" encrypt "$ntfy_reply_enc_key" "$reply_body" 2>/dev/null) || {
        echo "Warning: could not encrypt reply body for choice \"$choice\"; sending unencrypted" >&2
        reply_body="NFTY_REPLY:${pending_id}:${choice}"
      }
    fi

    action_str="http, $choice, $ntfy_reply_url, method=POST, body=$reply_body"
    [ -n "$ntfy_reply_token" ] && action_str="${action_str}, headers.Authorization=Bearer $ntfy_reply_token"
    actions+=("$action_str")
  done
fi

# --- Bake check-at time into message body ---
check_at_ts=""
check_at_human=""
if [ -n "$check_at_nz" ]; then
  [ -z "$with_reply" ] && { echo "Error: --check-at requires --with-reply" >&2; exit 1; }
  read -r check_at_ts check_at_human < <(python3 - "$check_at_nz" <<'PYEOF'
import sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, k): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)
nz = ZoneInfo('Pacific/Auckland')
raw = sys.argv[1]
for fmt in ('%Y-%m-%d %H:%M', '%Y-%m-%d %H:%M:%S', '%d/%m/%Y %H:%M'):
    try:
        dt = datetime.datetime.strptime(raw, fmt)
        break
    except ValueError:
        continue
else:
    print(f'Error: cannot parse "{raw}"', file=sys.stderr); sys.exit(1)
dt_nz = dt.replace(tzinfo=nz)
now_utc = datetime.datetime.now(datetime.timezone.utc)
unix_ts = int(dt_nz.timestamp())
if unix_ts <= int(now_utc.timestamp()):
    print(f'Error: --check-at time "{raw}" (NZ) is in the past', file=sys.stderr); sys.exit(1)
human = dt_nz.strftime('%H:%M %Z, %-d %b')
print(unix_ts, human)
PYEOF
  )
  # Append to message — visible in ntfy app without needing to open Claude
  message="${message}

⏰ Reply checked at ${check_at_human} — tap a button before then."
fi

# --- Encryption of outbound message (opt-in via --encrypt) ---
if $encrypt && [ -n "$ntfy_enc_key" ]; then
  encrypted=$(bash "$ENCRYPT_SH" encrypt "$ntfy_enc_key" "$message" 2>/dev/null) || {
    echo "Error: message encryption failed — check encrypt.sh set-key $ntfy_enc_key" >&2; exit 1
  }
  message="$encrypted"
  # Encrypted messages are base64; disable markdown if it was auto-set
  markdown=false
fi

# --- NZ scheduled time → Unix timestamp ---
delay_header=""
if [ -n "$at_nz" ]; then
  delay_ts=$(python3 - "$at_nz" <<'PYEOF'
import sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, key): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)
nz = ZoneInfo('Pacific/Auckland')
raw = sys.argv[1]
for fmt in ('%Y-%m-%d %H:%M', '%Y-%m-%d %H:%M:%S', '%d/%m/%Y %H:%M', '%d %b %Y %H:%M'):
    try:
        dt = datetime.datetime.strptime(raw, fmt)
        break
    except ValueError:
        continue
else:
    print(f'Error: could not parse date "{raw}". Use YYYY-MM-DD HH:MM', file=sys.stderr)
    sys.exit(1)
dt_nz = dt.replace(tzinfo=nz)
now_utc = datetime.datetime.now(datetime.timezone.utc)
unix_ts = int(dt_nz.timestamp())
if unix_ts <= int(now_utc.timestamp()):
    print(f'Error: scheduled time "{raw}" (NZ) is in the past', file=sys.stderr)
    sys.exit(1)
print(unix_ts)
PYEOF
  )
  delay_header="$delay_ts"
fi

# --- Priority normalisation ---
if [ -n "$priority" ]; then
  case "$priority" in
    1|min)        priority="min" ;;
    2|low)        priority="low" ;;
    3|default)    priority="default" ;;
    4|high)       priority="high" ;;
    5|urgent|max) priority="urgent" ;;
    *) echo "Warning: unknown priority \"$priority\", using default" >&2; priority="default" ;;
  esac
fi

# --- Build curl command ---
curl_args=(-sf -o /dev/null -w "%{http_code}" -X POST)

[ -n "$ntfy_token" ]   && curl_args+=(-H "Authorization: Bearer $ntfy_token")
[ -n "$title" ]        && curl_args+=(-H "Title: $title")
[ -n "$priority" ]     && curl_args+=(-H "Priority: $priority")
[ -n "$tags" ]         && curl_args+=(-H "Tags: $tags")
[ -n "$delay_header" ] && curl_args+=(-H "Delay: $delay_header")
[ -n "$attach" ]       && curl_args+=(-H "Attach: $attach")
[ -n "$icon" ]         && curl_args+=(-H "Icon: $icon")
[ -n "$email" ]        && curl_args+=(-H "X-Email: $email")
$markdown              && curl_args+=(-H "Markdown: yes")
$no_cache              && curl_args+=(-H "Cache: no")

for action in "${actions[@]+"${actions[@]}"}"; do
  curl_args+=(-H "Actions: $action")
done

curl_args+=(-d "$message" "$ntfy_url")

http_status=$(curl "${curl_args[@]}" 2>&1)
exit_code=$?

if [ $exit_code -ne 0 ] || [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
  echo "Error: ntfy request failed (HTTP $http_status)" >&2; exit 1
fi

# --- Post-send: create pending record if reply requested ---
if [ -n "$with_reply" ] && [ -n "$pending_id" ] && [ -n "$ntfy_reply_url" ]; then
  pending_args=("${channel:-}" "$ntfy_reply_url" "$effective_ttl")
  $encrypt && [ -n "$ntfy_reply_enc_key" ] && pending_args+=(--encrypt-key "$ntfy_reply_enc_key")
  [ -n "$ntfy_reply_token" ]   && pending_args+=(--token "$ntfy_reply_token")
  # Get stopper from channel store (only when referencing by name, not bare URL)
  if [ -n "$channel" ] && [[ "$channel" != http* ]]; then
    stopper=$(python3 - "$channel" <<'PYEOF'
import json, sys, os
store = os.path.expanduser('~/.claude/channels/nfty/channels.json')
if not os.path.exists(store):
    sys.exit(0)
data = json.load(open(store))
ch = next((c for c in data['channels'] if c['name'] == sys.argv[1]), None)
print(ch.get('stopper','') if ch else '')
PYEOF
    ) 2>/dev/null || stopper=""
    [ -n "$stopper" ] && pending_args+=(--stopper "$stopper")
  fi
  pending_args+=(--id "$pending_id")
  bash "$PENDING_SH" create "${pending_args[@]}" > /dev/null 2>&1 || true

  # Report expiry in NZ local time
  expiry_nz=$(python3 - "$effective_ttl" <<'PYEOF'
import sys, time, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, key): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)
ttl = int(sys.argv[1])
now = int(time.time())
expires_ts = now + ttl
nz = ZoneInfo('Pacific/Auckland')
dt = datetime.datetime.fromtimestamp(expires_ts, tz=nz)
h, m = divmod(ttl // 60, 60)
window = f'{h}h' if m == 0 else f'{h}h {m}m'
print(f'{dt.strftime("%Y-%m-%d %H:%M %Z")} ({window} window)')
PYEOF
  )
  echo "Reply tracking: $pending_id"
  echo "Reply window:   expires $expiry_nz"
  # Emit schedule signal for the skill layer to wire up /schedule
  if [ -n "$check_at_ts" ] && [ -n "$check_at_human" ]; then
    echo "SCHEDULE_POLL_AT: $pending_id $check_at_ts $check_at_human"
  fi
fi

# --- Output ---
if [ -n "$delay_header" ]; then
  human_time=$(python3 - "$delay_header" <<'PYEOF'
import sys, datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    class ZoneInfo:
        def __init__(self, key): pass
        def utcoffset(self, dt):
            import datetime as dt_mod
            return dt_mod.timedelta(hours=13 if dt.month in (10,11,12,1,2,3,4) else 12)
ts = int(sys.argv[1])
nz = ZoneInfo('Pacific/Auckland')
dt = datetime.datetime.fromtimestamp(ts, tz=nz)
print(dt.strftime('%Y-%m-%d %H:%M %Z'))
PYEOF
  )
  echo "Scheduled: delivery at $human_time (NZ) — server-side, session can close"
else
  echo "Sent: notification delivered to $ntfy_url"
fi
