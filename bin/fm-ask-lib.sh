# shellcheck shell=bash
# fm-ask-lib.sh - the one owner of the captain-ask identity and its revision ledger.
# Usage: . bin/fm-ask-lib.sh
#
# A captain-held backlog row is a QUESTION firstmate is putting to the captain, and
# an attention board needs to know when two sightings of that row are the same
# question. Deriving that from the row's prose is what made an answered question
# come back: firstmate rewrites a hold reason to make it clearer or action-first,
# and a prose-derived identity turns that rewrite into a brand-new question the
# captain's earlier answer no longer settles.
#
# So the identity names the SUBJECT, and re-asking is a deliberate act:
#
#   fm-ask/1:<subject>:<hold-kind>:<revision>
#
#   subject     the backlog item id. For a decision hold that is the durable
#               <origin-id>-decision-<key> bin/fm-decision-hold.sh mints, which
#               already survives every rewrite of the reason.
#   hold-kind   always "captain" today. It is in the string so a future carded
#               hold of another kind cannot collide with a captain ask on the
#               same item rather than because it varies.
#   revision    producer-owned, 1 until firstmate deliberately re-asks.
#
# Nothing about the reason, the title, the options a reader might parse out of the
# prose, or the board's own card kind is in it. Rewriting any of those preserves
# the identity, which is the safe default and costs the author nothing.
#
# THE REVISION LEDGER: $FM_HOME/data/ask-revisions, one "<subject>=<revision>"
# line per re-asked subject, "#" comments and blank lines ignored, last line for a
# subject wins. It is durable private fleet data, not runtime state, so it outlives
# every teardown that prunes state/<id>.* - a subject that dropped back to an
# earlier revision would let an old answer settle a genuinely new question.
#
# An absent file and an absent line both mean revision 1, so the ledger stays empty
# until firstmate actually re-asks, and only bin/fm-ask.sh writes it. That is what
# makes "a reason rewrite never re-asks" true by construction rather than by
# remembering to preserve something: no rewrite path touches this file at all.
#
# A ledger that exists but cannot be read is NOT the same as an absent one: the read
# reports failure, bin/fm-ask.sh refuses rather than answering 1, and the snapshot
# publishes no identity for any row. Answering 1 for a subject already recorded
# higher would hand an old answer a genuinely new question.
#
# A line with no "=" or whose key is not a privacy-safe slug is ignored, so a human
# annotation is tolerated. A line whose key IS a valid subject but whose value is
# not a positive integer is a different thing: that subject was re-asked and its
# revision is now unknowable, so it gets no identity at all - bin/fm-ask.sh fails
# naming the line and the snapshot publishes null for that subject only. Reading it
# as revision 1, as an absent line legitimately is, would silently return the
# subject to an earlier revision and let an old answer settle a genuinely new
# question. As everywhere in the ledger the last line for a subject wins, so a
# later valid line repairs an earlier malformed one.
#
# A re-ask rewrites only its own subject's line, so comments and every other line
# a human wrote survive it.

fm_ask_ledger_path() {  # [<data-dir>]
  local data=${1:-${FM_DATA_OVERRIDE:-${FM_HOME:-.}/data}}
  printf '%s/ask-revisions\n' "$data"
}

# The one reading of a ledger line, shared by every awk program below. fm_ask_pair
# fills out["key"] and out["val"] and returns 1 for a valid pair, returns 2 with
# only out["key"] filled for a valid subject carrying a malformed value, and
# returns 0 for a line the ledger ignores.
_FM_ASK_LEDGER_AWK='
function fm_ask_pair(line, out,    f, n) {
  if (line ~ /^[[:space:]]*(#|$)/) return 0
  n = split(line, f, "=")
  if (n < 2) return 0
  out["key"] = f[1]; sub(/^[[:space:]]+/, "", out["key"]); sub(/[[:space:]]+$/, "", out["key"])
  out["val"] = f[2]; sub(/^[[:space:]]+/, "", out["val"]); sub(/[[:space:]]+$/, "", out["val"])
  if (out["key"] !~ /^[A-Za-z0-9._-]+$/) return 0
  if (out["val"] !~ /^[0-9]+$/ || out["val"] + 0 < 1) return 2
  out["val"] = out["val"] + 0
  return 1
}
'

# Prints "<subject>\t<revision>", one per subject. A subject whose winning line
# carries a malformed value prints "<subject>\t!line <n>: <the line>" instead.
fm_ask_ledger_pairs() {  # <ledger-path>
  local ledger=$1 pairs
  [ -f "$ledger" ] || return 0
  pairs=$(LC_ALL=C awk "$_FM_ASK_LEDGER_AWK"'
    {
      kind = fm_ask_pair($0, p)
      if (kind == 1) pairs[p["key"]] = p["val"]
      else if (kind == 2) pairs[p["key"]] = "!line " NR ": " $0
    }
    END { for (k in pairs) printf "%s\t%s\n", k, pairs[k] }
  ' "$ledger") || return 1
  [ -z "$pairs" ] || printf '%s\n' "$pairs"
}

fm_ask_is_subject() {  # <subject>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The lookup rule, over pairs already read. fm_ask_ledger_pairs keeps one entry
# per subject, so the first match is the answer. A subject whose value is malformed
# has no revision: this prints the offending ledger line instead and returns 2.
fm_ask_revision_in() {  # <pairs-text> <subject>
  local key value
  if fm_ask_is_subject "$2"; then
    while IFS=$'\t' read -r key value; do
      [ "$key" = "$2" ] || continue
      case "$value" in
        '!'*) printf '%s\n' "${value#!}"; return 2 ;;
      esac
      printf '%s\n' "$value"
      return 0
    done <<EOF
$1
EOF
  fi
  printf '1\n'
}

# Returns 1 when the ledger cannot be read, and 2 with the offending line printed
# when the subject's value is malformed.
fm_ask_revision() {  # <ledger-path> <subject>
  local pairs
  pairs=$(fm_ask_ledger_pairs "$1") || return 1
  fm_ask_revision_in "$pairs" "$2"
}

fm_ask_id() {  # <subject> <hold-kind> <revision>
  printf 'fm-ask/1:%s:%s:%s\n' "$1" "$2" "$3"
}

# Rewrite <ledger-path> so <subject> records <revision>, touching only that
# subject's own line: the last line naming it is rewritten in place, an earlier
# duplicate is dropped, a subject with no line is appended, and a revision of 1
# removes the line so the ledger keeps naming exactly the re-asked subjects.
# Every failure says why on stderr, in its own words or the failing tool's.
fm_ask_write_revision() {  # <ledger-path> <subject> <revision>
  local ledger=$1 subject=$2 revision=$3 tmp dir
  fm_ask_is_subject "$subject" || { printf 'subject is not a privacy-safe slug: %s\n' "$subject" >&2; return 1; }
  case "$revision" in
    ''|*[!0-9]*) printf 'revision is not a positive integer: %s\n' "$revision" >&2; return 1 ;;
  esac
  revision=$((10#$revision))
  [ "$revision" -ge 1 ] || { printf 'revision is not a positive integer: %s\n' "$revision" >&2; return 1; }
  dir=$(dirname "$ledger")
  [ -d "$dir" ] || { printf 'ledger directory does not exist: %s\n' "$dir" >&2; return 1; }
  tmp=$(mktemp "$ledger.XXXXXX") || return 1
  {
    if [ -f "$ledger" ]; then
      LC_ALL=C awk -v k="$subject" -v r="$revision" "$_FM_ASK_LEDGER_AWK"'
        {
          line[NR] = $0
          mine[NR] = (fm_ask_pair($0, p) && p["key"] == k)
          if (mine[NR]) last = NR
        }
        END {
          for (i = 1; i <= NR; i++) {
            if (!mine[i]) print line[i]
            else if (i == last && r != 1) printf "%s=%s\n", k, r
          }
          if (!last && r != 1) printf "%s=%s\n", k, r
        }' "$ledger"
    else
      printf '# Captain-ask revisions, written only by bin/fm-ask.sh again.\n'
      printf '# An absent subject is revision 1; see bin/fm-ask-lib.sh.\n'
      [ "$revision" = 1 ] || printf '%s=%s\n' "$subject" "$revision"
    fi
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$ledger" || { rm -f "$tmp"; return 1; }
}

# Add ask_id and ask_revision to every structured record of a backlog_json
# document read on stdin, printing the annotated document. Both fields are null on
# a record that carries no captain ask, so a consumer always finds the key.
#
# A row is a captain ask when it carries a captain hold and is not yet Done, which
# includes a hold whose deadline has lapsed: a lapse is neither an answer nor a new
# question, so it must not move the identity. A Done row keeps its
# "(hold: ...) (hold-kind: captain)" markers on the item line, so the Done test is
# what stops an answered card from still publishing a live identity.
#
# The identity itself is composed here in shell rather than in jq, so the form
# above has exactly one writer. The subject alphabet is also what makes the
# composed map safe to build as text: data/backlog.md is hand-maintainable and its
# ids are not validated anywhere upstream, so a row whose id is outside the slug
# alphabet publishes no identity at all rather than a quoted-in string.
#
# Both payloads reach jq on stdin, never as an argument: the annotated document is
# unbounded, and the map grows with the fleet's captain holds.
#
# A ledger that cannot be read leaves every record null, and a subject whose ledger
# value is malformed leaves that one record null, which is the same "no identity"
# answer a consumer already handles for an out-of-alphabet id, rather than a
# published revision 1 the ledger never said.
fm_ask_annotate_backlog_json() {  # [<ledger-path>]
  local ledger=${1:-$(fm_ask_ledger_path)} parsed pairs subject revision entries='' sep='' ask_row
  ask_row='def ask_row: .structured == true and .state != "done" and .hold_kind == "captain" and .hold_reason != null and .id != null;'
  parsed=$(cat)
  if pairs=$(fm_ask_ledger_pairs "$ledger"); then
    while IFS= read -r subject; do
      fm_ask_is_subject "$subject" || continue
      revision=$(fm_ask_revision_in "$pairs" "$subject") || continue
      entries="$entries$sep\"$subject\":{\"ask_id\":\"$(fm_ask_id "$subject" captain "$revision")\",\"ask_revision\":$revision}"
      sep=','
    done <<EOF
$(printf '%s' "$parsed" | jq -r "$ask_row"' .records[]? | select(ask_row) | .id')
EOF
  fi
  {
    printf '{%s}\n' "$entries"
    printf '%s\n' "$parsed"
  } | jq -s "$ask_row"'
    .[0] as $asks
    | .[1]
    | .records |= map(
        if .structured == true then
          . + {ask_id: null, ask_revision: null} + (if ask_row then ($asks[.id] // {}) else {} end)
        else . end)
  '
}
