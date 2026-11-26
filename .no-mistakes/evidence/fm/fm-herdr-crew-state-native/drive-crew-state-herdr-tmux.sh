#!/usr/bin/env bash
# Evidence driver: runs the real bin/fm-crew-state.sh of <root> against real
# Herdr panes in an isolated fm-lab-* session (native agent state set through
# Herdr's own `pane report-agent`, or a pane with no agent at all) and against
# a private tmux server, printing one line per case.
# Usage: drive-crew-state-herdr-tmux.sh <firstmate-root> <lab-helper>
set -u
ROOT=$(cd "$1" && pwd -P)
LAB_HELPER=$2
ORIGINAL_PATH=$PATH
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" "$@"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE
SESSION=$(lab name csdrv)
LAB=$(mktemp -d /tmp/fm-csdrv.XXXXXX)
export TMUX_TMPDIR="$LAB/tmux"
mkdir -p "$TMUX_TMPDIR" "$LAB/bin" "$LAB/home/state" "$LAB/home/config" "$LAB/home/data" "$LAB/home/projects"
cleanup() {
  lab teardown "$SESSION" >/dev/null 2>&1 || echo "WARN: lab teardown failed for $SESSION"
  tmux kill-server >/dev/null 2>&1 || true   # private server under $TMUX_TMPDIR only
  rm -rf -- "$LAB"
}
trap cleanup EXIT

cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
EOF
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "no-mistakes version v1.79.0 (fake)";; esac\nexit 0\n' > "$LAB/bin/no-mistakes"
chmod +x "$LAB/bin/herdr" "$LAB/bin/no-mistakes"
export PATH="$LAB/bin:$PATH"

WT="$LAB/wt"
git init -q -b fm/feat-drv "$WT" && git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
STATE="$LAB/home/state"
ID=feat-drv

lab provision "$SESSION" >/dev/null || { echo "FATAL: provision failed"; exit 1; }
P_NOAGENT=$(lab run "$SESSION" workspace create --cwd "$WT" --no-focus | jq -r '.result.root_pane.pane_id')
P_AGENT=$(lab run "$SESSION" workspace create --cwd "$WT" --no-focus | jq -r '.result.root_pane.pane_id')
tmux new-session -d -s fmcs -c "$WT"

native() {  # <state>  set Herdr's native state of P_AGENT through Herdr's own reporting API
  lab run "$SESSION" pane report-agent --source fmdrv --agent claude --state "$1" "$P_AGENT" >/dev/null
}
meta() {  # <target> <backend> <kind> <harness>
  printf 'window=%s\nworktree=%s\nkind=%s\nbackend=%s\nharness=%s\nhome=%s\n' "$1" "$WT" "$3" "$2" "$4" "$WT" > "$STATE/$ID.meta"
}
record() {  # fresh|aged|none
  rm -f "$STATE/$ID.busy-state" "$STATE/$ID.busy-gen"* 2>/dev/null
  [ "$1" = none ] && return 0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
  "$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" busy --gen "$gen" --source claude-hook --event user-prompt-submit
  [ "$1" = aged ] && printf 'v1 gen=%s seq=9 state=busy source=claude-hook event=user-prompt-submit ts=%s\n' \
    "$gen" "$(( $(date +%s) - 60 ))" > "$STATE/$ID.busy-state"
  return 0
}
log() { if [ -n "$1" ]; then printf '%s\n' "$1" > "$STATE/$ID.status"; else rm -f "$STATE/$ID.status"; fi; }
crew() {
  env FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$LAB/home/data" \
    FM_PROJECTS_OVERRIDE="$LAB/home/projects" FM_CONFIG_OVERRIDE="$LAB/home/config" \
    "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | head -1
}
# The watcher's absorb classifier (bin/fm-classify-lib.sh crew_absorb_class) over the real crew-state:
# working/paused absorb a wake, none surfaces it.
absorb() {
  env FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$LAB/home/data" \
    FM_PROJECTS_OVERRIDE="$LAB/home/projects" FM_CONFIG_OVERRIDE="$LAB/home/config" \
    bash -c '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class "$2"' _ "$ROOT" "$ID" 2>/dev/null
}
nat() { lab run "$SESSION" agent get "$1" 2>&1 | jq -r '.result.agent.agent_status // .error.code // empty' 2>/dev/null || true; }
case_() {  # <name> <herdr-native-shown-pane>
  printf '%-58s | native=%-15s | absorb=%-7s | %s\n' "$1" "${2:+$(nat "$2")}" "$(absorb)" "$(crew)"
}

echo "# root=$ROOT"
echo "# $(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null) lab session=$SESSION; tmux $(tmux -V) private socket under $TMUX_TMPDIR"
echo "--- Herdr, pane with no registered agent ($P_NOAGENT)"
meta "$SESSION:$P_NOAGENT" herdr ship claude
record fresh; log 'working: implementing'
case_ "H1 ship/claude busy record + 'working:' log"          "$P_NOAGENT"
record none; log ''
case_ "H2 ship/claude no record, no log"                     "$P_NOAGENT"
record fresh; log 'done: report ready'
case_ "H3 ship/claude busy record + 'done:' log"             "$P_NOAGENT"
log 'failed: build broke'
case_ "H4 ship/claude busy record + 'failed:' log"           "$P_NOAGENT"
log 'needs-decision: pick a schema'
case_ "H5 ship/claude busy record + 'needs-decision:' log"   "$P_NOAGENT"
meta "$SESSION:$P_NOAGENT" herdr scout claude
record fresh; log 'working: reading'
case_ "H6 scout/claude busy record + 'working:' log"         "$P_NOAGENT"
meta "$SESSION:$P_NOAGENT" herdr secondmate claude
record none; log 'paused: holding for the upstream release'
case_ "H7 secondmate agent-less + 'paused:' log"             "$P_NOAGENT"
echo "--- Herdr, pane whose agent state is reported as claude ($P_AGENT)"
meta "$SESSION:$P_AGENT" herdr ship claude
native idle; record fresh; log ''
case_ "N1 native idle + FRESH busy claude-hook record"       "$P_AGENT"
record aged
case_ "N2 native idle + busy record aged 60s (interrupted)"  "$P_AGENT"
log 'working: implementing'
case_ "N3 native idle + aged record + 'working:' log"        "$P_AGENT"
native working; log ''
case_ "N4 native working + aged record"                      "$P_AGENT"
native blocked; record fresh
case_ "N5 native blocked + busy record (claude)"             "$P_AGENT"
meta "$SESSION:$P_AGENT" herdr ship cursor
case_ "N6 native blocked + busy record (cursor)"             "$P_AGENT"
meta "$SESSION:$P_AGENT" herdr secondmate claude
log 'working: supervising'
case_ "N7 native blocked, secondmate + 'working:' log"       "$P_AGENT"
echo "--- tmux (private server, no native state)"
meta "fmcs:0" tmux ship claude
record aged; log 'working: implementing'
case_ "T1 tmux ship/claude aged busy record + 'working:' log" ""
record fresh; log ''
case_ "T2 tmux ship/claude fresh busy record"                 ""
record none; log ''
case_ "T3 tmux ship/claude no record, no log"                 ""
