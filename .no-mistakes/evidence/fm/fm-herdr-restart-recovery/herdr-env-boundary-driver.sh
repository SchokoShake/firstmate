#!/usr/bin/env bash
# Live boundary check for the HERDR_ENV launch guard in bin/fm-spawn.sh.
# Spawns, through the REAL bin/fm-spawn.sh onto an isolated Herdr lab session
# (every Herdr call via bin/fm-herdr-lab.sh), a Claude SCOUT and a Claude
# SECONDMATE, logs the exact launch text firstmate types into each Herdr pane,
# and reads the resulting claude process environment from /proc.
# Expected (intent: ship and scout drop HERDR_ENV; secondmates untouched):
#   scout      launch carries `-u HERDR_ENV`, its claude has no HERDR_ENV
#   secondmate launch carries no `-u HERDR_ENV`, its claude keeps HERDR_ENV=1
# Usage: herdr-env-boundary-driver.sh <worktree-root>
set -u
WT_ROOT=$1
# shellcheck source=/dev/null
. "$WT_ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"

ORIGINAL_PATH=$PATH
REAL_PS=$(command -v ps)
HELPER=$ROOT/bin/fm-herdr-lab.sh
lab() { PATH="$ORIGINAL_PATH" "$HELPER" "$@"; }
SESSION=$(lab name fm-hdrenv-bnd) || fail "could not name a lab session"
LAB=$(fm_test_tmproot fm-hdrenv-bnd) || fail "no scratch dir"
LAB=$(cd "$LAB" && pwd -P)
SENDLOG="$LAB/send-text.log"
: > "$SENDLOG"
SCOUT_ID="hbscout$$"
SM_ID="hbsm$$"
HOME_DIR="$LAB/fmhome"
STATE_DIR="$HOME_DIR/state"
PROJ_DIR="$LAB/proj"
WT="$LAB/pool/1/wt"
SM_HOME="$LAB/smhome"
RC=0

cleanup() {
  local rc=$? p
  trap - EXIT
  lab teardown "$SESSION" || { echo "not ok - lab teardown or default-session tripwire failed" >&2; rc=1; }
  for p in "$WT" "$PROJ_DIR" "$SM_HOME"; do
    case "$p" in */fm-hdrenv-bnd.*/*)
      rm -rf -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')" ;;
    esac
  done
  rm -rf -- "/tmp/fm-$SCOUT_ID" "/tmp/fm-$SM_ID"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

herdr_forget_inherited_pane
unset HERDR_BIN_PATH TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT \
  CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT \
  CLAUDE_CODE_CHILD_NOTES_DIR CLAUDE_CODE_DISABLE_AGENT_VIEW
mkdir -p "$LAB/bin" "$HOME_DIR/data/$SCOUT_ID" "$HOME_DIR/data/$SM_ID" "$HOME_DIR/projects" "$STATE_DIR" "$HOME_DIR/config"

# Lab-scoped herdr wrapper (as in the restart guard) that also logs the text of
# every `pane send-text`, i.e. exactly what firstmate types into a Herdr pane.
cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -uo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
if [ "\${#args[@]}" -eq 1 ] && [ "\${args[0]}" = server ]; then
  PATH='$ORIGINAL_PATH' exec '$HELPER' provision '$SESSION'
fi
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-text ]; then
  printf 'PANE=%s TEXT=%s\n' "\${args[2]:-}" "\${args[3]:-}" >> '$SENDLOG'
fi
PATH='$ORIGINAL_PATH' exec '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$LAB/bin/herdr"
fm_fake_treehouse "$LAB/bin"
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "no-mistakes version v1.79.0 (fake)" ;;
  axi) printf 'runs_on_current_branch: 0\n' ;;
esac
exit 0
SH
chmod +x "$LAB/bin/no-mistakes"
fm_fake_exit0 "$LAB/bin" agent-presence gh gh-axi
export PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION"
[ "$(command -v herdr)" = "$LAB/bin/herdr" ] || fail "lab herdr wrapper must shadow the real herdr"

fm_git_worktree "$PROJ_DIR" "$WT" "task-$SCOUT_ID" || fail "scratch repo"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' "$$" > "$STATE_DIR/.lock"
printf '%s off\n' "$$" > "$STATE_DIR/.trace-context-effective"
touch "$STATE_DIR/.last-watcher-beat"
for id in "$SCOUT_ID" "$SM_ID"; do
  printf '# Live boundary check\nReply with the single word noted and do nothing else. Use no tool.\n' > "$HOME_DIR/data/$id/brief.md"
done
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$SM_HOME/data"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'trivial secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

fm_env() {
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" "$@"
}
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "herdr adapter did not load"

pane_of() { local t; t=$(fm_backend_target_of_meta "$STATE_DIR/$1.meta"); printf '%s' "${t#*:}"; }
claude_pid() {  # <pane>
  lab run "$SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]? | "\(.pid) \(.argv | join(" "))"' 2>/dev/null \
    | grep -E '^[0-9]+ ([^ ]*/)?claude( |$)' | head -n1 | cut -d' ' -f1
}
wait_pid() { local i p; for i in $(seq 1 40); do p=$(claude_pid "$1"); [ -n "$p" ] && { echo "$p"; return 0; }; sleep 0.5; done; return 1; }
herdr_env_of() { tr '\0' '\n' < "/proc/$1/environ" | grep '^HERDR_ENV=' || echo '(no HERDR_ENV)'; }

lab provision "$SESSION" >/dev/null || fail "could not provision lab session"

check() {  # <label> <id> <expect: dropped|kept> <spawn args...>
  local label=$1 id=$2 expect=$3 out pane launch pid envline
  shift 3
  out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$@" 2>&1) || { echo "not ok - $label: spawn failed:"; echo "$out"; RC=1; return; }
  echo "# $label spawn: $(printf '%s\n' "$out" | grep '^spawned' | head -n1)"
  pane=$(pane_of "$id")
  launch=$(grep -F "PANE=$pane " "$SENDLOG" | grep -E 'TEXT=.*(claude|env -u)' | tail -n1 | sed 's/^PANE=[^ ]* TEXT=//')
  echo "# $label launch typed into Herdr pane $pane:"
  printf '#   %s\n' "$(printf '%s' "$launch" | cut -c1-600)"
  pid=$(wait_pid "$pane") || { echo "not ok - $label: no claude process appeared in pane $pane"; RC=1; return; }
  envline=$(herdr_env_of "$pid")
  echo "# $label claude pid $pid environment: $envline"
  case "$expect" in
    dropped)
      case "$launch" in *"env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u HERDR_ENV "*) ;; *) echo "not ok - $label: launch lacks -u HERDR_ENV"; RC=1; return ;; esac
      [ "$envline" = '(no HERDR_ENV)' ] || { echo "not ok - $label: claude still carries $envline"; RC=1; return; }
      echo "ok - $label: launched without HERDR_ENV (env -u HERDR_ENV in the launch line, absent from the claude process)" ;;
    kept)
      case "$launch" in *"-u HERDR_ENV"*) echo "not ok - $label: launch drops HERDR_ENV"; RC=1; return ;; esac
      [ "$envline" = 'HERDR_ENV=1' ] || { echo "not ok - $label: claude lacks HERDR_ENV ($envline)"; RC=1; return; }
      echo "ok - $label: keeps HERDR_ENV (no -u HERDR_ENV in the launch line, HERDR_ENV=1 in the claude process)" ;;
  esac
  # Stop the agent right away; only the launch matters here.
  lab run "$SESSION" pane send-keys "$pane" ctrl+c >/dev/null 2>&1
  lab run "$SESSION" pane send-keys "$pane" ctrl+c >/dev/null 2>&1
}

echo "# claude $(claude --version | head -1) on $(herdr --version | head -1), lab session $SESSION"
check "claude scout on herdr" "$SCOUT_ID" dropped "$SCOUT_ID" "$PROJ_DIR" --scout --model haiku --backend herdr
check "claude secondmate on herdr" "$SM_ID" kept "$SM_ID" "$SM_HOME" --secondmate --model haiku --backend herdr
[ "$RC" -eq 0 ] && echo "# all HERDR_ENV boundary checks passed"
exit "$RC"
