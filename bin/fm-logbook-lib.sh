#!/usr/bin/env bash
# Shared config resolution and the POST helper for the logbook attention-board
# client (fm-logbook-up.sh, fm-logbook-push.sh, fm-logbook-sync.sh, and
# fm-logbook-resolve.sh). logbook is a local, loopback-only "what needs you" board
# that firstmate FEEDS; this is the mirror of fm-x-lib.sh with the public relay
# swapped for a 127.0.0.1 tool server. It ships for every user but is inert unless
# opted in via config/logbook.env with a truthy LOGBOOK_ENABLE (section 15).
#
# This file is sourced, never executed. It defines:
#   LOGBOOK_COMPOSE_PRODUCER      - the card-ownership stamp (see below)
#   LOGBOOK_ITEM_NORM_JQ          - the ONE jq normalization of a card's content
#                                   (see below), read by every script that has to
#                                   decide "is this still the same card"
#   logbook_item_hash             - content hash of one item read on stdin
#   logbook_cleared_record <id> <board-file> - remember that <id> was cleared, with
#                                   the content it carried when it was
#   logbook_cleared_filter <composed-file> <board-file|""> <out-file> - the settled-card
#                                   rule for both compose-driven writers: writes the
#                                   JSON array of ids to SUPPRESS and evicts spent records
#   logbook_env_get <key> <file>  - read one KEY=VALUE from a .env-style file
#   logbook_load_config           - resolve LOGBOOK_ENABLE, LOGBOOK_URL,
#                                   LOGBOOK_TOKEN, LOGBOOK_TOOL_DIR, LOGBOOK_PORT,
#                                   and LOGBOOK_DRY (an explicit environment value
#                                   wins over config/logbook.env)
#   logbook_enabled               - succeed when LOGBOOK_ENABLE is truthy
#   logbook_valid_id <id>         - validate an item id as the tool's safe slug
#                                   (starts alphanumeric, then [A-Za-z0-9._:-],
#                                   <=200 chars, no "..")
#   logbook_auth_header_file      - write the bearer header to a 0600 temp file
#   logbook_get_board <out-file>  - GET /api/board through logbook_get_json and
#                                   answer for the BOARD VIEW rather than for the
#                                   request; the one gate every board reader uses
#   logbook_get_json <api-path> <out-file> - bounded curl GET of
#                                   $LOGBOOK_URL<api-path> into <out-file> with the
#                                   bearer token. A GET has no side effects, so
#                                   there is NO dry-run branch: even a dry-run
#                                   caller must read to compose its body
#   logbook_post_json <api-path> <json-file|-> [outbox-name] - bounded curl POST
#                                   to $LOGBOOK_URL<api-path>; under LOGBOOK_DRY it
#                                   records the would-be body to
#                                   state/logbook-outbox/<name>.json and skips the
#                                   network AND the token entirely (mirrors
#                                   FMX_DRY_RUN)
# Callers must have FM_HOME set before calling logbook_load_config.

LOGBOOK_DEFAULT_URL="http://127.0.0.1:8137"
LOGBOOK_DEFAULT_PORT="8137"

# The CARD-OWNERSHIP STAMP, written into every card's opaque "source" blob by
# bin/fm-logbook-compose.sh and read back off the live board by
# bin/fm-logbook-resync.sh. It is the single fact that lets the automatic refresh
# tell its OWN mechanical baseline apart from a rich card firstmate hand-composed
# through bin/fm-logbook-push.sh, so the refresh can overwrite and clear the former
# while never touching the latter. It lives here, in the file both scripts already
# source, so the writer and the reader can never drift onto two different values.
# A card with no stamp (pushed by hand, or composed before this existed) is NOT
# owned, which is the safe default in both directions: it is never overwritten and
# never cleared.
LOGBOOK_COMPOSE_PRODUCER="fm-logbook-compose"

# The ONE normalization of a card's CONTENT, as a jq definition every script that has
# to decide "is this still the same card" reads from here. It keeps exactly the fields
# bin/fm-logbook-compose.sh declares, defaulted so an absent field and an empty one
# compare equal, and drops everything the TOOL fills in (status, priority, timestamps)
# so a card the board merely echoed back can never read as a difference.
#
# It lives here because three scripts now depend on agreeing about it byte for byte:
# bin/fm-logbook-resync.sh diffs the live board against the composed set with it,
# bin/fm-logbook-resolve.sh hashes a card through it when it clears one, and both
# compose-driven writers hash the composed item through it again to decide whether a
# cleared card is the SAME question the captain already settled. Two copies of this
# definition drifting apart would silently turn "settled" into "changed", which is the
# board re-asking an answered question - the exact failure the record exists to prevent.
LOGBOOK_ITEM_NORM_JQ='def norm:
    { id, project: (.project // ""), subproject: (.subproject // ""),
      kind, title, body: (.body // ""), options: (.options // []),
      source: (.source // null) };'

# The OWNERSHIP TEST over a board card, as the jq companion to the stamp above and for
# the same reason the stamp's value lives here: bin/fm-logbook-resync.sh asks it of every
# card it is about to rewrite or clear, and the settled-card record below asks it of a
# card being cleared to decide whether the board content and the composed content are
# even comparable. Two copies of this predicate answering differently would let one of
# those two decide "mine" while the other decides "someone else's".
# shellcheck disable=SC2016  # single quotes are deliberate: $producer is jq's own named argument, bound by the caller with --arg, and must reach jq unexpanded.
LOGBOOK_ITEM_OWNED_JQ='def owned($producer):
    ((.source | type) == "object") and (.source.producer == $producer);'

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
logbook_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Extract the explicit port from a URL (scheme://host[:port][/path]); print nothing
# (and succeed) when the URL carries no explicit numeric port. POSIX parameter
# expansion only, so it is set -eu/set -u safe and needs no external tools.
logbook_url_port() {
  local url=${1-} rest hostport port
  rest=${url#*://}       # strip scheme://
  hostport=${rest%%/*}   # strip any /path
  case "$hostport" in
    \[*\]) port= ;;                    # bracketed IPv6 literal, no port
    \[*\]:*) port=${hostport##*:} ;;   # [ipv6]:port
    *:*) port=${hostport##*:} ;;       # host:port
    *) port= ;;
  esac
  case "$port" in
    ''|*[!0-9]*) return 0 ;;           # no port or non-numeric: print nothing
  esac
  printf '%s' "$port"
}

# Resolve the logbook settings into LOGBOOK_ENABLE, LOGBOOK_URL, LOGBOOK_TOKEN,
# LOGBOOK_TOOL_DIR, LOGBOOK_PORT, and LOGBOOK_DRY. An explicit environment variable
# (even when empty) always wins over config/logbook.env. The board URL defaults to
# the loopback address and the tool dir to this home's projects/logbook clone; the
# port, when not set explicitly, is derived from the resolved LOGBOOK_URL (falling
# back to 8137 only when the URL carries no explicit port) so a lone URL override
# cannot mismatch the server bind port and the client URL. All are resolved at
# runtime; LOGBOOK_DRY is "1" when LOGBOOK_DRY_RUN is truthy (anything other than
# unset/empty/0/false/no/off) and "" otherwise.
logbook_load_config() {
  local config_file dry
  config_file="${LOGBOOK_ENV_FILE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/logbook.env}"

  if [ -n "${LOGBOOK_ENABLE+x}" ]; then
    LOGBOOK_ENABLE=${LOGBOOK_ENABLE-}
  else
    LOGBOOK_ENABLE=$(logbook_env_get LOGBOOK_ENABLE "$config_file")
  fi

  if [ -n "${LOGBOOK_URL+x}" ]; then
    LOGBOOK_URL=${LOGBOOK_URL-}
  else
    LOGBOOK_URL=$(logbook_env_get LOGBOOK_URL "$config_file")
  fi
  [ -n "$LOGBOOK_URL" ] || LOGBOOK_URL="$LOGBOOK_DEFAULT_URL"
  LOGBOOK_URL=${LOGBOOK_URL%/}

  if [ -n "${LOGBOOK_TOKEN+x}" ]; then
    LOGBOOK_TOKEN=${LOGBOOK_TOKEN-}
  else
    LOGBOOK_TOKEN=$(logbook_env_get LOGBOOK_TOKEN "$config_file")
  fi

  if [ -n "${LOGBOOK_TOOL_DIR+x}" ]; then
    LOGBOOK_TOOL_DIR=${LOGBOOK_TOOL_DIR-}
  else
    LOGBOOK_TOOL_DIR=$(logbook_env_get LOGBOOK_TOOL_DIR "$config_file")
  fi
  [ -n "$LOGBOOK_TOOL_DIR" ] || LOGBOOK_TOOL_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/logbook"

  # An explicit LOGBOOK_PORT (env or file) wins. Otherwise derive the port from the
  # already-resolved LOGBOOK_URL so a lone URL override cannot silently mismatch the
  # server bind port and the client/health-check URL; fall back to 8137 only when
  # the URL carries no explicit port.
  if [ -n "${LOGBOOK_PORT+x}" ]; then
    LOGBOOK_PORT=${LOGBOOK_PORT-}
  else
    LOGBOOK_PORT=$(logbook_env_get LOGBOOK_PORT "$config_file")
  fi
  if [ -z "$LOGBOOK_PORT" ]; then
    LOGBOOK_PORT=$(logbook_url_port "$LOGBOOK_URL")
    [ -n "$LOGBOOK_PORT" ] || LOGBOOK_PORT="$LOGBOOK_DEFAULT_PORT"
  fi

  if [ -n "${LOGBOOK_DRY_RUN+x}" ]; then
    dry=${LOGBOOK_DRY_RUN-}
  else
    dry=$(logbook_env_get LOGBOOK_DRY_RUN "$config_file")
  fi
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) LOGBOOK_DRY="" ;;
    *) LOGBOOK_DRY=1 ;;
  esac

  # Where dry-run previews are recorded; mirrors the client scripts' own STATE.
  LOGBOOK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  # The settled-card record: { "<item id>": "<content hash>" } for every card
  # fm-logbook-resolve.sh actually cleared, so neither compose-driven writer puts an
  # answered question straight back on the board.
  LOGBOOK_CLEARED_FILE="$LOGBOOK_STATE/logbook-cleared.json"

  # Mark the resolved config surface as read: LOGBOOK_TOOL_DIR/LOGBOOK_PORT are
  # consumed by fm-logbook-up.sh and LOGBOOK_ENABLE by logbook_enabled after
  # sourcing, so shellcheck must not flag them as unused within this library.
  # LOGBOOK_COMPOSE_PRODUCER rides the same marker: it is a constant this file only
  # declares, read by fm-logbook-compose.sh and fm-logbook-resync.sh after sourcing.
  : "$LOGBOOK_ENABLE" "$LOGBOOK_TOKEN" "$LOGBOOK_TOOL_DIR" "$LOGBOOK_PORT" \
    "$LOGBOOK_URL" "$LOGBOOK_DRY" "$LOGBOOK_STATE" "$LOGBOOK_COMPOSE_PRODUCER" \
    "$LOGBOOK_CLEARED_FILE" "$LOGBOOK_ITEM_NORM_JQ" "$LOGBOOK_ITEM_OWNED_JQ"
}

# THE SETTLED-CARD RECORD. docs/configuration.md "Board refresh" owns the contract;
# this is how it is implemented.
#
# GET /api/board deliberately omits resolved and dismissed rows, so a card the captain
# answered and firstmate then CLEARED is simply ABSENT to a compose-driven writer - and a
# writer whose rule is "add what the board lacks" re-adds it as a pending card for as
# long as its task stays in the composed set. The captain taps Hold or Done, firstmate
# acts and clears the card, and the board asks the same settled question again. That is
# the failure this whole surface exists to remove, so both compose-driven writers -
# bin/fm-logbook-resync.sh on the watcher beat and bin/fm-logbook-refresh.sh at session
# start - consult this record before they declare a card the board does not have.
#
# ONLY A CAPTAIN-ANSWERED CLEAR MAY RECORD. Clearing is not one act: the answer loop
# clears because the captain decided and firstmate acted, while the refresh clears
# MECHANICALLY, because the work simply left the attention set. Recording the mechanical
# one would suppress the card if that same work ever came back unchanged - a task parked
# to Queued and later resumed - which is the original under-reporting bug re-introduced
# for resumed work. So the caller says which kind of clear it performed
# (LOGBOOK_MECHANICAL_CLEAR in bin/fm-logbook-resolve.sh), and recording is the default
# because the answer loop is every other caller.
#
# The record is CONTENT-KEYED rather than a plain id list: a cleared id whose composed
# content still hashes the same is the settled question and stays down, while a differing
# hash means the situation genuinely moved on and the card goes back up (and the record
# is dropped). That mirrors the board tool's own rule, that a client re-declaring a
# cleared id is the client saying the work needs the captain again.
#
# BOTH SIDES OF THAT COMPARISON MUST BE THE SAME SIDE - compose's baseline content - or
# the guard means nothing. For a compose-OWNED card the board content and the composed
# content are identical, so the board hash taken at clear time is already that value.
# For a card that is NOT owned - a hand-composed escalation pushed through
# bin/fm-logbook-push.sh, which never carries the ownership stamp (and must not: the
# refresh would then flatten it back to the baseline every cycle, which is why that
# script strips the stamp rather than trusting each escalation to omit it) - the two can
# never match, because `source` alone differs and `source` is inside the normalization.
# Those record a SENTINEL instead, the empty hash, which the reader treats as "suppress
# on this pass, and adopt the composed hash you see now". From then on the id is compared
# like-for-like and stays down until its COMPOSED content actually changes.
#
# cksum/CRC32 is the hash, for the reason the refresh gives for its own fingerprint: a
# collision costs one card that stays down until its content moves again, which does
# not justify a non-POSIX dependency.

# logbook_item_hash: read ONE item object on stdin, print its content hash. Prints
# nothing and fails when the input is not an item or the tools are missing, so a caller
# can never mistake "could not hash" for a hash that matched.
#
# Keys are SORTED (-S) before the bytes are hashed. The normalization above fixes the
# top-level order but copies `source` and `options` through verbatim, so their internal
# order is whatever the input carried - and the two sides of this comparison come from
# different places: the record hashes a card as GET /api/board returned it, while both
# readers hash compose's own output. The board validates and rebuilds every item it
# stores, so it owes no byte-for-byte round trip of a nested object; without -S a
# re-serialized `source` would make every recorded hash unmatchable, and the settled
# card would be re-asked on the very next cycle with no diagnostic anywhere. Sorting
# makes the record independent of the board's serialization, and it is symmetric
# because both sides go through this one function.
logbook_item_hash() {
  local normalized
  normalized=$(jq -cS "$LOGBOOK_ITEM_NORM_JQ norm" 2>/dev/null) || return 1
  [ -n "$normalized" ] || return 1
  printf '%s' "$normalized" | cksum 2>/dev/null | awk '{ print $1 "-" $2 }'
}

# THE RECORD'S SINGLE-WRITER LOCK.
#
# state/logbook-cleared.json has two writers by design - fm-logbook-resolve.sh from
# firstmate's interactive answer loop, and the refresh on the watcher beat - and both
# read-modify-write it. They overlap on exactly the turns where clears happen, because
# firstmate's own backlog edits are what break the fingerprint that makes the refresh
# fire. A clear landing inside the filter's read/replace window would be dropped, and
# the settled card re-asked on the next cycle: the failure this whole surface exists to
# remove, so the window is worth closing even though it is milliseconds wide.
#
# FAIL-OPEN, always. A lock that cannot be taken must never fail a clear or wedge a
# refresh, so both holders proceed unlocked after a bounded wait - which is exactly
# today's behavior, and no worse. A lock dir older than a minute cannot be a live
# holder (both do a handful of jq calls and release), so it is broken rather than
# allowed to make the record permanently unserialized.
LOGBOOK_CLEARED_LOCK=""

logbook_cleared_lock() {
  local lock tries=0
  [ -n "${LOGBOOK_CLEARED_FILE:-}" ] || return 1
  lock="$LOGBOOK_CLEARED_FILE.lock"
  mkdir -p "${LOGBOOK_CLEARED_FILE%/*}" 2>/dev/null || return 1
  while [ "$tries" -lt 20 ]; do
    if mkdir "$lock" 2>/dev/null; then
      LOGBOOK_CLEARED_LOCK=$lock
      return 0
    fi
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    sleep 0.05 2>/dev/null || true
    tries=$((tries + 1))
  done
  return 1
}

logbook_cleared_unlock() {
  [ -n "${LOGBOOK_CLEARED_LOCK:-}" ] || return 0
  rmdir "$LOGBOOK_CLEARED_LOCK" 2>/dev/null || true
  LOGBOOK_CLEARED_LOCK=""
}

# logbook_cleared_record <id> <board-body-file>: remember that <id> was cleared. An
# OWNED card records the hash of the card as the board still held it, which is the same
# value compose derives; an unowned one records the empty sentinel, because its board
# content is not comparable with anything compose produces. Returns non-zero without
# disturbing the existing record when it cannot, so a caller can warn: the clear itself
# is the important half and must never fail on this. Serialized against the refresh's
# own read-modify-write by the fail-open lock above; the wrapper is what guarantees the
# lock is released on every return path the body takes.
logbook_cleared_record() {
  local rc
  logbook_cleared_lock || true
  if logbook_cleared_record_locked "$@"; then rc=0; else rc=$?; fi
  logbook_cleared_unlock
  return "$rc"
}

logbook_cleared_record_locked() {
  local id=${1-} board=${2-} card hash existing dir tmp
  [ -n "$id" ] && [ -n "${LOGBOOK_CLEARED_FILE:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  card=$(jq -c --arg id "$id" 'first((.items // [])[] | select(.id == $id))' "$board" 2>/dev/null) || return 1
  [ -n "$card" ] || return 1
  hash=""
  if printf '%s' "$card" | jq -e --arg producer "$LOGBOOK_COMPOSE_PRODUCER" \
       "$LOGBOOK_ITEM_OWNED_JQ owned(\$producer)" >/dev/null 2>&1; then
    hash=$(printf '%s' "$card" | logbook_item_hash) || return 1
    [ -n "$hash" ] || return 1
  fi

  # A record that is there and cannot be READ is not a corrupt one, and the difference
  # matters: falling back to "{}" here would write this one clear over every clear the
  # captain has answered so far. Refuse the record instead, without touching the file -
  # the caller warns, the clear itself still lands, and nothing is forgotten.
  existing='{}'
  if [ -s "$LOGBOOK_CLEARED_FILE" ]; then
    [ -r "$LOGBOOK_CLEARED_FILE" ] || return 1
    existing=$(jq -c 'if type == "object" then . else {} end' "$LOGBOOK_CLEARED_FILE" 2>/dev/null) || existing='{}'
    [ -n "$existing" ] || existing='{}'
  fi
  dir=${LOGBOOK_CLEARED_FILE%/*}
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.logbook-cleared.XXXXXX" 2>/dev/null) || return 1
  if jq -nc --argjson cur "$existing" --arg id "$id" --arg hash "$hash" \
       '$cur + { ($id): $hash }' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$LOGBOOK_CLEARED_FILE" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# logbook_cleared_filter <composed-body-file> <board-body-file|""> <out-file>
# The reader half, shared by both compose-driven writers so they cannot diverge on what
# "settled" means. It writes the JSON array of composed ids to SUPPRESS to <out-file>
# (always valid JSON, "[]" when there is nothing to suppress) and maintains the record
# in the same pass, so it cannot grow without bound:
#   - recorded id no longer in the composed set  -> evict (nothing left to suppress)
#   - recorded id back on the board              -> evict (something re-added it)
#   - recorded id composed with a DIFFERENT hash -> evict, and let the card go back up
#   - recorded id composed with the SAME hash    -> suppress; the captain settled it
#   - recorded id holding the empty SENTINEL     -> suppress, and adopt the composed hash
#                                                   it has now, so every later pass
#                                                   compares like with like
# Pass "" for the board only from a caller whose suppression means "do not ADD this id":
# the two board-dependent rules then simply do not fire, and the next cycle with a view
# applies them. A caller whose payload is DECLARATIVE must not: there, leaving an id out
# means DELETE, and the "recorded id is back on the board -> evict" rule is the only
# thing standing between a settled id and the destruction of a fresh card firstmate has
# since pushed under it. bin/fm-logbook-refresh.sh is that caller, and it skips this
# filter entirely rather than call it with no view.
# Always returns 0: a record it cannot read must degrade to the old behavior (the card
# reappears), never to a failed refresh. Serialized against a concurrent clear by the
# fail-open lock above, through the same wrapper shape the writer uses.
logbook_cleared_filter() {
  local rc
  logbook_cleared_lock || true
  if logbook_cleared_filter_locked "$@"; then rc=0; else rc=$?; fi
  logbook_cleared_unlock
  return "$rc"
}

logbook_cleared_filter_locked() {
  local composed=${1-} board=${2-} out=${3-}
  local record=${LOGBOOK_CLEARED_FILE:-} board_ids='[]' plan verb id want have
  local keep="" drop="" adopt="" dropped adopted suppress dir tmp

  [ -n "$out" ] || return 0
  printf '[]\n' > "$out" 2>/dev/null || return 0
  [ -n "$record" ] && [ -s "$record" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # Unreadable is not corrupt, and only one of the two may cost the captain their
  # answers. A record this pass cannot open degrades to the documented fail-open (no
  # suppression this cycle, so the card reappears) with the FILE LEFT ALONE, so the next
  # readable pass honors it again. Only a file jq actually parsed and found not to be
  # this object is dropped.
  [ -r "$record" ] || return 0
  if ! jq -e 'type == "object"' "$record" >/dev/null 2>&1; then
    # A record that is not the object this owns cannot be reasoned about; drop it
    # rather than let a corrupt file suppress cards forever.
    rm -f "$record" 2>/dev/null
    return 0
  fi
  if [ -n "$board" ] && [ -s "$board" ]; then
    board_ids=$(jq -c '[ (.items // [])[] | .id ]' "$board" 2>/dev/null) || board_ids='[]'
    [ -n "$board_ids" ] || board_ids='[]'
  fi

  # Every lookup argument is bound before use: jq evaluates an argument to index()
  # against the value being searched, not against the item in hand.
  plan=$(jq -r --slurpfile rec "$record" --argjson bids "$board_ids" '
      ($rec[0] // {}) as $r
      | ([ (.items // [])[] | .id ]) as $cids
      | $r
      | keys_unsorted[]
      | . as $id
      | if (($cids | index($id)) == null) or (($bids | index($id)) != null)
        then "drop " + $id
        else "check " + $id end' "$composed" 2>/dev/null) || plan=""

  while IFS=' ' read -r verb id; do
    [ -n "$id" ] || continue
    if [ "$verb" = drop ]; then
      drop="$drop$id
"
      continue
    fi
    want=$(jq -r --arg id "$id" '.[$id] // ""' "$record" 2>/dev/null) || want=""
    have=$(jq -c --arg id "$id" 'first((.items // [])[] | select(.id == $id))' "$composed" 2>/dev/null \
      | logbook_item_hash) || have=""
    # A hash that could not be computed counts as CHANGED, so a broken tool degrades
    # to the board re-asking rather than to a card silently held down.
    if [ -z "$want" ]; then
      keep="$keep$id
"
      [ -n "$have" ] && adopt="$adopt$id	$have
"
    elif [ -n "$have" ] && [ "$have" = "$want" ]; then
      keep="$keep$id
"
    else
      drop="$drop$id
"
    fi
  done <<EOF
$plan
EOF

  suppress=$(printf '%s' "$keep" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || suppress='[]'
  [ -n "$suppress" ] || suppress='[]'
  printf '%s\n' "$suppress" > "$out" 2>/dev/null || true

  # Suppression is decided above and applies on every path; only the record WRITE - the
  # evictions and the sentinel adoptions - is skipped under LOGBOOK_DRY, so a preview can
  # never change which cards a later live refresh puts in front of the captain.
  [ -z "${LOGBOOK_DRY:-}" ] || return 0
  [ -n "$drop" ] || [ -n "$adopt" ] || return 0
  dropped=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || return 0
  [ -n "$dropped" ] || return 0
  adopted=$(printf '%s' "$adopt" | jq -R -s \
    'split("\n") | map(select(length > 0) | split("\t") | { key: .[0], value: .[1] }) | from_entries' 2>/dev/null) || return 0
  [ -n "$adopted" ] || return 0
  dir=${record%/*}
  tmp=$(mktemp "$dir/.logbook-cleared.XXXXXX" 2>/dev/null) || return 0
  if jq -c --argjson drop "$dropped" --argjson adopt "$adopted" \
       'with_entries(select(.key as $k | ($drop | index($k)) == null)) + $adopt' "$record" > "$tmp" 2>/dev/null; then
    if jq -e 'length == 0' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp" "$record" 2>/dev/null
    else
      mv -f "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Succeed when LOGBOOK_ENABLE is truthy (anything other than unset/empty/0/false/
# no/off). Callers gate opt-in behavior on this after logbook_load_config.
logbook_enabled() {
  case "$(printf '%s' "${LOGBOOK_ENABLE:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Validate a value as the tool's safe slug before it is used in a path or body: it
# must start alphanumeric, contain only [A-Za-z0-9._:-] thereafter, be at most 200
# characters, and never contain "..". This is the exact rule the tool enforces, and
# the single owner of the safe-slug rule for both item ids and sub-project keys
# (fm-logbook-compose.sh validates each declared sub-project key with it).
logbook_valid_id() {
  local id=${1-}
  [ -n "$id" ] || return 1
  [ "${#id}" -le 200 ] || return 1
  case "$id" in
    [!A-Za-z0-9]*) return 1 ;;
    *..*) return 1 ;;
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  return 0
}

# Write the bearer auth header to a private 0600 temp file and print its path, so
# the token never appears in curl's argv (which is world-readable via ps). Returns
# non-zero if the token contains a newline or the temp file cannot be created.
logbook_auth_header_file() {
  local file
  case "$LOGBOOK_TOKEN" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-logbook-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$LOGBOOK_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# logbook_get_json <api-path> <out-file>
# GET $LOGBOOK_URL<api-path> into <out-file> with the bearer token (streamed via a
# 0600 header file, never on argv, exactly like logbook_post_json). A GET has no
# side effects, so there is deliberately NO dry-run branch: a resolve must read the
# card's current fields to compose the full item it will upsert, even under
# LOGBOOK_DRY (only the write is suppressed downstream, by logbook_post_json). On
# success it prints the HTTP status code and returns 0 for a 2xx; otherwise it
# writes a stderr diagnostic and returns non-zero. Runs in a subshell so its EXIT
# trap and temp files never leak into the caller.
logbook_get_json() (
  local path=$1 out=$2 auth_header_file="" code rc
  command -v curl >/dev/null 2>&1 || { echo "logbook: curl not found" >&2; return 1; }
  [ -n "$LOGBOOK_TOKEN" ] || { echo "logbook: no LOGBOOK_TOKEN configured for a board read" >&2; return 1; }
  auth_header_file=$(logbook_auth_header_file) || { echo "logbook: invalid LOGBOOK_TOKEN" >&2; return 3; }
  trap 'rm -f "$auth_header_file" 2>/dev/null || true' EXIT

  rc=0
  code=$(curl -m 10 -s -o "$out" -w '%{http_code}' \
    -H "@$auth_header_file" \
    -H 'Accept: application/json' \
    "$LOGBOOK_URL$path" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "logbook: request to the board failed" >&2
    return 4
  fi
  case "$code" in
    2[0-9][0-9]) printf '%s\n' "$code"; return 0 ;;
    *) echo "logbook: board returned HTTP $code" >&2; return 1 ;;
  esac
)

# logbook_get_board <out-file>
# THE ONE GATE EVERY BOARD READ GOES THROUGH. logbook_get_json answers for the REQUEST -
# it returns 0 for any 2xx - and a 2xx is not a board view. Every reader here indexes
# into what came back, and jq reads an empty file, a `null`, or an object that is not a
# board as A BOARD WITH NO CARDS rather than as a failed read. That silent substitution
# is the dangerous one in both directions this client writes:
#
#   - the DECLARATIVE session-start sync subtracts settled ids from its payload, and a
#     board with no ids cannot fire the "this id is back on the board -> evict" rule, so
#     a live card under a settled id is stripped from the payload and DELETED;
#   - the INCREMENTAL refresh partitions on what the board already holds, and a board
#     with no cards puts every composed item in the ADD set with the ownership test never
#     consulted, FLATTENING a hand-pushed escalation back to the mechanical baseline -
#     and the writes answer 2xx, so the cycle banks its fingerprint and never retries.
#
# So the check lives HERE, once, rather than at each call site remembering it: a board
# view is a 2xx whose body is present and is an object carrying an `items` array and a
# `projects` array, which is what GET /api/board returns and what its readers walk. A
# legitimately empty board passes; a body that merely parsed does not. On success it
# prints the HTTP status code, exactly like logbook_get_json; otherwise it returns
# non-zero, forwarding that function's own code when the request itself was the problem.
logbook_get_board() {
  local out=${1-} code
  [ -n "$out" ] || return 2
  code=$(logbook_get_json /api/board "$out") || return $?
  if [ ! -s "$out" ] || ! jq -e '
        (type == "object") and ((.items | type) == "array")
        and ((.projects | type) == "array")' "$out" >/dev/null 2>&1; then
    echo "logbook: the board URL answered, but not with a board" >&2
    return 5
  fi
  printf '%s\n' "$code"
  return 0
}

# logbook_post_json <api-path> <json-file|-> [outbox-name]
# POST the JSON in <json-file> (or stdin when "-") to $LOGBOOK_URL<api-path> with
# the bearer token. Under LOGBOOK_DRY it records the would-be body to
# state/logbook-outbox/<outbox-name>.json and skips the network AND the token
# entirely (mirrors FMX_DRY_RUN); <outbox-name> defaults to the last path segment.
# The body is streamed from a file, never inlined into an argument, so composed
# item text (title/body from fleet internals) can never break out of a shell word.
# On a live post it prints the HTTP status code and returns 0 for a 2xx, non-zero
# otherwise (with a stderr diagnostic). Runs in a subshell so its EXIT trap and
# temp files never leak into the caller.
logbook_post_json() (
  local path=$1 src=$2 outbox_name=${3:-} body_file tmp_body="" auth_header_file="" code rc outbox_dir outbox_file
  command -v jq >/dev/null 2>&1 || { echo "logbook: jq not found" >&2; return 1; }

  # Resolve the body source into a real file (slurp stdin when "-").
  if [ "$src" = "-" ]; then
    tmp_body=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-body.XXXXXX") || { echo "logbook: cannot create body temp file" >&2; return 1; }
    body_file=$tmp_body
    trap 'rm -f "$tmp_body" "$auth_header_file" 2>/dev/null || true' EXIT
    cat > "$body_file" || { echo "logbook: cannot read body from stdin" >&2; return 1; }
  else
    body_file=$src
    trap 'rm -f "$tmp_body" "$auth_header_file" 2>/dev/null || true' EXIT
  fi
  [ -r "$body_file" ] || { echo "logbook: body not readable: $body_file" >&2; return 2; }

  # Default the outbox record name to the last path segment (items, sync, ...).
  if [ -z "$outbox_name" ]; then
    outbox_name=${path##*/}
    [ -n "$outbox_name" ] || outbox_name=post
  fi
  # Guard the outbox filename against traversal (resolve passes item ids here).
  case "$outbox_name" in
    ''|*/*|*..*) echo "logbook: unsafe outbox name: $outbox_name" >&2; return 2 ;;
  esac

  # Preview / dry-run: record the would-be body and stop, without auth or network.
  if [ -n "$LOGBOOK_DRY" ]; then
    outbox_dir="$LOGBOOK_STATE/logbook-outbox"
    outbox_file="$outbox_dir/$outbox_name.json"
    mkdir -p "$outbox_dir" 2>/dev/null || { echo "logbook: cannot create dry-run outbox: $outbox_dir" >&2; return 1; }
    if ! jq -c '.' "$body_file" > "$outbox_file" 2>/dev/null; then
      rm -f "$outbox_file"
      echo "logbook: cannot record dry-run outbox: $outbox_file" >&2
      return 1
    fi
    printf 'logbook: DRY RUN - would POST to %s%s (recorded: state/logbook-outbox/%s.json)\n' \
      "$LOGBOOK_URL" "$path" "$outbox_name" >&2
    return 0
  fi

  # Live post: needs curl and a token.
  command -v curl >/dev/null 2>&1 || { echo "logbook: curl not found" >&2; return 1; }
  [ -n "$LOGBOOK_TOKEN" ] || { echo "logbook: no LOGBOOK_TOKEN configured for a live post" >&2; return 1; }
  auth_header_file=$(logbook_auth_header_file) || { echo "logbook: invalid LOGBOOK_TOKEN" >&2; return 3; }

  rc=0
  code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "@$auth_header_file" \
    -H 'Content-Type: application/json' \
    --data-binary "@$body_file" \
    "$LOGBOOK_URL$path" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "logbook: request to the board failed" >&2
    return 4
  fi
  case "$code" in
    2[0-9][0-9]) printf '%s\n' "$code"; return 0 ;;
    *) echo "logbook: board returned HTTP $code" >&2; return 1 ;;
  esac
)
