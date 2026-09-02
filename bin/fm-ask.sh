#!/usr/bin/env bash
# fm-ask.sh - read a captain-held row's question identity, and re-ask deliberately.
#
# bin/fm-ask-lib.sh owns the identity form and the revision ledger; this script is
# the only writer of that ledger and the one command that re-asks. AGENTS.md
# section 10 carries the rule.
#
# Usage:
#   fm-ask.sh id <task-id>
#   fm-ask.sh revision <task-id>
#   fm-ask.sh again <task-id> --reason <reason>
#
# `id` and `revision` are read-only and answer for a row that is currently held
# for the captain; a row that is not being asked about has no question identity.
# bin/fm-fleet-snapshot.sh publishes the same two values on every structured
# backlog record as ask_id and ask_revision, which is how a board consumes them
# without re-deriving anything from the row's title or prose.
#
# `again` is the deliberate re-ask: it bumps the revision, which changes the
# identity, and writes the new question as the hold reason. Every other way of
# changing a hold - `tasks-axi hold --reason`, a hold refresh, a resync, a restart,
# and fm-decision-hold.sh's own resolve, decline and repair - leaves the ledger
# untouched and therefore preserves the identity. That is the point: the safe path
# is the one an author already takes.
#
# --reason is required, because a re-ask has to say what is now being asked. A
# genuine re-ask of the identical sentence is a nag, not a new question, and
# bumping for one would spend the captain's answer on nothing.
#
# The bump lands BEFORE the reason. If the reason write then fails the revision is
# restored, so an interrupted re-ask leaves the row exactly as it was; if the
# restore also fails, this reports the row as re-asked with its old wording, which
# is the recoverable direction - the captain sees a question twice instead of a new
# question being silently settled by an old answer.
#
# The bump, the reason write, and the restore run under one per-home lock,
# state/.ask-revisions.lock, so two re-asks racing in the same home cannot drop
# each other's ledger line.
#
# A decision hold re-asks by minting a NEW decision key through
# bin/fm-decision-hold.sh, which is already one command and already refuses to
# reopen a resolved decision. `again` refuses those rows rather than becoming a
# second way to do the same thing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-ask-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ask-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

LEDGER=$(fm_ask_ledger_path "$DATA")
LEDGER_LOCK="$STATE/.ask-revisions.lock"
LEDGER_LOCK_HELD=0

release_ledger_lock() {
  if [ "$LEDGER_LOCK_HELD" = 1 ]; then
    fm_lock_release "$LEDGER_LOCK" || true
    LEDGER_LOCK_HELD=0
  fi
}
trap release_ledger_lock EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-ask: %s\n' "$*" >&2
  exit 1
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
}

# tasks-axi quotes a field whose value needs it and backslash-escapes inside the
# quotes, so a compared value is unwrapped and decoded.
show_field() {  # <show-output> <field>
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$value" in
    '"'*'"')
      value=${value#\"}
      value=${value%\"}
      value=$(printf '%s' "$value" | awk '{
        out = ""
        n = length($0)
        i = 1
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == "\\" && i < n) {
            i++
            c = substr($0, i, 1)
            if (c == "n") c = "\n"
            else if (c == "r") c = "\r"
            else if (c == "t") c = "\t"
          }
          out = out c
          i++
        }
        printf "%s", out
      }')
      ;;
  esac
  printf '%s' "$value"
}

# The show output of the row, once it is confirmed to be an open captain ask.
require_captain_ask() {  # <task-id>
  local id=$1 show state held hold_kind
  fm_ask_is_subject "$id" || fail "task id must be a non-empty privacy-safe slug: $id"
  require_tasks_axi
  show=$(tasks_axi show "$id" --full 2>/dev/null) \
    || fail "backlog item $id is absent from $DATA/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" != "done" ] || fail "backlog item $id is done; a closed row asks the captain nothing"
  [ "$held" = yes ] || fail "backlog item $id is not held; only a held row is a question to the captain"
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id is held for $hold_kind, not the captain"
  printf '%s' "$show"
}

# fm-decision-hold.sh writes "Decision key:" into the body when it creates the
# hold, and only replaces that body when it CLOSES the decision, so an open
# decision hold always still carries it.
refuse_decision_hold() {  # <task-id> <show-output>
  local id=$1 body
  body=$(show_field "$2" body)
  case "$body" in
    *"Decision key:"*)
      fail "$id is a decision hold; re-ask it with a new decision key through fm-decision-hold.sh hold, which mints a new durable identity"
      ;;
  esac
}

command_id() {
  local id=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_captain_ask "$id" >/dev/null || exit 1
  fm_ask_id "$id" captain "$(fm_ask_revision "$LEDGER" "$id")"
}

command_revision() {
  local id=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_captain_ask "$id" >/dev/null || exit 1
  fm_ask_revision "$LEDGER" "$id"
}

command_again() {
  local id=${1:-} reason='' show previous next
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$reason" ] || fail "--reason is required; a re-ask must state what is now being asked"
  case "$reason" in
    *$'\n'*|*$'\r'*) fail "reason must be one line" ;;
    *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;;
  esac
  show=$(require_captain_ask "$id") || exit 1
  refuse_decision_hold "$id" "$show"
  [ "$reason" != "$(show_field "$show" hold_reason)" ] \
    || fail "the reason is unchanged; rewriting the same question is not a re-ask"

  fm_lock_acquire_wait "$LEDGER_LOCK"
  LEDGER_LOCK_HELD=1
  previous=$(fm_ask_revision "$LEDGER" "$id")
  next=$((previous + 1))
  fm_ask_write_revision "$LEDGER" "$id" "$next" || fail "could not record revision $next for $id"
  if ! tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null; then
    fm_ask_write_revision "$LEDGER" "$id" "$previous" \
      || fail "could not write the new question on $id, and revision $next is now recorded with the old wording; re-run with the intended reason"
    fail "could not write the new question on $id; revision $previous is unchanged"
  fi
  release_ledger_lock
  fm_ask_id "$id" captain "$next"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  revision) shift; command_revision "$@" ;;
  again) shift; command_again "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
