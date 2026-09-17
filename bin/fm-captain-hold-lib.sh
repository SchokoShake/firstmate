# shellcheck shell=bash
# fm-captain-hold-lib.sh - the one owner of "when does a captain hold lapse?"
# Usage: . bin/fm-captain-hold-lib.sh
#
# A captain hold with no deadline never lapses, so a question the captain has
# chosen not to answer keeps competing with ones they have not seen. Every
# firstmate producer resolves its deadline here: bin/fm-decision-hold.sh,
# bin/fm-captain-hold.sh, the stow skill through the latter, and
# `bin/fm-ask.sh again`. All but the last expose `--hold-until <YYYY-MM-DD>` to
# override the default window and `--hold-until none` for a genuinely open-ended
# question.
#
# LAPSE IS DEMOTION, NEVER DELETION. Past the deadline tasks-axi reports the row
# `held: no` and keeps hold_reason, hold_kind and hold_until on it; only
# `tasks-axi unhold` clears them. A lapsed hold is therefore still a captain hold
# with an answer owed, and every gate asking "is this decision still open?" reads
# hold_kind, never held. Re-running `hold` on a lapsed row gives it a fresh
# deadline. bin/fm-ready.sh owns keeping a lapsed hold out of dispatchable work.
#
# Dates are integer day numbers rather than date(1) arithmetic, because BSD and
# GNU date disagree on every flag that would do this. The conversions assume
# proleptic Gregorian dates in positive years.

# The scout report's line: holds over a week old had stopped being live questions.
FM_CAPTAIN_HOLD_DEFAULT_DAYS=7

# The LOCAL date, because tasks-axi decides hold activity from it too; UTC would
# let a home east of it write a deadline the tool already counts as lapsed.
# FM_CAPTAIN_HOLD_NOW pins today's date for tests.
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

# Prints a one-line reason when <value> cannot be a deadline and nothing when it
# can, so each caller reports it under its own prefix. Empty means the default.
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
  # tasks-axi holds are inactive ON the deadline, so today is already lapsed.
  if [ "$days" -le "$today_days" ]; then
    printf '%s\n' "--hold-until must be later than $today: $value"
  fi
}

fm_captain_hold_until_is_future() {  # <value>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ -z "$(fm_captain_hold_until_reject "$1")" ]
}

# Prints the date for `tasks-axi hold --until`, or nothing for a deliberately
# open-ended hold. Reject the value first.
fm_captain_hold_resolve_until() {  # <value>
  case "$1" in
    '') fm_captain_hold_default_until ;;
    none) ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# An explicit value always wins. Otherwise a deadline the clock has not reached
# is kept, so an idempotent re-hold cannot shorten a window the captain was
# already given; an absent, lapsed or unreadable one takes the default.
# A RE-ASK is the opposite case and never comes through here: `bin/fm-ask.sh again`
# asks a new question, so it always takes fm_captain_hold_default_until and carries
# no deadline forward, whether the row's was future, lapsed or absent.
fm_captain_hold_effective_until() {  # <explicit> <existing>
  if [ -z "$1" ] && fm_captain_hold_until_is_future "$2"; then
    printf '%s\n' "$2"
    return 0
  fi
  fm_captain_hold_resolve_until "$1"
}

# Same reporting shape as fm_captain_hold_until_reject. Defense in depth for a
# stripped or forked build that advertises a compatible version without the flags.
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

# An empty <until> is the deliberate open-ended hold, not a missing value.
fm_captain_hold_write() {  # <id> <reason> <until>
  if [ -n "$3" ]; then
    (cd "$FM_HOME" && tasks-axi hold "$1" --reason "$2" --kind captain --until "$3" >/dev/null)
  else
    (cd "$FM_HOME" && tasks-axi hold "$1" --reason "$2" --kind captain >/dev/null)
  fi
}

# Appended after any caller-chosen fields: none of these can contain a comma, so
# a title or hold reason that does cannot shift them out of position.
FM_CAPTAIN_HOLD_LAPSE_FIELDS=hold_kind,hold_until,held

# tasks-axi's own listing row for every queued row whose CAPTAIN hold has lapsed,
# read from the tool's verdict rather than a clock of ours. A lapsed hold of any
# other kind is a scheduling gate that opened and is never listed.
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

fm_captain_hold_lapsed_row_ids() {  # <rows>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/,.*//'
}

# Filters a `tasks-axi ready` rendering on stdin: drops the <lapsed-ids> rows,
# restates the count and ready[N] header to match, and discloses the withheld
# count after the rows. <where-listed> is the caller's own pointer, because each
# surface shows the withheld rows somewhere different or nowhere at all.
fm_captain_hold_withhold_lapsed() {  # <lapsed-ids> <where-listed>
  FM_CAPTAIN_HOLD_LAPSED_IDS="$1" awk -v where="$2" '
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
          printf "(%d lapsed captain hold(s) withheld from this group; %s)\n", withheld, where
        }
      }
    }
  '
}

# Firstmate's dispatchable-now set, the function under bin/fm-ready.sh. Pass
# <lapsed-ids> when the caller already listed them; otherwise they are queried
# here. A failed lapse query fails the call rather than withholding nothing.
fm_captain_hold_ready() {  # <backlog-path> <where-listed> [<lapsed-ids>]
  local path=$1 where=$2 lapsed_ids=${3:-} rows ready
  if [ "$#" -lt 3 ]; then
    rows=$(fm_captain_hold_lapsed_rows "$path") || { printf '%s\n' "$rows"; return 1; }
    lapsed_ids=$(fm_captain_hold_lapsed_row_ids "$rows")
  fi
  ready=$(tasks-axi ready --file "$path" 2>&1) || { printf '%s\n' "$ready"; return 1; }
  printf '%s\n' "$ready" | fm_captain_hold_withhold_lapsed "$lapsed_ids" "$where"
}
