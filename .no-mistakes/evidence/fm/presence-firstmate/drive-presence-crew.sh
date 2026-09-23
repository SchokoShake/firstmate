#!/usr/bin/env bash
# Manual product driver: stand up isolated firstmate homes, run the REAL
# bin/fm-spawn.sh for each harness, then fire each adapter's real turn-boundary
# wiring with a recording stand-in for bridge-axi's agent-presence CLI and print
# what the captain's board would have been told.
set -u
ROOT=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M37BVYP4KRZEJ5GFH74YYCV4
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-presence-drive)

hr() { printf '\n========== %s ==========\n' "$*"; }
sub() { printf '\n-- %s\n' "$*"; }

NO_PRESENCE_PATH=$(fm_presence_absent_path "$TMP_ROOT/no-presence" \
  bash sh node jq touch awk basename cat date dirname grep head mkdir mv rm rmdir sed sleep stat tail) || exit 1

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" pi opencode claude codex
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# spawn_case <name> <harness> <id> [extra spawn args...]
spawn_case() {
  local name=$1 harness=$2 id=$3
  shift 3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  TMUX_LOG="$CASE_DIR/tmux-calls.log"
  FAKEBIN=$(make_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$id"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_TMUX_CALL_LOG="$TMUX_LOG" HOME="$CASE_DIR/fake-user-home" \
    GROK_HOME="$CASE_DIR/grok" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" > "$CASE_DIR/spawn.out" 2>&1
  SPAWN_RC=$?
  SPAWN_OUT="$CASE_DIR/spawn.out"
  return $SPAWN_RC
}

recorder() {  # <dir> <log> [exit] [witness]
  fm_fake_agent_presence "$@"
}

show_beats() {  # <log>
  printf 'board saw:\n'
  if [ -s "$1" ]; then sed 's/^/    agent-presence /' "$1"; else printf '    (nothing)\n'; fi
}

##############################################################################
hr "CLAUDE CREWMATE: real spawn, real hooks, four presence states"
spawn_case claude-crew claude presence-claude-1 --mode no-mistakes --yolo off
printf 'spawn rc=%s\n' "$?"
tail -2 "$SPAWN_OUT"
SETTINGS="$WT_DIR/.claude/settings.local.json"
sub "generated $(basename "$SETTINGS") (the artifact Claude Code itself reads)"
jq -r '.hooks | to_entries[] | "\(.key):\n  \(.value[0].hooks[0].command)"' "$SETTINGS"

BIN="$CASE_DIR/presence-bin"; LOG="$CASE_DIR/presence.log"
recorder "$BIN" "$LOG"
sub "firing each hook exactly as Claude Code would"
for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
  cmd=$(jq -r ".hooks[\"$ev\"][0].hooks[0].command" "$SETTINGS")
  hook_out=$(PATH="$BIN:$PATH" sh -c "$cmd" 2>/dev/null); rc=$?
  printf '  %-17s exit=%s stdout=%s\n' "$ev" "$rc" "$(printf '%q' "$hook_out")"
done
show_beats "$LOG"
printf 'firstmate busy record after the beats: %s\n' \
  "$(. "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w claude presence-claude-1 "$HOME_DIR/state")"

sub "ADVERSARIAL 1: bridge-axi not installed (hermetic PATH, no agent-presence resolvable)"
for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
  cmd=$(jq -r ".hooks[\"$ev\"][0].hooks[0].command" "$SETTINGS")
  hook_out=$(PATH="$NO_PRESENCE_PATH" sh -c "$cmd" 2>/dev/null); rc=$?
  printf '  %-17s exit=%s stdout=%s\n' "$ev" "$rc" "$(printf '%q' "$hook_out")"
done
printf 'firstmate busy record: %s\n' \
  "$(. "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w claude presence-claude-1 "$HOME_DIR/state")"

sub "ADVERSARIAL 2: agent-presence installed but failing (exit 3) and noisy on both streams"
BROKEN="$CASE_DIR/broken-bin"; BLOG="$CASE_DIR/broken.log"
recorder "$BROKEN" "$BLOG" 3
for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
  cmd=$(jq -r ".hooks[\"$ev\"][0].hooks[0].command" "$SETTINGS")
  hook_out=$(PATH="$BROKEN:$PATH" sh -c "$cmd" 2>/dev/null); rc=$?
  printf '  %-17s exit=%s stdout=%s\n' "$ev" "$rc" "$(printf '%q' "$hook_out")"
done
printf 'the failing CLI was still called %s times; firstmate busy record: %s\n' \
  "$(wc -l < "$BLOG")" \
  "$(. "$ROOT/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w claude presence-claude-1 "$HOME_DIR/state")"

##############################################################################
hr "CODEX CREWMATE: the beat rides the launch command through the pane"
spawn_case codex-crew codex presence-codex-1 --mode no-mistakes --yolo off
printf 'spawn rc=%s\n' "$?"
tail -1 "$SPAWN_OUT"
sub "launch command fm-spawn actually sent to the pane (send-keys), verbatim"
grep -o -- 'codex .*' "$TMUX_LOG" | head -1 | fold -w 150
sub "notify program recovered from that launch command and executed"
raw=$(grep -o -- '-c "notify=\[[^]]*\]"' "$TMUX_LOG" | head -1)
raw=${raw#-c \"notify=}; raw=${raw%\"}
script=$(printf '%s' "$raw" | sed 's/\\"/"/g' | jq -r '.[2]')
printf '  %s\n' "$script"
BIN="$CASE_DIR/presence-bin"; LOG="$CASE_DIR/presence.log"
recorder "$BIN" "$LOG"
rm -f "$HOME_DIR/state/presence-codex-1.turn-ended"
hook_out=$(PATH="$BIN:$PATH" bash -c "$script" 2>&1); rc=$?
printf '  exit=%s stdout=%s turn-end marker written=%s\n' "$rc" "$(printf '%q' "$hook_out")" \
  "$([ -f "$HOME_DIR/state/presence-codex-1.turn-ended" ] && echo yes || echo no)"
show_beats "$LOG"

##############################################################################
hr "OPENCODE CREWMATE: generated plugin driven in a plain Node host"
spawn_case oc-crew opencode presence-oc-1 --mode no-mistakes --yolo off
printf 'spawn rc=%s\n' "$?"
tail -1 "$SPAWN_OUT"
PLUGIN="$WT_DIR/.opencode/plugins/fm-busy-state.js"
BIN="$CASE_DIR/presence-bin"; LOG="$CASE_DIR/presence.log"
recorder "$BIN" "$LOG"
drive_oc() {
  PLUGIN_PATH="$PLUGIN" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) await hooks.event({ event: JSON.parse(arg) });
EOF
}
st() { printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"; }
idle() { printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"; }
sub "worker session busy -> child session busy/idle -> worker session idle"
PATH="$BIN:$PATH" drive_oc "$(st ses_worker busy)" "$(st ses_child busy)" "$(st ses_child idle)" "$(st ses_worker idle)"
show_beats "$LOG"
sub "ADVERSARIAL: a foreign session's idle must not speak for this worker"
: > "$LOG"
PATH="$BIN:$PATH" drive_oc "$(st ses_worker busy)" "$(idle ses_someone_else)"
show_beats "$LOG"

##############################################################################
hr "PI CREWMATE: generated extension driven in a plain Node host"
spawn_case pi-crew pi presence-pi-1 --mode no-mistakes --yolo off
printf 'spawn rc=%s\n' "$?"
tail -1 "$SPAWN_OUT"
EXT="$HOME_DIR/state/presence-pi-1.pi-ext.ts"
BIN="$CASE_DIR/presence-bin"; LOG="$CASE_DIR/presence.log"
recorder "$BIN" "$LOG"
drive_pi() {
  EXT_PATH="$EXT" MODE="$1" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const h = {};
mod.default({ on: (n, f) => { h[n] = f; } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
if (process.env.MODE === "agent-start") await h["agent_start"]({}, ctx);
else if (process.env.MODE === "turn-end") { await h["turn_end"]({}, ctx); await new Promise(r => setTimeout(r, 200)); }
else await h["agent_settled"]({}, ctx);
EOF
}
for mode in agent-start turn-end settle-continuing settle-idle; do
  PATH="$BIN:$PATH" drive_pi "$mode" >/dev/null
  printf '  after %-17s beats so far: %s\n' "$mode" "$(tr '\n' '|' < "$LOG")"
done
show_beats "$LOG"

##############################################################################
hr "SCOUT: a scout is a covered worker (crewmates AND scouts)"
spawn_case claude-scout claude presence-scout-1 --scout
printf 'spawn rc=%s\n' "$?"
tail -1 "$SPAWN_OUT"
SETTINGS="$WT_DIR/.claude/settings.local.json"
BIN="$CASE_DIR/presence-bin"; LOG="$CASE_DIR/presence.log"
recorder "$BIN" "$LOG"
for ev in UserPromptSubmit Stop SessionEnd; do
  cmd=$(jq -r ".hooks[\"$ev\"][0].hooks[0].command" "$SETTINGS")
  PATH="$BIN:$PATH" sh -c "$cmd" >/dev/null 2>&1
done
show_beats "$LOG"

##############################################################################
hr "NO USER-LEVEL HOOK, AND NO UNSUBSTITUTED PLACEHOLDER ANYWHERE"
sub "every spawn above ran with its own HOME; a user-level ~/.claude/settings.json would be a captain-decision violation"
find "$TMP_ROOT" -path '*fake-user-home*' -name 'settings.json' -print 2>/dev/null | sed 's/^/  LEAK: /'
printf '  user-level claude settings written by any spawn: %s\n' \
  "$(find "$TMP_ROOT" -path '*fake-user-home*' -name 'settings.json' 2>/dev/null | wc -l)"
sub "search every generated artifact and every launch command for an unsubstituted __PRESENCE placeholder"
grep -rl '__PRESENCE' "$TMP_ROOT" 2>/dev/null | sed 's/^/  LEAK: /'
printf '  files still carrying a raw __PRESENCE token: %s\n' \
  "$(grep -rl '__PRESENCE' "$TMP_ROOT" 2>/dev/null | wc -l)"
