#!/usr/bin/env bash
# fm-ready.sh - firstmate's dispatchable-now set: the one answer to "what work
# can be picked up right now?".
#
# `tasks-axi ready` offers a lapsed captain hold as work anyone may start, and
# forking tasks-axi is out of bounds, so firstmate withholds it on its own side.
# Every firstmate reader of dispatchable work goes through this path and never
# through raw `tasks-axi ready`: an agent at a prompt runs this script, and
# bin/fm-session-start.sh's digest calls the same fm_captain_hold_ready.
#
# Only a lapsed CAPTAIN hold is withheld. A lapsed hold of any other kind is a
# time gate that opened, which is how that work becomes startable.
#
# WITHHOLDING IS PRESENTATION ONLY. Nothing here closes, unholds, resolves,
# deletes or rewrites a hold. The withheld count is disclosed on its own line
# with a query carrying the SAME backlog this run filtered, so it resolves from
# any directory and for a --file or FM_DATA_OVERRIDE home.
#
# Usage:
#   fm-ready.sh [--file <backlog-path>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

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
  printf 'fm-ready: %s\n' "$*" >&2
  exit 1
}

BACKLOG="$DATA/backlog.md"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --file)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      BACKLOG=$2
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -f "$BACKLOG" ] || fail "no backlog to read at $BACKLOG"
fm_tasks_axi_compatible || fail "compatible tasks-axi is required"

READY=$(fm_captain_hold_ready "$BACKLOG" \
  "each is still an unanswered captain hold, shown in session start's held group and by tasks-axi list --file $BACKLOG --state queued --fields hold_kind,hold_until,held") \
  || fail "could not read the dispatchable set from $BACKLOG: $READY"
printf '%s\n' "$READY"
