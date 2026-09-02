# shellcheck shell=bash
# fm-captain-hold-lib.sh - the one owner of "when does a captain hold lapse?"
# Usage: . bin/fm-captain-hold-lib.sh
#
# A captain hold with no deadline never lapses, so a question the captain has
# decided not to answer keeps competing for attention with questions they have
# not seen yet. tasks-axi has carried `hold --until` the whole time and every
# reader downstream renders and lapses it; no firstmate producer ever passed one.
# This library makes the deadline the default so that stops being true.
#
# The default window is FM_CAPTAIN_HOLD_DEFAULT_DAYS days. Callers expose it as
# `--hold-until`, which takes a YYYY-MM-DD date to override the default or the
# literal `none` for a genuinely open-ended question. The two firstmate paths
# that create a captain hold both resolve the value here:
#
#   bin/fm-decision-hold.sh    an investigation's or visual review's decision.
#   bin/fm-captain-hold.sh     a main-side thread held for the captain.
#
# LAPSE IS DEMOTION, NEVER DELETION. Past the deadline tasks-axi reports the row
# `held: no` and keeps hold_reason, hold_kind and hold_until on it, so a lapsed
# hold is still a captain hold with an answer owed - it has only stopped gating
# dispatch. `tasks-axi unhold` clears all three, which is what separates a hold
# somebody released from one that merely ran out of clock. Every gate that asks
# "is this decision still open?" must therefore read hold_kind, never held.
# Re-running `hold` on a lapsed row reactivates it with a fresh deadline, which
# is how firstmate deliberately re-asks a question that went unanswered.
#
# Dates are integer day numbers here rather than date(1) arithmetic: BSD and GNU
# date disagree on every flag that would do this, and a deadline that silently
# fails to compute is a hold that never lapses - the exact bug the default
# exists to fix. The conversions assume proleptic Gregorian dates in positive
# years, which every date reachable from `date -u +%Y-%m-%d` satisfies.

# Seven days. The scout census that produced this default recorded eleven open
# captain holds aged 47, 27, 15, 12, 9, 8, 6, 2, 1, 0 and 0 days, and named the
# holds "over a week old" as the ones that had stopped being live questions. A
# week is the line that census already drew: it lapses exactly the six holds the
# report calls the failure and leaves the five recent ones gating dispatch.
FM_CAPTAIN_HOLD_DEFAULT_DAYS=7

# FM_CAPTAIN_HOLD_NOW pins today's date so a test can assert an exact deadline.
fm_captain_hold_today() {
  local today=${FM_CAPTAIN_HOLD_NOW:-}
  if [ -z "$today" ]; then
    today=$(date -u +%Y-%m-%d) || return 1
  fi
  case "$today" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$today"
}

fm_captain_hold_month() {  # <yyyy-mm-dd>
  local rest=${1#*-}
  printf '%s\n' "${rest%%-*}"
}

fm_captain_hold_days_from_civil() {  # <yyyy> <mm> <dd>
  local y m d era yoe doy doe
  y=$(( 10#$1 ))
  m=$(( 10#$2 ))
  d=$(( 10#$3 ))
  if [ "$m" -le 2 ]; then y=$(( y - 1 )); fi
  era=$(( y / 400 ))
  yoe=$(( y - era * 400 ))
  if [ "$m" -gt 2 ]; then
    doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  printf '%s\n' "$(( era * 146097 + doe - 719468 ))"
}

fm_captain_hold_civil_from_days() {  # <day-number>
  local z era doe yoe y doy mp d m
  z=$(( $1 + 719468 ))
  era=$(( z / 146097 ))
  doe=$(( z - era * 146097 ))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
  y=$(( yoe + era * 400 ))
  doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
  mp=$(( (5 * doy + 2) / 153 ))
  d=$(( doy - (153 * mp + 2) / 5 + 1 ))
  if [ "$mp" -lt 10 ]; then m=$(( mp + 3 )); else m=$(( mp - 9 )); fi
  if [ "$m" -le 2 ]; then y=$(( y + 1 )); fi
  printf '%04d-%02d-%02d\n' "$y" "$m" "$d"
}

fm_captain_hold_default_until() {
  local today days
  today=$(fm_captain_hold_today) || return 1
  days=$(fm_captain_hold_days_from_civil "${today%%-*}" "$(fm_captain_hold_month "$today")" "${today##*-}") || return 1
  fm_captain_hold_civil_from_days "$(( days + FM_CAPTAIN_HOLD_DEFAULT_DAYS ))"
}

# fm_captain_hold_until_reject <value>
#   Prints a one-line reason when <value> cannot be used as a deadline and
#   nothing when it can, so each caller reports it with its own error prefix.
#   An empty value is the default and is always accepted.
fm_captain_hold_until_reject() {  # <value>
  local value=$1 today days today_days
  case "$value" in
    ''|none) return 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
      printf '%s\n' "--hold-until must be a YYYY-MM-DD date or none: $value"
      return 0
      ;;
  esac
  days=$(fm_captain_hold_days_from_civil "${value%%-*}" "$(fm_captain_hold_month "$value")" "${value##*-}")
  if [ "$(fm_captain_hold_civil_from_days "$days")" != "$value" ]; then
    printf '%s\n' "--hold-until is not a real calendar date: $value"
    return 0
  fi
  if ! today=$(fm_captain_hold_today); then
    printf '%s\n' "could not read the current date to check --hold-until"
    return 0
  fi
  today_days=$(fm_captain_hold_days_from_civil "${today%%-*}" "$(fm_captain_hold_month "$today")" "${today##*-}")
  # tasks-axi holds are inactive on and after the deadline, so today's date would
  # write a hold that is already lapsed rather than one that gates anything.
  if [ "$days" -le "$today_days" ]; then
    printf '%s\n' "--hold-until must be later than $today: $value"
  fi
}

# fm_captain_hold_until_is_future <value>
#   True when <value> is a real calendar date the clock has not reached, which
#   is what makes an existing deadline worth keeping on an idempotent re-hold.
fm_captain_hold_until_is_future() {  # <value>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ -z "$(fm_captain_hold_until_reject "$1")" ]
}

# fm_captain_hold_resolve_until <value>
#   Prints the date to pass to `tasks-axi hold --until`, or nothing when the
#   hold is deliberately open-ended. Reject the value first.
fm_captain_hold_resolve_until() {  # <value>
  case "$1" in
    '') fm_captain_hold_default_until ;;
    none) ;;
    *) printf '%s\n' "$1" ;;
  esac
}
