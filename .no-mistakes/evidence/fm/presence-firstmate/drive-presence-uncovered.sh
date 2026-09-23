#!/usr/bin/env bash
# Manual product driver, part 3: the two adapters the intent deliberately leaves
# UNCOVERED. Neither may acquire a beat by accident, and a worker on them must
# simply be absent from the board rather than reporting a wrong state.
set -u
ROOT=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M37BVYP4KRZEJ5GFH74YYCV4
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-presence-uncovered)
hr() { printf '\n========== %s ==========\n' "$*"; }

spawn_uncovered() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin uhome
  case_dir="$TMP_ROOT/$name"; home="$case_dir/home"; proj="$case_dir/project"
  wt="$case_dir/wt"; uhome="$case_dir/user-home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # A cursor-agent that identifies itself the way the real CLI does, so the
  # verified resolver accepts it and the spawn gets as far as writing wiring.
  printf '#!/bin/sh\necho "Start the Cursor Agent"\n' > "$fakebin/cursor-agent"
  chmod +x "$fakebin/cursor-agent"
  fm_fake_exit0 "$fakebin" muse
  fm_fake_treehouse "$fakebin"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$uhome"
  # muse refuses to launch a worker with no reachable credential; give the
  # fixture one so the spawn gets far enough to write whatever wiring it writes.
  mkdir -p "$uhome/.config/muse"
  printf '{"api_key":"fixture-key"}\n' > "$uhome/.config/muse/auth.json"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  CASE_DIR="$case_dir"; HOME_DIR="$home"; WT_DIR="$wt"; TMUX_LOG="$case_dir/tmux.log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    TMUX="fake,1,0" FM_FAKE_TMUX_CALL_LOG="$TMUX_LOG" HOME="$uhome" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$harness" --mode no-mistakes --yolo off \
    > "$case_dir/spawn.out" 2>&1
  printf 'spawn rc=%s: %s\n' "$?" "$(tail -1 "$case_dir/spawn.out")"
}

report_uncovered() {  # <label>
  printf -- '-- %s\n' "$1"
  printf '  turn-boundary wiring generated in the worktree: %s\n' \
    "$(find "$WT_DIR" \( -name 'settings.local.json' -o -name 'fm-busy-state.js' -o -name 'hooks.json' \) 2>/dev/null | wc -l)"
  printf '  sidecar the adapter DOES write (a pull-source binding, no writer, no beat):\n'
  find "$HOME_DIR/state" -name '*-session' -o -name '*-session*' 2>/dev/null | sed 's|.*/|    |'
  printf '  launch command sent to the pane mentions agent-presence: %s\n' \
    "$(grep -c 'agent-presence' "$TMUX_LOG" 2>/dev/null || echo 0)"
  printf '  any generated artifact under the worktree or state mentions agent-presence: %s\n' \
    "$(grep -rl 'agent-presence' "$WT_DIR" "$HOME_DIR/state" 2>/dev/null | wc -l)"
  printf '  launch command:\n'
  grep -o 'send-keys.*' "$TMUX_LOG" 2>/dev/null | tail -1 | cut -c1-220 | sed 's/^/    /'
}

hr "CURSOR: presence NOT COVERED until its crewmate stop event is live-verified"
spawn_uncovered cursor cursor presence-cursor-1
report_uncovered "cursor crewmate"

hr "MUSE: presence NONE, its only hook surface is off in the default build"
spawn_uncovered muse muse presence-muse-1
report_uncovered "muse crewmate"
