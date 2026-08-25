# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll (state/x-watch.check.sh),
# or an enabled logbook board (state/logbook-*.check.sh), and whether its watcher
# has a fresh liveness beacon (state/.last-watcher-beat, touched every poll
# cycle, within the grace window).
#
# Relay and logbook are the two opt-ins whose ONLY inbound channel is the
# watcher's own check sweep, so an empty fleet is exactly when they are most
# exposed: with no state/<id>.meta anywhere, nothing else would ask for a
# watcher and every board answer or public mention would sit unread. Both are
# therefore keyed on the poll shim the connector's enable step leaves in state/,
# never on a config/ file. The shim is what the watcher actually runs, so its
# presence is the same fact as "a wake can arrive here"; config/ is the operator
# preference surface bin/fm-config-inherit-lib.sh propagates to secondmate
# homes, where the board itself does not exist.
# A board shim must be bound with bin/fm-check-register.sh, exactly like any
# other custom check: an unregistered one is quarantined unrun by the watcher's
# own startup migration (bin/fm-pr-check-migrate.sh), which would take this
# supervision need down with it.
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_RELAY          true/false - an X-mode relay poll shim is armed
#   FM_SUP_LOGBOOK        true/false - a logbook board poll shim is armed
#   FM_SUP_NEEDED         true/false - in-flight work, a registered event source
#                         (a source is a wait on an external process, not a
#                         task, so it has no metadata), an X-mode relay poll, or
#                         an enabled logbook board
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source board beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_RELAY=false
  FM_SUP_LOGBOOK=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  [ -f "$state/x-watch.check.sh" ] && FM_SUP_RELAY=true
  # The logbook connector arms its board polls under the reserved
  # state/logbook-*.check.sh namespace, one shim per channel it watches.
  for board in "$state"/logbook-*.check.sh; do
    [ -f "$board" ] || continue
    FM_SUP_LOGBOOK=true
    break
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_RELAY" = true ] \
    || [ "$FM_SUP_LOGBOOK" = true ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
