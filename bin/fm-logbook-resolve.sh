#!/usr/bin/env bash
# Clear an attention card from the logbook board.
#
# Usage: fm-logbook-resolve.sh <id> [resolved|dismissed]
#
# The board has no dedicated resolve endpoint (the tool drops resolved/dismissed
# items), so a card is cleared by UPSERTING the item with a terminal status. This
# posts {id, status} to POST /api/items, with status defaulting to "resolved"
# ("dismissed" also drops the card). <id> is validated as the tool's safe slug
# before it is used. Both input paths - the captain answering on the board (a later
# phase) or answering firstmate in chat - converge here once firstmate has acted.
#
# Honors LOGBOOK_DRY_RUN: with it set (truthy), the would-be POST body is recorded
# to state/logbook-outbox/<id>.json and nothing is sent (needs neither a token nor
# the board). See fm-logbook-lib.sh and AGENTS.md section 15.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

usage() { echo "usage: fm-logbook-resolve.sh <id> [resolved|dismissed]" >&2; }

case "${1:-}" in
  --help|-h) echo "Clear a card by upserting {id, status} (resolved|dismissed) via POST /api/items."; exit 0 ;;
esac

ID=${1:-}
STATUS=${2:-resolved}
if [ -z "$ID" ]; then usage; exit 2; fi
case "$STATUS" in
  resolved|dismissed) ;;
  *) echo "fm-logbook-resolve: status must be 'resolved' or 'dismissed' (got: $STATUS)" >&2; exit 2 ;;
esac

logbook_load_config
if ! logbook_valid_id "$ID"; then
  echo "fm-logbook-resolve: unsafe item id: $ID" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-resolve: jq not found" >&2; exit 1; }

# Build the body with jq so id/status are correctly JSON-escaped.
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-resolve.XXXXXX") || { echo "fm-logbook-resolve: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$BODY_FILE"' EXIT
jq -cn --arg id "$ID" --arg status "$STATUS" '{id:$id, status:$status}' > "$BODY_FILE" || {
  echo "fm-logbook-resolve: failed to build request body" >&2; exit 1; }

logbook_post_json /api/items "$BODY_FILE" "$ID" >/dev/null || exit 1
