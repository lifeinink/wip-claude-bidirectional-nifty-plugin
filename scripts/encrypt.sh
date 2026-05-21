#!/usr/bin/env bash
# ntfy-compatible AES-256-GCM encryption / decryption.
# Implements the same protocol as ntfy web and Android apps:
#   base64(PBKDF2-SHA256-salt[16] + AES-GCM-IV[12] + ciphertext+tag)
#
# Usage:
#   encrypt.sh check                       # print status: ok, missing-lib, or no-keys
#   encrypt.sh set-key <key-id>            # interactively store / update a key password
#   encrypt.sh list-keys                   # list configured key IDs
#   encrypt.sh encrypt <key-id> <text>     # output base64 ciphertext (to stdout)
#   encrypt.sh decrypt <key-id> <b64>      # output plaintext (to stdout)

set -euo pipefail

SECRETS="${HOME}/.claude/channels/nfty/secrets.json"

_init_secrets() {
  mkdir -p "$(dirname "$SECRETS")"
  if [ ! -f "$SECRETS" ]; then
    printf '{"keys":[]}\n' > "$SECRETS"
    chmod 600 "$SECRETS"
  fi
}

_check_lib() {
  python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" 2>/dev/null
}

cmd_check() {
  if _check_lib; then
    echo "ok — Python cryptography package available"
  else
    echo "missing-lib — run: pip install cryptography"
    exit 1
  fi
}

cmd_set_key() {
  local key_id="${1:-}"
  [ -z "$key_id" ] && { echo "Error: key-id required" >&2; exit 1; }
  _init_secrets

  # Prompt securely
  local password
  read -r -s -p "Password for key \"$key_id\": " password
  echo
  local confirm
  read -r -s -p "Confirm password: " confirm
  echo
  [ "$password" != "$confirm" ] && { echo "Error: passwords do not match" >&2; exit 1; }
  [ -z "$password" ] && { echo "Error: password cannot be empty" >&2; exit 1; }

  python3 - "$key_id" "$password" <<'PYEOF'
import json, sys, os
key_id, password = sys.argv[1], sys.argv[2]
secrets_path = os.path.expanduser('~/.claude/channels/nfty/secrets.json')
data = json.load(open(secrets_path))
keys = data.setdefault('keys', [])
existing = next((k for k in keys if k['id'] == key_id), None)
if existing:
    existing['password'] = password
    action = 'Updated'
else:
    keys.append({'id': key_id, 'password': password})
    action = 'Stored'
with open(secrets_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
os.chmod(secrets_path, 0o600)
print(f'{action} key "{key_id}"')
PYEOF
}

cmd_list_keys() {
  _init_secrets
  python3 - <<'PYEOF'
import json, os
secrets_path = os.path.expanduser('~/.claude/channels/nfty/secrets.json')
data = json.load(open(secrets_path))
keys = data.get('keys', [])
if not keys:
    print('No keys stored. Use: encrypt.sh set-key <key-id>')
else:
    for k in keys:
        print(k['id'])
PYEOF
}

_get_password() {
  local key_id="$1"
  python3 - "$key_id" <<'PYEOF'
import json, sys, os
key_id = sys.argv[1]
secrets_path = os.path.expanduser('~/.claude/channels/nfty/secrets.json')
if not os.path.exists(secrets_path):
    print(f'Error: secrets file not found — run: /nfty:key set {key_id}', file=sys.stderr)
    sys.exit(1)
data = json.load(open(secrets_path))
key = next((k for k in data.get('keys', []) if k['id'] == key_id), None)
if not key:
    print(f'Error: key "{key_id}" not found — run: /nfty:key set {key_id}', file=sys.stderr)
    sys.exit(1)
print(key['password'], end='')
PYEOF
}

cmd_encrypt() {
  local key_id="${1:-}"
  local plaintext="${2:-}"
  [ -z "$key_id" ]   && { echo "Error: key-id required" >&2; exit 1; }
  [ -z "$plaintext" ] && { echo "Error: plaintext required" >&2; exit 1; }

  local password
  password=$(_get_password "$key_id")

  python3 - "$password" "$plaintext" <<'PYEOF'
import sys, os, base64
password, plaintext = sys.argv[1], sys.argv[2]
try:
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print('Error: pip install cryptography', file=sys.stderr)
    sys.exit(2)
salt = os.urandom(16)
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=50000)
key = kdf.derive(password.encode('utf-8'))
iv = os.urandom(12)
ciphertext = AESGCM(key).encrypt(iv, plaintext.encode('utf-8'), None)
print(base64.b64encode(salt + iv + ciphertext).decode('ascii'))
PYEOF
}

cmd_decrypt() {
  local key_id="${1:-}"
  local b64="${2:-}"
  [ -z "$key_id" ] && { echo "Error: key-id required" >&2; exit 1; }
  [ -z "$b64" ]    && { echo "Error: base64 ciphertext required" >&2; exit 1; }

  local password
  password=$(_get_password "$key_id")

  python3 - "$password" "$b64" <<'PYEOF'
import sys, base64
password, b64 = sys.argv[1], sys.argv[2]
try:
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print('Error: pip install cryptography', file=sys.stderr)
    sys.exit(2)
try:
    raw = base64.b64decode(b64)
except Exception:
    print('Error: invalid base64', file=sys.stderr)
    sys.exit(1)
if len(raw) < 29:
    print('Error: ciphertext too short', file=sys.stderr)
    sys.exit(1)
salt, iv, ciphertext = raw[:16], raw[16:28], raw[28:]
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=50000)
key = kdf.derive(password.encode('utf-8'))
try:
    print(AESGCM(key).decrypt(iv, ciphertext, None).decode('utf-8'), end='')
except Exception:
    print('Error: decryption failed — wrong password or corrupted data', file=sys.stderr)
    sys.exit(1)
PYEOF
}

case "${1:-}" in
  check)    cmd_check ;;
  set-key)  cmd_set_key "${2:-}" ;;
  list-keys) cmd_list_keys ;;
  encrypt)  cmd_encrypt "${2:-}" "${3:-}" ;;
  decrypt)  cmd_decrypt "${2:-}" "${3:-}" ;;
  *)
    echo "Usage: encrypt.sh <check|set-key|list-keys|encrypt|decrypt> [args]"
    exit 1
    ;;
esac
