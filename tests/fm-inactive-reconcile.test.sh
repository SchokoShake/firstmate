#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
REAL_CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
fm_git_identity fmtest fmtest@example.invalid

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$route" = local ]; then
    cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  else
    cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  fi
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

write_mate_meta() {
  fm_write_secondmate_meta "$MAIN/state/mate.meta" "$MATE"
  printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
  age "$MAIN/state/mate.meta" "$MAIN/state/mate.status"
}

# CREW_STATE_BIN selects the current-state reader; the canned fake by default.
run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="${CREW_STATE_BIN:-$WORLD/fakebin/fm-crew-state.sh}" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

# For cases read by the real fm-crew-state.sh: turns <home>'s recorded worktree
# for <id> into a git repository on <branch>, installs a fake no-mistakes that
# prints FM_FAKE_AXI_STATUS for `axi status` and FM_FAKE_RUNS_LIST for the plain
# `runs` listing, and echoes the worktree HEAD.
real_state_worktree() { # <home> <id> <branch>
  local wt="$1/projects/$2"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "$3"
  cat > "$WORLD/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status') printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  'runs '*) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
SH
  chmod +x "$WORLD/fakebin/no-mistakes"
  git -C "$wt" rev-parse HEAD
}

# A review fix the pipeline committed on top of <worktree>'s submission in a
# separate gate clone, so the worktree's object store never receives it.
pipeline_fix_head() { # <worktree>
  git clone -q "$1" "$1.gate"
  git -C "$1.gate" commit -q --allow-empty -m 'no-mistakes(review): apply review fix'
  git -C "$1.gate" rev-parse HEAD
}

axi_status_failed() { # <branch> <run-id> <head>
  cat <<EOF
run:
  id: "$2"
  branch: $1
  status: failed
  head: ${3:0:8}
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,failed,0,1200
outcome: failed
error: "step review failed: agent review: exit status 1"
EOF
}

# A run parked at its review gate after the pipeline moved its head. With
# <submitted>, no-mistakes' push provenance for the run names that submission.
axi_status_parked() { # <branch> <run-id> <head> [<submitted>]
  cat <<EOF
run:
  id: "$2"
  branch: $1
  status: running
  awaiting_agent: parked 4m10s
  head: ${3:0:8}
  findings: 1 awaiting
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,awaiting_approval,1,812000
EOF
  [ -z "${4:-}" ] || cat <<EOF
branch_sync:
  state: pipeline_owned
  local:
    branch: $1
    head: $4
  pipeline:
    run: "$2"
    status: running
    submitted_head: $4
    current_head: $3
EOF
  cat <<'EOF'
gate:
  step: review
  status: awaiting_approval
  findings[1]{id,severity,file,action,description}:
    r1,warning,a.go,ask-user,changes product behavior
EOF
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

prime_seen() { # <state> <status>
  local state=$1 status=$2 sig
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$status"); else sig=$(stat -c '%s:%Y' "$status"); fi
  printf '%s' "$sig" > "$state/.seen-$(basename "$status" | tr '.' '_')"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# A secondmate independently reports a genuinely terminal inactive child.
test_local_secondmate_reports_terminal_child() {
  make_world local; bind_secondmate local; write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  grep -Fq 'done [key=inactive-outcome-mate-child-done]:' "$MAIN/state/mate.status" \
    || fail "secondmate did not append its durable parent report"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "secondmate report receipt was not durable"
  pass "secondmate reports its own inactive terminal child"
}

test_local_secondmate_rejects_relative_parent_home() {
  make_world relative-parent; bind_secondmate local
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=relative-parent\n' \
    > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  (cd "$WORLD" && FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
  [ ! -e "$WORLD/relative-parent/state/mate.status" ] \
    || fail "relative parent home received a false durable report"
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "relative parent route was recorded as reported"
  [ "$(outcome_count "$MATE" pending)" = 1 ] \
    || fail "failed relative parent route did not retain its pending receipt"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] \
    || fail "failed relative parent route did not surface a recovery notice"
  pass "relative local parent homes fail closed"
}

# A present invalid identity marker cannot turn a secondmate home into a main
# home. The original child state remains available after the routing alarm.
test_invalid_secondmate_marker_blocks_routing() {
  local kind out target
  for kind in malformed symlink; do
    make_world "invalid-marker-$kind"
    write_child "$MATE" child 'failed: terminal'
    if [ "$kind" = malformed ]; then
      printf '../main\n' > "$MATE/.fm-secondmate-home"
    else
      target="$WORLD/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$MATE/.fm-secondmate-home"
    fi

    out=$(FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
    printf '%s\n' "$out" | grep -Fq 'inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker' \
      || fail "$kind secondmate marker did not surface the blocked terminal obligation"
    [ "$(outcome_count "$MATE" pending)" = 0 ] \
      || fail "$kind secondmate marker created a main-home pending receipt"
    ! grep -Fq 'inactive-outcome:' "$MATE/state/.wake-queue" 2>/dev/null \
      || fail "$kind secondmate marker routed a captain presentation wake"
    [ -f "$MATE/state/child.meta" ] && [ -f "$MATE/state/child.status" ] \
      || fail "$kind secondmate marker lost the terminal obligation"
  done
  pass "invalid secondmate markers block routing and surface the obligation"
}

# A remote child route writes the existing mirror input once even across restarts.
test_remote_parent_reply_is_idempotent() {
  make_world remote; bind_secondmate remote; write_child "$MATE" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote parent reply was not restart-idempotent"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "remote parent report receipt missing"
  pass "remote parent-replies mirror input is durable and idempotent"
}

# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  rm -f "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  write_child "$MATE" child 'failed: terminal' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "reused task id collided with the retired incarnation receipt"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 2 ] \
    || fail "reused task id did not produce an independent parent report"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  meta="$MATE/state/child.meta"
  tmp="$MATE/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup

  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "legacy metadata rewrite duplicated the parent report"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MATE" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.reported' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

# The actual watcher poll invokes the helper, while an idle secondmate remains
# exempt from wedge escalation and emits no false wake.
test_watcher_hook_and_idle_secondmate_exemption() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"

  make_world idle-secondmate; bind_secondmate local; write_mate_meta; prime_seen "$MAIN/state" "$MAIN/state/mate.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WORLD/idle.out" 2>&1 &
  pid=$!; sleep 2; kill -0 "$pid" 2>/dev/null || fail "idle secondmate watcher exited unexpectedly"; reap "$pid"
  grep -F 'stale:' "$WORLD/idle.out" >/dev/null && fail "idle secondmate was treated as a wedge"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "idle secondmate emitted a false wake"
  pass "watcher hook wakes for terminal loss and preserves idle secondmate exemption"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  [ "$elapsed" -le 3 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

test_notice_recovery_does_not_duplicate_wake() {
  local record err seq generation
  make_world notice-recovery; bind_secondmate remote
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "parent-report failure did not queue one notice"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  awk '{ sub(/^notice_emitted=1$/, "notice_emitted=0"); print }' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "recovery duplicated an already queued notice"

  err="$WORLD/drain.err"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 0 ] || fail "acknowledged notice was emitted again"
  pass "notice recovery remains idempotent across queue acknowledgement"
}

# Regression through the real current-state reader: a resumed validation keeps
# an earlier failed run on its branch, whose head is still the worktree HEAD,
# beside the live run parked at its review gate after the pipeline moved its
# head. The live run is the task's state, so no terminal outcome is raised - and
# none either when the newest run cannot be bound to the current head at all.
# The same wiring does raise one when the newest run failed on the current head.
test_real_state_resumed_validation_raises_no_terminal_outcome() {
  local head pipe listing
  make_world real-state-failed; write_child "$MAIN" child 'failed: validation run failed at review'
  head=$(real_state_worktree "$MAIN" child fm/child)
  FM_FAKE_AXI_STATUS=$(axi_status_failed fm/child 01EARLIER "$head") \
    CREW_STATE_BIN="$REAL_CREW_STATE" run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "a newest run that failed on the current head raised no terminal outcome"
  grep -Fq 'child=child state=failed' "$MAIN/state/.wake-queue" \
    || fail "a newest run that failed on the current head queued no presentation"

  make_world real-state-resumed
  write_child "$MAIN" child 'needs-decision [key=r1]: review gate finding r1 needs a decision'
  head=$(real_state_worktree "$MAIN" child fm/child)
  pipe=$(pipeline_fix_head "$MAIN/projects/child")
  listing=$(printf '  running      fm/child %s  2026-09-02 19:13\n  failed       fm/child %s  2026-09-02 16:05\n' \
    "${pipe:0:8}" "${head:0:8}")
  FM_FAKE_AXI_STATUS=$(axi_status_parked fm/child 01LIVE "$pipe" "$head") FM_FAKE_RUNS_LIST=$listing \
    CREW_STATE_BIN="$REAL_CREW_STATE" run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] \
    || fail "the earlier failed run raised a terminal outcome while the live run was parked"
  ! grep -Fq 'inactive-outcome:' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail "the earlier failed run queued a terminal presentation while the live run was parked"

  make_world real-state-unbound; write_child "$MAIN" child 'working: rerunning validation'
  head=$(real_state_worktree "$MAIN" child fm/child)
  pipe=$(pipeline_fix_head "$MAIN/projects/child")
  listing=$(printf '  running      fm/child %s  2026-09-02 19:13\n  failed       fm/child %s  2026-09-02 16:05\n' \
    "${pipe:0:8}" "${head:0:8}")
  FM_FAKE_AXI_STATUS=$(axi_status_parked fm/child 01LIVE "$pipe") FM_FAKE_RUNS_LIST=$listing \
    CREW_STATE_BIN="$REAL_CREW_STATE" run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] \
    || fail "an older failed run raised a terminal outcome for a newest run not matching the current head"
  pass "a resumed validation raises no terminal outcome from its earlier run"
}

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_main_direct_terminal_presentation_receipt
test_local_secondmate_reports_terminal_child
test_local_secondmate_rejects_relative_parent_home
test_invalid_secondmate_marker_blocks_routing
test_remote_parent_reply_is_idempotent
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_watcher_hook_and_idle_secondmate_exemption
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_real_state_resumed_validation_raises_no_terminal_outcome
test_reconciliation_never_calls_forge

echo "all inactive reconciliation tests passed"
