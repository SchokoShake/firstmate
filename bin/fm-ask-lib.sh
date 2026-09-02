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
# An entry whose key is not a privacy-safe slug or whose value is not a positive
# integer is ignored rather than repaired, so a hand-edit that went wrong degrades
# to revision 1 - the board's behaviour before any of this existed - instead of
# minting an identity from a malformed line.

fm_ask_ledger_path() {  # [<data-dir>]
  local data=${1:-${FM_DATA_OVERRIDE:-${FM_HOME:-.}/data}}
  printf '%s/ask-revisions\n' "$data"
}

fm_ask_ledger_pairs() {  # <ledger-path>; prints "<subject>\t<revision>", sorted
  local ledger=$1
  [ -f "$ledger" ] || return 0
  LC_ALL=C awk -F= '
    /^[[:space:]]*(#|$)/ { next }
    NF < 2 { next }
    {
      key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      val = $2; sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
      if (key ~ /^[A-Za-z0-9._-]+$/ && val ~ /^[0-9]+$/ && val + 0 >= 1) pairs[key] = val
    }
    END { for (k in pairs) printf "%s\t%s\n", k, pairs[k] }
  ' "$ledger" | LC_ALL=C sort
}

fm_ask_is_subject() {  # <subject>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The lookup rule, over pairs already read. fm_ask_ledger_pairs keeps one entry
# per subject, so the first match is the answer.
fm_ask_revision_in() {  # <pairs-text> <subject>
  local key value
  if fm_ask_is_subject "$2"; then
    while IFS=$'\t' read -r key value; do
      [ "$key" = "$2" ] || continue
      printf '%s\n' "$value"
      return 0
    done <<EOF
$1
EOF
  fi
  printf '1\n'
}

fm_ask_revision() {  # <ledger-path> <subject>
  fm_ask_revision_in "$(fm_ask_ledger_pairs "$1")" "$2"
}

fm_ask_id() {  # <subject> <hold-kind> <revision>
  printf 'fm-ask/1:%s:%s:%s\n' "$1" "$2" "$3"
}

# Rewrite <ledger-path> so <subject> records <revision>, dropping the entry again
# when it falls back to 1 so the ledger keeps naming exactly the re-asked subjects.
fm_ask_write_revision() {  # <ledger-path> <subject> <revision>
  local ledger=$1 subject=$2 revision=$3 tmp dir
  fm_ask_is_subject "$subject" || return 1
  case "$revision" in ''|*[!0-9]*|0) return 1 ;; esac
  dir=$(dirname "$ledger")
  [ -d "$dir" ] || return 1
  tmp=$(mktemp "$ledger.XXXXXX") || return 1
  {
    printf '# Captain-ask revisions, written only by bin/fm-ask.sh again.\n'
    printf '# An absent subject is revision 1; see bin/fm-ask-lib.sh.\n'
    fm_ask_ledger_pairs "$ledger" \
      | LC_ALL=C awk -F'\t' -v k="$subject" '$1 != k { printf "%s=%s\n", $1, $2 }'
    [ "$revision" = 1 ] || printf '%s=%s\n' "$subject" "$revision"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$ledger" || { rm -f "$tmp"; return 1; }
}

# Add ask_id and ask_revision to every structured record of a backlog_json
# document read on stdin, printing the annotated document. Both fields are null on
# a record that carries no captain ask, so a consumer always finds the key.
#
# A row is a captain ask when it is held for the captain and not yet Done. A Done
# row keeps its "(hold: ...) (hold-kind: captain)" markers on the item line, so the
# Done test is what stops an answered card from still publishing a live identity.
#
# The identity itself is composed here in shell rather than in jq, so the form
# above has exactly one writer. The subject alphabet is also what makes the
# composed map safe to build as text: data/backlog.md is hand-maintainable and its
# ids are not validated anywhere upstream, so a row whose id is outside the slug
# alphabet publishes no identity at all rather than a quoted-in string.
#
# Both payloads reach jq on stdin, never as an argument: the annotated document is
# unbounded, and the map grows with the fleet's captain holds.
fm_ask_annotate_backlog_json() {  # [<ledger-path>]
  local ledger=${1:-$(fm_ask_ledger_path)} parsed pairs subject revision entries='' sep=''
  parsed=$(cat)
  pairs=$(fm_ask_ledger_pairs "$ledger")
  while IFS= read -r subject; do
    fm_ask_is_subject "$subject" || continue
    revision=$(fm_ask_revision_in "$pairs" "$subject")
    entries="$entries$sep\"$subject\":{\"ask_id\":\"$(fm_ask_id "$subject" captain "$revision")\",\"ask_revision\":$revision}"
    sep=','
  done <<EOF
$(printf '%s' "$parsed" | jq -r '
    .records[]?
    | select(.structured == true and .state != "done")
    | select(.hold_kind == "captain" and .hold_reason != null and .id != null)
    | .id')
EOF
  {
    printf '{%s}\n' "$entries"
    printf '%s\n' "$parsed"
  } | jq -s '
    .[0] as $asks
    | .[1]
    | .records |= map(
        if .structured == true then
          . + {ask_id: null, ask_revision: null} + ($asks[.id // ""] // {})
        else . end)
  '
}
