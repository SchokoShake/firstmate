#!/usr/bin/env bash
# fm-send refuses to type into a recorded task whose agent has exited.
#
# Text typed at the bare shell left behind runs as a shell command, and an
# apostrophe wedges the shell in quote continuation. The recovery-grade
# classifier (fm_backend_agent_state) decides, with a stubbed tmux standing in
# for the pane's foreground command:
#   1. A bare shell gets no text and no key, and the refusal names the task and
#      the control-plane fix (revive for a ship, relaunch for a secondmate),
#      before a secondmate's reply expectation is recorded.
#   2. A live agent's send is unchanged.
#   3. An unidentifiable foreground refuses text but still takes a --key, the
#      path a trust-dialog answer uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-exited-agent)

# The stub answers the classifier's window inventory and foreground command,
# and logs every send-keys call.
make_stubs() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    printf 'send-keys %s\n' "$*" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "$FM_FAKE_COMMAND"; exit 0 ;;
        *pane_tty*) exit 0 ;;
      esac
    done
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'fm-t1\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_case <name> <foreground-command> <kind> <fm-send args...>: sets OUT, RC,
# LOG (the send-keys log), and HOME_DIR.
run_case() {
  local name=$1 command=$2 kind=$3 dir fb
  shift 3
  dir="$TMP_ROOT/$name"
  HOME_DIR="$dir/home"
  LOG="$dir/tmux.log"
  mkdir -p "$HOME_DIR/state"
  : > "$LOG"
  fb=$(make_stubs "$dir")
  fm_write_meta "$HOME_DIR/state/t1.meta" "window=sess:fm-t1" "kind=$kind" "harness=claude"
  OUT=$(PATH="$fb:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_TMUX_LOG="$LOG" \
    FM_FAKE_COMMAND="$command" FM_SEND_SETTLE=0 "$SEND" t1 "$@" 2>&1)
  RC=$?
}

test_bare_shell_gets_nothing() {
  run_case dead-text zsh ship "don't run this"
  expect_code 1 "$RC" "text to a bare shell should be refused"$'\n'"$OUT"
  assert_contains "$OUT" "task t1's agent has exited" "the refusal should name the task"
  assert_contains "$OUT" "bin/fm-control.sh t1 revive" "the refusal should name the fix"
  [ ! -s "$LOG" ] || fail "a refused send still typed into the shell"$'\n'"$(cat "$LOG")"
  run_case dead-key zsh ship --key Enter
  expect_code 1 "$RC" "a key to a bare shell should be refused"$'\n'"$OUT"
  [ ! -s "$LOG" ] || fail "a refused key still reached the shell"$'\n'"$(cat "$LOG")"
  pass "fm-send: a task whose agent has exited gets no text and no key, and the refusal names the fix"
}

test_bare_shell_secondmate_records_nothing() {
  run_case dead-mate bash secondmate "status please"
  expect_code 1 "$RC" "text to a secondmate's bare shell should be refused"$'\n'"$OUT"
  assert_contains "$OUT" "bin/fm-control.sh t1 relaunch" "a secondmate's fix is relaunch"
  [ ! -s "$LOG" ] || fail "a refused send still typed into the shell"$'\n'"$(cat "$LOG")"
  [ -z "$(ls -A "$HOME_DIR/state/pending-replies" 2>/dev/null)" ] \
    || fail "a refused send still recorded a reply expectation"
  pass "fm-send: a secondmate whose agent has exited is refused before any reply expectation is recorded"
}

test_live_agent_send_unchanged() {
  run_case alive-text claude ship "carry on"
  expect_code 0 "$RC" "text to a live agent should be sent"$'\n'"$OUT"
  assert_contains "$(cat "$LOG")" "-l carry on" "the text should be typed"
  assert_contains "$(cat "$LOG")" "sess:fm-t1 Enter" "the text should be submitted"
  pass "fm-send: a live agent's send is unchanged"
}

test_ambiguous_takes_keys_not_text() {
  run_case odd-text python3 ship "carry on"
  expect_code 1 "$RC" "text to an unidentifiable foreground should be refused"$'\n'"$OUT"
  assert_contains "$OUT" "not identifiable as its agent" "the refusal should say why"
  [ ! -s "$LOG" ] || fail "a refused send still typed into the pane"$'\n'"$(cat "$LOG")"
  run_case odd-key python3 ship --key Enter
  expect_code 0 "$RC" "a key to an unidentifiable foreground should be sent"$'\n'"$OUT"
  assert_contains "$(cat "$LOG")" "sess:fm-t1 Enter" "the key should be delivered"
  pass "fm-send: an unidentifiable foreground refuses text but still takes a key"
}

test_bare_shell_gets_nothing
test_bare_shell_secondmate_records_nothing
test_live_agent_send_unchanged
test_ambiguous_takes_keys_not_text
echo "# all fm-send-exited-agent tests passed"
