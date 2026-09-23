#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, the global hook's optional
# agent-presence beat, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)
NO_PRESENCE_PATH=$(fm_presence_absent_path "$TMP_ROOT/no-presence" bash cat touch) || exit 1

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  # shellcheck disable=SC2031 # An ordinary environment prefix on an external command; nothing is expected to outlive it.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok --mode no-mistakes --yolo off 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  # shellcheck disable=SC2031 # An ordinary environment prefix on an external command; nothing is expected to outlive it.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # shellcheck disable=SC2031 # An ordinary environment prefix on an external command; nothing is expected to outlive it.
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_hook_presence_beat() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target
  local bin log evil
  rec=$(make_spawn_case presence)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed: $out"
  hook="$grok_home/hooks/fm-turn-end.sh"
  target="$home/state/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  bin="$case_dir/presence-bin"
  log="$case_dir/presence.log"
  fm_fake_agent_presence "$bin" "$log"

  # grok exposes no turn-START and no session-end event, so its one hook beats
  # "waiting" and never "working" or "end".
  # shellcheck disable=SC2031 # An ordinary environment prefix on an external command; nothing is expected to outlive it.
  out=$(PATH="$bin:$PATH" GROK_WORKSPACE_ROOT="$wt" bash "$hook" 2>&1)
  status=$?
  expect_code 0 "$status" "the grok hook must exit zero"
  [ -z "$out" ] || fail "the grok hook printed output: $out"
  assert_present "$target" "the grok hook stopped touching the turn-end marker"
  fm_assert_presence_beats "$log" 'beat --state waiting'
  # The beat must resolve the WORKER's worktree, not whatever cwd grok handed
  # the hook, because the CLI derives its subject from the worker's own repo.
  [ "$(cat "$log.pwd")" = "$(cd "$wt" && pwd -P)" ] \
    || fail "the grok beat ran in '$(cat "$log.pwd")', expected the task worktree"

  # A workspace the registry does not authorise must not beat at all.
  evil="$case_dir/evil"
  mkdir -p "$evil"
  printf 'token=%s\n' "not-a-token" > "$evil/.fm-grok-turnend"
  : > "$log"
  # shellcheck disable=SC2031 # An ordinary environment prefix on an external command; nothing is expected to outlive it.
  out=$(PATH="$bin:$PATH" GROK_WORKSPACE_ROOT="$evil" bash "$hook" 2>&1)
  expect_code 0 $? "an unauthorised grok workspace must still exit zero"
  fm_assert_presence_beats "$log"

  # Not installed: the hook is unchanged for every home without bridge-axi.
  rm -f "$target"
  out=$(PATH="$NO_PRESENCE_PATH" GROK_WORKSPACE_ROOT="$wt" bash "$hook" 2>&1)
  expect_code 0 $? "the grok hook must exit zero with no agent-presence installed"
  [ -z "$out" ] || fail "the grok hook printed with no agent-presence installed: $out"
  assert_present "$target" "an uninstalled agent-presence broke the turn-end marker touch"
  pass "grok global hook beats waiting in the authorised worktree only, and stays silent and zero"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_grok_hook_presence_beat
test_fm_lock_recognizes_grok_holder
