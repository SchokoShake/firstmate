#!/usr/bin/env bash
# Declaratively reconcile the whole logbook board in one shot.
#
# Usage: fm-logbook-sync.sh --json-file <path>
#        fm-logbook-sync.sh -                     (read the JSON body from stdin)
#        cat board.json | fm-logbook-sync.sh
#
# The body is a {projects?, items?} object, matching the tool's POST /api/sync
# contract: a collection present in the body becomes exactly that set (absent
# members are deleted), an omitted collection is left untouched, and an empty array
# clears it. This is firstmate's session-start truth-restore, so the board is
# accurate even after a restart. The body is passed via file or stdin and NEVER
# inlined into a shell argument, mirroring fm-x-reply.sh; it is validated as JSON
# before posting.
#
# Honors LOGBOOK_DRY_RUN: with it set (truthy), the would-be POST body is recorded
# to state/logbook-outbox/sync.json and nothing is sent (needs neither a token nor
# the board). See fm-logbook-lib.sh and AGENTS.md section 15.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

usage() { echo "usage: fm-logbook-sync.sh --json-file <path> | -" >&2; }

case "${1:-}" in
  --help|-h) echo "Declarative full board reconcile via POST /api/sync {projects?, items?}. Body from --json-file <path> or stdin."; exit 0 ;;
esac

SRC=-
case "${1:-}" in
  ''|-) SRC=- ;;
  --json-file)
    [ -n "${2:-}" ] || { usage; exit 2; }
    SRC=$2 ;;
  *) usage; exit 2 ;;
esac

logbook_load_config
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-sync: jq not found" >&2; exit 1; }

# Slurp the body so we can validate it parses as JSON before posting.
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-sync.XXXXXX") || { echo "fm-logbook-sync: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$BODY_FILE"' EXIT
if [ "$SRC" = "-" ]; then
  cat > "$BODY_FILE" || { echo "fm-logbook-sync: cannot read body from stdin" >&2; exit 1; }
else
  cat -- "$SRC" > "$BODY_FILE" || { echo "fm-logbook-sync: cannot read body file: $SRC" >&2; exit 1; }
fi
jq -e . "$BODY_FILE" >/dev/null 2>&1 || { echo "fm-logbook-sync: body is not valid JSON" >&2; exit 1; }

logbook_post_json /api/sync "$BODY_FILE" sync >/dev/null || exit 1
