#!/usr/bin/env bash
# Upsert one attention item (or an array of items) onto the logbook board.
#
# Usage: fm-logbook-push.sh --json-file <path>
#        fm-logbook-push.sh -                     (read the JSON body from stdin)
#        cat item.json | fm-logbook-push.sh
#
# The body is one item object or a JSON array of them, matching the tool's
# POST /api/items upsert contract (keyed by id). The body is passed via file or
# stdin and NEVER inlined into a shell argument, mirroring fm-x-reply.sh, because
# an item's title/body is composed from fleet internals. It is validated as JSON
# before posting.
#
# Honors LOGBOOK_DRY_RUN: with it set (truthy), the would-be POST body is recorded
# to state/logbook-outbox/items.json and nothing is sent (needs neither a token nor
# the board). See fm-logbook-lib.sh and AGENTS.md section 15.
#
# MERGE POLICY: this is a WRITE path onto the board, so it is gated like one. The rich
# cards firstmate composes here replace the mechanical baseline bin/fm-logbook-compose.sh
# built (the upsert is keyed by id), so a hand-composed "Merge" would put back exactly the
# option compose withheld. An item whose project is "+captain-merge" therefore has any
# merge option REMOVED before the upsert and the acknowledgement compose uses offered in
# its place, so both write paths onto the board speak one vocabulary and neither can offer
# the captain the one thing firstmate would then refuse to do.
# bin/fm-merge-policy-lib.sh owns the contract, and it is read through the SAME two
# independent signals bin/fm-pr-merge.sh reads, either of which strips:
#
#   1. The item's own "project" field, the field compose sets.
#   2. The item's "source.pr", matched against the origin of every clone under projects/.
#
# Signal 2 is not redundant. The board's item schema treats "project" as OPTIONAL, and
# this is the HAND-composed path, so a rich card written without one - or with a display
# name the registry never listed - would walk straight past a project-only gate carrying
# the very Merge button compose withheld. A guard with a bypass is not a guard, so the
# url, which is the thing the button would act on and is present on any card that has a
# Merge to offer, gets its own say.
# The push itself is never refused over it: an attention item the captain never sees at
# all is worse than one with a button removed, and AGENTS.md section 15 requires that
# everything reaching the captain also reaches the board. It warns to stderr instead, so
# the authoring mistake is visible rather than silent. An item for a project without the
# flag keeps every field it was handed except the ownership stamp below, which this path
# always removes.
#
# CARD OWNERSHIP: this path never hands over a card as the automatic refresh's own.
# bin/fm-logbook-lib.sh's LOGBOOK_COMPOSE_PRODUCER stamp, written into "source" by
# bin/fm-logbook-compose.sh, is what tells bin/fm-logbook-resync.sh which cards are its
# mechanical baseline to rewrite and clear. A card pushed HERE is firstmate's own
# composition, and the natural way to write a rich escalation is on top of the composed
# baseline - which carries that stamp along with everything else. Left in place, the
# refresh reads the curated card as its own and flattens it back to the baseline on the
# next cycle, destroying the escalation. So the stamp is stripped at this boundary, where
# the fact "this was hand-pushed" is actually known, rather than guessed at later from a
# cleverer read-time test. Only ".source.producer" goes: ".source.pr" is the merge-policy
# gate's second signal and stays exactly as it was.
# Every step of this gate that can FAIL therefore falls open - a selector jq that will not
# run, a list that cannot be built, a temp file that cannot be allocated, a gated body that
# cannot be written or installed - and every one of them SAYS SO, on stderr. Falling open
# in silence would be worse than having no gate at all: the run reads exactly like one that
# held, so a live Merge on a "+captain-merge" card looks like a card the policy had nothing
# to say about.
# Each of those diagnostics reports only what it KNOWS where it fires, which for the steps
# before the rewrite is the signal that went dark and nothing more. The two signals are
# independent and the strip runs after both, so a dead project signal leaves the url still
# able to remove the option and vice versa: a step that announced the OUTCOME - "pushing
# the item as composed" - would be claiming something not yet decided, and would be flatly
# wrong whenever the surviving signal went on to strip. Only the rewrite's own branches,
# which install the gated body or fail to, are in a position to say that.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"
# shellcheck source=bin/fm-merge-policy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-merge-policy-lib.sh"

usage() { echo "usage: fm-logbook-push.sh --json-file <path> | -" >&2; }

# json_array_of <newline-accumulated-list> <what>: that list as a JSON array of its
# non-empty lines, "[]" when it is empty or cannot be converted. One owner for both gates
# below, so the project list and the url list can never be built by two rules that drifted
# apart - and so the fall-open on a jq that will not run is the same fall-open for both.
#
# That fall-open is the loudest of the three, because it is the one that CONTRADICTS what
# the run already said: the per-item warnings above have announced the projects and urls
# whose Merge is being dropped, and an empty array here hands the strip nothing to drop for
# this signal. Silent, the run claimed a strip it did not perform. It says only that much -
# the OTHER signal's list is unaffected and may still strip the very option this one
# announced, so this is not the place to say how the item reached the board.
# jq's output is captured rather than streamed, so a jq that died halfway cannot leave a
# partial array with "[]" appended to it either.
json_array_of() {
  local list=${1-} what=${2-gate} out
  [ -n "$list" ] || { printf '[]'; return 0; }
  if out=$(printf '%s' "$list" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  echo "fm-logbook-push: could not build the forbidden-$what list, so the $what signal removed nothing it announced above; the other signal still applies" >&2
  printf '[]'
}

case "${1:-}" in
  --help|-h) echo "Upsert attention item(s) via POST /api/items. Body from --json-file <path> or stdin."; exit 0 ;;
esac

SRC=-
case "${1:-}" in
  ''|-) SRC=- ;;
  --json-file)
    [ -n "${2:-}" ] || { usage; exit 2; }
    SRC=$2 ;;
  *) usage; exit 2 ;;
esac

logbook_load_config
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-push: jq not found" >&2; exit 1; }

# Slurp the body so we can validate it parses as JSON before posting.
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-push.XXXXXX") || { echo "fm-logbook-push: cannot create temp file" >&2; exit 1; }
# Allocated lazily by the ownership strip and the gate below, and cleaned up here on
# every exit path whether either reached them or not.
GATED_FILE=
UNSTAMPED_FILE=
trap 'rm -f "$BODY_FILE" ${GATED_FILE:+"$GATED_FILE"} ${UNSTAMPED_FILE:+"$UNSTAMPED_FILE"}' EXIT
if [ "$SRC" = "-" ]; then
  cat > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body from stdin" >&2; exit 1; }
else
  cat -- "$SRC" > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body file: $SRC" >&2; exit 1; }
fi
jq -e . "$BODY_FILE" >/dev/null 2>&1 || { echo "fm-logbook-push: body is not valid JSON" >&2; exit 1; }

# Strip the ownership stamp, as the header explains, BEFORE either merge-policy signal
# reads the body, so every later step works on the item that will actually be posted.
# Its own mktemp for the same reason the gated body gets one: a derived name in a shared
# temp dir is predictable and redirect-able, and mktemp's 0600 is what keeps composed
# card text from sitting there world-readable.
# Falls open like every other step here - a card the captain never sees is worse than one
# the refresh may later flatten - and says so, because a silent fall-open would leave a
# curated escalation looking exactly like one this boundary had nothing to do.
UNSTAMPED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-push-unstamped.XXXXXX") || UNSTAMPED_FILE=
if [ -z "$UNSTAMPED_FILE" ]; then
  echo "fm-logbook-push: cannot create a temp file to strip the ownership stamp; the board refresh may treat this card as its own and flatten it" >&2
elif jq -c '
    def unstamp:
      if (type == "object") and ((.source? | type) == "object")
      then .source |= del(.producer) else . end;
    if type == "array" then map(unstamp) else unstamp end' "$BODY_FILE" > "$UNSTAMPED_FILE"; then
  mv -f "$UNSTAMPED_FILE" "$BODY_FILE" ||
    echo "fm-logbook-push: could not install the unstamped body; the board refresh may treat this card as its own and flatten it" >&2
else
  echo "fm-logbook-push: could not strip the ownership stamp; the board refresh may treat this card as its own and flatten it" >&2
fi

# JQ_USABLE_LINES: the ONE definition of "a value this gate can carry", read by BOTH
# selectors below so the project list and the url list can never be built by two rules that
# drifted apart. It is what json_array_of is, one step earlier: every list here is
# newline-delimited end to end - jq writes lines, "read -r" reads them back, json_array_of
# splits on them again - so a value that cannot survive that round trip has to be dropped
# before it enters rather than read as something it is not.
#
# A value carrying whitespace is exactly that value, and an embedded NEWLINE is the
# damaging half: read as lines, ONE name arrives at the lookup as two DIFFERENT names,
# either of which may be flagged, and the strip below then looks the whole original up and
# finds neither - so the run announces a drop it did not perform, which is the failure this
# file works hardest to avoid. Skipping such a value forbids nothing that was ever
# forbiddable: bin/fm-merge-policy-lib.sh already answers a name it cannot key "firstmate"
# without a lookup, a registry project name is a single whitespace-free field (it is an awk
# field to bin/fm-project-mode.sh, so no registry line can declare one), and a url whose
# owner or repo carries whitespace is blanked by fm_merge_slug and matches no clone.
JQ_USABLE_LINES='def usable_lines:
  map(select((type == "string") and (. != "") and ((test("\\s")) | not))) | unique;'

# Both signals are asked only about the items that actually stand to lose something: an
# item carrying no merge option has nothing to strip, so the body is left alone and the
# lookups are never paid for.
#
# Signal 1, the item's project. Names are read as whole lines, and one that cannot key a
# registry lookup is answered permissively by the library rather than here.
#
# A selector that will not RUN is not the same fact as a body with nothing to gate, and the
# two are indistinguishable in an empty result: the body already parsed as JSON at the check
# above, so a failure here is jq itself (killed, out of memory, a build without any/2), and
# it leaves THIS signal with nothing to forbid. Said out loud, the way every other fall-open
# in this file is, rather than left to a board that quietly grew back the button compose
# withheld - and said as exactly that, since signal 2 still runs and may still strip the
# option on a card carrying a url.
MERGE_PROJECTS=$(jq -r "$JQ_USABLE_LINES"'
  [ (if type=="array" then .[] else . end)
    | select(type=="object")
    | select((.options? | type) == "array")
    | select(any(.options[]?; (type=="object") and (.value? == "merge")))
    | .project? ]
  | usable_lines | .[]' "$BODY_FILE" 2>/dev/null) || {
  MERGE_PROJECTS=""
  echo "fm-logbook-push: could not read the items' projects for the merge-policy gate; the project signal is unavailable and only the PR url signal applies" >&2
}

FORBIDDEN=""
if [ -n "$MERGE_PROJECTS" ]; then
  while IFS= read -r policy_project; do
    [ -n "$policy_project" ] || continue
    if fm_merge_forbidden_project "$FM_ROOT" "$FM_HOME" "$policy_project"; then
      FORBIDDEN=$FORBIDDEN$policy_project$'\n'
      echo "fm-logbook-push: project \"$policy_project\" is +captain-merge; dropping the Merge option and offering \"Done / dismiss\" instead" >&2
    fi
  done <<EOF
$MERGE_PROJECTS
EOF
fi

FORBIDDEN_JSON=$(json_array_of "$FORBIDDEN" project)

# Signal 2, the item's PR url, asked only of the items signal 1 did not already settle -
# an item whose project is flagged is stripped either way, and the scan across projects/
# is the expensive half. Its values are held to the same usable_lines contract signal 1's
# are, for the same reason and out of the same definition.
MERGE_URLS=$(jq -r --argjson forbidden "$FORBIDDEN_JSON" "$JQ_USABLE_LINES"'
  def pr_of:
    if ((.source? | type) == "object") and ((.source.pr? | type) == "string")
    then .source.pr else "" end;
  [ (if type=="array" then .[] else . end)
    | select(type=="object")
    | select((.options? | type) == "array")
    | select(any(.options[]?; (type=="object") and (.value? == "merge")))
    | . as $item
    | select((($item.project? | type) != "string") or (($forbidden | index($item.project)) == null))
    | pr_of ]
  | usable_lines | .[]' "$BODY_FILE" 2>/dev/null) || {
  MERGE_URLS=""
  echo "fm-logbook-push: could not read the items' PR urls for the merge-policy gate; the PR url signal is unavailable and only the project signal applies" >&2
}

FORBIDDEN_URLS=""
if [ -n "$MERGE_URLS" ]; then
  while IFS= read -r policy_url; do
    [ -n "$policy_url" ] || continue
    if fm_merge_forbidden_url "$FM_ROOT" "$FM_HOME" "$PROJECTS" "$policy_url"; then
      FORBIDDEN_URLS=$FORBIDDEN_URLS$policy_url$'\n'
      echo "fm-logbook-push: $policy_url is the PR of project \"$FM_MERGE_FORBIDDEN_PROJECT\", which is +captain-merge; dropping the Merge option and offering \"Done / dismiss\" instead" >&2
    fi
  done <<EOF
$MERGE_URLS
EOF
fi

FORBIDDEN_URLS_JSON=$(json_array_of "$FORBIDDEN_URLS" "PR url")

# Rewritten only when there is something to strip, so every other push reaches the board
# as the ownership strip above left it, option for option.
if [ -n "$FORBIDDEN" ] || [ -n "$FORBIDDEN_URLS" ]; then
  # The gated body gets its own mktemp rather than a name derived from $BODY_FILE's. A
  # derived name is predictable the moment the first file exists, and this temp dir is
  # shared, so a plain redirect onto it can be aimed at another file by a symlink planted
  # there ahead of the write - and it would be created at the ambient umask rather than
  # mktemp's 0600, leaving the composed card text world-readable while it sits there.
  GATED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-push-gated.XXXXXX") || GATED_FILE=
  if [ -z "$GATED_FILE" ]; then
    echo "fm-logbook-push: cannot create a temp file for the gated body; pushing the item as composed" >&2
  # The acknowledgement leads, the way compose orders it, and an item that already carries
  # one keeps just the one; every other option, and every other field, is left as it was.
  elif jq --argjson forbidden "$FORBIDDEN_JSON" --argjson forbidden_urls "$FORBIDDEN_URLS_JSON" '
      def gate_options:
        if ([ .[] | select((type=="object") and (.value? == "merge")) ] | length) == 0 then .
        else
          ([ .[] | select((type != "object") or (.value? != "merge")) ]) as $rest
          | if ([ $rest[] | select((type=="object") and (.value? == "dismiss")) ] | length) > 0
            then $rest
            else [{label: "Done / dismiss", value: "dismiss"}] + $rest
            end
        end;
      def pr_of:
        if ((.source? | type) == "object") and ((.source.pr? | type) == "string")
        then .source.pr else "" end;
      def gate:
        if (type=="object") and ((.options? | type) == "array")
        then
          # Both names are bound BEFORE index(), whose argument is evaluated against the
          # array being searched rather than against the item.
          (if ((.project? | type) == "string") then .project else null end) as $p
          | pr_of as $u
          | ( (($p != null) and (($forbidden | index($p)) != null))
              or (($u != "") and (($forbidden_urls | index($u)) != null)) ) as $forbid
          | if $forbid then .options |= gate_options else . end
        else . end;
      if type=="array" then map(gate) else gate end' "$BODY_FILE" > "$GATED_FILE"; then
    # Falls open like both branches around it, and for the reason the header gives: under
    # "set -eu" an unguarded "mv" that fails is the LAST command of this branch, so it
    # would exit before the push and drop the card off the board entirely - strictly worse
    # than a card with one button too many, which is at least still in front of the
    # captain. The gate that matters is bin/fm-pr-merge.sh's refusal, which holds whatever
    # this button says.
    mv -f "$GATED_FILE" "$BODY_FILE" ||
      echo "fm-logbook-push: could not install the gated body; pushing the item as composed" >&2
  else
    echo "fm-logbook-push: could not remove the forbidden Merge option; pushing the item as composed" >&2
  fi
fi

logbook_post_json /api/items "$BODY_FILE" items >/dev/null || exit 1
