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
# tasks-axi's own `ready` set counts a lapsed hold as dispatchable, and forking
# tasks-axi is not on the table, so firstmate withholds it on its own side. That
# happens in exactly one place: fm_captain_hold_ready, the dispatchable-now set
# every firstmate reader of ready work goes through - bin/fm-ready.sh for an
# agent at a prompt, bin/fm-session-start.sh's digest for the startup queue.
# Nothing may read raw `tasks-axi ready` instead. Withholding is presentation
# only; a withheld row is still listed as a held row, marked lapsed, so lapsing
# demotes a question rather than hiding or answering it.
#
# Dates are integer day numbers here rather than date(1) arithmetic: BSD and GNU
# date disagree on every flag that would do this, and a deadline that silently
# fails to compute is a hold that never lapses - the exact bug the default
# exists to fix. The conversions assume proleptic Gregorian dates in positive
# years, which every date reachable from `date +%Y-%m-%d` satisfies.

# Seven days. The scout census that produced this default recorded eleven open
# captain holds aged 47, 27, 15, 12, 9, 8, 6, 2, 1, 0 and 0 days, and named the
# holds "over a week old" as the ones that had stopped being live questions. A
# week is the line that census already drew: it lapses exactly the six holds the
# report calls the failure and leaves the five recent ones gating dispatch.
FM_CAPTAIN_HOLD_DEFAULT_DAYS=7

# The LOCAL date, because tasks-axi decides whether a hold is still gating from
# the local date too. Reading UTC here would let a home east of it accept, write,
# and immediately lapse the same deadline in the hours after local midnight.
# FM_CAPTAIN_HOLD_NOW pins today's date so a test can assert an exact deadline.
fm_captain_hold_today() {
  local today=${FM_CAPTAIN_HOLD_NOW:-}
  if [ -z "$today" ]; then
    today=$(date +%Y-%m-%d) || return 1
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

# fm_captain_hold_effective_until <explicit> <existing>
#   The deadline to write. An explicit value always wins; otherwise a deadline
#   the clock has not reached is kept rather than reset, so an idempotent re-hold
#   cannot shorten a window the captain was already given.
fm_captain_hold_effective_until() {  # <explicit> <existing>
  if [ -z "$1" ] && fm_captain_hold_until_is_future "$2"; then
    printf '%s\n' "$2"
    return 0
  fi
  fm_captain_hold_resolve_until "$1"
}

# fm_captain_hold_contract_reject
#   Prints a one-line reason when the installed tasks-axi cannot carry a captain
#   hold with a deadline and nothing when it can, so each caller reports it with
#   its own error prefix. Defense in depth for a stripped or forked build that
#   advertises a compatible version without the flags.
fm_captain_hold_contract_reject() {
  local hold_help
  hold_help=$(tasks-axi hold --help 2>&1) || {
    printf '%s\n' "tasks-axi does not expose the hold contract"
    return 0
  }
  printf '%s\n' "$hold_help" | grep -F -- '--kind captain' >/dev/null || {
    printf '%s\n' "tasks-axi does not expose the captain-hold contract"
    return 0
  }
  printf '%s\n' "$hold_help" | grep -F -- '--until' >/dev/null \
    || printf '%s\n' "tasks-axi does not expose the hold deadline contract"
}

# fm_captain_hold_write <id> <reason> <until>
#   Applies the hold in the active FM_HOME, with the deadline when there is one.
#   An empty <until> is the deliberate open-ended hold, not a missing value.
fm_captain_hold_write() {  # <id> <reason> <until>
  if [ -n "$3" ]; then
    (cd "$FM_HOME" && tasks-axi hold "$1" --reason "$2" --kind captain --until "$3" >/dev/null)
  else
    (cd "$FM_HOME" && tasks-axi hold "$1" --reason "$2" --kind captain >/dev/null)
  fi
}

# The three fields that decide whether a captain hold has lapsed, appended after
# any caller-chosen ones. They are last because none of them can contain a comma,
# so a title or hold reason that does cannot shift them out of position.
FM_CAPTAIN_HOLD_LAPSE_FIELDS=hold_kind,hold_until,held

# fm_captain_hold_lapsed_rows <backlog-path> [<extra-fields>]
#   Prints tasks-axi's own listing row for every queued row whose captain hold
#   has lapsed. tasks-axi answers "has this deadline passed?" itself, so this
#   reads its verdict rather than re-deriving the clock the hold was written
#   against: past the date it reports `held: no` while hold_kind survives, and
#   that pair exists on no other row.
fm_captain_hold_lapsed_rows() {  # <backlog-path> [<extra-fields>]
  local listing
  listing=$(tasks-axi list --file "$1" --state queued \
    --fields "${2:+$2,}$FM_CAPTAIN_HOLD_LAPSE_FIELDS" 2>&1) || {
    printf '%s\n' "$listing"
    return 1
  }
  printf '%s\n' "$listing" | awk '
    /^help\[/ { exit }
    /^tasks\[/ { rows = 1; next }
    rows && /^[[:space:]]/ {
      n = split($0, field, ",")
      if (n >= 3 && field[n] == "no" && field[n - 2] == "captain" &&
          field[n - 1] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) print
      next
    }
    { rows = 0 }
  '
}

# fm_captain_hold_lapsed_row_ids <rows>
#   The ids of an fm_captain_hold_lapsed_rows listing, one per line, so a caller
#   that already has the rows does not query the same verdict twice.
fm_captain_hold_lapsed_row_ids() {  # <rows>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/,.*//'
}

# fm_captain_hold_withhold_lapsed <lapsed-ids>
#   Reads a `tasks-axi ready` rendering on stdin and writes it back without the
#   rows whose id is in <lapsed-ids>, with the tool's own count and ready[N]
#   header restated so they describe what is actually listed, and one disclosure
#   line after the rows so the withholding is never silent. Everything else the
#   tool printed passes through untouched.
fm_captain_hold_withhold_lapsed() {  # <lapsed-ids>
  FM_CAPTAIN_HOLD_LAPSED_IDS="$1" awk '
    function row_id(line,   id) {
      id = line
      sub(/^[[:space:]]+/, "", id)
      sub(/,.*/, "", id)
      return id
    }
    BEGIN {
      count = split(ENVIRON["FM_CAPTAIN_HOLD_LAPSED_IDS"], id_list, "\n")
      for (i = 1; i <= count; i++) if (id_list[i] != "") lapsed[id_list[i]] = 1
    }
    {
      buffer[++lines] = $0
      if (in_help) next
      if ($0 ~ /^help\[/) { in_help = 1; rows = 0; next }
      if ($0 ~ /^ready\[/) { rows = 1; next }
      if (rows && $0 ~ /^[[:space:]]/) {
        last_row = lines
        if (row_id($0) in lapsed) { withheld_line[lines] = 1; withheld++ }
        next
      }
      rows = 0
    }
    END {
      for (i = 1; i <= lines; i++) {
        if (!(i in withheld_line)) {
          line = buffer[i]
          if (withheld > 0) {
            if (line ~ /^count: [0-9]+$/) {
              listed = line
              sub(/^count: /, "", listed)
              line = "count: " (listed - withheld)
            } else if (line ~ /^ready\[[0-9]+\]/) {
              listed = line
              sub(/^ready\[/, "", listed)
              sub(/\].*/, "", listed)
              sub(/^ready\[[0-9]+\]/, "ready[" (listed - withheld) "]", line)
            }
          }
          print line
        }
        if (withheld > 0 && i == last_row) {
          printf "(%d lapsed captain hold(s) withheld from this group and listed under held)\n", withheld
        }
      }
    }
  '
}

# fm_captain_hold_ready <backlog-path> [<lapsed-ids>]
#   Firstmate's dispatchable-now set: tasks-axi's own `ready` rendering with
#   every lapsed captain hold withheld. This is the single owner of "a lapsed
#   captain hold is never dispatchable work", so every firstmate reader of ready
#   work calls it rather than `tasks-axi ready`. Pass <lapsed-ids> when the
#   caller has already listed them for its own display; otherwise they are
#   queried here.
fm_captain_hold_ready() {  # <backlog-path> [<lapsed-ids>]
  local path=$1 lapsed_ids=${2:-} rows ready
  if [ "$#" -lt 2 ]; then
    rows=$(fm_captain_hold_lapsed_rows "$path") || { printf '%s\n' "$rows"; return 1; }
    lapsed_ids=$(fm_captain_hold_lapsed_row_ids "$rows")
  fi
  ready=$(tasks-axi ready --file "$path" 2>&1) || { printf '%s\n' "$ready"; return 1; }
  printf '%s\n' "$ready" | fm_captain_hold_withhold_lapsed "$lapsed_ids"
}
