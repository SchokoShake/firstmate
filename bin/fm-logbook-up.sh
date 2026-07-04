#!/usr/bin/env bash
# Idempotently ensure the local logbook attention-board server is running, detached.
#
# Usage: fm-logbook-up.sh
#
# Hard no-op unless opted in (config/logbook.env with a truthy LOGBOOK_ENABLE),
# mirroring fm-x-poll.sh's inert-by-default default. When opted in it health-checks
# GET $LOGBOOK_URL/health; if the board already answers it prints one line and
# exits 0. Otherwise it launches `node $LOGBOOK_TOOL_DIR/server.mjs` DETACHED
# (setsid/nohup, output to state/logbook-server.log, LOGBOOK_TOKEN/LOGBOOK_PORT in
# the env, runtime data kept under state/ so nothing is ever written into
# projects/), briefly polls /health for readiness, prints the board URL, and
# returns. It NEVER blocks the caller - the same discipline as arming the watcher -
# so bootstrap can call it safely.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

logbook_load_config
# Inert unless opted in: keeps this a safe no-op for non-adopters.
logbook_enabled || exit 0

command -v curl >/dev/null 2>&1 || { echo "fm-logbook-up: curl not found; cannot manage the board" >&2; exit 1; }

health_code() {
  local c
  c=$(curl -m 2 -s -o /dev/null -w '%{http_code}' "$LOGBOOK_URL/health" 2>/dev/null) || c=000
  printf '%s' "$c"
}

# Already up? Then we are done - the common, cheap path (and all the tests exercise).
case "$(health_code)" in
  2[0-9][0-9]) echo "logbook: board already up at $LOGBOOK_URL"; exit 0 ;;
esac

# The board is down: we need node and the tool checkout to launch it.
command -v node >/dev/null 2>&1 || { echo "fm-logbook-up: node not found; cannot start the board" >&2; exit 1; }
SERVER="$LOGBOOK_TOOL_DIR/server.mjs"
[ -f "$SERVER" ] || { echo "fm-logbook-up: board server not found at $SERVER" >&2; exit 1; }

mkdir -p "$STATE" 2>/dev/null || { echo "fm-logbook-up: cannot create state dir: $STATE" >&2; exit 1; }
LOG="$STATE/logbook-server.log"
# Keep the tool's runtime data under firstmate's state dir, never inside projects/
# (the projects/ tree is read-only for firstmate - prime directive #1).
export LOGBOOK_DATA="$STATE/logbook.data"
export LOGBOOK_PORT
[ -n "$LOGBOOK_TOKEN" ] && export LOGBOOK_TOKEN

# Launch DETACHED so the server outlives this script and never blocks the caller.
if command -v setsid >/dev/null 2>&1; then
  setsid node "$SERVER" >>"$LOG" 2>&1 </dev/null &
else
  nohup node "$SERVER" >>"$LOG" 2>&1 </dev/null &
fi

# Briefly poll for readiness (bounded, ~3s, so we never block the caller). The
# server is already detached; this only decides which message to print.
i=0
while [ "$i" -lt 15 ]; do
  case "$(health_code)" in
    2[0-9][0-9]) echo "logbook: board started at $LOGBOOK_URL"; exit 0 ;;
  esac
  i=$((i + 1))
  sleep 0.2
done

echo "fm-logbook-up: board launched but not yet healthy at $LOGBOOK_URL (see ${LOG#"$FM_HOME/"})" >&2
exit 1
