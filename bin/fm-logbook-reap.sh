#!/usr/bin/env bash
# Board-liveness reap: notice a dead logbook attention board and bring it back.
#
# Usage: fm-logbook-reap.sh
#
# This is the body of the watcher check shim state/logbook-reap.check.sh, which
# bootstrap drops on opt-in beside the board-response poll shim. The watcher runs
# every *.check.sh each check cycle (15s once logbook is on, 300s under away mode),
# so the board gets a cheap liveness read on the same beat the answer-loop already
# polls it - and, like the poll, entirely through the EXISTING check rail, with no
# edit to fm-watch.sh or any other watcher-backbone file (docs/configuration.md
# "Board liveness").
#
# The gap it closes: the board is a bare detached `node server.mjs` with no
# supervisor, and before this only a session-start bootstrap ever started it. A board
# killed mid-session (an OOM kill under memory pressure, a stray signal) stayed dead
# until the next session start, silently - the poll above simply finds nothing.
#
# Wake discipline. Reaping the board is HOUSEKEEPING, not an event the captain needs:
#   board healthy                   -> print nothing, exit 0 (no wake)
#   board dead, relaunch succeeds   -> print nothing, exit 0 (no wake)
#   board it cannot keep alive      -> print ONE deduped "logbook-error ..." line,
#                                      which the watcher surfaces as a check: wake and
#                                      the logbook-respond skill reports to the captain
# Only a board firstmate cannot fix reaches the captain, and only once per incident:
# each diagnostic is deduped by its own text in state/logbook-reap.error, exactly as
# fm-logbook-poll.sh dedupes with state/logbook-poll.error (its own marker, so the two
# never clear each other).
#
# Anti-thrash by two monotone streaks plus a wall-clock stability reset. There is NO
# time window, rate, decay, floor, or cadence assumption here; the reap counts
# CONSECUTIVE events and measures wall-clock health, so it behaves identically at a 15s
# and a 300s watcher cadence. All of it lives in one line of state/logbook-reap.state,
# "<phase> <ws> <cl> <since>":
#   phase  launching | up | wontstart | crashloop  (an absent file is the steady, healthy state)
#   ws     wont-start streak: consecutive relaunch attempts after which the board still
#          does not answer /health (node missing, port taken, crash-on-boot)
#   cl     crash-loop streak: consecutive revivals that did NOT stick - the board came
#          back up but died again before it had been healthy for STABLE_SECS
#   since  epoch of the phase's reference moment (the last relaunch while launching; the
#          first healthy read after a relaunch while up; the give-up moment otherwise)
# When either streak reaches MAX_STRIKES the reap surfaces its diagnostic ONCE and STOPS
# relaunching until reset - relaunching a genuinely broken board every cycle forever is
# worse than leaving it down and saying so once. The board then heals on the next
# session-start bootstrap, or through the recommended systemd unit, or any external
# fm-logbook-up.sh; the reap notices it healthy again and resets. A wall-clock reset is
# the ONLY reset: once the board has been continuously healthy for STABLE_SECS since the
# last relaunch, BOTH streaks and the diagnostic clear and the board is stable again.
#
# Crash-safety: the streak state is written BEFORE the (slow) relaunch, pessimistically,
# so a shim killed at the watcher's FM_CHECK_TIMEOUT mid-relaunch still records the
# attempt and cannot retry flat out forever. A relaunch that actually succeeded is
# corrected on the next cycle, when the board reads healthy and the streak resets.
#
# Inert unless opted in: a hard no-op (exit 0, no output, no network) without a truthy
# LOGBOOK_ENABLE - the same discipline fm-logbook-up.sh and fm-logbook-poll.sh follow,
# and bootstrap only drops the shim for an opted-in home anyway.
#
# It never launches the board itself. fm-logbook-up.sh already health-checks first,
# launches detached, is idempotent, and reports success only when the board answers, so
# the reap calls it (belt-and-braces timeout) and uses its exit status as the "did the
# board come up" signal rather than reimplementing the launch.
#
# Where systemd exists, a `systemd --user` unit with Restart=always is the recommended
# setup instead (docs/configuration.md "Board liveness"): it also covers "no firstmate
# session is running at all". This reap is the portable fallback, and a no-op on such a
# machine because the board practically always answers /health.
#
# Tunables (env): FM_LOGBOOK_REAP_MAX_STRIKES (5, the give-up threshold for BOTH
# streaks), FM_LOGBOOK_REAP_STABLE_SECS (120s, the continuous-health span that declares
# the board stable and resets the streaks), FM_LOGBOOK_REAP_TIMEOUT (20s, the bound on
# one relaunch attempt, kept well inside the watcher's 30s FM_CHECK_TIMEOUT). Config:
# see fm-logbook-lib.sh and AGENTS.md sec. 15.
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

MAX_STRIKES=${FM_LOGBOOK_REAP_MAX_STRIKES:-5}
STABLE_SECS=${FM_LOGBOOK_REAP_STABLE_SECS:-120}
RELAUNCH_TIMEOUT=${FM_LOGBOOK_REAP_TIMEOUT:-20}
case "$MAX_STRIKES" in ''|*[!0-9]*) MAX_STRIKES=5 ;; esac
[ "$MAX_STRIKES" -ge 1 ] || MAX_STRIKES=5
case "$STABLE_SECS" in ''|*[!0-9]*) STABLE_SECS=120 ;; esac

STATE_FILE="$STATE/logbook-reap.state"
ERROR_FILE="$STATE/logbook-reap.error"

now=$(date +%s)

health_code() {
  local c
  c=$(curl -m 2 -s -o /dev/null -w '%{http_code}' "$LOGBOOK_URL/health" 2>/dev/null) || c=000
  printf '%s' "$c"
}

# Atomically replace the one-line state with "<phase> <ws> <cl> <since>". A rename is
# atomic on POSIX, so a reader never sees a half-written line even if the reap is killed.
write_state() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE/.logbook-reap.state.XXXXXX" 2>/dev/null) || return 0
  if printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# The board is stable again: forget the streaks and any surfaced diagnostic, so a board
# that dies later is reaped - and, if unfixable, reported - afresh.
clear_reap_state() {
  [ -e "$STATE_FILE" ] || [ -e "$ERROR_FILE" ] || return 0
  rm -f "$STATE_FILE" "$ERROR_FILE" 2>/dev/null || true
}

# One deduped diagnostic, keyed by its own text. Printing on stdout is exactly what
# turns it into the watcher's check: wake, so this is the ONLY path here that wakes
# firstmate. Ordered emit-then-mark: the marker is the durable record, so a reap killed
# right after printing still dedupes on the next cycle instead of double-waking.
emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf 'logbook-error %s\n' "$msg"
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
}

# Read state/logbook-reap.state into PHASE/WS/CL/SINCE. A missing, empty, malformed, or
# unknown-phase line reads as no incident (PHASE=""), the conservative default: the
# worst case is one extra relaunch of a board that is actually down, which is harmless.
PHASE="" WS=0 CL=0 SINCE=0
read_state() {
  local p w c s
  [ -f "$STATE_FILE" ] || return 0
  read -r p w c s _ < "$STATE_FILE" 2>/dev/null || return 0
  case "$p" in launching|up|wontstart|crashloop) : ;; *) return 0 ;; esac
  # Every count and the timestamp must be a non-empty digit string; a short or malformed
  # line (any field missing or non-numeric) reads as no incident.
  case "$w" in ''|*[!0-9]*) return 0 ;; esac
  case "$c" in ''|*[!0-9]*) return 0 ;; esac
  case "$s" in ''|*[!0-9]*) return 0 ;; esac
  PHASE=$p WS=$w CL=$c SINCE=$s
}

# Bound one relaunch so it can never eat the watcher's whole check budget, capture the
# launcher's own last diagnostic as a flat one-line reason, and report its exit status:
# 0 means the board answers /health now (fm-logbook-up.sh confirms readiness before it
# returns 0), non-zero means it could not be brought up. REASON is set as a side effect.
REASON=""
relaunch() {
  local err rc=0 line
  # Capture the launcher's stderr to a temp file; fall back to /dev/null (no reason
  # available) if a temp file cannot be made, so the invocation below never branches on
  # its presence and stays portable (no empty-array expansion under set -u).
  err=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-reap.XXXXXX" 2>/dev/null) || err=/dev/null
  if command -v timeout >/dev/null 2>&1; then
    timeout "$RELAUNCH_TIMEOUT" "$FM_ROOT/bin/fm-logbook-up.sh" >/dev/null 2>"$err" || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$RELAUNCH_TIMEOUT" "$FM_ROOT/bin/fm-logbook-up.sh" >/dev/null 2>"$err" || rc=$?
  else
    "$FM_ROOT/bin/fm-logbook-up.sh" >/dev/null 2>"$err" || rc=$?
  fi
  REASON=""
  if [ "$err" != /dev/null ] && [ -s "$err" ]; then
    line=$(grep -v '^[[:space:]]*$' "$err" 2>/dev/null | tail -n1)
    line=${line#fm-logbook-up: }
    REASON=$(printf '%s' "$line" | tr '\t\r\n' '   ' | cut -c1-160)
  fi
  [ "$err" != /dev/null ] && rm -f "$err" 2>/dev/null
  return "$rc"
}

# ---------------------------------------------------------------------------

# The board is up: the overwhelmingly common path, and one bounded loopback GET.
case "$(health_code)" in
  2[0-9][0-9])
    read_state
    case "$PHASE" in
      "")
        # Steady healthy state, no incident: read nothing, write nothing.
        exit 0 ;;
      up)
        # A revived board proving it sticks. Once it has been continuously healthy for
        # STABLE_SECS since the revival, it is stable: clear both streaks and the marker.
        if [ "$((now - SINCE))" -ge "$STABLE_SECS" ]; then
          clear_reap_state
        fi
        exit 0 ;;
      launching)
        # The relaunch worked: the board answers now. Reset the wont-start streak (it DID
        # start) and start the stability clock; the crash-loop streak rides along until a
        # full stable reset, so a board that only briefly comes back still counts as a
        # non-sticking revival if it dies again before STABLE_SECS.
        write_state up 0 "$CL" "$now"
        exit 0 ;;
      wontstart|crashloop)
        # We had given up, but the board is healthy again - an external revival (the
        # systemd unit, a new session's bootstrap, a manual fm-logbook-up.sh). Start the
        # stability clock; the streaks and marker clear once it proves stable above.
        write_state up "$WS" "$CL" "$now"
        exit 0 ;;
    esac
    ;;
esac

# The board is DOWN.
read_state

case "$PHASE" in
  wontstart|crashloop)
    # Given up on this incident already: stay silent and do NOT relaunch. If the give-up
    # emit was interrupted before it printed, re-surface it now (deduped, so at most one
    # wake per incident); the board recovers only externally, and we notice above.
    if [ ! -f "$ERROR_FILE" ]; then
      if [ "$PHASE" = crashloop ]; then
        emit_error_once "logbook board is crash-looping at $LOGBOOK_URL; revived $CL times but it keeps dying"
      else
        emit_error_once "logbook board won't start at $LOGBOOK_URL; $WS relaunch attempts failed"
      fi
    fi
    exit 0 ;;

  up)
    # The board was revived and is now down again before it proved stable: this revival
    # did not stick, so the crash-loop streak advances by one.
    cl_next=$((CL + 1))
    if [ "$cl_next" -ge "$MAX_STRIKES" ]; then
      # Give up: surface once, record the terminal phase, and stop relaunching.
      emit_error_once "logbook board is crash-looping at $LOGBOOK_URL; revived $cl_next times but it keeps dying"
      write_state crashloop "$WS" "$cl_next" "$now"
      exit 0
    fi
    # Try to revive it again. Record the advanced streak BEFORE the relaunch so a killed
    # attempt still counts (crash-safety); a revival is confirmed on the next cycle.
    write_state launching "$WS" "$cl_next" "$now"
    if relaunch; then
      write_state up "$WS" "$cl_next" "$now"
    fi
    exit 0 ;;

  launching)
    # A prior relaunch has not brought the board up. Count this attempt against the
    # wont-start streak, recording it BEFORE the relaunch (crash-safety), then try again.
    ws_next=$((WS + 1))
    write_state launching "$ws_next" "$CL" "$now"
    if relaunch; then
      # It finally came up: revival. Reset the wont-start streak and start proving.
      write_state up 0 "$CL" "$now"
      exit 0
    fi
    if [ "$ws_next" -ge "$MAX_STRIKES" ]; then
      # Exhausted the tries: surface once with the launcher's own reason, then stop.
      reason=$REASON
      [ -n "$reason" ] || reason="relaunch failed"
      emit_error_once "logbook board won't start at $LOGBOOK_URL; $ws_next relaunch attempts failed: $reason"
      write_state wontstart "$ws_next" "$CL" "$now"
    fi
    exit 0 ;;

  "")
    # First death of a healthy board. Assume the relaunch will fail (record a wont-start
    # of 1 before it, for crash-safety); a success rewrites that to a clean revival.
    write_state launching 1 0 "$now"
    if relaunch; then
      write_state up 0 0 "$now"
      exit 0
    fi
    # The very first relaunch failed. With the default MAX_STRIKES this is silent (a board
    # merely slow to bind lands here and recovers next cycle); only a MAX_STRIKES of 1
    # gives up immediately.
    if [ 1 -ge "$MAX_STRIKES" ]; then
      reason=$REASON
      [ -n "$reason" ] || reason="relaunch failed"
      emit_error_once "logbook board won't start at $LOGBOOK_URL; 1 relaunch attempts failed: $reason"
      write_state wontstart 1 0 "$now"
    fi
    exit 0 ;;
esac
