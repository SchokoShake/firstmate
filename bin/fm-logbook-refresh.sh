#!/usr/bin/env bash
# Refresh the whole logbook board from current fleet state: compose the attention
# set and declaratively sync it. The one-call session-start truth-restore.
#
# Usage: fm-logbook-refresh.sh
#
# Runs fm-logbook-compose.sh (the {projects, items} baseline from data/projects.md,
# data/backlog.md, state/*.meta, state/*.status, and each project clone's "origin"
# remote) and hands it to fm-logbook-sync.sh (POST /api/sync). This is what
# bootstrap invokes after the board server is up so the session-start reconcile is
# automatic, not a step firstmate has to remember; firstmate can also run it by
# hand mid-session to re-truth the board.
#
# One thing is subtracted from that composed set before it goes up: a card the captain
# already answered and firstmate already cleared. The board keeps no trace a client can
# read back (GET /api/board omits resolved and dismissed rows), so compose - which knows
# only fleet state - re-derives such a card for as long as its task stays in the
# attention set, and syncing it would put a settled question back in front of the
# captain. bin/fm-logbook-resolve.sh records every clear it performs and this honors
# that record; docs/configuration.md "Board refresh" owns the contract.
#
# THAT SUBTRACTION IS WHY THIS READS THE BOARD FIRST, and the read is not optional.
# On the incremental refresh, leaving an id out of the payload means "do not add it".
# HERE it means DELETE: fm-logbook-sync.sh is declarative, and its own header states
# that a collection present in the body becomes exactly that set, absent members
# deleted. So a settled id that firstmate has since pushed a FRESH card under would be
# stripped from the payload and the live card destroyed - strictly worse than the
# staleness this whole surface exists to fix. Reading the board first lets the record's
# "this id is back on the board -> evict" rule fire on this path too, so a card that is
# actually there is never suppressed out of the payload. Do not re-introduce a payload
# strip without this read.
#
# "Not optional" is enforced rather than asserted: a board read that FAILS cancels the
# subtraction entirely instead of degrading it. Without the view, the eviction rule
# cannot fire, and a suppression applied blind is a live card deleted - the one outcome
# that cannot be undone. A settled card re-declared because this cycle could not read
# the board is recoverable: the record itself is untouched, and the next readable cycle
# (this script re-run by hand, or the mid-session refresh on its own beat) suppresses it
# again. That is the whole trade, and it only ever runs in the recoverable direction.
#
# Inert by default: a hard no-op (exit 0, no output) unless logbook is opted in via
# a truthy LOGBOOK_ENABLE. Honors LOGBOOK_DRY_RUN transitively - fm-logbook-sync.sh
# records the would-be body to state/logbook-outbox/sync.json instead of posting.
# Best-effort and bounded for its bootstrap caller: it does one compose+sync (the
# sync posts with a bounded curl, so it never hangs) and returns the sync result; a
# failure is a single stderr diagnostic, and the caller decides whether to continue.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

case "${1:-}" in
  --help|-h) echo "Compose the fleet attention set and declaratively sync it to the board (POST /api/sync). No-op unless opted in; honors LOGBOOK_DRY_RUN via fm-logbook-sync.sh."; exit 0 ;;
esac

logbook_load_config
# Inert unless opted in.
logbook_enabled || exit 0
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-refresh: jq not found" >&2; exit 1; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-refresh.XXXXXX") || { echo "fm-logbook-refresh: cannot create temp file" >&2; exit 1; }
SUPPRESSED=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-refresh-cleared.XXXXXX") || { echo "fm-logbook-refresh: cannot create temp file" >&2; exit 1; }
FILTERED=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-refresh-body.XXXXXX") || { echo "fm-logbook-refresh: cannot create temp file" >&2; exit 1; }
BOARD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-refresh-board.XXXXXX") || { echo "fm-logbook-refresh: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$BODY_FILE" "$SUPPRESSED" "$FILTERED" "$BOARD_FILE"' EXIT

# Compose the attention set. compose is itself opt-in gated, so we are past that;
# treat an empty/non-JSON body as a compose failure rather than syncing garbage.
if ! "$SCRIPT_DIR/fm-logbook-compose.sh" > "$BODY_FILE"; then
  echo "fm-logbook-refresh: could not compose the attention set" >&2
  exit 1
fi
if [ ! -s "$BODY_FILE" ] || ! jq -e . "$BODY_FILE" >/dev/null 2>&1; then
  echo "fm-logbook-refresh: composed board body was empty or not valid JSON" >&2
  exit 1
fi

# The live board, and the licence for the subtraction below. Read-only and best-effort
# in the sense that it never fails the refresh - but a read that did not answer leaves
# BOARD_VIEW empty, and an empty view means nothing is subtracted at all (see the
# header): the suppression rule that needs it most is "this id is back on the board ->
# evict", and that is exactly the rule protecting a live card from a declarative delete.
#
# All THREE conditions, because a 2xx is not a board view. logbook_get_json answers for
# the request, not for the body, so a 200 carrying nothing, or an HTML error page from
# whatever else is listening on this URL, would otherwise set BOARD_VIEW - and the filter
# reads an unusable body as a board with NO ids on it, which is precisely the state that
# cannot fire the eviction and deletes the live card. Neither bad body is distinguishable
# from a dead board here, so both take the same branch it does.
BOARD_VIEW=""
if logbook_get_json /api/board "$BOARD_FILE" >/dev/null 2>&1 \
   && [ -s "$BOARD_FILE" ] \
   && jq -e 'type == "object"' "$BOARD_FILE" >/dev/null 2>&1; then
  BOARD_VIEW="$BOARD_FILE"
fi

# Drop the cards the captain already settled, against a board this cycle could actually
# read. Best-effort by construction: the filter writes an empty suppression set when it
# cannot read its record, which is the old behavior (the card reappears) rather than a
# failed refresh. `$drop[0]` is bound before index() because jq evaluates an argument to
# index() against the value being searched, not against the item in hand.
#
# With no view the filter is not consulted at all, so the record is neither read nor
# maintained on this cycle: a settled card is re-declared once, and stays settled for
# every cycle that can see the board. Skipping the maintenance too is deliberate - a
# pass that adopted a sentinel hash without suppressing anything would spend the one
# suppression that sentinel exists to grant.
if [ -n "$BOARD_VIEW" ]; then
  logbook_cleared_filter "$BODY_FILE" "$BOARD_VIEW" "$SUPPRESSED"
  if ! jq -e 'length == 0' "$SUPPRESSED" >/dev/null 2>&1; then
    if jq -c --slurpfile drop "$SUPPRESSED" '
          (($drop[0]) // []) as $settled
          | .items = [ (.items // [])[] | . as $i | select(($settled | index($i.id)) == null) ]
        ' "$BODY_FILE" > "$FILTERED" 2>/dev/null && [ -s "$FILTERED" ]; then
      cat "$FILTERED" > "$BODY_FILE"
    else
      echo "fm-logbook-refresh: could not apply the settled-card record; syncing the full composed set" >&2
    fi
  fi
else
  echo "fm-logbook-refresh: could not read a usable board view, so the settled-card record is not applied to this declarative sync" >&2
fi

# Declarative full reconcile. Honors LOGBOOK_DRY_RUN inside fm-logbook-sync.sh, so a
# dry-run refresh previews to state/logbook-outbox/sync.json and posts nothing.
"$SCRIPT_DIR/fm-logbook-sync.sh" --json-file "$BODY_FILE"
