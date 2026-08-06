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
# bin/fm-merge-policy-lib.sh owns the contract; the project is read from the item's own
# "project" field, the same field compose sets.
# The push itself is never refused over it: an attention item the captain never sees at
# all is worse than one with a button removed, and AGENTS.md section 15 requires that
# everything reaching the captain also reaches the board. It warns to stderr instead, so
# the authoring mistake is visible rather than silent. An item for a project without the
# flag is passed through untouched, byte for byte.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"
# shellcheck source=bin/fm-merge-policy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-merge-policy-lib.sh"

usage() { echo "usage: fm-logbook-push.sh --json-file <path> | -" >&2; }

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
trap 'rm -f "$BODY_FILE" "$BODY_FILE.gated"' EXIT
if [ "$SRC" = "-" ]; then
  cat > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body from stdin" >&2; exit 1; }
else
  cat -- "$SRC" > "$BODY_FILE" || { echo "fm-logbook-push: cannot read body file: $SRC" >&2; exit 1; }
fi
jq -e . "$BODY_FILE" >/dev/null 2>&1 || { echo "fm-logbook-push: body is not valid JSON" >&2; exit 1; }

# Ask the policy only about the projects that actually stand to lose something: an item
# carrying no merge option has nothing to strip, so the body is left alone and the lookup
# is never paid for. Names are read as whole lines, and one that cannot key a registry
# lookup is answered permissively by the library rather than here.
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

# Rewritten only when there is something to strip, so every other push reaches the board
# as exactly the bytes it was handed.
if [ -n "$FORBIDDEN" ]; then
  FORBIDDEN_JSON=$(printf '%s' "$FORBIDDEN" | jq -R -s 'split("\n") | map(select(length > 0))') || FORBIDDEN_JSON=""
  # The acknowledgement leads, the way compose orders it, and an item that already carries
  # one keeps just the one; every other option, and every other field, is left as it was.
  if [ -n "$FORBIDDEN_JSON" ] && jq --argjson forbidden "$FORBIDDEN_JSON" '
      def gate_options:
        if ([ .[] | select((type=="object") and (.value? == "merge")) ] | length) == 0 then .
        else
          ([ .[] | select((type != "object") or (.value? != "merge")) ]) as $rest
          | if ([ $rest[] | select((type=="object") and (.value? == "dismiss")) ] | length) > 0
            then $rest
            else [{label: "Done / dismiss", value: "dismiss"}] + $rest
            end
        end;
      def gate:
        if (type=="object")
          and ((.project? | type) == "string")
          and ((.options? | type) == "array")
        then .project as $p
          | if ($forbidden | index($p)) != null then .options |= gate_options else . end
        else . end;
      if type=="array" then map(gate) else gate end' "$BODY_FILE" > "$BODY_FILE.gated"; then
    mv -f "$BODY_FILE.gated" "$BODY_FILE"
  else
    echo "fm-logbook-push: could not remove the forbidden Merge option; pushing the item as composed" >&2
  fi
fi

logbook_post_json /api/items "$BODY_FILE" items >/dev/null || exit 1
