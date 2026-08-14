#!/usr/bin/env bash
# Mid-session board refresh: keep the logbook attention board current as fleet state
# changes, instead of frozen at the session-start sync.
#
# Usage: fm-logbook-resync.sh
#
# This is the body of the watcher check shim state/logbook-resync.check.sh, which
# bootstrap drops on opt-in beside the board-response poll and the board-liveness
# reap. The watcher runs every *.check.sh each check cycle (15s once logbook is on,
# 300s under away mode), so the board is reconciled on the same beat those two already
# ride - and, like them, entirely through the EXISTING check rail, with no new
# scheduler, daemon, or timer and no edit to fm-watch.sh or any other
# watcher-backbone file (docs/configuration.md "Board refresh").
#
# The gap it closes: bin/fm-logbook-compose.sh has always derived the correct item set
# at any moment, but the ONLY thing that ever pushed that set to the board was the
# session-start sync in fm-bootstrap.sh. The board was therefore a photograph taken
# when the session opened, and every dispatch, completion, decision and merge after
# that was invisible until the next session unless firstmate remembered to hand-push a
# card. A board that silently under-reports is worse than one that is obviously empty,
# because the captain uses it to know what needs them.
#
# ---------------------------------------------------------------------------
# IT NEVER CALLS POST /api/sync. That is the whole point.
# ---------------------------------------------------------------------------
# /api/sync is a DECLARATIVE FULL-ITEM REPLACE: it deletes every stored item the
# payload does not list, then overwrites every column of the ones it does. Run once a
# session that is survivable - firstmate re-pushes what it wants back. Run every 15s it
# is not: it would delete every hand-pushed card compose does not know about and flatten
# every rich card compose DOES know about back to its mechanical baseline, on a timer.
# So this script reconciles INCREMENTALLY against the live board instead, and every
# write it makes is scoped by CARD OWNERSHIP:
#
#   ADD     a composed item the board does not have          -> upsert (always safe)
#   UPDATE  a composed item whose board card is OWNED and
#           whose content actually differs                   -> upsert
#   CLEAR   an OWNED board card the composed set no longer
#           contains, and which the captain has not answered -> fm-logbook-resolve.sh
#   SKIP    everything else, in particular every card this
#           script does not own
#
# Ownership is the $LOGBOOK_COMPOSE_PRODUCER stamp compose writes into each card's
# opaque "source" blob (fm-logbook-lib.sh owns the value). A hand-composed card pushed
# through fm-logbook-push.sh carries no such stamp, so this script will not rewrite it
# and will not clear it - it survives indefinitely, which is strictly better than
# today, where the next session-start sync flattens it. An unstamped card also cannot
# be cleared here, so a card compose has stopped producing but firstmate pushed by hand
# is left for firstmate or the next session-start sync to deal with.
#
# Three further protections, each guarding a way an automatic writer could be worse
# than the staleness it fixes:
#   - The captain's per-project `active` toggle. Projects go up through
#     POST /api/projects (upsert-only), NEVER through the deleting sync, and the tool's
#     upsertProject treats `active` as seed-only: a brand-new project takes the composed
#     value, an existing one keeps whatever the captain toggled. No project is ever
#     deleted on this path either; a project that leaves the registry mid-session is the
#     session-start sync's business, not a timer's.
#   - The captain's set-aside ("not now"). An unchanged card is not re-upserted at all
#     (the content diff above), so a card put down stays down - and a card that DID
#     change still keeps its set-aside unless it became a different question, because
#     the tool's own isNewClaim is far narrower than this diff. It clears the set-aside
#     in exactly two cases: an unanswerable card (an fyi) re-declared as an answerable
#     one (a decision or an action), and an ALREADY-answerable card whose options list
#     changed. A re-declared body, a new title and a moved moment are not inputs to it
#     at all, so the status line a live crewmate rewrites every few minutes - which IS a
#     composed fyi's body - cannot disturb a set-aside however often this beat re-upserts
#     it. That narrowness is the tool's, so no client-side exception is needed here and
#     none is wanted: one would only freeze a set-aside card's text while the captain has
#     it put down, and the board would then show them stale text the moment they pick it
#     back up.
#   - The captain's unacted answer. A card at status `submitted` has been answered on
#     the board and is waiting on firstmate, so THIS script neither clears it NOR
#     rewrites it: the answer loop (fm-logbook-ack.sh / fm-logbook-resolve.sh) owns it
#     end to end and clears it once firstmate acts. Both the clear set and the update
#     set test the stored status, because a mid-answer content drift - another status
#     line, a lapsed gate, an edited backlog one-liner - would otherwise re-upsert the
#     baseline over the card the captain just answered. The session-start declarative
#     sync still re-declares such a card, which is safe for a different reason that
#     belongs to the board tool rather than to this script; docs/configuration.md
#     "Board refresh" states it, and a test pins it.
#   - The captain's ANSWERED-AND-ACTED card. GET /api/board omits resolved and dismissed
#     rows, so a card firstmate already cleared reads here as a card the board lacks -
#     and the ADD rule above would put it straight back as pending, seconds after the
#     answer, for as long as its task stays in the composed set. The settled-card record
#     the answer loop writes through fm-logbook-resolve.sh is therefore consulted before
#     every ADD; docs/configuration.md "Board refresh" owns that contract and
#     fm-logbook-lib.sh implements it. The clears THIS script performs are mechanical and
#     record nothing (see the clear loop below), so a card can never be held down by its
#     own retirement.
#
# CHANGE DETECTION - an unchanged fleet must cost approximately nothing.
# Composing is not cheap (it shells out to git once per carded project), so this never
# composes speculatively. It first fingerprints exactly what compose READS - data/
# projects.md, data/backlog.md, every state/*.meta and state/*.status, and the calendar
# day - and exits without touching the network when that fingerprint is unchanged.
# Measured at 9ms on a 93KB backlog with six state files, which against a 15s cycle is a
# 0.06% duty cycle. The fingerprint hashes CONTENT rather than mtimes, so a backlog the
# backend rewrites byte-identically (tasks-axi renders the file in place on every
# mutation) does not trigger a pointless refresh; the file NAMES are hashed alongside the
# contents so a teardown removing a meta registers as a change too. cksum is CRC32 and
# could in principle collide across two successive states; the cost is one skipped
# refresh that the next real change repairs, which is why a stronger digest is not worth
# a non-POSIX dependency here.
#
# The DAY is in there because compose has one input that is not a file: it reads
# date +%Y-%m-%d and drops a hold whose "(hold-until: <date>)" gate has arrived. When
# that gate lapses, compose's output changes with nothing on disk changing - an in-flight
# task with a verified PR flips from a not-ready fyi to an action card offering the
# Merge - and a file-only fingerprint would keep showing the pre-lapse card until some
# unrelated file moved. The worst case is exactly what the board is for: review-ready
# work with no live crew writing status files, so nothing else moves. It costs at most
# one extra compose per day.
#
# What the fingerprint deliberately does NOT cover, so this is not mistaken for
# exhaustive: each clone's "origin" remote, compose's one other input. Reading it is a
# git subprocess per project, it changes approximately never, and a stale one costs the
# board a wrong repo in a Merge gate that the next session start corrects. Likewise the
# fingerprint tracks FLEET state, not the BOARD's: a board whose store is wiped out from
# under firstmate reads as "nothing changed" until fleet state next moves, and is
# restored by the next session start or a hand-run bin/fm-logbook-refresh.sh.
#
# WAKE DISCIPLINE. Refreshing the board is HOUSEKEEPING, so this prints NOTHING on
# stdout, ever, and therefore never wakes firstmate - the watcher turns a check shim's
# stdout into a check: wake. Every failure is quiet and non-fatal, like the reap: a
# board that cannot be reached is not a reason to disturb the captain or interrupt
# supervision, and it is already the reap's story to tell if it is down for good. Any
# diagnostic goes to stderr, which the watcher discards and a hand run shows. A failed
# cycle does not record the fingerprint, so it simply retries on the next beat - bounded,
# for a failure that lasts; see BOUNDED RETRY below.
#
# That is also why compose's stderr is RELAYED here rather than dropped. Composing the
# board reads every carded project's merge policy, so this is a second unattended read
# of the +captain-merge posture - and unlike the session-start sync it runs on every
# fleet change. A mistyped "+captain-merge" flag, or a policy lookup that fails outright
# and leaves every project mergeable, composes a live Merge for a project the captain
# reserved to themselves, and the policy library's warning is the only thing standing
# between that and the tap; discarded, it is a warning that never existed. The relay
# selects on the ONE marker bin/fm-merge-policy-lib.sh stamps, never on a copy of the
# message texts, so a diagnostic added there later arrives here already selected. It
# goes to STDERR only, exactly like every other diagnostic above: the rule that this
# script never prints on stdout is what keeps housekeeping from waking firstmate, and no
# fall-open warning is worth breaking it. The rest of compose's stream stays dropped as
# plumbing noise.
#
# THE RELAY OUTLIVES THE BACKOFF. Past the bound below the compose is skipped, and with
# it the stream those diagnostics normally ride in - which would trade a permission
# warning for a duty-cycle saving on all but one beat in RESYNC_BACKOFF_AFTER. A bounded
# suppression of a fall-open warning is the same defect as an unbounded one, only
# smaller, so the relay is lifted out of the skipped work instead. It can be: not one of
# those lines is compose's own. Every one comes from fm_merge_policy_project reading the
# REGISTRY, so a skipped beat asks the policy library about each registry project itself
# and relays what it says, through the same marker-selected filter. That costs one
# registry lookup per registry project - no git, no backlog parse, no per-item jq - which
# is the whole reason the expensive half can be skipped while this half is not.
#
# Inert unless opted in: a hard no-op (exit 0, no output, no network) without a truthy
# LOGBOOK_ENABLE, the same discipline the other client scripts follow, and bootstrap
# only drops the shim for an opted-in home anyway.
#
# Honors LOGBOOK_DRY_RUN transitively: the writes go through logbook_post_json and
# fm-logbook-resolve.sh, which record to state/logbook-outbox/ instead of posting.
# The fingerprint is still recorded on a dry run, so a preview does not re-fire every
# cycle; the reads it needs are GETs, which have no side effects.
#
# Relationship to bin/fm-logbook-refresh.sh: that is the one-call FULL declarative
# truth-restore (compose | sync), which bootstrap runs at session start and firstmate
# can run by hand to re-truth the board from scratch. This is the incremental,
# ownership-scoped rider that keeps it true in between. Neither replaces the other.
#
# Config: see fm-logbook-lib.sh and AGENTS.md section 15.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"
# Sourced for FM_MERGE_POLICY_DIAG_MARKER alone: the relay below has to pick that
# library's diagnostics out of compose's stderr, and reading the marker from its owner is
# what keeps this caller from holding a copy of anything that can drift. Best-effort like
# everything else on this path: a home whose bin/ is missing it (a partial update) loses
# the relay, not the refresh.
# shellcheck source=bin/fm-merge-policy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-merge-policy-lib.sh" 2>/dev/null || true

case "${1:-}" in
  --help|-h)
    echo "Incrementally refresh the logbook board from fleet state when it changes; ownership-scoped, never POST /api/sync. Silent; no-op unless opted in."
    exit 0 ;;
esac

logbook_load_config
# Hard no-op when logbook is off: this is what keeps the check shim inert.
logbook_enabled || exit 0

# A missing curl or jq is fm-logbook-poll.sh's diagnostic to own - it emits it on this
# same check cycle. Staying silent here keeps one fact to one owner, and one wake.
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

FINGERPRINT_FILE="$STATE/logbook-resync.fingerprint"
FAILURE_FILE="$STATE/logbook-resync.failures"
PROJECTS_MD="$DATA/projects.md"
BACKLOG_MD="$DATA/backlog.md"

# The fingerprint of compose's inputs; see the header for what it covers and what it
# deliberately does not. The calendar day goes in first, because it is compose's one
# input that is not a file (a "(hold-until: <date>)" gate lapses with nothing on disk
# changing). The file NAMES go in ahead of the contents so a meta or status appearing or
# disappearing changes the hash even when the surviving bytes do not. Every read is
# best-effort: a missing input is a legitimate state (a home with no registry yet, a
# fleet with no live crew), and it hashes as absent rather than failing.
fleet_fingerprint() {
  {
    date +%Y-%m-%d 2>/dev/null
    ls -1 "$STATE"/*.meta "$STATE"/*.status 2>/dev/null
    cat "$PROJECTS_MD" "$BACKLOG_MD" "$STATE"/*.meta "$STATE"/*.status 2>/dev/null
  } | cksum 2>/dev/null | awk '{ print $1 "-" $2 }'
}

FINGERPRINT=$(fleet_fingerprint)
# An unreadable fingerprint (no cksum, no awk) would make every cycle look identical
# and silently wedge the refresh forever, so treat it as "cannot tell" and stop rather
# than reconcile blind on a broken signal.
[ -n "$FINGERPRINT" ] || exit 0

if [ -f "$FINGERPRINT_FILE" ] && [ "$(cat "$FINGERPRINT_FILE" 2>/dev/null)" = "$FINGERPRINT" ]; then
  # The overwhelmingly common path: nothing in the fleet moved, so nothing is owed.
  exit 0
fi

# BOUNDED RETRY. A cycle that cannot complete records no fingerprint, so it retries on
# the next beat. That is right for the transient failure it was written for and wrong for
# one that lasts: a board that stays down after the reap gives up, or a board that is up
# and rejecting every write, would otherwise buy a full compose - a git shell-out per
# carded project plus a jq invocation per item - every 15s for as long as the failure
# lasts, and throw the result away. So consecutive cycles that did not reach the board
# state they composed are COUNTED, persisted beside the fingerprint (and the same way, so
# the count survives a cycle exactly as the fingerprint does), and past the bound this
# backs off toward the staleness it had before this script existed: one attempt every
# RESYNC_BACKOFF_AFTER beats instead of one every beat.
#
# The bound is 20 because at the 15s beat 20 consecutive failures is FIVE MINUTES of
# continuous failure - generous headroom for the board-liveness reap to notice a dead
# board and relaunch it, including a crash-loop retry or two, so an ordinary board
# restart never trips this. Past five minutes the board is not transiently down, and
# paying a full compose every 15s to throw the result away buys nothing.
#
# Recovery needs no restart and no session start: ONE cycle that completes deletes the
# counter, and the very next fleet change is reconciled on the normal beat again. The
# skipped beats are counted too, which is what spaces the retries out; without that the
# counter would freeze one past the bound and the backoff would become a wedge.
RESYNC_BACKOFF_AFTER=20

FAILURES=$(cat "$FAILURE_FILE" 2>/dev/null)
case "$FAILURES" in
  ''|*[!0-9]*) FAILURES=0 ;;
esac

# The relay's voice, in one place, so a line this script writes about the merge policy and
# a line it forwards from the library can never be shaped by two rules that drifted apart.
# STDERR only, like every other diagnostic here.
merge_policy_relay_line() {
  echo "fm-logbook-resync: merge policy - ${1-}" >&2
}

# Re-emit every merge-policy diagnostic the stream in <file> carried, on THIS script's
# stderr and in its own voice. Selected on the marker its owner stamps rather than on any
# copy of the texts, so a line that library gains later arrives here already selected.
# Everything else that stream carried stays dropped.
relay_merge_policy_diagnostics() {
  local line
  [ -n "${FM_MERGE_POLICY_DIAG_MARKER:-}" ] || return 0
  [ -s "$1" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$FM_MERGE_POLICY_DIAG_MARKER "*)
        merge_policy_relay_line "${line#"$FM_MERGE_POLICY_DIAG_MARKER "}" ;;
    esac
  done < "$1"
}

# The relay's other source, for the beats the backoff skips: ask the policy library about
# every project the registry lists, and relay what it says through the same filter. The
# registry line rule is the one every other parser in this fleet uses. The sweep runs in a
# subshell so the library's per-process memo and its once-warned flag cannot leak into a
# cycle that goes on to compose, and so the child's answer on stdout can never reach the
# stdout this script keeps silent.
#
# Best-effort, but never SILENTLY so: every way this can decline to sweep says so on
# stderr. A sweep it could not run is not the absence of a posture problem, and the state
# where it matters most is the one where it is likeliest to bail - a registry that exists
# and cannot be READ is the fleet-wide fall-open the whole marker mechanism was built for,
# with every project reading as mergeable. A composing beat relays that; a backed-off beat
# must never be quieter than a composing beat, which is the entire contract this function
# exists to keep.
#
# The one exception is a home with NO registry, which is a legitimate state (a fresh home
# with nothing declared) and which the policy library itself drops as routine noise. Saying
# nothing there is MATCHING the composing beat, not falling short of it.
relay_registry_merge_policy() {
  local err_file
  if [ -z "${FM_MERGE_POLICY_DIAG_MARKER:-}" ] \
     || ! command -v fm_merge_forbidden_project >/dev/null 2>&1; then
    merge_policy_relay_line "the policy library did not load in this home, so no posture can be read or relayed on a backed-off beat"
    return 0
  fi
  if ! command -v awk >/dev/null 2>&1; then
    merge_policy_relay_line "no awk here, so the registry cannot be swept on a backed-off beat"
    return 0
  fi
  [ -e "$PROJECTS_MD" ] || return 0
  if [ ! -r "$PROJECTS_MD" ]; then
    merge_policy_relay_line "could not read the registry at $PROJECTS_MD; every project in the fleet reads as mergeable until it can be read"
    return 0
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-resync-policy.XXXXXX" 2>/dev/null) || {
    merge_policy_relay_line "could not capture the registry sweep, so a posture warning may be going unheard on a backed-off beat"
    return 0
  }
  (
    while IFS= read -r policy_project; do
      [ -n "$policy_project" ] || continue
      fm_merge_forbidden_project "$FM_ROOT" "$FM_HOME" "$policy_project" || true
    done <<EOF
$(awk '$1 == "-" && $2 != "" { print $2 }' "$PROJECTS_MD" 2>/dev/null)
EOF
  ) >/dev/null 2>"$err_file"
  relay_merge_policy_diagnostics "$err_file"
  rm -f "$err_file" 2>/dev/null || true
}

# resync_state_write <file> <value>: this script's one way to put a line of its own state
# on disk. Both things it persists - the fingerprint and the consecutive-failure count -
# are read by the NEXT cycle to decide whether to work at all, so a half-written one would
# be read as a state no cycle ever reached; the write therefore lands through a temp file
# in the same directory and a rename. One owner, so the two can never drift apart on that
# or on the best-effort rule below.
#
# Best-effort and silent by contract: a state write that cannot happen costs the
# short-circuit or the backoff on a later beat, never this cycle, so it always returns 0.
resync_state_write() {
  local file=${1-} value=${2-} dir tmp
  [ -n "$file" ] || return 0
  dir=${file%/*}
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp=$(mktemp "$dir/.${file##*/}.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$value" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Persist one more consecutive cycle that did not get there.
record_failure() {
  resync_state_write "$FAILURE_FILE" "$((FAILURES + 1))"
}

if [ "$FAILURES" -ge "$RESYNC_BACKOFF_AFTER" ] \
   && [ "$((FAILURES % RESYNC_BACKOFF_AFTER))" -ne 0 ]; then
  # Backed off: the compose that is the expensive half is skipped, the merge-policy relay
  # is NOT, and the skip says so on stderr - every other path here explains why it did
  # nothing, and an operator running this by hand must be able to tell a backed-off beat
  # from a beat with nothing to do. Stdout stays empty, so no wake is bought.
  relay_registry_merge_policy
  record_failure
  echo "fm-logbook-resync: backed off after $FAILURES consecutive failed cycles; retrying every $RESYNC_BACKOFF_AFTER beats" >&2
  exit 0
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-logbook-resync.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -rf "$WORK_DIR" 2>/dev/null || true' EXIT

COMPOSED="$WORK_DIR/composed.json"
COMPOSE_ERR="$WORK_DIR/compose.err"
BOARD="$WORK_DIR/board.json"
PLAN="$WORK_DIR/plan.json"
ITEMS="$WORK_DIR/items.json"
PROJECTS="$WORK_DIR/projects.json"
SUPPRESSED="$WORK_DIR/suppressed.json"

# Compose the desired attention set. compose is opt-in gated too, so we are past that;
# an empty or non-JSON body is a compose failure, and syncing garbage off it would be
# worse than staying stale for one more cycle.
if ! "$SCRIPT_DIR/fm-logbook-compose.sh" > "$COMPOSED" 2>"$COMPOSE_ERR"; then
  relay_merge_policy_diagnostics "$COMPOSE_ERR"
  echo "fm-logbook-resync: could not compose the attention set" >&2
  record_failure
  exit 0
fi
relay_merge_policy_diagnostics "$COMPOSE_ERR"
if [ ! -s "$COMPOSED" ] || ! jq -e . "$COMPOSED" >/dev/null 2>&1; then
  echo "fm-logbook-resync: composed board body was empty or not valid JSON" >&2
  record_failure
  exit 0
fi

# Read the live board. This is what makes the reconcile incremental rather than
# declarative: without it there is no way to know which cards are already right, which
# are this script's to rewrite, and which belong to someone else.
if ! logbook_get_json /api/board "$BOARD" >/dev/null 2>&1; then
  # Almost always the board being down, which the reap already owns and reports.
  echo "fm-logbook-resync: could not read the board" >&2
  record_failure
  exit 0
fi

# The cards the captain has already settled: cleared through the answer loop, and so
# absent from the board even though the composed set still carries them. Suppressed
# below unless their composed content has moved on since the clear, which makes them a
# different question. This also evicts the records that are spent, using the board read
# above, so the record cannot grow without bound (fm-logbook-lib.sh owns the rule).
logbook_cleared_filter "$COMPOSED" "$BOARD" "$SUPPRESSED"
SUPPRESS=$(cat "$SUPPRESSED" 2>/dev/null)
[ -n "$SUPPRESS" ] || SUPPRESS='[]'

# Partition into the three write sets. Both sides are normalized to exactly the fields
# compose declares before they are compared, so fields the TOOL fills in (priority,
# status, timestamps) can never read as a difference and cause a rewrite every cycle.
# That normalization is fm-logbook-lib.sh's LOGBOOK_ITEM_NORM_JQ, shared with the
# settled-card hash so this diff and that record can never disagree about what "the same
# card" means. Every lookup argument is bound to a variable before use: jq evaluates an
# argument against the value being searched, not against the item in hand, so an unbound
# `.id` inside index() would silently compare the wrong thing.
if ! jq -n \
  --slurpfile composed "$COMPOSED" \
  --slurpfile board "$BOARD" \
  --argjson suppress "$SUPPRESS" \
  --arg producer "$LOGBOOK_COMPOSE_PRODUCER" \
  "$LOGBOOK_ITEM_NORM_JQ$LOGBOOK_ITEM_OWNED_JQ"'
  def pnorm:
    { name, repo: (.repo // ""), mode: (.mode // ""),
      subprojects: (.subprojects // []) };

  (($composed[0] // {}) | .items // []) as $citems
  | (($composed[0] // {}) | .projects // []) as $cprojects
  | (($board[0] // {}) | .items // []) as $bitems
  | (($board[0] // {}) | .projects // []) as $bprojects
  | ($bitems | map({ key: .id, value: . }) | from_entries) as $bindex
  | ($bprojects | map({ key: .name, value: . }) | from_entries) as $bpindex
  | ([ $citems[] | .id ]) as $cids
  | {
      items: [ $citems[]
               | . as $c
               | ($bindex[$c.id] // null) as $prev
               | select(if $prev == null
                        then (($suppress | index($c.id)) == null)
                        else (($prev | owned($producer))
                              and ($prev.status != "submitted")
                              and (($prev | norm) != ($c | norm))) end) ],
      clear: [ $bitems[]
               | . as $b
               | select($b | owned($producer))
               | select($b.status != "submitted")
               | select(($cids | index($b.id)) == null)
               | $b.id ],
      projects: [ $cprojects[]
                  | . as $p
                  | ($bpindex[$p.name] // null) as $prev
                  | select($prev == null or (($prev | pnorm) != ($p | pnorm))) ]
    }' > "$PLAN" 2>/dev/null; then
  echo "fm-logbook-resync: could not reconcile the composed set against the board" >&2
  record_failure
  exit 0
fi

FAILED=0

# Projects first, so a brand-new project exists before a card referencing it lands.
# POST /api/projects is an upsert-only route: it never deletes, and the tool keeps
# `active` on an existing project, so this cannot undo the captain's board toggle.
if ! jq -e '.projects | length > 0' "$PLAN" >/dev/null 2>&1; then
  :
elif ! jq -c '.projects' "$PLAN" > "$PROJECTS" 2>/dev/null; then
  echo "fm-logbook-resync: could not write the project upsert body" >&2
  FAILED=1
elif ! logbook_post_json /api/projects "$PROJECTS" resync-projects >/dev/null 2>&1; then
  echo "fm-logbook-resync: could not upsert projects" >&2
  FAILED=1
fi

# Items: one batch upsert for everything new or genuinely changed. POST /api/items is
# all-or-nothing, so either the whole batch lands or nothing does and we retry next
# cycle with the fingerprint unrecorded.
if ! jq -e '.items | length > 0' "$PLAN" >/dev/null 2>&1; then
  :
elif ! jq -c '.items' "$PLAN" > "$ITEMS" 2>/dev/null; then
  echo "fm-logbook-resync: could not write the item upsert body" >&2
  FAILED=1
elif ! logbook_post_json /api/items "$ITEMS" resync-items >/dev/null 2>&1; then
  echo "fm-logbook-resync: could not upsert items" >&2
  FAILED=1
fi

# Clears go through fm-logbook-resolve.sh rather than being folded into the batch above.
# The board has no dedicated resolve endpoint, so clearing a card means re-upserting the
# WHOLE item with a terminal status, and that script is the single owner of how that is
# done. Re-deriving it here to save a GET per card would be a second copy of a contract
# that has to stay in step, for a saving on the rarest path: a card leaves the attention
# set only when its work actually finishes.
#
# Every clear here is MECHANICAL - the work left the composed set, nobody answered
# anything - so each one says so, and no settled-card record is written for it. Recording
# these would be the under-reporting bug turned inside out: work parked to Queued and
# later resumed composes a byte-identical card, and a record taken at the clear would
# match it and hold it off the board for good. Only the answer loop settles questions.
while IFS= read -r clear_id; do
  [ -n "$clear_id" ] || continue
  logbook_valid_id "$clear_id" || continue
  if ! LOGBOOK_MECHANICAL_CLEAR=1 "$SCRIPT_DIR/fm-logbook-resolve.sh" "$clear_id" >/dev/null 2>&1; then
    echo "fm-logbook-resync: could not clear card $clear_id" >&2
    FAILED=1
  fi
done <<EOF
$(jq -r '.clear[]?' "$PLAN" 2>/dev/null)
EOF

# Record the fingerprint only when the board actually reached the state this
# fingerprint describes. A partial cycle leaves it unrecorded so the next beat retries,
# which is why every failure above is a quiet FAILED=1 rather than an early exit: the
# writes are independent, and one that could not land must not cancel the others.
#
# The consecutive-failure counter is settled here too, and by the same test: one cycle
# that got there drops it outright, so a board that comes back is back on the normal
# beat immediately, with no restart and no session start.
if [ "$FAILED" -ne 0 ]; then
  record_failure
else
  rm -f "$FAILURE_FILE" 2>/dev/null || true
  resync_state_write "$FINGERPRINT_FILE" "$FINGERPRINT"
fi

exit 0
