#!/usr/bin/env bash
# nfty SessionStart hook
# 1. Cleans up expired pending records
# 2. Polls all active pending reply topics for replies received since last session
# 3. Outputs a summary for Claude to surface to the user if replies were found
#
# Cloud Claude Code: hooks timeout at 5 seconds.
# The timeout 4 guard below ensures we never blow that budget.
# On CLI (no 5s limit) the same guard is harmless.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PENDING_SH="${PLUGIN_ROOT}/scripts/pending.sh"
PENDING_DIR="${HOME}/.claude/nfty/pending"

# Nothing to do if no pending dir yet
[ -d "$PENDING_DIR" ] || exit 0

# 1. Cleanup (fast, local I/O only)
bash "$PENDING_SH" cleanup > /dev/null 2>&1 || true

# 2. Count active pendings
active_json=$(bash "$PENDING_SH" list-active 2>/dev/null || echo "No active pending replies.")
count=$(echo "$active_json" | grep -c '^\[nfty_' 2>/dev/null || echo 0)

[ "$count" -eq 0 ] && exit 0

# 3. Poll for replies — hard cap at 4s so we never exceed the cloud hook timeout.
#    On CLI this limit is never reached in practice (each poll is ~1s).
results=$(timeout 4 bash "$PENDING_SH" poll-all 2>/dev/null || echo "(poll timed out — will retry at next session start)")

if echo "$results" | grep -qE '^(REPLY|STOPPER|Reply received)'; then
  echo "=== nfty: pending reply update(s) ==="
  echo "$results"
  echo "====================================="
elif echo "$results" | grep -q "timed out"; then
  # Let Claude know replies couldn't be checked; don't surface if nothing relevant
  echo "nfty: $count pending reply check(s) timed out (cloud hook limit). Use /nfty:check to poll manually."
fi
