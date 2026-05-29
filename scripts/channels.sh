#!/usr/bin/env bash
# CRUD for the nfty channel store at ~/.claude/channels/nfty/channels.json
#
# Usage:
#   channels.sh list
#   channels.sh get <name>
#   channels.sh resolve <name|url>
#     → 7 lines: url, token, encrypt_key, reply_url, reply_token, reply_enc_key, ntfy_ttl
#   channels.sh add <name> <url> [desc] [--token <tok>] [--mode new|existing]
#                [--reply] [--encrypt <key-id>] [--ttl <seconds>]
#   channels.sh update <name> <field> <value>
#   channels.sh remove <name>
#   channels.sh default <name>
#   channels.sh enable-reply <name> [--mode new|existing-inbound <url>]
#   channels.sh disable-reply <name>
#   channels.sh deprecate <name> [--no-send]    # mark deprecated (optionally send stopper msg)
#   channels.sh set-debug <url> [--token <tok>] # set global debug channel
#   channels.sh get-debug                       # print debug channel URL (or empty)
#   channels.sh clear-debug                     # remove debug channel config
#   channels.sh debug-send <message> [--title T] [--priority P] [--context C]
#     Post to debug channel. No-op (exit 0) if not configured. Never fails the caller.
#
# Reply channel URL is auto-generated as <base_topic_url>_r<8-hex-random>
# Stopper pattern is auto-generated as NFTY_STOP_<name>_<creation_hash>
# ntfy_ttl (seconds): how long ntfy retains messages on this topic (default 43200 = 12h)
#   Used to set the expiry window on pending replies. Match to your ntfy plan / server config.

set -euo pipefail

STORE="${HOME}/.claude/channels/nfty/channels.json"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENCRYPT_SH="${PLUGIN_ROOT}/scripts/encrypt.sh"
SEND_SH="${PLUGIN_ROOT}/scripts/send.sh"

_init_store() {
  mkdir -p "$(dirname "$STORE")"
  [ -f "$STORE" ] || printf '{"channels":[]}\n' > "$STORE"
}

_py() { python3 -c "$@"; }

_channel_exists() {
  python3 - "$STORE" "$1" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
exists = any(c['name'] == sys.argv[2] for c in data['channels'])
sys.exit(0 if exists else 1)
PYEOF
}

_now_ts() {
  python3 -c "import time; print(int(time.time()))"
}

_now_iso() {
  python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

_generate_reply_url() {
  local base_url="$1"
  local suffix
  suffix=$(python3 -c "import secrets; print(secrets.token_hex(4))")
  # Strip trailing slash
  base_url="${base_url%/}"
  # Extract base topic (last path component) and append _r<suffix>
  local base_topic="${base_url##*/}"
  local base_server="${base_url%/*}"
  echo "${base_server}/${base_topic}_r${suffix}"
}

_generate_stopper() {
  local name="$1"
  local created_iso="$2"
  python3 - "$name" "$created_iso" <<'PYEOF'
import hashlib, sys
name, created_iso = sys.argv[1], sys.argv[2]
digest = hashlib.sha256(f'{name}:{created_iso}'.encode()).hexdigest()[:8]
print(f'NFTY_STOP_{name}_{digest}')
PYEOF
}

_check_topic_unused() {
  local url="$1"
  local token="${2:-}"
  local poll_url="${url}/json?poll=1&limit=1"
  local auth_args=()
  [ -n "$token" ] && auth_args+=(-H "Authorization: Bearer $token")
  local response
  response=$(curl -sf --max-time 5 "${auth_args[@]+"${auth_args[@]}"}" "$poll_url" 2>/dev/null || true)
  if [ -n "$response" ]; then
    echo "Warning: topic $url has existing messages — may already be in use." >&2
    return 1
  fi
  return 0
}

_check_topic_reachable() {
  local url="$1"
  local token="${2:-}"
  local auth_args=()
  [ -n "$token" ] && auth_args+=(-H "Authorization: Bearer $token")
  local http_status
  http_status=$(curl -so /dev/null -w "%{http_code}" --max-time 5 \
    "${auth_args[@]+"${auth_args[@]}"}" "$url" 2>/dev/null || echo "000")
  if [ "$http_status" = "000" ] || [ "$http_status" -lt 100 ]; then
    echo "Error: could not reach $url" >&2
    return 1
  fi
  return 0
}

_check_stopper_at_url() {
  local url="$1"
  local token="${2:-}"
  local stopper="${3:-}"
  local encrypt_key="${4:-}"
  [ -z "$stopper" ] && return 0
  local poll_url="${url}/json?poll=1&limit=10&since=0"
  local auth_args=()
  [ -n "$token" ] && auth_args+=(-H "Authorization: Bearer $token")
  local response
  response=$(curl -sf --max-time 5 "${auth_args[@]+"${auth_args[@]}"}" "$poll_url" 2>/dev/null || true)
  [ -z "$response" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local body
    body=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('message',''))" "$line" 2>/dev/null || true)
    # Attempt decryption if key is configured — stopper may have been sent encrypted
    if [ -n "$encrypt_key" ] && [ -n "$body" ]; then
      local decrypted
      decrypted=$(bash "$ENCRYPT_SH" decrypt "$encrypt_key" "$body" 2>/dev/null || true)
      [ -n "$decrypted" ] && body="$decrypted"
    fi
    if [ "$body" = "$stopper" ]; then
      echo "Stopper message found at $url — this topic has been deprecated." >&2
      return 1
    fi
  done <<< "$response"
  return 0
}

cmd_list() {
  _init_store
  python3 - "$STORE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
channels = data.get('channels', [])
if not channels:
    print('No channels stored. Use: /nfty:add <name> <url>')
    sys.exit(0)
print(f"{'':2}{'NAME':<18} {'REPLY':6} {'ENC':4} {'URL'}")
print('-' * 80)
for c in channels:
    marker = '* ' if c.get('default') else '  '
    reply  = '✓ ' if c.get('reply', {}).get('enabled') else '  '
    enc    = '✓ ' if c.get('encrypt_key') else '  '
    dep    = ' [DEPRECATED]' if c.get('deprecated') else ''
    print(f"{marker}{c['name']:<18} {reply:<6} {enc:<4} {c.get('url','')}{dep}")
PYEOF
}

cmd_get() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  python3 - "$STORE" "$name" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
ch = next((c for c in data['channels'] if c['name'] == sys.argv[2]), None)
if not ch:
    print(f'Error: channel "{sys.argv[2]}" not found', file=sys.stderr)
    sys.exit(1)
display = dict(ch)
if display.get('token'):       display['token'] = '***'
if display.get('encrypt_key'): pass
reply = display.get('reply', {})
if reply.get('token'):         reply['token'] = '***'
print(json.dumps(display, indent=2))
PYEOF
}

cmd_resolve() {
  local name_or_url="${1:-}"
  _init_store
  python3 - "$STORE" "$name_or_url" <<'PYEOF'
import json, sys
store, name_or_url = sys.argv[1], sys.argv[2]
data = json.load(open(store))
channels = data.get('channels', [])
ch = next((c for c in channels if c['name'] == name_or_url), None)
if not ch and not name_or_url:
    ch = next((c for c in channels if c.get('default')), None)
DEFAULT_TTL = 43200
if ch:
    print(ch.get('url', ''))
    print(ch.get('token') or '')
    print(ch.get('encrypt_key') or '')
    reply = ch.get('reply', {})
    if reply.get('enabled'):
        print(reply.get('url', ''))
        print(reply.get('token') or '')
        print(reply.get('encrypt_key') or ch.get('encrypt_key') or '')
    else:
        print(''); print(''); print('')
    print(ch.get('ntfy_ttl', DEFAULT_TTL))   # line 7: TTL in seconds
elif name_or_url and name_or_url.startswith('http'):
    print(name_or_url)
    print(''); print(''); print(''); print(''); print('')
    print(DEFAULT_TTL)
else:
    print(f'Error: channel "{name_or_url}" not found', file=sys.stderr)
    sys.exit(1)
PYEOF
}

cmd_add() {
  local name="${1:-}"
  local url="${2:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  [ -z "$url"  ] && { echo "Error: url required" >&2; exit 1; }

  local description="" token="" mode="" enable_reply=false encrypt_key="" ntfy_ttl="43200"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --token)     token="${2:-}";       shift 2 ;;
      --mode)      mode="${2:-}";        shift 2 ;;
      --reply)     enable_reply=true;    shift ;;
      --encrypt)   encrypt_key="${2:-}"; shift 2 ;;
      --ttl)       ntfy_ttl="${2:-}";    shift 2 ;;
      *)           [ -z "$description" ] && description="$1"; shift ;;
    esac
  done

  _init_store

  if _channel_exists "$name" 2>/dev/null; then
    echo "Error: channel \"$name\" already exists. Use /nfty:update to modify it." >&2; exit 1
  fi

  # Outbound topic verification
  if [ "$mode" = "new" ]; then
    echo "Checking outbound topic..."
    _check_topic_unused "$url" "$token" || exit 1
    echo "Outbound topic appears unused."
  elif [ "$mode" = "existing" ]; then
    echo "Verifying outbound topic..."
    _check_topic_reachable "$url" "$token" || exit 1
    echo "Outbound topic reachable."
  fi

  local created
  created=$(_now_iso)
  local stopper
  stopper=$(_generate_stopper "$name" "$created")

  # Reply channel
  local reply_url="" reply_token="" reply_encrypt_key=""
  if $enable_reply; then
    # New outbound + existing inbound: NOT ALLOWED
    # (Only makes sense to generate a fresh inbound alongside a new outbound,
    #  or add to existing-outbound via enable-reply)
    if [ "$mode" = "existing" ]; then
      # Existing outbound + new inbound
      reply_url=$(_generate_reply_url "$url")
      reply_encrypt_key="${encrypt_key}"
      echo "Generated reply topic: $reply_url"
      if [ "$mode" = "new" ] || true; then
        echo "Checking reply topic..."
        _check_topic_unused "$reply_url" "$reply_token" || {
          echo "Collision generating reply URL — regenerating..." >&2
          reply_url=$(_generate_reply_url "$url")
        }
      fi
    else
      # New outbound + new inbound (default)
      reply_url=$(_generate_reply_url "$url")
      reply_encrypt_key="${encrypt_key}"
      echo "Generated reply topic: $reply_url"
      if [ "$mode" = "new" ]; then
        echo "Checking reply topic..."
        _check_topic_unused "$reply_url" "$reply_token" || {
          reply_url=$(_generate_reply_url "$url")
          echo "Re-generated reply topic: $reply_url"
        }
      fi
    fi
  fi

  # Check stopper on existing outbound
  if [ "$mode" = "existing" ]; then
    _check_stopper_at_url "$url" "$token" "$stopper" "$encrypt_key" || {
      echo "Cannot register: stopper message found on this topic." >&2; exit 1
    }
  fi

  python3 - "$STORE" "$name" "$url" "$description" "$token" "$created" \
            "$encrypt_key" "$reply_url" "$reply_token" "$reply_encrypt_key" "$stopper" "$ntfy_ttl" <<'PYEOF'
import json, sys
(store, name, url, description, token, created,
 encrypt_key, reply_url, reply_token, reply_enc_key, stopper, ntfy_ttl_str) = sys.argv[1:]
ntfy_ttl = int(ntfy_ttl_str) if ntfy_ttl_str.isdigit() else 43200
data = json.load(open(store))

is_default = len(data['channels']) == 0
entry = {
    'name': name,
    'url': url,
    'default': is_default,
    'created': created,
    'ntfy_ttl': ntfy_ttl,
    'stopper': stopper,
    'deprecated': False,
    'deprecated_at': None,
}
if description:   entry['description'] = description
if token:         entry['token'] = token
if encrypt_key:   entry['encrypt_key'] = encrypt_key
if reply_url:
    entry['reply'] = {
        'url': reply_url,
        'token': reply_token or None,
        'encrypt_key': reply_enc_key or encrypt_key or None,
        'enabled': True,
    }
data['channels'].append(entry)
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
note = ' (set as default)' if is_default else ''
ttl_h = ntfy_ttl // 3600
ttl_note = f'\n  Reply window: {ttl_h}h ({ntfy_ttl}s TTL)'
reply_note = f'\n  Reply channel: {reply_url}{ttl_note}' if reply_url else f'\n  TTL: {ttl_h}h'
print(f'Added channel "{name}"{note}{reply_note}')
PYEOF
}

cmd_update() {
  local name="${1:-}" field="${2:-}" value="${3:-}"
  [ -z "$name" ]  && { echo "Error: name required" >&2; exit 1; }
  [ -z "$field" ] && { echo "Error: field required" >&2; exit 1; }

  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  python3 - "$STORE" "$name" "$field" "$value" <<'PYEOF'
import json, sys
store, name, field, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(store))
protected = {'name', 'created', 'default', 'stopper', 'deprecated', 'deprecated_at', 'reply'}
# ntfy_ttl is editable — changing it affects pending TTL for future sends only
if field in protected:
    print(f'Error: "{field}" is managed — use dedicated commands', file=sys.stderr)
    sys.exit(1)
for c in data['channels']:
    if c['name'] == name:
        if value == '':
            c.pop(field, None)
        else:
            c[field] = value
        break
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Updated {name}.{field}')
PYEOF
}

cmd_remove() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  python3 - "$STORE" "$name" <<'PYEOF'
import json, sys
store, name = sys.argv[1], sys.argv[2]
data = json.load(open(store))
was_default = any(c['name'] == name and c.get('default') for c in data['channels'])
data['channels'] = [c for c in data['channels'] if c['name'] != name]
if was_default and data['channels']:
    data['channels'][0]['default'] = True
    extra = f' New default: {data["channels"][0]["name"]}'
else:
    extra = ''
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Removed "{name}".{extra}')
PYEOF
}

cmd_default() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  python3 - "$STORE" "$name" <<'PYEOF'
import json, sys
store, name = sys.argv[1], sys.argv[2]
data = json.load(open(store))
for c in data['channels']:
    c['default'] = (c['name'] == name)
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Default channel set to "{name}"')
PYEOF
}

cmd_enable_reply() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  local mode="new"
  local inbound_url=""
  shift 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --inbound-url) inbound_url="${2:-}"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  # Get current channel URL
  local channel_url
  channel_url=$(python3 - "$STORE" "$name" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
ch = next((c for c in data['channels'] if c['name'] == sys.argv[2]), None)
print(ch.get('url','') if ch else '')
PYEOF
  )

  if [ "$mode" = "new" ]; then
    # Existing outbound + new inbound
    if [ -n "$inbound_url" ]; then
      echo "Error: --mode new generates the inbound URL automatically; don't pass --inbound-url" >&2; exit 1
    fi
    local reply_url
    reply_url=$(_generate_reply_url "$channel_url")
    echo "Generated reply topic: $reply_url"
    _check_topic_unused "$reply_url" "" || {
      reply_url=$(_generate_reply_url "$channel_url")
      echo "Re-generated reply topic: $reply_url"
    }
  elif [ "$mode" = "existing-inbound" ]; then
    # Existing outbound + existing inbound provided by user
    [ -z "$inbound_url" ] && { echo "Error: --inbound-url required for --mode existing-inbound" >&2; exit 1; }
    reply_url="$inbound_url"
    echo "Verifying inbound topic..."
    _check_topic_reachable "$reply_url" "" || exit 1
    echo "Inbound topic reachable."
  else
    echo "Error: --mode must be 'new' or 'existing-inbound'" >&2; exit 1
  fi

  python3 - "$STORE" "$name" "$reply_url" <<'PYEOF'
import json, sys
store, name, reply_url = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(store))
for c in data['channels']:
    if c['name'] == name:
        enc = c.get('encrypt_key')
        c['reply'] = {
            'url': reply_url,
            'token': None,
            'encrypt_key': enc,
            'enabled': True,
        }
        break
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Reply enabled for "{name}" → {reply_url}')
PYEOF
}

cmd_disable_reply() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  python3 - "$STORE" "$name" <<'PYEOF'
import json, sys
store, name = sys.argv[1], sys.argv[2]
data = json.load(open(store))
for c in data['channels']:
    if c['name'] == name:
        if 'reply' in c:
            c['reply']['enabled'] = False
        break
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Reply disabled for "{name}"')
PYEOF
}

cmd_deprecate() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "Error: name required" >&2; exit 1; }
  _init_store
  _channel_exists "$name" || { echo "Error: channel \"$name\" not found" >&2; exit 1; }

  local no_send=false
  shift 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-send) no_send=true; shift ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  # Get channel info
  local channel_url stopper encrypt_key token
  channel_url=$(python3 - "$STORE" "$name" "url"      <<'PYEOF'
import json,sys; d=json.load(open(sys.argv[1])); ch=next((c for c in d['channels'] if c['name']==sys.argv[2]),None); print(ch.get(sys.argv[3],'') if ch else '')
PYEOF
  )
  stopper=$(python3 - "$STORE" "$name" "stopper" <<'PYEOF'
import json,sys; d=json.load(open(sys.argv[1])); ch=next((c for c in d['channels'] if c['name']==sys.argv[2]),None); print(ch.get(sys.argv[3],'') if ch else '')
PYEOF
  )
  encrypt_key=$(python3 - "$STORE" "$name" "encrypt_key" <<'PYEOF'
import json,sys; d=json.load(open(sys.argv[1])); ch=next((c for c in d['channels'] if c['name']==sys.argv[2]),None); print(ch.get(sys.argv[3],'') if ch else '')
PYEOF
  )
  token=$(python3 - "$STORE" "$name" "token" <<'PYEOF'
import json,sys; d=json.load(open(sys.argv[1])); ch=next((c for c in d['channels'] if c['name']==sys.argv[2]),None); print(ch.get(sys.argv[3],'') if ch else '')
PYEOF
  )

  # Send stopper message to the topic — always encrypted if channel has a key
  # (stopper is a channel integrity signal; encrypting it prevents an intruder
  #  from triggering deregistration by posting the plaintext stopper pattern)
  if ! $no_send && [ -n "$channel_url" ] && [ -n "$stopper" ]; then
    echo "Sending stopper message to $channel_url ..."
    local send_args=(-c "$channel_url" -m "$stopper")
    [ -n "$token" ]       && send_args+=(-H "Authorization: Bearer $token")
    [ -n "$encrypt_key" ] && send_args+=(--encrypt)
    bash "$SEND_SH" "${send_args[@]}" 2>/dev/null && echo "Stopper sent." || echo "Warning: could not send stopper message." >&2
  fi

  # Mark deprecated in store
  local now
  now=$(_now_iso)
  python3 - "$STORE" "$name" "$now" <<'PYEOF'
import json, sys
store, name, now = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(store))
for c in data['channels']:
    if c['name'] == name:
        c['deprecated'] = True
        c['deprecated_at'] = now
        if 'reply' in c:
            c['reply']['enabled'] = False
        break
with open(store, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print(f'Channel "{name}" marked as deprecated.')
PYEOF
}

cmd_set_debug() {
  local url="${1:-}"
  [ -z "$url" ] && { echo "Error: debug channel URL required" >&2; exit 1; }
  local token=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --token) token="${2:-}"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  _init_store
  python3 - "$STORE" "$url" "$token" <<'PYEOF'
import json, sys
store, url, token = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(store))
data['debug_channel'] = {'url': url, 'token': token or None}
with open(store, 'w') as f:
    json.dump(data, f, indent=2); f.write('\n')
print(f'Debug channel set: {url}')
PYEOF
}

cmd_get_debug() {
  _init_store
  python3 - "$STORE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
dc = data.get('debug_channel')
print(dc['url'] if dc else '')
PYEOF
}

cmd_clear_debug() {
  _init_store
  python3 - "$STORE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
data.pop('debug_channel', None)
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2); f.write('\n')
print('Debug channel cleared.')
PYEOF
}

cmd_debug_send() {
  # No-op if debug channel is not configured — never fails the caller
  local message="${1:-}"
  [ -z "$message" ] && return 0
  local title="nfty debug" priority="2" context=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)    title="${2:-}";   shift 2 ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --context)  context="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Read debug channel config
  local debug_url debug_token
  debug_url=$(python3 - "$STORE" <<'PYEOF'
import json, sys, os
store = sys.argv[1]
if not os.path.exists(store): print(''); sys.exit(0)
data = json.load(open(store))
dc = data.get('debug_channel')
print(dc['url'] if dc else '')
PYEOF
  ) 2>/dev/null || return 0
  [ -z "$debug_url" ] && return 0

  debug_token=$(python3 - "$STORE" <<'PYEOF'
import json, sys, os
store = sys.argv[1]
if not os.path.exists(store): print(''); sys.exit(0)
data = json.load(open(store))
dc = data.get('debug_channel', {})
print(dc.get('token') or '')
PYEOF
  ) 2>/dev/null || true

  # Append context if provided
  [ -n "$context" ] && message="${message}

Context: ${context}"

  local curl_args=(-s -o /dev/null -w "%{http_code}"
    -H "Title: ${title}"
    -H "Priority: ${priority}"
    -H "Tags: warning"
    -d "$message")
  [ -n "$debug_token" ] && curl_args+=(-H "Authorization: Bearer ${debug_token}")

  curl "${curl_args[@]}" "$debug_url" > /dev/null 2>&1 || true
}

case "${1:-}" in
  list)           cmd_list ;;
  get)            cmd_get "${2:-}" ;;
  resolve)        cmd_resolve "${2:-}" ;;
  add)            shift; cmd_add "$@" ;;
  update)         cmd_update "${2:-}" "${3:-}" "${4:-}" ;;
  remove)         cmd_remove "${2:-}" ;;
  default)        cmd_default "${2:-}" ;;
  enable-reply)   shift; cmd_enable_reply "$@" ;;
  disable-reply)  cmd_disable_reply "${2:-}" ;;
  deprecate)      shift; cmd_deprecate "$@" ;;
  set-debug)      shift; cmd_set_debug "$@" ;;
  get-debug)      cmd_get_debug ;;
  clear-debug)    cmd_clear_debug ;;
  debug-send)     shift; cmd_debug_send "$@" ;;
  *)
    echo "Usage: channels.sh <command> [args]"
    echo "Commands: list, get, resolve, add, update, remove, default,"
    echo "          enable-reply, disable-reply, deprecate,"
    echo "          set-debug, get-debug, clear-debug, debug-send"
    exit 1
    ;;
esac
