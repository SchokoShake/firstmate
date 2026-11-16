#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions. Its last section restarts that server from a different HOME
# to prove every task window the adapter creates or recreates starts with the
# launching process's HOME instead.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
ENV_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  [ -n "${ENV_DIR:-}" ] && rm -rf "$ENV_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- endpoint environment: the launcher's HOME, not the server's -------------
# A worker must start with the HOME of the firstmate that launched it even when
# the tmux server, and so any session it reuses, was started from another
# environment, as when the primary runs inside the captain's own session.
# Restart the private server from a different HOME, then read HOME back from
# the shell of a created window, of a window recreated into a live session, and
# of a window recreated into a gone session.

# endpoint_home: the HOME <target>'s shell reports, written through <out-file>.
# The probe is retyped until the new shell has read its startup files and runs it.
endpoint_home() {  # <target> <out-file>
  local target=$1 out=$2 i
  rm -f "$out"
  for _ in $(seq 1 100); do
    tmux send-keys -t "$target" C-c
    tmux send-keys -t "$target" -l "printf '%s\\n' \"\$HOME\" > '$out'"
    tmux send-keys -t "$target" Enter
    for i in $(seq 1 10); do
      [ -s "$out" ] && { cat "$out"; return 0; }
      sleep 0.1
    done
  done
  return 1
}

"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
ENV_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-env.XXXXXX")
SERVER_HOME="$ENV_DIR/server-home"
LAUNCHER_HOME="$ENV_DIR/launcher-home"
mkdir -p "$SERVER_HOME" "$LAUNCHER_HOME"
HOME="$SERVER_HOME" SHELL=/bin/sh tmux -f /dev/null new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: could not start the private server from its own HOME"
[ "$(tmux show-environment -g HOME)" = "HOME=$SERVER_HOME" ] \
  || fail "the private server did not start with its own HOME, so this case would prove nothing"
HOME=$LAUNCHER_HOME

wid=$(fm_backend_tmux_create_task "$SESSION" "fm-env-create" "$ENV_DIR") \
  || fail "fm_backend_tmux_create_task failed on the server started from another HOME"
got=$(endpoint_home "$wid" "$ENV_DIR/create.home") || fail "the created window's shell never reported its HOME"
[ "$got" = "$LAUNCHER_HOME" ] \
  || fail "a created window's shell sees HOME '$got', not the launcher's '$LAUNCHER_HOME'"

wid=$(fm_backend_tmux_recreate_task "$SESSION:fm-env-recreate" "$ENV_DIR") \
  || fail "fm_backend_tmux_recreate_task failed to reopen a window in the live session"
got=$(endpoint_home "$wid" "$ENV_DIR/recreate-live.home") || fail "the reopened window's shell never reported its HOME"
[ "$got" = "$LAUNCHER_HOME" ] \
  || fail "a window reopened in a live session sees HOME '$got', not the launcher's '$LAUNCHER_HOME'"

tmux has-session -t "=fm-env-gone" 2>/dev/null && fail "session fm-env-gone should not exist yet"
wid=$(fm_backend_tmux_recreate_task "fm-env-gone:fm-env-recreate" "$ENV_DIR") \
  || fail "fm_backend_tmux_recreate_task failed to reopen a window in a gone session"
got=$(endpoint_home "$wid" "$ENV_DIR/recreate-gone.home") || fail "the recreated session's shell never reported its HOME"
[ "$got" = "$LAUNCHER_HOME" ] \
  || fail "a window recreated with its session sees HOME '$got', not the launcher's '$LAUNCHER_HOME'"

# The reused session and the server keep their own environment.
[ "$(tmux show-environment -g HOME)" = "HOME=$SERVER_HOME" ] \
  || fail "creating task windows changed the server's global HOME"
if tmux show-environment -t "$SESSION" HOME >/dev/null 2>&1; then
  fail "creating task windows set HOME in the reused session's environment"
fi
pass "real tmux: created and recreated task windows start with the launcher's HOME, not the server's, and leave the session's environment alone"

cleanup_all
trap - EXIT
