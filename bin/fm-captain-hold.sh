#!/usr/bin/env bash
# fm-captain-hold.sh - hold an existing backlog item for the captain, with a deadline.
#
# Firstmate's path for a main-side thread waiting on the captain that is not an
# investigation's or visual review's decision (AGENTS.md section 10);
# bin/fm-decision-hold.sh owns that path and its identities. The default deadline
# lives in this wrapper because tasks-axi has no configuration surface for one:
# .tasks.toml configures only the markdown backend's path, archive and retention.
#
# Usage:
#   fm-captain-hold.sh <id> --reason <reason> [--hold-until <YYYY-MM-DD>|none]
#
# The item must already exist and must still be open; create it with
# `tasks-axi add` first. bin/fm-captain-hold-lib.sh owns the default window,
# `--hold-until`, the `none` opt-out, and what lapsing does and does not mean.
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
# Without the count check, a flag typed as the last token dies on `shift 2`
# under `set -e` with no diagnostic.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason|--hold-until)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --reason) REASON=$2 ;;
        *) HOLD_UNTIL=$2 ;;
      esac
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
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
REJECT=$(fm_captain_hold_contract_reject)
[ -z "$REJECT" ] || fail "$REJECT"

SHOW=$(tasks_axi show "$ID" --full 2>/dev/null) \
  || fail "backlog item $ID does not exist in $FM_HOME/data/backlog.md; create it with tasks-axi add first"
show_field() {  # <field>
  printf '%s\n' "$SHOW" | sed -n "s/^  $1: //p" | head -1
}
# tasks-axi would hold a done row too, and no surface shows one to the captain.
STATE=$(show_field state)
[ "$STATE" != "done" ] \
  || fail "backlog item $ID is already done; hold a new item for a new captain question"

UNTIL_DATE=$(fm_captain_hold_effective_until "$HOLD_UNTIL" "$(show_field hold_until)") \
  || fail "could not compute the default captain-hold deadline"
fm_captain_hold_write "$ID" "$REASON" "$UNTIL_DATE" \
  || fail "could not hold $ID for the captain"
if [ -n "$UNTIL_DATE" ]; then
  printf 'held: %s until %s\n' "$ID" "$UNTIL_DATE"
else
  printf 'held: %s with no deadline\n' "$ID"
fi
