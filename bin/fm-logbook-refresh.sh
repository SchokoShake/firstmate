#!/usr/bin/env bash
# Refresh the whole logbook board from current fleet state: compose the attention
# set and declaratively sync it. The one-call session-start truth-restore.
#
# Usage: fm-logbook-refresh.sh
#
# Runs fm-logbook-compose.sh (the {projects, items} baseline from data/projects.md,
# data/backlog.md, state/*.meta, and state/*.status) and hands it to
# fm-logbook-sync.sh (POST /api/sync). This is what bootstrap invokes after the
# board server is up so the session-start reconcile is automatic, not a step
# firstmate has to remember; firstmate can also run it by hand mid-session to
# re-truth the board.
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
trap 'rm -f "$BODY_FILE"' EXIT

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

# Declarative full reconcile. Honors LOGBOOK_DRY_RUN inside fm-logbook-sync.sh, so a
# dry-run refresh previews to state/logbook-outbox/sync.json and posts nothing.
"$SCRIPT_DIR/fm-logbook-sync.sh" --json-file "$BODY_FILE"
