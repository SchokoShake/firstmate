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
# flag is passed through untouched, byte for byte.
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

# json_array_of <newline-accumulated-list>: that list as a JSON array of its non-empty
# lines, "[]" when it is empty or cannot be converted. One owner for both gates below, so
# the project list and the url list can never be built by two rules that drifted apart -
# and so the fall-open on a jq that will not run is the same fall-open for both.
json_array_of() {
  local list=${1-}
  [ -n "$list" ] || { printf '[]'; return 0; }
  printf '%s' "$list" | jq -R -s 'split("\n") | map(select(length > 0))' || printf '[]'
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
# Allocated lazily by the gate below, and cleaned up here on every exit path whether the
# gate reached it or not.
GATED_FILE=
trap 'rm -f "$BODY_FILE" ${GATED_FILE:+"$GATED_FILE"}' EXIT
if [ "$SRC" = "-" ]; then
  cat > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body from stdin" >&2; exit 1; }
else
  cat -- "$SRC" > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body file: $SRC" >&2; exit 1; }
fi
jq -e . "$BODY_FILE" >/dev/null 2>&1 || { echo "fm-logbook-push: body is not valid JSON" >&2; exit 1; }

# Both signals are asked only about the items that actually stand to lose something: an
# item carrying no merge option has nothing to strip, so the body is left alone and the
# lookups are never paid for.
#
# Signal 1, the item's project. Names are read as whole lines, and one that cannot key a
# registry lookup is answered permissively by the library rather than here.
MERGE_PROJECTS=$(jq -r '
  [ (if type=="array" then .[] else . end)
    | select(type=="object")
    | select((.options? | type) == "array")
    | select(any(.options[]?; (type=="object") and (.value? == "merge")))
    | .project? ]
  | map(select((type=="string") and (. != ""))) | unique | .[]' "$BODY_FILE" 2>/dev/null) || MERGE_PROJECTS=""

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

FORBIDDEN_JSON=$(json_array_of "$FORBIDDEN")

# Signal 2, the item's PR url, asked only of the items signal 1 did not already settle -
# an item whose project is flagged is stripped either way, and the scan across projects/
# is the expensive half. A url carrying whitespace is skipped rather than read as a line:
# the library blanks a whitespace-bearing owner or repo, so such a url can match no clone
# anyway, and skipping it keeps this line-oriented read honest about what it forbade.
MERGE_URLS=$(jq -r --argjson forbidden "$FORBIDDEN_JSON" '
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
  | map(select((. != "") and ((test("\\s")) | not))) | unique | .[]' "$BODY_FILE" 2>/dev/null) || MERGE_URLS=""

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

FORBIDDEN_URLS_JSON=$(json_array_of "$FORBIDDEN_URLS")

# Rewritten only when there is something to strip, so every other push reaches the board
# as exactly the bytes it was handed.
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
