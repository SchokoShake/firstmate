#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh --retire-record and for ordinary teardown's
# refusal of a record whose treehouse slot the pool has re-leased.
#
# Every case drives the real script against a fixture home, a fixture treehouse
# pool state file, and logging fakes for tmux and treehouse, so any touch of the
# working copy, the pool, or an endpoint is observable. The ownership verdict
# itself is owned by bin/fm-slot-lib.sh; these cases pin it through the
# executable: a later fresh claimant or a durable lease held by someone else
# proves a re-lease, this record's own lease proves ownership, and everything
# else stays unproven.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-retire-record)
REAL_TMUX=$(command -v tmux || true)
REAL_SLEEP=$(command -v sleep || true)
# The generations of the live evidence this feature was built for: an older
# finished record and the later spawn the pool handed the same slot to.
OLD_GEN=s1788765996.150863.30112
NEW_GEN=s1789026483.244338.3761

# make_case <name> -> a case dir holding home/{state,data,config}, logging fakes,
# and a treehouse pool whose slot 1 is the working copy the records share.
make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" \
    "$dir/pool/1/repo" "$dir/project"
  printf 'the current holder is mid-edit\n' > "$dir/pool/1/repo/sentinel"
  : > "$dir/runtime.log"
  : > "$dir/pool/treehouse-state.lock"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in
  list-windows) printf '%s\n' unrelated-window ;;
esac
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  fm_fake_exit0 "$dir/fakebin" no-mistakes
  printf '%s\n' "$dir"
}

# write_pool <case> [extra-json-fields]: the pool's record for slot 1.
write_pool() {
  printf '{"worktrees":[{"name":"1","path":"%s","created_at":"2026-07-02T11:44:26Z"%s}]}\n' \
    "$1/pool/1/repo" "${2:-}" > "$1/pool/treehouse-state.json"
}

# write_record <case> <id> <kind> <spawn-gen> [key=value...]: a tmux-backed
# record naming slot 1 as its working copy. RECORD_TASKTMP overrides its temp
# root, which otherwise names a path that never exists.
write_record() {
  local dir=$1 id=$2 kind=$3 gen=$4
  shift 4
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/repo" "project=$dir/project" \
    "harness=claude" "kind=$kind" "tasktmp=${RECORD_TASKTMP:-$dir/tasktmp-$id}" \
    "spawn_gen=$gen" "$@"
}

# populate_task_state <case> <id>: every kind of per-task state record a
# finished task leaves behind, including the watcher's own markers.
populate_task_state() {
  local state="$1/home/state" id=$2 marker gen
  printf 'done: PR merged\n' > "$state/$id.status"
  : > "$state/$id.turn-ended"
  printf 'version=4\noffset=0\nident=1:1\n' > "$state/.$id.open-decisions-cursor"
  for marker in hash count stale paused paused-rechecked paused-resurfaced; do
    printf 'x\n' > "$state/.$marker-firstmate_fm-$id"
  done
  printf 'x\n' > "$state/.seen-${id}_status"
  printf 'x\n' > "$state/.seen-${id}_turn-ended"
  printf 'x\n' > "$state/.hb-surfaced-$id"
  printf 'x\n' > "$state/.subsuper-paused-$id"
  mkdir -p "$state/.pr-check-quarantine"
  chmod 700 "$state/.pr-check-quarantine"
  (umask 077 && printf 'neutralized\n' > "$state/.pr-check-quarantine/$id.diagnostic.ambiguous")
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm fixture busy state for $id"
  printf 'busy_gen=%s\n' "$gen" >> "$state/$id.meta"
}

# task_paths <case> <id>: the per-task paths populate_task_state writes.
task_paths() {
  local state="$1/home/state" id=$2 marker
  printf '%s\n' "$state/$id.meta" "$state/$id.status" "$state/$id.turn-ended" \
    "$state/.$id.open-decisions-cursor" "$state/.seen-${id}_status" \
    "$state/.seen-${id}_turn-ended" "$state/.hb-surfaced-$id" \
    "$state/.subsuper-paused-$id" "$state/.pr-check-quarantine/$id.diagnostic.ambiguous" \
    "$state/$id.busy-gen" "$state/$id.busy-state"
  for marker in hash count stale paused paused-rechecked paused-resurfaced; do
    printf '%s\n' "$state/.$marker-firstmate_fm-$id"
  done
}

write_presentation_rows() {  # <case> <id>...
  local manifest="$1/home/state/.status-presentation-cursor" id n=0
  shift
  : > "$manifest"
  for id in "$@"; do
    n=$((n + 1))
    printf '%s\t1:%s\t0\n' "$id" "$n" >> "$manifest"
  done
}

# The live shape: an older finished record and a later spawn on one slot whose
# process-bound owner reservation has since died.
make_superseded_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  write_pool "$dir" ',"owner_pid":999999,"owner_started_at":1789026475860'
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "pr=https://github.com/example/repo/pull/829"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off"
  populate_task_state "$dir" old-r1
  populate_task_state "$dir" new-r1
  write_presentation_rows "$dir" old-r1 new-r1
  printf '%s\n' "$dir"
}

run_teardown() {  # <case> <id> [args...]
  local dir=$1 id=$2
  shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

assert_copy_and_pool_untouched() {  # <case> <pool-cksum> <label>
  local dir=$1 before=$2 label=$3
  assert_grep 'the current holder is mid-edit' "$dir/pool/1/repo/sentinel" \
    "$label: the shared working copy changed"
  [ "$(cksum < "$dir/pool/treehouse-state.json")" = "$before" ] \
    || fail "$label: the pool record changed"
  assert_no_grep 'treehouse' "$dir/runtime.log" "$label: treehouse was invoked"
  assert_no_grep 'kill-window' "$dir/runtime.log" "$label: an endpoint was closed"
}

test_retire_drops_only_a_superseded_record() {
  local dir before rc out path
  dir=$(make_superseded_case superseded)
  before=$(cksum < "$dir/pool/treehouse-state.json")

  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "retiring a superseded record"$'\n'"$out"
  while IFS= read -r path; do
    assert_absent "$path" "retire left $path behind"
  done <<EOF
$(task_paths "$dir" old-r1)
EOF
  while IFS= read -r path; do
    case "$path" in */.pr-check-quarantine/*) continue ;; esac
    assert_present "$path" "retire removed the current holder's $path"
  done <<EOF
$(task_paths "$dir" new-r1)
EOF
  assert_present "$dir/home/state/.pr-check-quarantine/new-r1.diagnostic.ambiguous" \
    "retire removed the current holder's quarantine entry"
  assert_no_grep "old-r1"$'\t' "$dir/home/state/.status-presentation-cursor" \
    "retire kept the retired record's presentation row"
  assert_grep "new-r1"$'\t' "$dir/home/state/.status-presentation-cursor" \
    "retire dropped the current holder's presentation row"
  assert_copy_and_pool_untouched "$dir" "$before" "retire"
  assert_contains "$out" "task new-r1 names the same working copy" \
    "retire did not name the evidence that the slot was re-leased"
  assert_contains "$out" "retire-record: removed $dir/home/state/old-r1.meta" \
    "retire did not report the records it removed"
  pass "fm-teardown --retire-record: drops every state record of a superseded task and nothing of the current holder's, the working copy, or the pool"
}

test_retire_dry_run_changes_nothing() {
  local dir before rc out path
  dir=$(make_superseded_case dry-run)
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record --dry-run 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a dry run of a retirable record"$'\n'"$out"
  while IFS= read -r path; do
    assert_present "$path" "the dry run removed $path"
  done <<EOF
$(task_paths "$dir" old-r1)
EOF
  assert_contains "$out" "dry run: would remove $dir/home/state/old-r1.meta" \
    "the dry run did not list the records it would remove"
  assert_contains "$out" "task new-r1 names the same working copy" \
    "the dry run did not print the verdict's evidence"
  assert_copy_and_pool_untouched "$dir" "$before" "dry run"
  pass "fm-teardown --retire-record --dry-run: prints the verdict and the records it would drop, and changes nothing"
}

assert_refused_without_mutation() {  # <case> <id> <expected-text> <label> [args...]
  local dir=$1 id=$2 expected=$3 label=$4 rc out before
  shift 4
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" "$id" "$@" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "$label"$'\n'"$out"
  assert_contains "$out" "$expected" "$label: wrong refusal"
  assert_present "$dir/home/state/$id.meta" "$label: the refused record was removed"
  assert_copy_and_pool_untouched "$dir" "$before" "$label"
  REFUSAL_OUTPUT=$out
}

test_retire_refuses_a_record_that_owns_its_lease() {
  local dir label=fm-task:own-r1:l1789000000.4242.17
  dir=$(make_case own-lease)
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$label\""
  write_record "$dir" own-r1 ship s1789000003.4242.18 "mode=direct-PR" "yolo=off" "lease_holder=$label"
  write_record "$dir" older-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  assert_refused_without_mutation "$dir" own-r1 "still owns its working copy" \
    "a record holding its own lease" --retire-record
  assert_contains "$REFUSAL_OUTPUT" "bin/fm-teardown.sh own-r1" \
    "the refusal did not name ordinary teardown"

  # The durable lease is authoritative in the other direction too: the older
  # record's slot is leased to someone else, so it is retirable.
  set +e
  run_teardown "$dir" older-r1 --retire-record --dry-run > "$dir/older.out" 2>&1
  expect_code 0 "$?" "a record whose slot is leased to another record"$'\n'"$(cat "$dir/older.out")"
  set -e
  assert_grep "task own-r1" "$dir/older.out" "the lease holder's task was not named"
  pass "fm-teardown --retire-record: refuses a record the pool still leases to it, and the lease proves the older claimant re-leased"
}

test_retire_refuses_an_unproven_re_lease() {
  local dir
  dir=$(make_case unproven)
  write_pool "$dir" ',"owner_pid":999999,"owner_started_at":1789026475860'
  write_record "$dir" alone-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  assert_refused_without_mutation "$dir" alone-r1 "cannot prove alone-r1's working copy" \
    "a record with no later claimant and no foreign lease" --retire-record

  # An unreadable pool record is no evidence at all, never a verdict.
  printf '{"worktrees": [truncated' > "$dir/pool/treehouse-state.json"
  assert_refused_without_mutation "$dir" alone-r1 "cannot prove alone-r1's working copy" \
    "a record whose pool state cannot be read" --retire-record

  # The newest record on a shared slot is the current holder, not a superseded one.
  dir=$(make_superseded_case newest)
  assert_refused_without_mutation "$dir" new-r1 "cannot prove new-r1's working copy" \
    "the newest of two claimants" --retire-record
  pass "fm-teardown --retire-record: refuses when no durable lease or later fresh claimant proves the slot was re-leased"
}

test_retire_refuses_when_the_later_claimant_was_relaunched() {
  local dir
  dir=$(make_case relaunched)
  write_pool "$dir" ''
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  # A relaunch mints a new generation without acquiring anything, so its
  # generation cannot say when that claimant took the slot.
  write_record "$dir" relaunched-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" \
    "control_relaunch_tx=2895592.20260831T141214Z.29720"
  assert_refused_without_mutation "$dir" old-r1 "cannot prove old-r1's working copy" \
    "a later claimant whose generation came from a relaunch" --retire-record
  pass "fm-teardown --retire-record: a relaunched claimant's generation is not evidence of a re-lease"
}

test_retire_follows_a_foreign_lease() {
  local dir before rc out
  dir=$(make_case foreign-lease)
  write_pool "$dir" ',"leased":true,"lease_holder":"boards-b1"'
  write_record "$dir" legacy-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  fm_write_secondmate_meta "$dir/home/state/boards-b1.meta" "$dir/pool/1/repo"
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" legacy-r1 --retire-record 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a record whose slot the pool now leases to a secondmate home"$'\n'"$out"
  assert_contains "$out" "leases $dir/pool/1/repo to boards-b1 (task boards-b1)" \
    "the foreign lease holder was not named"
  assert_absent "$dir/home/state/legacy-r1.meta" "the superseded record survived"
  assert_present "$dir/home/state/boards-b1.meta" "the lease holder's record was touched"
  assert_copy_and_pool_untouched "$dir" "$before" "foreign-lease retire"
  pass "fm-teardown --retire-record: a durable lease held by anyone else proves a record that never held one was re-leased"
}

test_retire_refuses_an_armed_pr_merge_poll() {
  local dir artifact
  dir=$(make_superseded_case armed-pr-poll)
  for artifact in check.sh pr-poll pr-poll-registration check-trust; do
    (umask 077 && printf 'armed\n' > "$dir/home/state/old-r1.$artifact")
  done
  assert_refused_without_mutation "$dir" old-r1 "still has an armed PR merge poll" \
    "an armed PR merge poll" --retire-record
  assert_contains "$REFUSAL_OUTPUT" "https://github.com/example/repo/pull/829" \
    "the refusal did not name the watched PR"
  for artifact in check.sh pr-poll pr-poll-registration check-trust; do
    assert_present "$dir/home/state/old-r1.$artifact" "the refusal removed the poll's $artifact"
  done

  rm -f "$dir/home/state/old-r1.pr-poll" "$dir/home/state/old-r1.pr-poll-registration"
  assert_refused_without_mutation "$dir" old-r1 "registered watcher check" \
    "an armed custom check" --retire-record
  pass "fm-teardown --retire-record: refuses while a PR merge poll or registered watcher check is armed for the task"
}

test_retire_refuses_a_live_agent() {
  local dir socket
  [ -n "$REAL_TMUX" ] && [ -n "$REAL_SLEEP" ] || { echo "skip - tmux or sleep not installed"; return 0; }
  dir=$(make_superseded_case live-agent)
  socket="$dir/tmux.sock"
  # A real pane whose foreground process carries a harness name as its argv[0],
  # so the recovery-grade agent-state classifier sees a live agent on the
  # endpoint. A renamed copy of sleep would not do: a multi-call coreutils build
  # refuses to run under an unknown program name. The trailing no-op keeps bash
  # from exec'ing sleep in its own place.
  cat > "$dir/agent.sh" <<'SH'
#!/usr/bin/env bash
exec -a claude bash -c 'sleep 60; :'
SH
  chmod +x "$dir/agent.sh"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s firstmate -n fm-old-r1 "$dir/agent.sh"
  sleep 0.5
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exec env -u TMUX -u TMUX_PANE '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  assert_refused_without_mutation "$dir" old-r1 "still holds a live agent" \
    "an endpoint running a live agent" --retire-record
  assert_contains "$REFUSAL_OUTPUT" "bin/fm-control.sh old-r1 exit" \
    "the refusal did not name the supported way to stop the worker"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" has-session -t firstmate 2>/dev/null \
    || fail "the refusal disturbed the live endpoint"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null || true
  pass "fm-teardown --retire-record: refuses while the record's own endpoint still runs a live agent"
}

test_retire_refuses_secondmate_and_orca_records() {
  local dir
  dir=$(make_case other-kinds)
  write_pool "$dir" ''
  fm_write_secondmate_meta "$dir/home/state/sm-r1.meta" "$dir/pool/1/repo"
  assert_refused_without_mutation "$dir" sm-r1 "is a secondmate home" \
    "a secondmate record" --retire-record
  fm_write_meta "$dir/home/state/orca-r1.meta" \
    "window=fm-orca-r1" "endpoint_task_id=orca-r1" "terminal=term-7" \
    "worktree=$dir/pool/1/repo" "project=$dir/project" "backend=orca" \
    "orca_worktree_id=worktree-9" "kind=ship" "spawn_gen=$OLD_GEN"
  assert_refused_without_mutation "$dir" orca-r1 "Orca worktree" \
    "an Orca record" --retire-record
  pass "fm-teardown --retire-record: refuses secondmate homes and Orca worktrees, which are never pool slots it can prove re-leased"
}

test_retire_rejects_malformed_requests() {
  local dir rc args
  dir=$(make_superseded_case bad-options)
  for args in "--retire-record --force" "--dry-run" "--force --dry-run" "--retire-record --bogus" "--bogus"; do
    set +e
    # shellcheck disable=SC2086 # each case is a deliberate word list
    run_teardown "$dir" old-r1 $args > "$dir/bad.out" 2>&1
    rc=$?
    set -e
    expect_code 2 "$rc" "teardown old-r1 $args"
  done
  assert_present "$dir/home/state/old-r1.meta" "a malformed request changed state"
  [ ! -s "$dir/runtime.log" ] || fail "a malformed request reached the runtime: $(cat "$dir/runtime.log")"
  pass "fm-teardown: rejects unknown or conflicting options before touching anything"
}

test_ordinary_teardown_refuses_a_re_leased_slot() {
  local dir mode
  for mode in plain force; do
    dir=$(make_superseded_case "ordinary-$mode")
    if [ "$mode" = force ]; then
      assert_refused_without_mutation "$dir" old-r1 "is no longer its own" \
        "ordinary teardown --force of a re-leased record" --force
    else
      assert_refused_without_mutation "$dir" old-r1 "is no longer its own" \
        "ordinary teardown of a re-leased record"
    fi
    assert_contains "$REFUSAL_OUTPUT" "bin/fm-teardown.sh old-r1 --retire-record" \
      "the $mode refusal did not name the record-only path"
    [ ! -s "$dir/runtime.log" ] \
      || fail "the $mode refusal reached the runtime: $(cat "$dir/runtime.log")"
    assert_present "$dir/home/state/.hash-firstmate_fm-old-r1" "the $mode refusal removed watcher state"
  done
  pass "fm-teardown: refuses, with or without --force, to tear down a record whose working copy was re-leased"
}

test_ordinary_teardown_lets_the_current_holder_through() {
  local dir rc out marker
  dir=$(make_case current-holder)
  write_pool "$dir" ',"owner_pid":999999,"owner_started_at":1789026475860'
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  write_record "$dir" new-r1 scout "$NEW_GEN"
  populate_task_state "$dir" new-r1
  write_presentation_rows "$dir" old-r1 new-r1
  set +e
  out=$(run_teardown "$dir" new-r1 --force 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "tearing down the newest claimant"$'\n'"$out"
  assert_grep "treehouse <return> <--force> <$dir/pool/1/repo>" "$dir/runtime.log" \
    "the current holder's teardown did not return its slot"
  assert_grep "kill-window" "$dir/runtime.log" "the current holder's endpoint was not closed"
  assert_present "$dir/home/state/old-r1.meta" "tearing down the current holder touched the older record"
  # Ordinary teardown drops the same per-task state set --retire-record does,
  # the watcher's own markers included.
  for marker in hash count stale paused paused-rechecked paused-resurfaced; do
    assert_absent "$dir/home/state/.$marker-firstmate_fm-new-r1" "teardown left the watcher's .$marker marker"
  done
  assert_absent "$dir/home/state/.seen-new-r1_status" "teardown left the signal seen-marker"
  assert_absent "$dir/home/state/.hb-surfaced-new-r1" "teardown left the heartbeat marker"
  assert_absent "$dir/home/state/.subsuper-paused-new-r1" "teardown left the away-mode pause marker"
  pass "fm-teardown: the newest claimant of a shared slot tears down normally and drops every per-task record, watcher markers included"
}

test_retire_removes_an_idle_task_temp_root() {
  local dir id tmpdir rc out
  id="retire-tmp-$$"
  tmpdir="/tmp/fm-$id"
  dir=$(make_case idle-tasktmp)
  write_pool "$dir" ''
  RECORD_TASKTMP=$tmpdir write_record "$dir" "$id" ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  write_record "$dir" newer-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off"
  mkdir -p "$tmpdir/gotmp"
  set +e
  out=$(run_teardown "$dir" "$id" --retire-record 2>&1)
  rc=$?
  set -e
  if [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
    command -v lsof >/dev/null 2>&1 || { echo "skip - lsof not installed, so the idle temp root is left by design"; return 0; }
    fail "retire left an idle task temp root behind"$'\n'"$out"
  fi
  expect_code 0 "$rc" "retiring a record with an idle temp root"$'\n'"$out"
  assert_contains "$out" "retire-record: removed $tmpdir" "retire did not report the temp root it removed"
  pass "fm-teardown --retire-record: removes the task's own idle /tmp/fm-<id> root"
}

test_retire_drops_only_a_superseded_record
test_retire_dry_run_changes_nothing
test_retire_refuses_a_record_that_owns_its_lease
test_retire_refuses_an_unproven_re_lease
test_retire_refuses_when_the_later_claimant_was_relaunched
test_retire_follows_a_foreign_lease
test_retire_refuses_an_armed_pr_merge_poll
test_retire_refuses_a_live_agent
test_retire_refuses_secondmate_and_orca_records
test_retire_rejects_malformed_requests
test_ordinary_teardown_refuses_a_re_leased_slot
test_ordinary_teardown_lets_the_current_holder_through
test_retire_removes_an_idle_task_temp_root

echo "# all fm-teardown-retire-record tests passed"
