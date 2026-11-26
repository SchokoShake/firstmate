#!/usr/bin/env bash
# fm-control.sh: the agent lifecycle CONTROL plane.
#
# These tests pin the control plane's observable behavior hermetically - a
# stubbed session provider, no real agent - through the executable interface
# firstmate actually calls:
#   1. Adapter contract: every verified harness gets its own verified exit
#      command and interrupt key, delivered as bytes to the endpoint.
#   2. Backend capability: a backend that cannot deliver the harness's
#      interrupt key, and a backend with no recovery-grade agent-state
#      classifier, both refuse instead of acting blind.
#   3. Exact-id scoping: a window label, an explicit endpoint, an unknown id,
#      and a record bound to another task are all refused.
#   4. Verb allowlist: no arbitrary text, no raw keys, no resume.
#   5. Lifecycle states: busy interrupts first, idle does not, already-stopped
#      is idempotent success, an agent that does not stop fails closed, and a
#      herdr composer that already holds unsent text gets no exit command.
#      revive starts the stopped Herdr server a herdr endpoint lives in and
#      waits for the restored pane before classifying it.
#   6. Marker non-regression: a control command to a kind=secondmate task
#      carries NO from-firstmate marker and opens no pending-reply expectation,
#      while fm-send's marking of the same task is untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SEND="$ROOT/bin/fm-send.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

VERIFIED_HARNESSES="claude codex opencode pi pi-signed grok kimi cursor muse"

# The expectation table, written out independently of the implementation so a
# silent change to either side shows up here. The fourth field is the composer
# clear that must FOLLOW the interrupt key, empty for every adapter that leaves
# its composer empty on cancel.
verified_adapter_contract() {  # <harness> -> exit command, interrupt key, repeat, clear key
  case "$1" in
    claude) printf '/exit\tEscape\t1\t\n' ;;
    codex) printf '/quit\tEscape\t1\t\n' ;;
    opencode) printf '/exit\tEscape\t2\t\n' ;;
    pi) printf '/quit\tEscape\t1\t\n' ;;
    pi-signed) printf '/quit\tEscape\t1\t\n' ;;
    grok) printf '/exit\tC-c\t1\t\n' ;;
    kimi) printf '/exit\tEscape\t1\t\n' ;;
    cursor) printf '/exit\tEscape\t1\t\n' ;;
    muse) printf '/exit\tEscape\t1\tC-u\n' ;;
    *) return 1 ;;
  esac
}

# --- fake session provider --------------------------------------------------
#
# A tmux stub whose whole model is four files under $FM_FAKE_DIR:
#   command  the pane's foreground process name, which IS the agent-state
#            classifier's input (bin/backends/tmux.sh).
#   cwd      the pane's current path.
#   literal  every `send-keys -l` payload, one per line - exactly what was
#            typed into the composer.
#   keys     every named key send, one per line.
#   pane     optional capture-pane override, for an adapter whose busy verdict
#            is read from the rendered tail.
# Two transitions make it a lifecycle model rather than a recorder: a literal
# that is the harness's exit command flips `command` to a shell (the agent
# stopped), and a literal carrying a launch brief flips it to the value in
# `becomes` (a new agent came up). FM_FAKE_NEVER_DIES suppresses the first, so
# a stubborn agent can be tested too.
make_tmux_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      if [ -z "${FM_FAKE_NEVER_DIES:-}" ] \
         && { [ "$payload" = /exit ] || [ "$payload" = /quit ]; }; then
        printf 'zsh' > "$D/command"
      fi
      case "$payload" in
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      if [ -n "${FM_FAKE_INTERRUPT_STOPS_AGENT:-}" ] \
         && { [ "$payload" = Escape ] || [ "$payload" = C-c ]; }; then
        printf 'zsh' > "$D/command"
      fi
      if [ "$payload" = Escape ] && [ -n "${FM_FAKE_MUSE_LOG:-}" ]; then
        if [ -n "${FM_FAKE_MUSE_DISAPPEAR_BEFORE_ACK:-}" ]; then
          : > "$D/muse-ack-pending"
        else
          printf '%s\n' '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"terminal","terminal":"cancelled","reason":null}}}' >> "$FM_FAKE_MUSE_LOG"
        fi
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_MUSE_DISAPPEAR_BEFORE_ACK:-}" ] \
   && [ -e "$FM_FAKE_DIR/muse-ack-pending" ]; then
  rm -f "$FM_FAKE_DIR/muse-ack-pending"
  printf 'zsh' > "$FM_FAKE_DIR/command"
  printf '%s\n' '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"terminal","terminal":"cancelled","reason":null}}}' >> "$FM_FAKE_MUSE_LOG"
fi
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# new_case <name> -> echoes a case dir holding home/, fake/, and fakebin.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# add_task <case-dir> <id> <harness> [kind] [backend] [window]
# Builds the task's worktree (a real git worktree so the relaunch checkpoint
# has something to account for), its brief, and its state/<id>.meta.
add_task() {
  local dir=$1 id=$2 harness=$3 kind=${4:-ship} backend=${5:-tmux}
  local window=${6:-fmses:fm-$id}
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=$window"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    [ "$backend" = tmux ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

# run_control <case-dir> <args...>: run fm-control against the case's home with
# the stubbed provider on PATH. Echoes combined output; returns its exit code.
run_control() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_MUSE_LOG="${FM_FAKE_MUSE_LOG:-}" \
    FM_FAKE_MUSE_DISAPPEAR_BEFORE_ACK="${FM_FAKE_MUSE_DISAPPEAR_BEFORE_ACK:-}" \
    FM_FAKE_INTERRUPT_STOPS_AGENT="${FM_FAKE_INTERRUPT_STOPS_AGENT:-}" \
    "$CONTROL" "$@" 2>&1
}

alive_as() {  # <case-dir> <command-name>
  printf '%s' "$2" > "$1/fake/command"
}

literals() {  # <case-dir>
  cat "$1/fake/literal"
}

# Every named key EXCEPT Enter, which is submission mechanics shared with every
# text send rather than a control-plane key.
keys_sent() {  # <case-dir>
  grep -v '^Enter$' "$1/fake/keys" || true
}

# --- 1. adapter contract across every verified harness -----------------------

test_exit_types_each_harness_verified_command() {
  local dir out rc harness expected key repeat clear
  for harness in $VERIFIED_HARNESSES; do
    dir=$(new_case "exit-$harness")
    add_task "$dir" t1 "$harness"
    if [ "$harness" = cursor ]; then
      alive_as "$dir" cursor-agent
    else
      alive_as "$dir" "$harness"
    fi
    out=$(run_control "$dir" t1 exit); rc=$?
    expect_code 0 "$rc" "exit on $harness should succeed"$'\n'"$out"
    IFS=$'\t' read -r expected key repeat clear <<< "$(verified_adapter_contract "$harness")"
    [ "$(literals "$dir")" = "$expected" ] \
      || fail "exit on $harness should type exactly '$expected', got: $(literals "$dir")"
    assert_contains "$out" "stopped t1 harness=$harness" "exit should report the stop for $harness"
  done
  pass "fm-control exit: every verified harness gets its own verified exit command"
}

test_interrupt_sends_each_harness_verified_key() {
  local dir out rc harness expected key repeat clear got want
  for harness in $VERIFIED_HARNESSES; do
    dir=$(new_case "int-$harness")
    add_task "$dir" t1 "$harness"
    if [ "$harness" = cursor ]; then
      alive_as "$dir" cursor-agent
    else
      alive_as "$dir" "$harness"
    fi
    out=$(run_control "$dir" t1 interrupt); rc=$?
    expect_code 0 "$rc" "interrupt on $harness should succeed"$'\n'"$out"
    IFS=$'\t' read -r expected key repeat clear <<< "$(verified_adapter_contract "$harness")"
    want=$(for _ in $(seq 1 "$repeat"); do printf '%s\n' "$key"; done)
    [ -z "$clear" ] || want="$want"$'\n'"$clear"
    got=$(keys_sent "$dir")
    [ "$got" = "$want" ] \
      || fail "interrupt on $harness should send $repeat x $key${clear:+ then $clear}, got: $got"
    [ -z "$(literals "$dir")" ] \
      || fail "interrupt on $harness must type no text, got: $(literals "$dir")"
  done
  pass "fm-control interrupt: every verified harness gets its own verified key and repeat count"
}

# A recorded harness can carry a raw launch command's basename, so the tables
# are reached through one prefix rule rather than an exact string match.
test_harness_family_resolution() {
  local pair recorded want got
  for pair in claude:claude claude-latest:claude codex:codex codex-cli:codex \
      opencode:opencode grok:grok grok-2:grok kimi:kimi cursor:cursor \
      cursor-agent:cursor muse:muse muse-bin-0.1.0:muse pi:pi \
      pi-signed:pi-signed; do
    recorded=${pair%%:*}
    want=${pair#*:}
    got=$(fm_control_harness_family "$recorded") \
      || fail "'$recorded' should resolve to the $want adapter"
    [ "$got" = "$want" ] || fail "'$recorded' should resolve to $want, got '$got'"
  done
  fm_control_harness_family someagent \
    && fail "an unrecognized launch command must not be guessed into an adapter family"
  fm_control_harness_family '' \
    && fail "an empty harness must not resolve to an adapter family"
  # The signed adapter is a distinct launch profile, not a pi variant.
  [ "$(fm_control_harness_family pi-signed)" != "$(fm_control_harness_family pi)" ] \
    || fail "pi-signed must not collapse into pi"
  pass "fm-control-lib: a recorded harness resolves to its verified adapter without guessing"
}

test_prefixed_recorded_harness_reaches_each_control_verb() {
  local dir out rc
  dir=$(new_case prefixed-interrupt)
  add_task "$dir" t1 grok-2
  alive_as "$dir" grok-2
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "interrupt should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(keys_sent "$dir")" = C-c ] \
    || fail "a grok-prefixed task should receive grok's interrupt key"
  assert_contains "$out" "harness=grok" \
    "interrupt should report the verified adapter that supplied its mechanics"

  dir=$(new_case prefixed-exit)
  add_task "$dir" t1 grok-2
  alive_as "$dir" grok-2
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(literals "$dir")" = /exit ] \
    || fail "a grok-prefixed task should receive grok's exit command"
  assert_contains "$out" "stopped t1 harness=grok" \
    "exit should report the verified adapter that supplied its mechanics"
  pass "fm-control: prefixed recorded harnesses reach interrupt and exit mechanics"
}

test_opencode_interrupts_twice_and_others_once() {
  # The one adapter that differs, asserted through the delivered keys rather
  # than the table, so a regression in either shows up here.
  local dir
  dir=$(new_case int-double)
  add_task "$dir" t1 opencode
  alive_as "$dir" opencode
  run_control "$dir" t1 interrupt >/dev/null
  [ "$(keys_sent "$dir" | wc -l | tr -d ' ')" = 2 ] \
    || fail "opencode should receive a double Escape"
  dir=$(new_case int-single)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  run_control "$dir" t1 interrupt >/dev/null
  [ "$(keys_sent "$dir" | wc -l | tr -d ' ')" = 1 ] \
    || fail "claude should receive a single Escape"
  pass "fm-control interrupt: opencode needs a double Escape, claude a single one"
}

test_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case unverified)
  add_task "$dir" t1 someagent
  alive_as "$dir" someagent
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "an unverified harness should refuse"
  assert_contains "$out" "no verified control mechanics" "refusal should name the missing verification"
  [ -z "$(literals "$dir")" ] || fail "an unverified harness must receive no bytes"
  pass "fm-control: a harness with no verified control mechanics is refused, not guessed at"
}

# --- 2. backend capability matrix -------------------------------------------

test_backend_key_capability_matrix() {
  local backend key
  for backend in tmux herdr zellij cmux; do
    # C-u is the composer clear muse's interrupt needs; every session provider
    # but Orca normalizes it (bin/backends/*.sh).
    for key in Escape Enter C-c C-u; do
      fm_control_backend_supports_key "$backend" "$key" \
        || fail "$backend should be able to deliver $key"
    done
  done
  fm_control_backend_supports_key orca Escape \
    && fail "orca's terminal API has no Escape and must not claim it"
  fm_control_backend_supports_key orca C-u \
    && fail "orca's terminal API has no composer clear and must not claim one"
  fm_control_backend_supports_key orca C-c || fail "orca should deliver C-c"
  fm_control_backend_supports_key orca Enter || fail "orca should deliver Enter"
  pass "fm-control-lib: the backend key matrix matches each adapter's real send-key surface"
}

# A verified adapter is not automatically verified for every task kind, and the
# check has to sit on the pre-stop side of a relaunch: muse has no primary
# supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate, and
# discovering that only after the running agent was stopped would strand the
# secondmate with no agent at all.
test_harness_kind_capability() {
  local harness
  for harness in $VERIFIED_HARNESSES; do
    fm_control_harness_supports_kind "$harness" ship \
      || fail "$harness should be able to run a ship task"
    fm_control_harness_supports_kind "$harness" scout \
      || fail "$harness should be able to run a scout task"
  done
  fm_control_harness_supports_kind muse secondmate \
    && fail "muse has no primary supervision protocol and must not claim a secondmate"
  for harness in claude codex opencode pi pi-signed grok kimi; do
    fm_control_harness_supports_kind "$harness" secondmate \
      || fail "$harness should be able to run a secondmate"
  done
  fm_control_harness_supports_kind someagent ship \
    && fail "an unverified harness must not claim any kind"
  pass "fm-control-lib: adapter capability is per task kind, not per adapter alone"
}

test_orca_refuses_an_escape_harness_interrupt() {
  local dir out rc
  dir=$(new_case orca-escape)
  add_task "$dir" t1 claude ship orca "term-1"
  # Orca records its endpoint as terminal=, which endpoint validation requires.
  {
    cat "$dir/home/state/t1.meta"
    echo "terminal=term-1"
    echo "orca_worktree_id=wt-1"
  } > "$dir/home/state/t1.meta.new"
  sed 's|^window=.*|window=fm-t1|' "$dir/home/state/t1.meta.new" > "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 1 "$rc" "an Escape harness on orca should refuse"
  assert_contains "$out" "cannot deliver" "refusal should name the undeliverable key"
  pass "fm-control interrupt: a backend that cannot deliver the harness's key refuses instead of sending another"
}

test_unverified_state_backends_refuse_stop_verbs() {
  local dir out rc backend
  for backend in zellij cmux; do
    dir=$(new_case "nostate-$backend")
    if [ "$backend" = zellij ]; then
      add_task "$dir" t1 claude ship zellij "sess:7"
      {
        echo "zellij_session=sess"
        echo "zellij_tab_id=1"
        echo "zellij_pane_id=7"
      } >> "$dir/home/state/t1.meta"
    else
      add_task "$dir" t1 claude ship cmux "ws1:surface1"
      {
        echo "cmux_workspace_id=ws1"
        echo "cmux_surface_id=surface1"
      } >> "$dir/home/state/t1.meta"
    fi
    out=$(run_control "$dir" t1 exit); rc=$?
    expect_code 1 "$rc" "exit on $backend should refuse"$'\n'"$out"
    assert_contains "$out" "no recovery-grade agent-state classifier" \
      "the $backend refusal should name the missing stop proof"
    [ -z "$(literals "$dir")" ] || fail "$backend must receive no exit command"
    out=$(run_control "$dir" t1 relaunch --note x); rc=$?
    expect_code 1 "$rc" "relaunch on $backend should refuse"$'\n'"$out"
    assert_contains "$out" "no recovery-grade agent-state classifier" \
      "the $backend relaunch refusal should name the missing stop proof"
  done
  pass "fm-control: a backend that cannot prove an agent stopped refuses exit and relaunch"
}

test_state_verified_backends_are_exactly_tmux_and_herdr() {
  fm_control_backend_state_verified tmux || fail "tmux has a recovery-grade classifier"
  fm_control_backend_state_verified herdr || fail "herdr has a recovery-grade classifier"
  local backend
  for backend in zellij orca cmux; do
    fm_control_backend_state_verified "$backend" \
      && fail "$backend has no recovery-grade classifier and must not claim one"
  done
  pass "fm-control-lib: stop-proving verbs are gated on the backends that really classify agent state"
}

# --- 3. exact-id scoping ----------------------------------------------------

test_window_label_is_refused_with_the_exact_id() {
  local dir out rc
  dir=$(new_case label)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" fm-t1 exit); rc=$?
  expect_code 1 "$rc" "a window label should refuse"
  assert_contains "$out" "pass the exact task id 't1'" "the refusal should name the exact id"
  [ -z "$(literals "$dir")" ] || fail "a refused target must receive no bytes"
  pass "fm-control: a legacy window label is refused and the exact task id is named"
}

test_explicit_endpoint_is_refused() {
  local dir out rc
  dir=$(new_case endpoint)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" "fmses:fm-t1" exit); rc=$?
  expect_code 1 "$rc" "an explicit endpoint should refuse"
  assert_contains "$out" "exact task id only" "the refusal should name the exact-id rule"
  [ -z "$(literals "$dir")" ] || fail "a refused target must receive no bytes"
  pass "fm-control: an explicit backend endpoint is never a control target"
}

test_unknown_task_is_refused() {
  local dir out rc
  dir=$(new_case unknown)
  add_task "$dir" t1 claude
  out=$(run_control "$dir" t2 exit); rc=$?
  expect_code 1 "$rc" "an unknown task should refuse"
  assert_contains "$out" "no task 't2'" "the refusal should name the missing task"
  pass "fm-control: an unrecorded task id is refused"
}

test_record_bound_to_another_task_is_refused() {
  local dir out rc
  dir=$(new_case foreign)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  sed 's/^endpoint_task_id=t1$/endpoint_task_id=other/' "$dir/home/state/t1.meta" \
    > "$dir/home/state/t1.meta.tmp"
  mv "$dir/home/state/t1.meta.tmp" "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "a record bound to another task should refuse"
  assert_contains "$out" "belongs to task other" "the refusal should name the conflicting binding"
  [ -z "$(literals "$dir")" ] || fail "a foreign record must receive no bytes"
  pass "fm-control: a record whose endpoint identity names another task is refused"
}

# A remotely placed secondmate's agent runs on another host, so none of the
# postconditions this plane verifies could be read for it here. Endpoint
# validation would refuse the record anyway - `window=remote:<id>` can never
# match a local backend's shape - but it would blame malformed metadata for a
# correctly configured route, so the placement is named instead. Every verb
# refuses, and none of them reaches a local endpoint.
test_remote_secondmate_is_refused_by_placement() {
  local dir out rc verb
  for verb in interrupt exit relaunch; do
    dir=$(new_case "remote-$verb")
    add_task "$dir" t1 claude secondmate
    alive_as "$dir" claude
    {
      grep -v '^window=' "$dir/home/state/t1.meta"
      echo "window=remote:t1"
      echo "home=$dir/wt-t1"
      echo "remote_host=example.invalid"
      echo "remote_root=/srv/fm"
      echo "remote_backend=herdr"
      echo "remote_target=fm:pane-1"
    } > "$dir/home/state/t1.meta.tmp"
    mv "$dir/home/state/t1.meta.tmp" "$dir/home/state/t1.meta"
    if [ "$verb" = relaunch ]; then
      out=$(run_control "$dir" t1 "$verb" --note "x"); rc=$?
    else
      out=$(run_control "$dir" t1 "$verb"); rc=$?
    fi
    expect_code 1 "$rc" "$verb on a remotely placed secondmate should refuse"
    assert_contains "$out" "remotely placed secondmate on example.invalid" \
      "the $verb refusal should name the remote placement, not blame the record"
    assert_not_contains "$out" "malformed" \
      "a correctly configured remote route must not be reported as malformed"
    [ -z "$(literals "$dir")" ] && [ -z "$(keys_sent "$dir")" ] \
      || fail "$verb on a remote secondmate must reach no local endpoint"
  done
  pass "fm-control: a remotely placed secondmate is refused by placement, not by a metadata complaint"
}

hold_lifecycle_lock() {  # <lock-path>
  local lifecycle_lock_path=$1
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$lifecycle_lock_path" || return 1
  sleep 30
}

test_interrupt_and_exit_lock_before_task_state_resolution() {
  local case_dir out rc verb lifecycle_lock_path holder i
  for verb in interrupt exit; do
    case_dir=$(new_case "locked-$verb")
    add_task "$case_dir" t1 claude
    alive_as "$case_dir" claude
    lifecycle_lock_path="$case_dir/home/state/.control-t1.lock"
    hold_lifecycle_lock "$lifecycle_lock_path" &
    holder=$!
    i=0
    while [ ! -e "$lifecycle_lock_path" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -e "$lifecycle_lock_path" ] || fail "could not stage the lifecycle lock for $verb"
    sed 's/^endpoint_task_id=t1$/endpoint_task_id=other/' "$case_dir/home/state/t1.meta" \
      > "$case_dir/home/state/t1.meta.tmp"
    mv "$case_dir/home/state/t1.meta.tmp" "$case_dir/home/state/t1.meta"
    out=$(run_control "$case_dir" t1 "$verb"); rc=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    expect_code 1 "$rc" "$verb should refuse a held lifecycle lock"
    assert_contains "$out" "another lifecycle action is already running" \
      "$verb should serialize before reading mutable task state"
    [ -z "$(literals "$case_dir")" ] || fail "contended $verb must type no command"
    [ -z "$(keys_sent "$case_dir")" ] || fail "contended $verb must send no control key"
  done
  pass "fm-control: interrupt and exit lock before task-state resolution"
}

# --- 4. verb allowlist ------------------------------------------------------

test_verb_allowlist_is_closed() {
  local dir out rc
  dir=$(new_case verbs)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" t1 restart); rc=$?
  expect_code 2 "$rc" "an unknown verb should be a usage error"
  assert_contains "$out" "is not a control verb" "the refusal should say so"
  assert_contains "$out" "interrupt" "the refusal should list the allowed verbs"
  out=$(run_control "$dir" t1 --key); rc=$?
  expect_code 2 "$rc" "a raw key is not a control verb"
  out=$(run_control "$dir" t1 clear); rc=$?
  expect_code 2 "$rc" "clear is not a control verb"
  out=$(run_control "$dir" t1 "please stop what you are doing"); rc=$?
  expect_code 2 "$rc" "arbitrary text is not a control verb"
  [ -z "$(literals "$dir")" ] || fail "a refused verb must send nothing"
  [ -z "$(keys_sent "$dir")" ] || fail "a refused verb must send no keys"
  pass "fm-control: the verb list is closed - no raw keys, arbitrary text, or clear verb"
}

test_resume_is_refused_with_its_reason() {
  local dir out rc
  dir=$(new_case resume)
  add_task "$dir" t1 claude
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 2 "$rc" "resume should be refused"
  assert_contains "$out" "not deterministic across the verified adapters" \
    "the refusal should explain why resume is excluded"
  assert_contains "$out" "relaunch" "the refusal should point at the deterministic alternative"
  pass "fm-control: resume is refused with the determinism reason and the alternative"
}

test_relaunch_only_flags_are_rejected_on_other_verbs() {
  local dir out rc
  dir=$(new_case flags)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" t1 exit --harness codex); rc=$?
  expect_code 1 "$rc" "--harness should not apply to exit"
  assert_contains "$out" "apply to 'relaunch' only" "the refusal should scope the flags"
  pass "fm-control: profile and note flags belong to relaunch only"
}

# --- 5. lifecycle states ----------------------------------------------------

test_already_stopped_exit_is_idempotent() {
  local dir out rc
  dir=$(new_case idempotent)
  add_task "$dir" t1 claude
  alive_as "$dir" zsh
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting an already-stopped agent should succeed"
  assert_contains "$out" "already-stopped t1" "the outcome should say it was already stopped"
  [ -z "$(literals "$dir")" ] || fail "an already-stopped agent must not be sent an exit command"
  pass "fm-control exit: an already-stopped agent is idempotent success with no bytes sent"
}

test_missing_endpoint_refuses() {
  local dir out rc
  dir=$(new_case gone)
  add_task "$dir" t1 claude
  : > "$dir/fake/windows"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "a missing endpoint should refuse"
  assert_contains "$out" "recorded endpoint is gone" "the refusal should name the missing endpoint"
  pass "fm-control exit: a vanished endpoint refuses instead of silently succeeding"
}

test_interrupt_refuses_when_no_agent_runs() {
  local dir out rc
  dir=$(new_case nointerrupt)
  add_task "$dir" t1 claude
  alive_as "$dir" zsh
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 1 "$rc" "interrupting a stopped agent should refuse"
  assert_contains "$out" "nothing to interrupt" "the refusal should say there is no agent"
  [ -z "$(keys_sent "$dir")" ] || fail "no key should reach a stopped agent"
  pass "fm-control interrupt: refuses when no agent is running rather than keying a shell"
}

test_ambiguous_endpoint_refuses() {
  local dir out rc
  dir=$(new_case ambiguous)
  add_task "$dir" t1 claude
  alive_as "$dir" some-unrelated-process
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "an unattributed endpoint should refuse"
  assert_contains "$out" "positively classified" "the refusal should name the missing attribution"
  [ -z "$(literals "$dir")" ] || fail "an unattributed endpoint must receive no bytes"
  pass "fm-control exit: an endpoint whose process cannot be attributed refuses"
}

test_busy_agent_is_interrupted_before_the_exit_command() {
  local dir out rc
  dir=$(new_case busy)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  # Arm the semantic busy contract and record a busy turn, exactly as the
  # harness's own lifecycle hook would.
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting a busy agent should succeed"$'\n'"$out"
  [ "$(keys_sent "$dir")" = "Escape" ] \
    || fail "a busy agent should be interrupted once before its exit command, got: $(keys_sent "$dir")"
  [ "$(literals "$dir")" = "/exit" ] || fail "the exit command should follow the interrupt"
  pass "fm-control exit: a busy agent receives interrupt delivery before the exit command"
}

test_idle_agent_is_not_interrupted() {
  local dir out rc gen
  dir=$(new_case idle)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1 --state idle --source fm-spawn --event seed)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting an idle agent should succeed"$'\n'"$out"
  [ -z "$(keys_sent "$dir")" ] \
    || fail "an idle agent needs no interrupt, got keys: $(keys_sent "$dir")"
  [ "$(literals "$dir")" = "/exit" ] || fail "the exit command should still be sent"
  pass "fm-control exit: an idle agent goes straight to its exit command"
}

test_interrupt_without_acknowledgement_preserves_busy_state() {
  local dir gen before after out rc
  dir=$(new_case unconfirmed)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  before=$(cat "$dir/home/state/t1.busy-state")
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "an interrupt without acknowledgement should still deliver"$'\n'"$out"
  after=$(cat "$dir/home/state/t1.busy-state")
  [ "$after" = "$before" ] || fail "an unconfirmed interrupt must preserve adapter-owned busy state"
  assert_contains "$out" "verified=agent-alive cancel=unconfirmed" \
    "the result should distinguish delivery proof from unconfirmed cancellation"
  assert_not_contains "$out" "cancel=confirmed" \
    "an adapter without acknowledgement must not report cancellation"
  pass "fm-control interrupt: unconfirmed delivery preserves observed busy state"
}

test_muse_interrupt_confirms_adapter_acknowledgement() {
  local dir root log out rc
  dir=$(new_case confirmed)
  add_task "$dir" t1 muse
  alive_as "$dir" muse
  root="$dir/muse-sessions"
  log="$root/2026/08/08/session-1/session.jsonl"
  mkdir -p "$(dirname "$log")"
  printf '%s\n' \
    "{\"schema_version\":1,\"payload_type\":\"runtime.session.metadata\",\"payload\":{\"kind\":\"metadata\",\"record\":{\"workspace_root\":\"$dir/wt-t1\"}}}" \
    '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"started","prompt":"work"}}}' > "$log"
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=test\n' \
    "$root" "$dir/wt-t1" > "$dir/home/state/t1.muse-session"
  out=$(FM_FAKE_MUSE_LOG="$log" run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "muse interrupt should observe its adapter acknowledgement"$'\n'"$out"
  assert_contains "$out" "verified=agent-alive cancel=confirmed" \
    "the result should report muse's cancelled terminal acknowledgement"
  pass "fm-control interrupt: muse confirms cancellation from its session log"
}

test_interrupt_revalidates_agent_after_acknowledgement_wait() {
  local dir root log out rc
  dir=$(new_case ack-race)
  add_task "$dir" t1 muse
  alive_as "$dir" muse
  root="$dir/muse-sessions"
  log="$root/2026/08/08/session-1/session.jsonl"
  mkdir -p "$(dirname "$log")"
  printf '%s\n' \
    "{\"schema_version\":1,\"payload_type\":\"runtime.session.metadata\",\"payload\":{\"kind\":\"metadata\",\"record\":{\"workspace_root\":\"$dir/wt-t1\"}}}" \
    '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"started","prompt":"work"}}}' > "$log"
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=test\n' \
    "$root" "$dir/wt-t1" > "$dir/home/state/t1.muse-session"
  out=$(FM_FAKE_MUSE_LOG="$log" FM_FAKE_MUSE_DISAPPEAR_BEFORE_ACK=1 \
    run_control "$dir" t1 interrupt); rc=$?
  expect_code 1 "$rc" "interrupt should fail when the agent stops during acknowledgement polling"
  assert_contains "$out" "agent is 'dead' after its interrupt key" \
    "the final postcondition should observe the agent after acknowledgement polling"
  assert_not_contains "$out" "interrupt-delivered" \
    "a stale pre-wait liveness proof must not be published"
  pass "fm-control interrupt: postconditions are revalidated after acknowledgement polling"
}

test_exit_accepts_agent_stopped_by_busy_interrupt() {
  local dir out rc gen
  dir=$(new_case interrupt-stops)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(FM_FAKE_INTERRUPT_STOPS_AGENT=1 run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit should accept a busy agent stopped by interrupt"$'\n'"$out"
  assert_contains "$out" "stopped t1 harness=claude" \
    "the authoritative gone-state should complete exit successfully"
  [ "$(keys_sent "$dir")" = Escape ] \
    || fail "exit should deliver the busy agent's interrupt sequence"
  [ -z "$(literals "$dir")" ] \
    || fail "exit should not type a command after interrupt already stopped the agent"
  [ ! -e "$dir/home/state/t1.busy-gen" ] && [ ! -e "$dir/home/state/t1.busy-state" ] \
    || fail "exit should retire busy wiring for an agent stopped by interrupt"
  pass "fm-control exit: an interrupt-stopped agent satisfies the gone-state postcondition"
}

test_agent_that_does_not_stop_fails_closed() {
  local dir out rc gen
  dir=$(new_case stubborn)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(env FM_FAKE_NEVER_DIES=1 PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    "$CONTROL" t1 exit 2>&1); rc=$?
  expect_code 1 "$rc" "an agent that ignores its exit command should fail closed"
  assert_contains "$out" "did not stop" "the failure should say the agent did not stop"
  assert_contains "$out" "exit-delivered t1 interrupt=delivered verified=agent-alive cancel=unconfirmed exit-command=delivered agent-state=alive exit=unconfirmed" \
    "the failure should distinguish delivered lifecycle input from the unconfirmed exit"
  assert_not_contains "$out" "nothing was changed" \
    "the failure must not deny the lifecycle input that was delivered"
  [ "$(keys_sent "$dir")" = Escape ] \
    || fail "a stubborn busy agent should receive its interrupt sequence"
  [ "$(literals "$dir")" = /exit ] \
    || fail "a stubborn busy agent should receive its exit command"
  pass "fm-control exit: a stubborn agent reports delivered input and an unconfirmed exit"
}

# A herdr stub for the exit command's typed-draft guard, on the same files as
# the tmux stub: `literal` and `keys` record what was typed and pressed,
# `herdr-agent` holds the agent's raw status (an Enter that submits the exit
# command turns it into `gone`), and `herdr-screen` is the rendered pane.
make_herdr_stub() {  # <case-dir>
  cat > "$1/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get")
    if [ "$(cat "$D/herdr-agent")" = gone ]; then
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}"
    else
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$D/herdr-agent")"
    fi ;;
  "pane read") cat "$D/herdr-screen" ;;
  "pane send-text") printf '%s\n' "${4:-}" >> "$D/literal" ;;
  "pane send-keys")
    printf '%s\n' "${4:-}" >> "$D/keys"
    if [ "${4:-}" = enter ] && [ "$(tail -n 1 "$D/literal")" = /exit ]; then
      printf 'gone' > "$D/herdr-agent"
    fi ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/herdr"
}

# A herdr worker's composer can already hold text typed by hand; an exit
# command typed after it would merge into it and submit as one message, so
# exit must type nothing and must not claim the exit command was delivered.
# The same exit into an empty composer stops the agent, so the refusal cannot
# pass for a reason other than the draft.
test_herdr_exit_refuses_a_composer_holding_unsent_text() {
  local dir out rc rule
  dir=$(new_case herdr-draft)
  add_task "$dir" t1 claude ship herdr "default:w1:p2"
  printf '%s\n' "herdr_session=default" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" \
    >> "$dir/home/state/t1.meta"
  make_herdr_stub "$dir"
  rule='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'
  printf 'idle' > "$dir/fake/herdr-agent"
  printf '%b\n\xe2\x9d\xaf\xc2\xa0please also list three fruits\n%b\n' "$rule" "$rule" > "$dir/fake/herdr-screen"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "exit into a composer holding a draft should refuse"$'\n'"$out"
  assert_contains "$out" "the exit command was not typed into task t1" \
    "the refusal should say the exit command was not typed"
  assert_contains "$out" "already holds unsent text" "the refusal should name the unsent text as the reason"
  assert_not_contains "$out" "exit-command=delivered" \
    "the refusal must not claim an exit command that was never typed"
  [ -z "$(literals "$dir")" ] || fail "nothing may be typed after a draft, got: $(literals "$dir")"
  [ ! -s "$dir/fake/keys" ] || fail "no key may reach a composer holding a draft, got: $(cat "$dir/fake/keys")"
  [ "$(cat "$dir/fake/herdr-agent")" = idle ] || fail "the agent must still be running after the refusal"

  printf '%b\n\xe2\x9d\xaf\xc2\xa0\n%b\n' "$rule" "$rule" > "$dir/fake/herdr-screen"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit into an empty composer should stop the agent, or the refusal above proves nothing"$'\n'"$out"
  assert_contains "$out" "stopped t1 harness=claude backend=herdr" "the empty-composer exit should report the stop"
  [ "$(literals "$dir")" = /exit ] || fail "the empty-composer exit should type exactly /exit, got: $(literals "$dir")"
  pass "fm-control exit (herdr): a composer holding unsent text gets no exit command and the exit refuses"
}

# A stateful herdr stub for revive after a reboot: $D/herdr-server holds
# `stopped` or `running`, and a `server` start makes it `running` only while
# $D/herdr-can-start exists. While stopped every pane read fails as Herdr's
# does; once running, the first $D/herdr-settle reads still fail, as a restore
# that has not settled yet, and then the restored pane reads agent-free.
make_herdr_restore_stub() {  # <case-dir>
  cat > "$1/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
running() { [ "$(cat "$D/herdr-server")" = running ]; }
case "${1:-} ${2:-}" in
  "status --json")
    if running; then r=true; else r=false; fi
    printf '{"client":{"version":"0.9.5","protocol":22},"server":{"running":%s}}\n' "$r" ;;
  "server --session")
    echo start >> "$D/herdr-starts"
    [ ! -e "$D/herdr-can-start" ] || printf 'running' > "$D/herdr-server" ;;
  "pane get"|"agent get")
    if ! running; then
      printf '{"error":{"code":"server_not_running","message":"server not running"}}\n'
      exit 1
    fi
    left=$(cat "$D/herdr-settle")
    if [ "$left" -gt 0 ]; then
      printf '%s' "$((left - 1))" > "$D/herdr-settle"
      printf '{"error":{"code":"session_restoring","message":"restoring"}}\n'
      exit 1
    fi
    if [ "$1" = pane ]; then
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}"
    fi ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/herdr"
}

# After a reboot the Herdr server is stopped, so a herdr endpoint reads
# unreadable; revive starts that server and waits out the restore before it
# classifies the pane. The instructions are removed, so revive stops at the
# first step after that classification and its refusal names them, which only
# a pane that read agent-free can reach. A server that cannot start refuses
# before anything else and names the server.
test_herdr_revive_starts_the_server_its_endpoint_needs() {
  local dir out rc
  dir=$(new_case herdr-revive)
  add_task "$dir" t1 claude ship herdr "default:w1:p2"
  printf '%s\n' "herdr_session=default" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" \
    >> "$dir/home/state/t1.meta"
  rm -f "$dir/home/data/t1/brief.md"
  make_herdr_restore_stub "$dir"
  printf 'stopped' > "$dir/fake/herdr-server"
  printf '0' > "$dir/fake/herdr-settle"

  out=$(FM_CONTROL_HERDR_RESTORE_WAIT=1 run_control "$dir" t1 revive); rc=$?
  expect_code 1 "$rc" "revive with a Herdr server that cannot start should refuse"$'\n'"$out"
  assert_contains "$out" "could not start the Herdr server that task t1's endpoint default:w1:p2 lives in" \
    "the refusal should name the server it could not start"
  [ -s "$dir/fake/herdr-starts" ] || fail "revive should have asked Herdr to start the server"

  : > "$dir/fake/herdr-starts"
  touch "$dir/fake/herdr-can-start"
  printf '3' > "$dir/fake/herdr-settle"
  out=$(FM_CONTROL_HERDR_RESTORE_WAIT=5 run_control "$dir" t1 revive); rc=$?
  expect_code 1 "$rc" "revive should stop at the missing instructions"$'\n'"$out"
  assert_contains "$out" "task t1 has no instructions" \
    "revive should classify the restored pane as agent-free once the server runs"$'\n'"$out"
  assert_not_contains "$out" "unreadable" "revive must not refuse the endpoint as unreadable once it started the server"
  [ "$(cat "$dir/fake/herdr-server")" = running ] || fail "revive should leave the Herdr server running"
  [ "$(wc -l < "$dir/fake/herdr-starts" | tr -d ' ')" = 1 ] || fail "revive should start the server exactly once"
  [ "$(cat "$dir/fake/herdr-settle")" = 0 ] \
    || fail "divergence lost: the restore must have read unreadable before it settled"

  : > "$dir/fake/herdr-starts"
  out=$(FM_CONTROL_HERDR_RESTORE_WAIT=1 run_control "$dir" t1 revive); rc=$?
  assert_contains "$out" "task t1 has no instructions" "revive into a running server should classify the pane directly"
  [ ! -s "$dir/fake/herdr-starts" ] || fail "revive must not start a server that is already running"
  pass "fm-control revive (herdr): starts the stopped server its endpoint lives in and waits for the restored pane"
}

test_grok_interrupt_without_acknowledgement_reports_unconfirmed() {
  local dir out rc
  dir=$(new_case nosettle)
  add_task "$dir" t1 grok
  alive_as "$dir" grok
  printf '╭────╮\n│    │\n╰────╯\n Ctrl+c:cancel\n' > "$dir/fake/pane"
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "grok interrupt delivery should not depend on inferred cancellation"$'\n'"$out"
  assert_contains "$out" "verified=agent-alive cancel=unconfirmed" \
    "a rendered busy hint is not a cancellation acknowledgement"
  pass "fm-control interrupt: grok reports delivery without claiming cancellation"
}

test_grok_idle_footer_does_not_confirm_cancellation() {
  local dir out rc
  dir=$(new_case settles)
  add_task "$dir" t1 grok
  alive_as "$dir" grok
  printf '╭────╮\n│    │\n╰────╯\n Shift+Tab:mode │ Ctrl+.:shortcuts\n' > "$dir/fake/pane"
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "grok interrupt delivery should succeed"$'\n'"$out"
  assert_contains "$out" "verified=agent-alive cancel=unconfirmed" \
    "an idle footer is not an explicit cancellation acknowledgement"
  [ "$(keys_sent "$dir")" = "C-c" ] || fail "grok should receive C-c, got: $(keys_sent "$dir")"
  pass "fm-control interrupt: grok's idle footer does not confirm cancellation"
}

# --- 6. marker non-regression -----------------------------------------------

test_secondmate_control_command_carries_no_marker() {
  local dir out rc typed home
  dir=$(new_case sm-marker)
  home="$dir/home"
  add_task "$dir" domain claude secondmate
  # A secondmate's worktree IS its home; give it the marker its records need.
  printf '%s\n' domain > "$dir/wt-domain/.fm-secondmate-home"
  alive_as "$dir" claude
  out=$(run_control "$dir" domain exit); rc=$?
  expect_code 0 "$rc" "exiting a secondmate's agent should succeed"$'\n'"$out"
  typed=$(literals "$dir")
  [ "$typed" = "/exit" ] \
    || fail "a secondmate control command must be the bare exit command, got: $typed"
  case "$typed" in
    *"$FM_FROMFIRST_MARK"*) fail "a control command must never carry the from-firstmate marker" ;;
  esac
  case "$typed" in
    *corr=*) fail "a control command must never carry a pending-reply correlation id" ;;
  esac
  [ -z "$(find "$home/state/pending-replies" -type f 2>/dev/null | head -n 1)" ] \
    || fail "a control command must not open a pending-reply expectation"
  pass "fm-control: a lifecycle command to a secondmate is unmarked and opens no reply expectation"
}

test_fm_send_still_marks_the_same_secondmate_task() {
  local dir log out rc
  dir=$(new_case sm-send)
  add_task "$dir" domain claude secondmate
  alive_as "$dir" claude
  log="$dir/fake/sendlog"
  : > "$log"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SEND_SETTLE=0 FM_ROOT_OVERRIDE="$dir/home" \
    "$SEND" domain "audit the build" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-send to a secondmate should still succeed"$'\n'"$out"
  case "$(literals "$dir")" in
    "$FM_FROMFIRST_MARK"*) : ;;
    *) fail "fm-send must still mark a kind=secondmate target: $(literals "$dir")" ;;
  esac
  pass "fm-control's arrival leaves fm-send's from-firstmate marking untouched"
}

test_exit_types_each_harness_verified_command
test_interrupt_sends_each_harness_verified_key
test_opencode_interrupts_twice_and_others_once
test_unverified_harness_is_refused
test_harness_family_resolution
test_prefixed_recorded_harness_reaches_each_control_verb
test_backend_key_capability_matrix
test_harness_kind_capability
test_orca_refuses_an_escape_harness_interrupt
test_unverified_state_backends_refuse_stop_verbs
test_state_verified_backends_are_exactly_tmux_and_herdr
test_window_label_is_refused_with_the_exact_id
test_explicit_endpoint_is_refused
test_unknown_task_is_refused
test_record_bound_to_another_task_is_refused
test_remote_secondmate_is_refused_by_placement
test_interrupt_and_exit_lock_before_task_state_resolution
test_verb_allowlist_is_closed
test_resume_is_refused_with_its_reason
test_relaunch_only_flags_are_rejected_on_other_verbs
test_already_stopped_exit_is_idempotent
test_missing_endpoint_refuses
test_interrupt_refuses_when_no_agent_runs
test_ambiguous_endpoint_refuses
test_busy_agent_is_interrupted_before_the_exit_command
test_idle_agent_is_not_interrupted
test_interrupt_without_acknowledgement_preserves_busy_state
test_muse_interrupt_confirms_adapter_acknowledgement
test_interrupt_revalidates_agent_after_acknowledgement_wait
test_exit_accepts_agent_stopped_by_busy_interrupt
test_agent_that_does_not_stop_fails_closed
test_herdr_exit_refuses_a_composer_holding_unsent_text
test_herdr_revive_starts_the_server_its_endpoint_needs
test_grok_interrupt_without_acknowledgement_reports_unconfirmed
test_grok_idle_footer_does_not_confirm_cancellation
test_secondmate_control_command_carries_no_marker
test_fm_send_still_marks_the_same_secondmate_task
