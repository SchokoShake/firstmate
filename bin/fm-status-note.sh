#!/usr/bin/env bash
# fm-status-note.sh - append firstmate's own line to a task's status log without waking firstmate.
#
# Usage:
#   fm-status-note.sh <task-id> <text...>
#   fm-status-note.sh --resolve <key> <task-id> <how it was resolved...>
#
# The first form appends `note: firstmate: <text>`, a memo firstmate leaves in
# a task's log. The second appends `resolved [key=<key>]: firstmate: <text>`,
# closing an open decision or blocker by hand without sending the worker
# anything; it refuses unless <key> is open in that log right now, and refuses a
# reserved key whose owning library is its only closer. To close a decision by
# answering the worker, use `fm-send.sh --resolve-key` instead.
#
# Firstmate writes such a line in the very turn it already has the content, so
# it must not come back as a new wake. The append goes through
# fm_wake_status_append_self_announced (bin/fm-wake-lib.sh), the one owner of
# that guard: it hides only the bytes this command appended, and when any
# earlier byte in the log is still unannounced it leaves the whole log for the
# watcher, so a worker's line is never swallowed. Every line a worker appends
# still wakes firstmate exactly as before. The drain's UNREAD STATUS section
# still lists a `note:` line once, because that presentation is not a wake.
#
# The `firstmate:` text prefix marks the line's provenance for later readers.
# A task's current state skips `note: firstmate:` lines (last_status_line in
# bin/fm-classify-lib.sh), so a memo never masks the worker's last line; a
# `--resolve` line is a real state change and stays current, as with
# fm-send.sh --resolve-key.
# Newlines, tabs, and other control characters in <text> become spaces or are
# dropped, so one call always writes exactly one line.
#
# The task must already have a status log in this home (FM_STATE_OVERRIDE, else
# $FM_HOME/state). Exit 0 when the line was appended, whether hidden or left
# for the watcher (stderr says which); 1 when refused or the append failed; 2
# on a usage error (no task id).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-status-note: %s\n' "$*" >&2
  exit 1
}

RESOLVE_KEY=''
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --resolve)
    [ "$#" -ge 2 ] || fail "--resolve requires a key"
    RESOLVE_KEY=$2
    shift 2
    ;;
esac

ID=${1:-}
[ -n "$ID" ] || { usage >&2; exit 2; }
shift
case "$ID" in
  -*|*[!A-Za-z0-9._-]*) fail "task id must be a non-empty slug: $ID" ;;
esac

TEXT=$(printf '%s' "$*" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
TEXT=${TEXT#"${TEXT%%[![:space:]]*}"}
TEXT=${TEXT%"${TEXT##*[![:space:]]}"}
[ -n "$TEXT" ] || fail "the note text is empty"

STATUS_FILE="$STATE/$ID.status"
[ -f "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ] \
  || fail "no status log for task '$ID' in this home ($STATUS_FILE)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ -n "$RESOLVE_KEY" ]; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  _fm_decision_slug_ok "$RESOLVE_KEY" || fail "--resolve key must be a slug of A-Za-z0-9._-: $RESOLVE_KEY"
  LINE="${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT} [key=$RESOLVE_KEY]: firstmate: $TEXT"
  _fm_decision_key_transition_allowed "$RESOLVE_KEY" "$(status_line_note "$LINE")" \
    || fail "key '$RESOLVE_KEY' is reserved for the library that opened it; only that owner closes it"
  open_set=$(status_open_decisions "$STATUS_FILE")
  case "$open_set" in
    "$RESOLVE_KEY"$'\t'*|*$'\n'"$RESOLVE_KEY"$'\t'*) ;;
    *) fail "no open decision or blocker with key '$RESOLVE_KEY' in $STATUS_FILE (already closed, mistyped, or transferred); nothing was written" ;;
  esac
else
  LINE="note: firstmate: $TEXT"
fi

rc=0
fm_wake_status_append_self_announced "$STATE" "$STATUS_FILE" "$LINE" || rc=$?
case "$rc" in
  0) ;;
  1) printf 'fm-status-note: appended; %s already had unannounced lines, so monitoring will still surface it\n' "$STATUS_FILE" >&2 ;;
  *) fail "could not append to $STATUS_FILE" ;;
esac
