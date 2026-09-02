#!/usr/bin/env bash
# fm-ready.sh - firstmate's dispatchable-now set: the one answer to "what work
# can be picked up right now?".
#
# `tasks-axi ready` is the tool's own answer, and it counts a lapsed captain hold
# as dispatchable. Past a hold's deadline tasks-axi reports the row `held: no`
# while keeping hold_reason, hold_kind and hold_until on it, drops it from
# `--state held`, and offers it in `ready` as work anyone may start. A lapsed
# hold is still a question the captain owes an answer on, so handing it to a
# dispatcher is the one thing lapsing must never mean.
#
# Forking or patching tasks-axi is out of bounds, so `ready` keeps returning the
# lapsed row and firstmate withholds it on its own side. This script is where an
# agent at a prompt does that, and bin/fm-captain-hold-lib.sh's
# fm_captain_hold_ready underneath it is where bin/fm-session-start.sh's startup
# digest does. Nothing in firstmate may read raw `tasks-axi ready` instead, so
# the rule holds at every reader rather than in whichever one remembered it.
#
# WITHHOLDING IS PRESENTATION ONLY. Nothing here closes, unholds, resolves,
# deletes or rewrites a hold. What is withheld is counted on its own line rather
# than dropped silently, and it stays visible as a still-held row: session
# start's digest lists it beside the held group marked lapsed, and
# `tasks-axi show <id> --full` still reports its reason, kind and deadline.
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

READY=$(fm_captain_hold_ready "$BACKLOG") \
  || fail "could not read the dispatchable set from $BACKLOG: $READY"
printf '%s\n' "$READY"
