#!/usr/bin/env bash
# nfty SessionStart hook
# 1. Cleans up expired pending records
# 2. Polls ALL active reply topics in PARALLEL (not sequential) so N pendings
#    still fit within the cloud hook's 5s budget
# 3. Writes structured results to ~/.claude/nfty/session-inbox.json before
#    printing to stdout — data is safe even if stdout is cut short
# 4. Prints a human-readable summary for Claude to surface at session start
#
# Cloud vs CLI: the 4s total timeout is enforced inside Python so the hook
# process itself exits cleanly. CLI sessions benefit too (faster with many pendings).

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PENDING_SH="${PLUGIN_ROOT}/scripts/pending.sh"
REPLY_POLL_SH="${PLUGIN_ROOT}/scripts/reply-poll.sh"
CHANNELS_SH="${PLUGIN_ROOT}/scripts/channels.sh"
PENDING_DIR="${HOME}/.claude/nfty/pending"
INBOX="${HOME}/.claude/nfty/session-inbox.json"

# Nothing to do if no pending directory
[ -d "$PENDING_DIR" ] || exit 0

# 1. Cleanup expired records (fast, local I/O only)
bash "$PENDING_SH" cleanup > /dev/null 2>&1 || true

# 2. Parallel poll — Python handles concurrency and the hard 4s cap
output=$(python3 - "$PENDING_DIR" "$REPLY_POLL_SH" "$INBOX" "$PLUGIN_ROOT" <<'PYEOF'
import json, os, sys, time, subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

pending_dir, reply_poll_sh, inbox_path, plugin_root = sys.argv[1:]
pending_sh = os.path.join(plugin_root, 'scripts', 'pending.sh')
now = int(time.time())

# Load all active (unresolved, unexpired) pending records with reply URLs
records = []
try:
    entries = os.listdir(pending_dir)
except OSError:
    sys.exit(0)

for fname in sorted(entries):
    if not fname.endswith('.json'):
        continue
    path = os.path.join(pending_dir, fname)
    try:
        data = json.load(open(path))
    except Exception:
        continue
    if data.get('resolved') or data.get('expires_at_ts', 0) <= now:
        continue
    if not data.get('reply_url'):
        continue
    records.append(data)

if not records:
    sys.exit(0)

TOTAL_TIMEOUT = 3.8  # leaves headroom for process startup and inbox write

def poll_one(rec):
    args = ['bash', reply_poll_sh, rec['reply_url'], str(rec.get('since_ts', now))]
    if rec.get('reply_token'):
        args += ['--token', rec['reply_token']]
    if rec.get('encrypt_key'):
        args += ['--encrypt-key', rec['encrypt_key']]
    if rec.get('stopper'):
        args += ['--stopper', rec['stopper']]
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=3.2)
        return rec, result.stdout.strip(), False
    except subprocess.TimeoutExpired:
        return rec, '', True
    except Exception:
        return rec, '', True

poll_results = []
timed_out = []
start = time.time()

with ThreadPoolExecutor(max_workers=max(1, len(records))) as pool:
    futures = {pool.submit(poll_one, rec): rec for rec in records}
    remaining = TOTAL_TIMEOUT - (time.time() - start)
    try:
        for future in as_completed(futures, timeout=max(0.1, remaining)):
            rec, raw_output, did_timeout = future.result(timeout=0)
            poll_results.append((rec, raw_output, did_timeout))
    except Exception:
        # Timeout: whatever finished is in poll_results; the rest timed out
        for f, rec in futures.items():
            if not f.done():
                timed_out.append(rec['id'])
                f.cancel()

# Process replies and resolve pending records
found = []
stoppers = []
for rec, raw_output, did_timeout in poll_results:
    if did_timeout or not raw_output:
        continue
    for line in raw_output.splitlines():
        parts = line.split('\t')
        if not parts:
            continue
        event = parts[0]
        if event == 'REPLY':
            corr_id = parts[1] if len(parts) > 1 else ''
            content  = parts[2] if len(parts) > 2 else ''
            recv_ts  = int(parts[3]) if len(parts) > 3 else now
            if not corr_id or corr_id == rec['id']:
                found.append({
                    'pending_id': rec['id'],
                    'channel': rec.get('channel', ''),
                    'content': content,
                    'received_ts': recv_ts,
                })
                # Resolve the pending record
                subprocess.run(
                    ['bash', pending_sh, 'resolve', rec['id'], content],
                    capture_output=True
                )
        elif event == 'STOP':
            content = parts[1] if len(parts) > 1 else ''
            stoppers.append({'pending_id': rec['id'], 'channel': rec.get('channel', '')})
            subprocess.run(
                ['bash', pending_sh, 'resolve', rec['id'], f'STOPPER:{content}'],
                capture_output=True
            )
            channels_sh = os.path.join(plugin_root, 'scripts', 'channels.sh')
            subprocess.run(
                ['bash', channels_sh, 'deprecate', rec.get('channel', ''), '--no-send'],
                capture_output=True
            )

# Write inbox file — written before any stdout so data survives a truncated hook
inbox = {
    'polled_at': now,
    'timed_out': bool(timed_out),
    'timed_out_ids': timed_out,
    'replies': found,
    'stoppers': stoppers,
}
os.makedirs(os.path.dirname(inbox_path), exist_ok=True)
with open(inbox_path, 'w') as f:
    json.dump(inbox, f, indent=2)
    f.write('\n')

# Print human-readable summary to stdout for Claude
if found or stoppers or timed_out:
    print('=== nfty: session start update ===')
    for r in found:
        print(f"Reply received for pending {r['pending_id']} (channel: {r['channel']}): {r['content']}")
    for s in stoppers:
        print(f"STOPPER received on channel \"{s['channel']}\" — marked deprecated")
    if timed_out:
        n = len(timed_out)
        print(f"{n} pending poll(s) timed out (cloud 5s hook limit). Use /nfty:check to poll manually.")
    print('==================================')
PYEOF
2>/dev/null || true)

# 3. Print whatever the Python script produced (may be empty if no activity)
[ -n "$output" ] && echo "$output"

# 4. If any polls timed out, fire a debug notification (no-op if no debug channel set)
if echo "$output" | grep -q "timed out"; then
  bash "$CHANNELS_SH" debug-send \
    "session-start: poll timeout — some pending replies not checked" \
    --title "nfty poll timeout" --priority 2 2>/dev/null || true
fi

exit 0
