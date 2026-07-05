#!/usr/bin/env bash
# Acknowledge a delivered board response so the connector stops offering it.
#
# Usage: fm-logbook-ack.sh <response_id>
#
# This is the Phase 2 mirror of fm-x-dismiss.sh: when logbook-respond has acted on
# a captain's answer, it acks the response so the board's connector marks it
# delivered and GET /api/connector/poll stops re-offering it. Delivery is
# at-least-once, so an ack is the client's "I have handled this" signal; it is
# idempotent, so re-acking a response the board already dropped is harmless.
#
# POSTs {"response_id":"<id>"} to $LOGBOOK_URL/api/connector/ack with the bearer
# token (streamed via a file, never on the command line). <response_id> is
# validated as the tool's safe slug before it is used. On success it echoes ONLY
# the response_id; on a non-2xx (or transport failure) it exits non-zero so the
# caller knows the ack did not land and can leave the inbox file for a later pass.
#
# Honors LOGBOOK_DRY_RUN like the other logbook client scripts: with it set
# (truthy), the would-be POST body {response_id} is recorded to
# state/logbook-outbox/<response_id>.json and nothing is sent (needs neither a
# token nor the board). See fm-logbook-lib.sh and AGENTS.md section 15.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

usage() { echo "usage: fm-logbook-ack.sh <response_id>" >&2; }

case "${1:-}" in
  --help|-h) echo "Ack a delivered board response via POST /api/connector/ack {response_id}."; exit 0 ;;
esac

RESPONSE_ID=${1:-}
if [ -z "$RESPONSE_ID" ] || [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

logbook_load_config
# The response_id becomes a filename (dry-run outbox record) and a body field, so
# never trust it into a path even though the board issues it.
if ! logbook_valid_id "$RESPONSE_ID"; then
  echo "fm-logbook-ack: unsafe response_id: $RESPONSE_ID" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-ack: jq not found" >&2; exit 1; }

# Build the body with jq so the response_id is correctly JSON-escaped. This is
# exactly what is POSTed (and, in dry-run, exactly what is recorded).
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-ack.XXXXXX") || { echo "fm-logbook-ack: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$BODY_FILE"' EXIT
jq -cn --arg rid "$RESPONSE_ID" '{response_id:$rid}' > "$BODY_FILE" || {
  echo "fm-logbook-ack: failed to build request body" >&2; exit 1; }

# logbook_post_json handles the dry-run record, the bearer-via-file live POST, and
# the 2xx check. The outbox record is keyed by the response_id so each ack preview
# is preserved on a multi-answer drain.
logbook_post_json /api/connector/ack "$BODY_FILE" "$RESPONSE_ID" >/dev/null || exit 1
printf '%s\n' "$RESPONSE_ID"
