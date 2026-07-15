#!/usr/bin/env bash
# Board-liveness reap: notice a dead logbook attention board and bring it back.
#
# Usage: fm-logbook-reap.sh
#
# This is the body of the watcher check shim state/logbook-reap.check.sh, which
# bootstrap drops on opt-in beside the board-response poll shim. The watcher runs
# every *.check.sh each check cycle (15s once logbook is on), so the board gets a
# cheap liveness read on the same beat the answer-loop already polls it - and, like
# the poll, entirely through the EXISTING check rail, with no edit to fm-watch.sh or
# any other watcher-backbone file (docs/configuration.md "Logbook").
#
# The gap it closes: the board is a bare detached `node server.mjs` with no
# supervisor, and before this only a session-start bootstrap ever started it. A board
# killed mid-session (an OOM kill under memory pressure, a stray signal) stayed dead
# until the next session start, silently - the poll above simply finds nothing.
#
# Wake discipline. Reaping the board is HOUSEKEEPING, not an event the captain needs:
#   board healthy                   -> print nothing, exit 0 (no wake)
#   board dead, relaunch succeeds   -> print nothing, exit 0 (no wake)
#   board dead, relaunch keeps      -> print ONE rate-limited "logbook-error ..." line,
#     failing                          which the watcher surfaces as a check: wake and
#                                      the logbook-respond skill reports to the captain
# Only a board firstmate cannot fix reaches the captain, and only once: the diagnostic
# is deduped by its own text in state/logbook-reap.error, exactly as fm-logbook-poll.sh
# dedupes with state/logbook-poll.error (its own marker, so the two never clear each
# other). It re-fires if the reason changes, and clears the moment the board answers.
#
# Anti-thrash. Relaunching a genuinely broken board (no node, the port taken by
# something else, a server that crashes on boot) every 15s forever is worse than
# leaving it down. Consecutive failures are counted in state/logbook-reap.fails; once
# the count reaches FM_LOGBOOK_REAP_MAX_TRIES the reap keeps retrying - so a fixed
# cause still self-heals without a session restart - but only every
# FM_LOGBOOK_REAP_RETRY_INTERVAL seconds, that file's mtime being the schedule. The
# counter is bumped BEFORE the attempt: a check shim is killed at the watcher's
# FM_CHECK_TIMEOUT and the relaunch is the slow part, so recording afterwards would
# let a reap killed mid-attempt retry flat out forever - the exact thrash this guards.
#
# Inert unless opted in: a hard no-op (exit 0, no output, no network) without a truthy
# LOGBOOK_ENABLE - the same discipline fm-logbook-up.sh and fm-logbook-poll.sh follow,
# and bootstrap only drops the shim for an opted-in home anyway.
#
# It never launches the board itself. fm-logbook-up.sh already health-checks first,
# launches detached, and is idempotent and internally bounded, so the reap just calls
# it rather than reimplementing the launch.
#
# Where systemd exists, a `systemd --user` unit with Restart=always is the recommended
# setup instead (docs/configuration.md "Logbook"): it also covers "no firstmate session
# is running at all". This reap is the portable fallback, and a no-op on such a machine
# because the board practically always answers /health.
#
# Tunables (env): FM_LOGBOOK_REAP_MAX_TRIES (5), FM_LOGBOOK_REAP_RETRY_INTERVAL (300s),
# FM_LOGBOOK_REAP_TIMEOUT (20s, the bound on one relaunch attempt, kept well inside the
# watcher's 30s FM_CHECK_TIMEOUT). Config: see fm-logbook-lib.sh and AGENTS.md sec. 15.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

logbook_load_config
# Hard no-op when logbook is off: this is what keeps the check shim inert.
logbook_enabled || exit 0

# A missing curl is fm-logbook-poll.sh's diagnostic to own - it emits it on this same
# check cycle. Staying silent here keeps one fact to one owner, and one wake.
command -v curl >/dev/null 2>&1 || exit 0

MAX_TRIES=${FM_LOGBOOK_REAP_MAX_TRIES:-5}
RETRY_INTERVAL=${FM_LOGBOOK_REAP_RETRY_INTERVAL:-300}
RELAUNCH_TIMEOUT=${FM_LOGBOOK_REAP_TIMEOUT:-20}

FAILS_FILE="$STATE/logbook-reap.fails"
ERROR_FILE="$STATE/logbook-reap.error"

# GNU and BSD stat disagree on the mtime flag, and the wrong one prints usage garbage
# that then breaks arithmetic. Detect the platform once, as fm-watch.sh does.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Seconds since <file> was last written; a huge number when it is missing or unreadable,
# so an absent schedule file always reads as "due now".
age_of() {
  local m
  m=$(stat_mtime "$1") || m=
  case "$m" in
    ''|*[!0-9]*) echo 999999; return 0 ;;
  esac
  echo $(( $(date +%s) - m ))
}

# Consecutive failed relaunch attempts; 0 when the file is absent, empty, or garbage.
read_tries() {
  local n
  n=$(cat "$FAILS_FILE" 2>/dev/null) || n=
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}

# One rate-limited diagnostic, deduped by its own text. Printing on stdout is exactly
# what turns it into the watcher's check: wake, so this is the ONLY path here that
# wakes firstmate.
emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'logbook-error %s\n' "$msg"
}

# The board answered: forget the failure streak and any surfaced diagnostic, so a board
# that dies again later is reaped - and, if unfixable, reported - afresh.
clear_reap_state() {
  [ -e "$FAILS_FILE" ] || [ -e "$ERROR_FILE" ] || return 0
  rm -f "$FAILS_FILE" "$ERROR_FILE" 2>/dev/null || true
}

health_code() {
  local c
  c=$(curl -m 2 -s -o /dev/null -w '%{http_code}' "$LOGBOOK_URL/health" 2>/dev/null) || c=000
  printf '%s' "$c"
}

# The board is up: the overwhelmingly common path, and one bounded loopback GET.
case "$(health_code)" in
  2[0-9][0-9]) clear_reap_state; exit 0 ;;
esac

# The board is down. Anti-thrash gate: once the streak has reached MAX_TRIES we have
# given up on a fast fix, so retry only on the slow interval - a permanently broken
# board then costs one bounded relaunch every RETRY_INTERVAL instead of one every
# check cycle, while still self-healing the moment its cause is fixed.
tries=$(read_tries)
if [ "$tries" -ge "$MAX_TRIES" ] && [ "$(age_of "$FAILS_FILE")" -lt "$RETRY_INTERVAL" ]; then
  exit 0
fi

# Count the attempt BEFORE making it (see the header). The write also stamps the
# schedule the gate above reads. Cap the stored count so a long outage cannot grow it
# without bound.
mkdir -p "$STATE" 2>/dev/null || exit 0
next=$((tries + 1))
[ "$next" -gt "$MAX_TRIES" ] && next=$MAX_TRIES
printf '%s\n' "$next" > "$FAILS_FILE" 2>/dev/null || true

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-reap.XXXXXX" 2>/dev/null) || ERR_FILE=
trap 'rm -f "$ERR_FILE" 2>/dev/null || true' EXIT

# Bound one attempt so it can never eat the watcher's whole check budget. fm-logbook-up.sh
# is already internally bounded; this is the belt to that braces.
run_up() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$RELAUNCH_TIMEOUT" "$FM_ROOT/bin/fm-logbook-up.sh"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$RELAUNCH_TIMEOUT" "$FM_ROOT/bin/fm-logbook-up.sh"
  else
    "$FM_ROOT/bin/fm-logbook-up.sh"
  fi
}

rc=0
if [ -n "$ERR_FILE" ]; then
  run_up >/dev/null 2>"$ERR_FILE" || rc=$?
else
  run_up >/dev/null 2>&1 || rc=$?
fi

if [ "$rc" -eq 0 ]; then
  # Back up. Say nothing: a reaped board is housekeeping, and printing here would
  # manufacture a check: wake for something the captain never needed to see.
  clear_reap_state
  exit 0
fi

# The relaunch failed. Fold the launcher's own last diagnostic into the message so the
# wake is actionable ("node not found", "board server not found at ...", "launched but
# not yet healthy ... see state/logbook-server.log"), and flatten it: a wake payload is
# one line in a TAB-delimited queue record.
reason=
if [ -n "$ERR_FILE" ] && [ -s "$ERR_FILE" ]; then
  reason=$(grep -v '^[[:space:]]*$' "$ERR_FILE" 2>/dev/null | tail -n1)
  reason=${reason#fm-logbook-up: }
  reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ' | cut -c1-160)
fi
[ -n "$reason" ] || reason="relaunch exited $rc"

# Surface only once we have exhausted the fast attempts, so a board that is merely slow
# to bind (one failed attempt, healthy on the next cycle) never wakes anyone.
if [ "$next" -ge "$MAX_TRIES" ]; then
  emit_error_once "board down at $LOGBOOK_URL; relaunch failed after $next tries: $reason"
fi
exit 0
