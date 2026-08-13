#!/usr/bin/env bash
# Clear an attention card from the logbook board.
#
# Usage: fm-logbook-resolve.sh <id> [resolved|dismissed]
#
# The board has no dedicated resolve endpoint (the tool drops resolved/dismissed
# items off the board), so a card is cleared by UPSERTING it with a terminal
# status via POST /api/items. The tool runs full validateItem on every upsert, so
# a bare {id, status} body is rejected (HTTP 400: kind/title/project required).
# Therefore this fetches the card's current fields from GET /api/board by id and
# re-POSTs the WHOLE item (project, kind, title, body, options, priority, source)
# with status set to the requested terminal value ("resolved" by default;
# "dismissed" also drops the card). If the id is not on the board (already
# resolved/dismissed, or unknown), there is nothing to clear: that is a clean
# no-op success, not an error. <id> is validated as the tool's safe slug before it
# is used. Both input paths - the captain answering on the board or answering
# firstmate in chat - converge here once firstmate has acted.
#
# This is also the SINGLE WRITER of the settled-card record
# (state/logbook-cleared.json; fm-logbook-lib.sh implements it and
# docs/configuration.md "Board refresh" owns the contract). The board keeps no trace
# of a cleared card that a client can read back: GET /api/board omits resolved and
# dismissed rows, so to a compose-driven writer a cleared card is simply a card the
# board lacks, which it re-adds. Recording the id here, with the content it carried,
# is what keeps the automatic refresh and the session-start sync from putting an
# answered question straight back in front of the captain.
#
# But clearing is not ONE act, and the difference decides whether a record may be
# written at all. A CAPTAIN-ANSWERED clear - the answer loop acting on a board
# response, or firstmate clearing after acting on a decision given in chat - means
# the question is settled, and records. A MECHANICAL clear - bin/fm-logbook-resync.sh
# retiring an owned card purely because the work left the composed set - means
# nothing of the sort, and must NOT record: the same work can come back (a task
# parked to Queued and later resumed composes a byte-identical card), and a record
# written here would hold that returning card off the board for good, which is the
# under-reporting bug this whole surface exists to remove. Callers say which they
# performed by setting LOGBOOK_MECHANICAL_CLEAR; recording is the DEFAULT, because
# every caller other than the refresh is the answer loop.
#
# The record is written only after the clear actually landed, never under LOGBOOK_DRY
# (nothing was cleared), and never at the cost of the clear itself: a record that
# cannot be written is one stderr warning, not a failure.
#
# Honors LOGBOOK_DRY_RUN: with it set (truthy), the composed would-be POST body
# (the full item) is recorded to state/logbook-outbox/<id>.json and no write is
# sent. Composing that faithful body still requires reading the card, so a dry-run
# resolve does perform the read-only GET /api/board (a GET has no side effects);
# it just never upserts. See fm-logbook-lib.sh and AGENTS.md section 15.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

usage() { echo "usage: fm-logbook-resolve.sh <id> [resolved|dismissed]" >&2; }

case "${1:-}" in
  --help|-h) echo "Clear a card by re-upserting its full item with a terminal status (resolved|dismissed); fetches current fields via GET /api/board."; exit 0 ;;
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

BOARD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-board.XXXXXX") || { echo "fm-logbook-resolve: cannot create temp file" >&2; exit 1; }
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-resolve.XXXXXX") || { echo "fm-logbook-resolve: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$BOARD_FILE" "$BODY_FILE"' EXIT

# Read the board to recover the card's current fields. This runs even under
# LOGBOOK_DRY (a GET has no side effects; only the upsert is suppressed) so the
# recorded preview is the exact full item a live resolve would send. A read
# failure (board down, no token, curl missing) is a real error: exit non-zero so
# the answer-loop leaves the inbox file and retries on the next poll.
logbook_get_json /api/board "$BOARD_FILE" >/dev/null || exit 1

# Compose the full valid upsert: the whole item with status overridden. jq prints
# nothing (and exits 0) when the id is not present, so an empty result is the
# clean "already cleared / unknown" no-op. A jq PARSE failure (malformed board
# response) is distinct from "not found" and surfaces as an error.
if ! FULL_ITEM=$(jq -c --arg id "$ID" --arg status "$STATUS" '
      first((.items // [])[] | select(.id == $id))
      | { id, project, kind, title, body, options, priority, source, status: $status }
    ' "$BOARD_FILE" 2>/dev/null); then
  echo "fm-logbook-resolve: could not parse the board response" >&2
  exit 1
fi

if [ -z "$FULL_ITEM" ]; then
  echo "fm-logbook-resolve: item '$ID' is not on the board; nothing to clear (already resolved/dismissed or unknown)" >&2
  exit 0
fi

printf '%s\n' "$FULL_ITEM" > "$BODY_FILE" || { echo "fm-logbook-resolve: failed to write request body" >&2; exit 1; }

logbook_post_json /api/items "$BODY_FILE" "$ID" >/dev/null || exit 1

# The clear landed. Remember it so the compose-driven writers do not re-declare a
# question the captain has settled - unless this clear was MECHANICAL, in which case
# nothing was settled and a record would hold the card down if the same work returned.
# Skipped under LOGBOOK_DRY too, where nothing was actually cleared, and never fatal:
# the clear is the important half, so a record that cannot be written is a warning.
case "$(printf '%s' "${LOGBOOK_MECHANICAL_CLEAR:-}" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|off) MECHANICAL="" ;;
  *) MECHANICAL=1 ;;
esac
if [ -z "$LOGBOOK_DRY" ] && [ -z "$MECHANICAL" ]; then
  logbook_cleared_record "$ID" "$BOARD_FILE" \
    || echo "fm-logbook-resolve: cleared '$ID' but could not record it as settled; an automatic refresh may re-add it" >&2
fi
