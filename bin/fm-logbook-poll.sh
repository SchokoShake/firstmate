#!/usr/bin/env bash
# One short-poll of the logbook board connector for pending captain answers.
#
# This is the Phase 2 inbound mirror of fm-x-poll.sh: where fm-x-poll.sh polls the
# public relay for a mention, this polls the LOCAL, loopback-only attention board
# for responses the captain gave on a card. It is the body of the watcher check
# shim state/logbook-watch.check.sh, where the contract is "output => wake
# firstmate, silence => keep sleeping".
#
# Inert by default: a HARD no-op (exit 0, no output) unless logbook is opted in via
# a truthy LOGBOOK_ENABLE in config/logbook.env (the same resolution
# fm-logbook-lib.sh already uses). So non-adopters see exactly the pre-Phase-2
# behavior - no poll, the default 300s watcher cadence - and the shim only exists
# for an opted-in home anyway (bootstrap drops it on opt-in, removes it on opt-out).
#
# Behavior when logbook is on:
#   HTTP 204 / empty / no responses  -> print nothing, exit 0 (no wake)
#   auth/config/tool errors          -> print one rate-limited diagnostic
#   pending responses                -> for each answer, stash the full response
#       object to state/logbook-inbox/<response_id>.json and print one compact line
#       "logbook-response <response_id>" (which becomes the watcher's check: wake
#       payload). The wake coalesces same-key checks, so one wake stands in for
#       several pending responses; logbook-respond drains the whole inbox.
# The full object is stashed verbatim, so every field the board sends
# (response_id, item_id, kind, value, text, created) is preserved for
# logbook-respond to route and act on.
#
# Config (config/logbook.env, LOGBOOK_ENV_FILE, or env): LOGBOOK_ENABLE (opt-in),
# LOGBOOK_URL (default http://127.0.0.1:8137), LOGBOOK_TOKEN (bearer auth). See
# fm-logbook-lib.sh and AGENTS.md section 15.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

logbook_load_config
# Hard no-op when logbook is off: this is what keeps the check shim inert.
logbook_enabled || exit 0

ERROR_FILE="$STATE/logbook-poll.error"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'logbook-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-poll.XXXXXX") || exit 0
AUTH_HEADER_FILE=
trap 'rm -f "$BODY_FILE" "$AUTH_HEADER_FILE"' EXIT
AUTH_HEADER_FILE=$(logbook_auth_header_file) || { emit_error_once "invalid token"; exit 0; }

# Short, bounded poll: a failure or timeout simply means "no wake this cycle";
# the next check cycle retries. -m 5 keeps this well inside the watcher's
# per-check timeout so the supervision loop is never starved.
code=$(curl -m 5 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Accept: application/json' \
  "$LOGBOOK_URL/api/connector/poll" 2>/dev/null) || exit 0

# 204 (nothing pending) is the common path; only 200 can carry responses.
case "$code" in
  200) ;;
  204) clear_error; exit 0 ;;
  400|401|403|404) emit_error_once "board returned HTTP $code"; exit 0 ;;
  *) exit 0 ;;
esac
[ -s "$BODY_FILE" ] || { clear_error; exit 0; }

# The board returns {"responses":[...]}. A missing/empty array means nothing
# pending (a defensive equivalent of 204) - stay silent.
count=$(jq -r '(.responses // []) | length' "$BODY_FILE" 2>/dev/null) || { clear_error; exit 0; }
case "$count" in ''|*[!0-9]*) count=0 ;; esac
[ "$count" -gt 0 ] || { clear_error; exit 0; }

INBOX="$STATE/logbook-inbox"
mkdir -p "$INBOX" 2>/dev/null || { emit_error_once "cannot create inbox"; exit 0; }

# Drain the array: stash each routable answer and print one wake line per answer.
# One malformed or unstashable response never aborts the others.
err_hit=0
i=0
while [ "$i" -lt "$count" ]; do
  RID=$(jq -r ".responses[$i].response_id // empty" "$BODY_FILE" 2>/dev/null)
  IID=$(jq -r ".responses[$i].item_id // empty" "$BODY_FILE" 2>/dev/null)
  idx=$i
  i=$((i + 1))

  # An answer with no id is unroutable; skip it rather than stash junk.
  [ -n "$RID" ] || continue
  [ -n "$IID" ] || continue

  # Defend the inbox filename: response_id is board-issued, but never trust it into
  # a path. Reject anything outside the tool's safe slug.
  logbook_valid_id "$RID" || continue

  # Stash the full response object atomically so a concurrent reader never sees a
  # half-written file.
  if jq ".responses[$idx]" "$BODY_FILE" > "$INBOX/$RID.json.tmp" 2>/dev/null \
    && mv -f "$INBOX/$RID.json.tmp" "$INBOX/$RID.json" 2>/dev/null; then
    printf 'logbook-response %s\n' "$RID"
  else
    rm -f "$INBOX/$RID.json.tmp" 2>/dev/null || true
    emit_error_once "cannot write inbox"
    err_hit=1
  fi
done

# Only clear the diagnostic marker on a fully clean drain; a persistent write
# problem stays surfaced.
[ "$err_hit" -eq 0 ] && clear_error
exit 0
