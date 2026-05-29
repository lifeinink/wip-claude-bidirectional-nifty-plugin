#!/usr/bin/env bash
# nfty SessionEnd hook
# Stamps all active pending reply records with the session-end timestamp so
# the next session knows where to start polling. Cleans up expired records.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PENDING_SH="${PLUGIN_ROOT}/scripts/pending.sh"
PENDING_DIR="${HOME}/.claude/nfty/pending"

[ -d "$PENDING_DIR" ] || exit 0

# Stamp session end timestamp on all active (unresolved, unexpired) pendings
bash "$PENDING_SH" session-end > /dev/null 2>&1 || true

# Clean up anything that expired during this session
bash "$PENDING_SH" cleanup > /dev/null 2>&1 || true

# Remove session inbox (it's only valid within a session)
rm -f "${HOME}/.claude/nfty/session-inbox.json" 2>/dev/null || true

exit 0
