#!/usr/bin/env bash
# fm-captain-hold.sh - hold an existing backlog item for the captain, with a deadline.
#
# This is firstmate's path for a main-side thread that is waiting on the captain
# and is not an investigation's or visual review's decision: a pending choice, a
# relay reminder, anything worth durable tracking under AGENTS.md section 10.
# bin/fm-decision-hold.sh owns the decision path and its identities; this script
# owns nothing but the hold itself.
#
# It exists so the deadline is not an option nobody passes. tasks-axi has carried
# `hold --until` all along and every reader downstream renders and lapses it, yet
# no hold firstmate had ever written carried one. tasks-axi has no configuration
# surface for a default (.tasks.toml configures only the markdown backend's path,
# archive and retention) and forking it is not on the table, so the default lives
# in the one wrapper both firstmate hold paths go through. The rule and the
# window are owned by bin/fm-captain-hold-lib.sh.
#
# Usage:
#   fm-captain-hold.sh <id> --reason <reason> [--hold-until <YYYY-MM-DD>|none]
#
# The item must already exist; create it with `tasks-axi add` first. Holding is
# idempotent: a deadline the clock has not reached is kept as it is, so a repeat
# cannot quietly shorten a window the captain was already given. Repeating it on
# a lapsed hold reactivates it with a fresh deadline, which is how firstmate
# re-asks a question that went unanswered.
#
# --hold-until overrides the default date. --hold-until none writes no deadline
# at all, for a genuinely open-ended question; it is the rare case, because a
# hold with no deadline is a question that can never stop competing with the ones
# the captain has not seen yet.
#
# Lapse is demotion, never deletion: past the deadline the row stops gating
# dispatch and keeps its hold reason, kind and date, so it is still a captain
# hold with an answer owed. Use `tasks-axi unhold` to actually release one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-captain-hold-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-captain-hold-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
[ -n "$ID" ] || { usage >&2; exit 2; }
shift

REASON=''
HOLD_UNTIL=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) shift; REASON=${1:-} ;;
    --hold-until) shift; HOLD_UNTIL=${1:-} ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$ID" in
  ''|*[!A-Za-z0-9._-]*) fail "task id must be a non-empty privacy-safe slug: $ID" ;;
esac
[ -n "$REASON" ] || fail "--reason is required"
case "$REASON" in
  *$'\n'*|*$'\r'*) fail "--reason must be one line" ;;
  *'('*|*')'*) fail "--reason must not contain parentheses (tasks-axi hold contract)" ;;
esac

REJECT=$(fm_captain_hold_until_reject "$HOLD_UNTIL")
[ -z "$REJECT" ] || fail "$REJECT"

fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
HOLD_HELP=$(tasks-axi hold --help 2>&1) || fail "tasks-axi does not expose the hold contract"
printf '%s\n' "$HOLD_HELP" | grep -F -- '--kind captain' >/dev/null \
  || fail "tasks-axi does not expose the captain-hold contract"
printf '%s\n' "$HOLD_HELP" | grep -F -- '--until' >/dev/null \
  || fail "tasks-axi does not expose the hold deadline contract"

SHOW=$(tasks_axi show "$ID" --full 2>/dev/null) \
  || fail "backlog item $ID does not exist in $FM_HOME/data/backlog.md; create it with tasks-axi add first"
EXISTING_UNTIL=$(printf '%s\n' "$SHOW" | sed -n 's/^  hold_until: //p' | head -1)

# An explicit deadline always wins. Otherwise a deadline the clock has not
# reached is kept, so re-holding cannot silently shorten a window the captain was
# already given; a lapsed or deadline-free hold takes the default, which is how a
# re-ask puts a fresh clock on it.
if [ -z "$HOLD_UNTIL" ] && fm_captain_hold_until_is_future "$EXISTING_UNTIL"; then
  UNTIL_DATE=$EXISTING_UNTIL
else
  UNTIL_DATE=$(fm_captain_hold_resolve_until "$HOLD_UNTIL") \
    || fail "could not compute the default captain-hold deadline"
fi

if [ -n "$UNTIL_DATE" ]; then
  tasks_axi hold "$ID" --reason "$REASON" --kind captain --until "$UNTIL_DATE" >/dev/null \
    || fail "could not hold $ID for the captain"
  printf 'held: %s until %s\n' "$ID" "$UNTIL_DATE"
else
  tasks_axi hold "$ID" --reason "$REASON" --kind captain >/dev/null \
    || fail "could not hold $ID for the captain"
  printf 'held: %s with no deadline\n' "$ID"
fi
