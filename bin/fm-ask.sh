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
# `id` and `revision` are read-only and answer for a row carrying a captain hold
# that is not yet Done; a row that is not being asked about has no question
# identity. A hold whose deadline has passed is still one of those rows: it keeps
# its hold markers, and a lapse is neither an answer nor a new question, so the
# identity must not move and the row stays askable. Demoting a lapsed row out of a
# needs-you feed is the consuming board's decision, not something firstmate encodes
# in the identity.
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
# `again` never carries the row's existing hold deadline into the rewritten hold. A
# re-ask is a new instance of the same question, so it passes no --until at all and
# takes whatever the shared tasks-axi hold write applies by default, which today is
# no deadline. Carrying the old date forward would re-ask a lapsed question into a
# card that is demoted the moment it is asked, and inventing one here would put a
# second owner on a deadline this script does not own.
#
# The revision is read before it is used, and a ledger that exists but cannot be
# read fails the command instead of answering 1: a subject silently dropped back to
# revision 1 is how an old answer settles a genuinely new question.
#
# --reason is required, because a re-ask has to say what is now being asked. It is
# never compared against the reason already on the row: running `again` IS the
# declaration that this is a new question, so it re-asks even when the wording is
# unchanged. Nothing else moves the revision, and no similarity test stands between
# the author and a question they deliberately asked again.
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
# second way to do the same thing, and recognizes them by the
# <origin-id>-decision-<key> shape of the id itself.
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

# tasks-axi renders an absent hold field and a hold field whose value is literally
# "-" the same way, and "-" is a legal hold reason. It is never a legal hold kind,
# so for hold_kind it can only mean absent. Only a row where every hold field reads
# that way at once has no hold at all.
hold_field_unset() {  # <field-value>
  case "${1:-}" in
    ''|-) return 0 ;;
  esac
  return 1
}

# The show output of the row, once it is confirmed to be an open captain ask.
require_captain_ask() {  # <task-id>
  local id=$1 show state hold_reason hold_kind hold_until
  fm_ask_is_subject "$id" || fail "task id must be a non-empty privacy-safe slug: $id"
  require_tasks_axi
  show=$(tasks_axi show "$id" --full 2>/dev/null) \
    || fail "backlog item $id is absent from $DATA/backlog.md"
  state=$(fm_tasks_axi_show_field "$show" state)
  hold_reason=$(fm_tasks_axi_show_field "$show" hold_reason)
  hold_kind=$(fm_tasks_axi_show_field "$show" hold_kind)
  hold_until=$(fm_tasks_axi_show_field "$show" hold_until)
  [ "$state" != "done" ] || fail "backlog item $id is done; a closed row asks the captain nothing"
  if hold_field_unset "$hold_reason" && hold_field_unset "$hold_kind" && hold_field_unset "$hold_until"; then
    fail "backlog item $id is not held; only a held row is a question to the captain"
  fi
  if hold_field_unset "$hold_kind"; then
    fail "backlog item $id is held without a hold kind, not for the captain"
  fi
  [ "$hold_kind" = captain ] \
    || fail "backlog item $id is held for $hold_kind, not the captain"
  printf '%s' "$show"
}

# The <origin-id>-decision-<key> shape fm-decision-hold.sh mints is the durable
# discriminator. A marker in the body is not: the close paths replace the body
# wholesale before the row is Done, and AGENTS.md section 10 has an author replace a
# considered body with an updated note, so either leaves an open decision hold
# looking like an ordinary captain ask.
refuse_decision_hold() {  # <task-id>
  local id=$1
  case "$id" in
    ?*-decision-?*)
      fail "$id is a decision hold; re-ask it with a new decision key through fm-decision-hold.sh hold, which mints a new durable identity"
      ;;
  esac
}

read_revision() {  # <task-id>
  fm_ask_revision "$LEDGER" "$1" \
    || fail "could not read the revision ledger $LEDGER; $1 has a recorded revision this cannot answer for"
}

command_id() {
  local id=${1:-} revision
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_captain_ask "$id" >/dev/null || exit 1
  revision=$(read_revision "$id") || exit 1
  fm_ask_id "$id" captain "$revision"
}

command_revision() {
  local id=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_captain_ask "$id" >/dev/null || exit 1
  read_revision "$id"
}

command_again() {
  local id=${1:-} reason='' previous next
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    [ "$#" -eq 0 ] || shift
  done
  [ -n "$reason" ] || fail "--reason is required; a re-ask must state what is now being asked"
  case "$reason" in
    *$'\n'*|*$'\r'*) fail "reason must be one line" ;;
    *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;;
  esac
  require_captain_ask "$id" >/dev/null || exit 1
  refuse_decision_hold "$id"

  fm_lock_acquire_wait "$LEDGER_LOCK"
  LEDGER_LOCK_HELD=1
  previous=$(read_revision "$id") || exit 1
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
