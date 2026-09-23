#!/usr/bin/env bash
# Behavior tests for the per-adapter turn-boundary wiring that bin/fm-spawn.sh
# installs: the semantic busy-state events under the contract owned by
# bin/fm-busy-lib.sh, and the optional agent-presence beat that rides the same
# boundaries under the contract owned by bin/fm-spawn.sh's header.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin, the Claude hook commands, the Codex notify program) in a
# plain Node host or shell, so the artifact, the real bin/fm-busy-event.sh
# writer, and the real classifier are exercised together with no live harness
# session.
#
# The presence tests put a recording `agent-presence` on PATH to observe the
# beat, and assert the not-installed and failing cases through the properties
# that must hold either way - status zero, empty stdout, and an unchanged busy
# record - so a machine that happens to have the real CLI installed cannot turn
# them into false failures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_fakebin() {
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

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  set -- "$@" --mode no-mistakes --yolo off
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_CALL_LOG="${FM_FAKE_TMUX_CALL_LOG:-/dev/null}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Run a driver with <dir> ahead of PATH, in a subshell so the assignment cannot
# leak into the next case (a bash `VAR=x func` assignment outlives the call).
with_path() {  # <dir> <command...>
  local dir=$1
  shift
  ( PATH="$dir:$PATH"; "$@" )
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_presence_beat() {
  local rec id=presence-pi-1 out state ext bin log absent
  rec=$(make_spawn_case pi-presence pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  bin="$CASE_DIR/presence-bin"
  log="$CASE_DIR/presence.log"
  fm_fake_agent_presence "$bin" "$log"

  out=$(with_path "$bin" drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working'

  # An inner turn boundary is not a run boundary: beating there would flip a
  # settled worker back to working, so turn_end stays a notification only.
  out=$(with_path "$bin" drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  fm_assert_presence_beats "$log" 'beat --state working'

  # A settle that raced another run keeps the worker busy, so it must not beat.
  out=$(with_path "$bin" drive_pi_ext "$ext" settle-continuing) \
    || fail "continuing settle drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working'

  out=$(with_path "$bin" drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working' 'beat --state waiting'
  [ "$(classify pi "$id" "$state")" = "idle pi-ext" ] \
    || fail "the presence beat displaced the agent_settled idle event"

  absent="$CASE_DIR/no-presence"
  mkdir -p "$absent"
  out=$(with_path "$absent" drive_pi_ext "$ext" agent-start) \
    || fail "agent_start must still succeed with no agent-presence installed: $out"
  [ "$(classify pi "$id" "$state")" = "busy pi-ext" ] \
    || fail "an uninstalled agent-presence changed the recorded busy state"
  pass "pi extension beats working on agent_start and waiting on a confirmed settle, never on turn_end"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

test_opencode_plugin_presence_beat() {
  local rec id=presence-oc-1 out state plugin bin log absent
  rec=$(make_spawn_case oc-presence opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  bin="$CASE_DIR/presence-bin"
  log="$CASE_DIR/presence.log"
  fm_fake_agent_presence "$bin" "$log"

  out=$(with_path "$bin" drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") \
    || fail "busy drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working'

  # Presence is scoped to the latched worker session exactly as busy state is:
  # a child session's own edges are not this worker's turn boundaries.
  : > "$log"
  out=$(with_path "$bin" drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)" \
    "$(oc_idle ses_other)") || fail "child-session drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working'

  : > "$log"
  out=$(with_path "$bin" drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_main idle)") || fail "latched idle drive failed: $out"
  fm_assert_presence_beats "$log" 'beat --state working' 'beat --state waiting'

  : > "$log"
  rm -f "$state/$id.turn-ended"
  out=$(with_path "$bin" drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  fm_assert_presence_beats "$log" 'beat --state working' 'beat --state waiting'
  [ "$(classify opencode "$id" "$state")" = "idle opencode-plugin" ] \
    || fail "the presence beat displaced the session.idle idle event"

  absent="$CASE_DIR/no-presence"
  mkdir -p "$absent"
  out=$(with_path "$absent" drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") \
    || fail "the plugin must still succeed with no agent-presence installed: $out"
  [ "$(classify opencode "$id" "$state")" = "busy opencode-plugin" ] \
    || fail "an uninstalled agent-presence changed the recorded busy state"
  pass "opencode plugin beats working and waiting only for the latched worker session"
}

# The Codex notify program is the one turn-boundary artifact that rides the
# LAUNCH COMMAND, so it is recovered from what fm-spawn actually sent to the
# pane and then executed, which is what proves it survived every quoting layer
# between here and `bash -c`.
codex_notify_script() {  # <tmux-call-log>
  local raw
  raw=$(grep -o -- '-c "notify=\[[^]]*\]"' "$1" | head -1)
  [ -n "$raw" ] || return 1
  raw=${raw#-c \"notify=}
  raw=${raw%\"}
  printf '%s' "$raw" | sed 's/\\"/"/g' | jq -r '.[2]'
}

test_codex_notify_presence_beat() {
  local rec id=presence-cx-1 out state log script bin beats absent
  rec=$(make_spawn_case codex-presence codex "$id")
  read_case_record "$rec"
  log="$CASE_DIR/tmux-calls.log"
  out=$(FM_FAKE_TMUX_CALL_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  script=$(codex_notify_script "$log") \
    || fail "codex launch carried no notify program: $(cat "$log")"

  bin="$CASE_DIR/presence-bin"
  beats="$CASE_DIR/presence.log"
  fm_fake_agent_presence "$bin" "$beats"
  rm -f "$state/$id.turn-ended"
  out=$(with_path "$bin" bash -c "$script")
  expect_code 0 $? "the codex notify program must exit zero: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the codex notify program stopped touching the marker"
  # Codex exposes no turn-START and no session-end event, so it beats waiting
  # at every turn end and never working or end.
  fm_assert_presence_beats "$beats" 'beat --state waiting'

  absent="$CASE_DIR/no-presence"
  mkdir -p "$absent"
  rm -f "$state/$id.turn-ended"
  out=$(with_path "$absent" bash -c "$script")
  expect_code 0 $? "the codex notify program must exit zero with no agent-presence: $out"
  [ -f "$state/$id.turn-ended" ] || fail "an uninstalled agent-presence broke the marker touch"
  pass "codex notify touches the turn-end marker and beats waiting, with or without the CLI"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_presence_beat() {
  local rec id=presence-cl-1 out state settings bin log
  rec=$(make_spawn_case claude-presence claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  bin="$CASE_DIR/presence-bin"
  log="$CASE_DIR/presence.log"
  fm_fake_agent_presence "$bin" "$log"

  out=$(with_path "$bin" run_claude_hook "$settings" UserPromptSubmit)
  expect_code 0 $? "UserPromptSubmit hook must exit zero"
  [ -z "$out" ] || fail "UserPromptSubmit hook printed on stdout: $out"
  fm_assert_presence_beats "$log" 'beat --state working'
  [ "$(classify claude "$id" "$state")" = "busy claude-hook" ] \
    || fail "the presence beat displaced the UserPromptSubmit busy event"

  out=$(with_path "$bin" run_claude_hook "$settings" Stop)
  expect_code 0 $? "Stop hook must exit zero"
  [ -z "$out" ] || fail "Stop hook printed on stdout: $out"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  [ "$(classify claude "$id" "$state")" = "idle claude-hook" ] \
    || fail "the presence beat displaced the Stop idle event"

  with_path "$bin" run_claude_hook "$settings" StopFailure || fail "StopFailure hook must exit zero"
  with_path "$bin" run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook must exit zero"
  # Claude is the only adapter that reaches all four states: a turn opens
  # working, both turn ends beat waiting, and the session end RETIRES the row
  # rather than beating a state that would have to expire.
  fm_assert_presence_beats "$log" 'beat --state working' 'beat --state waiting' 'beat --state waiting' 'end'
  pass "claude hooks beat working at turn start, waiting at both turn ends, and end at session end"
}

test_claude_presence_is_optional_and_can_never_fail_a_hook() {
  local rec id=presence-cl-2 out state settings absent broken log ev
  rec=$(make_spawn_case claude-presence-optional claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  absent="$CASE_DIR/no-presence"
  mkdir -p "$absent"

  # Not installed: the PATH probe makes every hook a plain busy-state hook.
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    out=$(with_path "$absent" run_claude_hook "$settings" "$ev")
    expect_code 0 $? "$ev hook must exit zero with no agent-presence installed"
    [ -z "$out" ] || fail "$ev hook printed with no agent-presence installed: $out"
  done
  [ "$(classify claude "$id" "$state")" = "idle claude-hook" ] \
    || fail "an uninstalled agent-presence changed the recorded busy state"

  # Installed but failing and noisy: still zero, still nothing on stdout.
  # Claude reads hook stdout as protocol, so silence is the load-bearing half.
  broken="$CASE_DIR/broken-presence"
  log="$CASE_DIR/broken.log"
  fm_fake_agent_presence "$broken" "$log" 3
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    out=$(with_path "$broken" run_claude_hook "$settings" "$ev" 2>/dev/null)
    expect_code 0 $? "$ev hook must exit zero when the beat fails"
    [ -z "$out" ] || fail "$ev hook leaked failing-beat output onto stdout: $out"
  done
  [ "$(classify claude "$id" "$state")" = "idle claude-hook" ] \
    || fail "a failing agent-presence changed the recorded busy state"
  pass "claude presence beats are optional, silent, and cannot fail or pollute a hook"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_pi_extension_presence_beat
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_opencode_plugin_presence_beat
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_claude_hooks_presence_beat
test_claude_presence_is_optional_and_can_never_fail_a_hook
test_codex_unverified_until_a_semantic_source_exists
test_codex_notify_presence_beat

echo "all fm-busy-adapter-wiring tests passed"
