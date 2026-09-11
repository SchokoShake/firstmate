#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh --retire-record, its --unproven-confirmed
# acknowledgement, and ordinary teardown's refusals of a record whose treehouse
# slot the pool has re-leased or whose working copy another record also stands on.
#
# Every case drives the real script against a fixture home, a fixture treehouse
# pool state file, and logging fakes for tmux and treehouse, so any touch of the
# working copy, the pool, or an endpoint is observable. The ownership verdict
# itself is owned by bin/fm-slot-lib.sh; these cases pin it through the
# executable: the pool's durable lease on the recorded path, matched against
# this record's own recorded claim and the claims other records in the home
# carry, is the only evidence, and a record that carries no claim stays
# unproven whatever else is true of its slot. Such a record goes only on a
# person's explicit --unproven-confirmed, and ordinary teardown refuses it once
# any other record stands on its copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-retire-record)
REAL_TMUX=$(command -v tmux || true)
REAL_SLEEP=$(command -v sleep || true)
# The generations of the live evidence this feature was built for: an older
# finished record and the later spawn the pool handed the same slot to.
OLD_GEN=s1788765996.150863.30112
NEW_GEN=s1789026483.244338.3761
# The lease claims those records carry once spawned under durable leases.
OLD_CLAIM=fm-task:old-r1:l1788765990.150863.30112
NEW_CLAIM=fm-task:new-r1:l1789026480.244338.3761

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
# record naming slot 1 as its working copy. RECORD_WORKTREE overrides that
# copy; RECORD_TASKTMP overrides its temp root, which otherwise names a path
# that never exists.
write_record() {
  local dir=$1 id=$2 kind=$3 gen=$4
  shift 4
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=${RECORD_WORKTREE:-$dir/pool/1/repo}" "project=$dir/project" \
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

# arm_pr_poll <case> <id> <url>: the canonical PR merge poll fm-pr-check arms
# for <id>, built through the PR library so its trust binding is genuine.
arm_pr_poll() {
  local state="$1/home/state" id=$2 url=$3
  (
    fm_pr_url_parse "$url" || exit 1
    fm_pr_poll_prepare "$state" "$id" "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" "$FM_PR_PATH" \
      "$FM_PR_NUMBER" "$ROOT/bin/fm-pr-poll.sh" || exit 1
    fm_pr_poll_publish_prepared
  ) || fail "could not arm the fixture PR poll for $id"
}

# arm_pending_receipt <case> <id> <url>: that poll plus the validated
# merged-result retirement receipt the watcher publishes, still pending, as an
# interrupted retirement leaves it.
arm_pending_receipt() {
  local state="$1/home/state" id=$2 url=$3
  arm_pr_poll "$1" "$id" "$url"
  (
    fm_pr_poll_snapshot_capture "$state" "$id" "$ROOT/bin/fm-pr-poll.sh" || exit 1
    fm_pr_poll_retirement_publish "$state" "$id" "$ROOT/bin/fm-pr-poll.sh" merged
  ) || fail "could not publish the fixture retirement receipt for $id"
}

# make_receipt_case <name> <url> -> a superseded case whose retired record has
# its PR poll armed and its merged-result receipt pending; the PR line is the
# record's last, as the PR library requires.
make_receipt_case() {
  local dir
  dir=$(make_case "$1")
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$NEW_CLAIM\""
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$OLD_CLAIM"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$NEW_CLAIM"
  populate_task_state "$dir" old-r1
  printf 'pr=%s\n' "$2" >> "$dir/home/state/old-r1.meta"
  printf '%s\n' "$dir"
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

# The re-leased shape: an older record whose claim the pool no longer holds,
# because the pool now leases the same slot to a later record's claim.
make_superseded_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$NEW_CLAIM\""
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "lease_holder=$OLD_CLAIM" "pr=https://github.com/example/repo/pull/829"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$NEW_CLAIM"
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
  assert_contains "$out" "task new-r1's own recorded claim on that same working copy" \
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
  assert_contains "$out" "task new-r1's own recorded claim on that same working copy" \
    "the dry run did not print the verdict's evidence"
  assert_copy_and_pool_untouched "$dir" "$before" "dry run"
  pass "fm-teardown --retire-record --dry-run: prints the verdict and the records it would drop, and changes nothing"
}

test_retire_dry_run_refuses_exactly_where_a_real_run_would() {
  local dir url=https://github.com/example/repo/pull/829 artifact before rc out

  # Completing a validated merged-result receipt removes the poll but not a
  # trust record, so a real run refuses on the trust record; the dry run must
  # say the same rather than list the poll as removable.
  dir=$(make_receipt_case pending-receipt "$url")
  arm_pending_receipt "$dir" old-r1 "$url"
  (umask 077 && printf 'armed\n' > "$dir/home/state/old-r1.check-trust")
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record --dry-run 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a dry run over a pending receipt and a trust record"$'\n'"$out"
  assert_contains "$out" "registered watcher check (state/old-r1.check-trust)" \
    "the dry run did not raise the refusal a real run raises"
  assert_not_contains "$out" "would remove" "the dry run listed records as removable"
  for artifact in check.sh pr-poll pr-poll-registration pr-poll-retirement check-trust; do
    assert_present "$dir/home/state/old-r1.$artifact" "the dry run removed $artifact"
  done
  assert_copy_and_pool_untouched "$dir" "$before" "pending-receipt dry run"
  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a real run over a pending receipt and a trust record"$'\n'"$out"
  assert_contains "$out" "registered watcher check (state/old-r1.check-trust)" \
    "the real run did not refuse on the trust record"
  for artifact in check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    assert_absent "$dir/home/state/old-r1.$artifact" "the real run left $artifact after completing the receipt"
  done
  assert_present "$dir/home/state/old-r1.meta" "the refused real run removed the record"
  assert_present "$dir/home/state/old-r1.check-trust" "the refused real run removed the trust record"

  # With no trust record, completing the receipt leaves nothing armed, so the
  # dry run lets the record go exactly as the real run then does.
  dir=$(make_receipt_case receipt-clear "$url")
  arm_pending_receipt "$dir" old-r1 "$url"
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record --dry-run 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a dry run over a pending receipt with nothing else armed"$'\n'"$out"
  assert_contains "$out" "a real run first completes old-r1's pending PR-poll retirement" \
    "the dry run did not say the receipt is completed first"
  assert_contains "$out" "dry run: would remove $dir/home/state/old-r1.meta" \
    "the dry run did not list the records to go"
  for artifact in check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    assert_present "$dir/home/state/old-r1.$artifact" "the dry run removed $artifact"
  done
  assert_copy_and_pool_untouched "$dir" "$before" "receipt-clear dry run"
  set +e
  out=$(run_teardown "$dir" old-r1 --retire-record 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a real run over a pending receipt with nothing else armed"$'\n'"$out"
  assert_contains "$out" "retired record old-r1" "the real run did not retire the record"
  for artifact in meta check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    assert_absent "$dir/home/state/old-r1.$artifact" "the real run left $artifact behind"
  done
  assert_copy_and_pool_untouched "$dir" "$before" "receipt-clear retire"
  pass "fm-teardown --retire-record --dry-run: scans for armed checks over what completing a pending receipt would leave, so its verdict matches the real run's in both directions"
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
  write_record "$dir" older-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "lease_holder=fm-task:older-r1:l1788765990.4242.16"
  assert_refused_without_mutation "$dir" own-r1 "still owns its working copy" \
    "a record holding its own lease" --retire-record
  assert_contains "$REFUSAL_OUTPUT" "bin/fm-teardown.sh own-r1" \
    "the refusal did not name ordinary teardown"

  # The durable lease is authoritative in the other direction too: the older
  # record's claim is no longer on the slot, which the pool leases to own-r1's
  # claim on that same path, so it is retirable.
  set +e
  run_teardown "$dir" older-r1 --retire-record --dry-run > "$dir/older.out" 2>&1
  expect_code 0 "$?" "a record whose slot is leased to another record"$'\n'"$(cat "$dir/older.out")"
  set -e
  assert_grep "task own-r1" "$dir/older.out" "the lease holder's task was not named"
  pass "fm-teardown --retire-record: refuses a record the pool still leases to it, and the lease proves the older claimant re-leased"
}

test_retire_refuses_an_unproven_re_lease() {
  local dir claim=fm-task:alone-r1:l1788765990.150863.30112
  dir=$(make_case unproven)
  write_pool "$dir" ',"owner_pid":999999,"owner_started_at":1789026475860'
  write_record "$dir" alone-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$claim"
  assert_refused_without_mutation "$dir" alone-r1 "holds no durable lease on" \
    "a claim with no durable lease on its slot" --retire-record
  assert_contains "$REFUSAL_OUTPUT" "Confirm by hand whose work the copy holds" \
    "the refusal did not name the person's alternatives"

  # An unreadable pool record is no evidence at all, never a verdict.
  printf '{"worktrees": [truncated' > "$dir/pool/treehouse-state.json"
  assert_refused_without_mutation "$dir" alone-r1 "could not be read" \
    "a record whose pool state cannot be read" --retire-record

  # A lease under a label no record in this home carries, such as a hand-run
  # treehouse get, proves nothing about who holds the copy.
  write_pool "$dir" ',"leased":true,"lease_holder":"fm-task:other-x9:l1789026480.7.7"'
  assert_refused_without_mutation "$dir" alone-r1 "no record in this home carries that label" \
    "a lease under a label nobody claims" --retire-record

  # A label another record carries as its claim on a DIFFERENT path is not a
  # re-lease of this slot: a spawn that held this slot aside and could not hand
  # it back leaves exactly that shape.
  write_pool "$dir" ',"leased":true,"lease_holder":"fm-task:elsewhere-r1:l1789026480.7.7"'
  fm_write_meta "$dir/home/state/elsewhere-r1.meta" \
    "window=firstmate:fm-elsewhere-r1" "endpoint_task_id=elsewhere-r1" \
    "worktree=$dir/pool/2/repo" "project=$dir/project" "harness=claude" "kind=ship" \
    "lease_holder=fm-task:elsewhere-r1:l1789026480.7.7"
  assert_refused_without_mutation "$dir" alone-r1 "no record in this home carries that label" \
    "a lease under a claim on a different path" --retire-record

  # The record the pool leases the slot to is the current holder.
  dir=$(make_superseded_case newest)
  assert_refused_without_mutation "$dir" new-r1 "still owns its working copy" \
    "the record the pool leases the slot to" --retire-record
  pass "fm-teardown --retire-record: a claim is unproven unless the pool's lease confirms it or another record's claim on the same path explains it, and the leased record is refused as the holder"
}

# Ownership is never inferred: a record that carries no lease claim reads
# unproven whatever else is true of its slot, so --retire-record refuses it in
# a real run and in a dry run alike and names what a person can do instead.
test_retire_refuses_a_record_without_a_recorded_claim() {
  local dir mode path
  dir=$(make_case no-claim)
  # A later fresh claimant on the same path, a foreign durable lease on it, and
  # spawn generations on both records, none of which is evidence.
  write_pool "$dir" ',"leased":true,"lease_holder":"fm-task:other-x9:l1789026480.7.7"'
  write_record "$dir" legacy-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$NEW_CLAIM"
  populate_task_state "$dir" legacy-r1
  for mode in dry real; do
    if [ "$mode" = dry ]; then
      assert_refused_without_mutation "$dir" legacy-r1 "carries no lease claim" \
        "a $mode run over a record with no recorded claim" --retire-record --dry-run
    else
      assert_refused_without_mutation "$dir" legacy-r1 "carries no lease claim" \
        "a $mode run over a record with no recorded claim" --retire-record
    fi
    assert_contains "$REFUSAL_OUTPUT" "Confirm by hand whose work the copy holds" \
      "the $mode refusal did not name the person's alternatives"
    assert_contains "$REFUSAL_OUTPUT" "bin/fm-teardown.sh legacy-r1 --retire-record --unproven-confirmed" \
      "the $mode refusal did not name the acknowledgement flag"
    assert_contains "$REFUSAL_OUTPUT" "whose ownership could not be proven" \
      "the $mode refusal did not say what the flag is for"
    assert_not_contains "$REFUSAL_OUTPUT" "would remove" "the $mode run listed records as removable"
    while IFS= read -r path; do
      assert_present "$path" "the $mode run removed $path"
    done <<EOF
$(task_paths "$dir" legacy-r1)
EOF
  done
  pass "fm-teardown --retire-record: a record with no recorded claim is unproven whatever its slot shows, and refuses in a real run and a dry run alike, naming --unproven-confirmed"
}

test_retire_follows_a_lease_to_a_secondmate_home() {
  local dir before rc out
  dir=$(make_case secondmate-lease)
  write_pool "$dir" ',"leased":true,"lease_holder":"boards-b1"'
  write_record "$dir" legacy-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "lease_holder=fm-task:legacy-r1:l1788765990.150863.30112"
  fm_write_secondmate_meta "$dir/home/state/boards-b1.meta" "$dir/pool/1/repo"
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" legacy-r1 --retire-record 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a record whose slot the pool now leases to a secondmate home"$'\n'"$out"
  assert_contains "$out" "leases $dir/pool/1/repo to boards-b1, task boards-b1's own recorded claim" \
    "the secondmate lease holder was not named"
  assert_absent "$dir/home/state/legacy-r1.meta" "the superseded record survived"
  assert_present "$dir/home/state/boards-b1.meta" "the lease holder's record was touched"
  assert_copy_and_pool_untouched "$dir" "$before" "secondmate-lease retire"
  pass "fm-teardown --retire-record: a secondmate home leased under its bare id on the same path proves the older claim was re-leased"
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
  # --unproven-confirmed acknowledges an unproven slot, never a live agent: the
  # same record with no recorded claim is refused on the agent just the same.
  write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  assert_refused_without_mutation "$dir" old-r1 "still holds a live agent" \
    "an endpoint running a live agent under --unproven-confirmed" --retire-record --unproven-confirmed
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" has-session -t firstmate 2>/dev/null \
    || fail "the refusal disturbed the live endpoint"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null || true
  pass "fm-teardown --retire-record: refuses while the record's own endpoint still runs a live agent, with or without --unproven-confirmed"
}

test_retire_refuses_secondmate_and_orca_records() {
  local dir
  dir=$(make_case other-kinds)
  write_pool "$dir" ''
  fm_write_secondmate_meta "$dir/home/state/sm-r1.meta" "$dir/pool/1/repo"
  assert_refused_without_mutation "$dir" sm-r1 "is a secondmate home" \
    "a secondmate record" --retire-record
  assert_refused_without_mutation "$dir" sm-r1 "is a secondmate home" \
    "a secondmate record under --unproven-confirmed" --retire-record --unproven-confirmed
  fm_write_meta "$dir/home/state/orca-r1.meta" \
    "window=fm-orca-r1" "endpoint_task_id=orca-r1" "terminal=term-7" \
    "worktree=$dir/pool/1/repo" "project=$dir/project" "backend=orca" \
    "orca_worktree_id=worktree-9" "kind=ship" "spawn_gen=$OLD_GEN"
  assert_refused_without_mutation "$dir" orca-r1 "Orca worktree" \
    "an Orca record" --retire-record
  assert_refused_without_mutation "$dir" orca-r1 "Orca worktree" \
    "an Orca record under --unproven-confirmed" --retire-record --unproven-confirmed
  pass "fm-teardown --retire-record: refuses secondmate homes and Orca worktrees, which are never pool slots it can prove re-leased, with or without --unproven-confirmed"
}

test_retire_rejects_malformed_requests() {
  local dir rc args
  dir=$(make_superseded_case bad-options)
  for args in "--retire-record --force" "--dry-run" "--force --dry-run" "--retire-record --bogus" "--bogus" \
      "--unproven-confirmed" "--force --unproven-confirmed" "--unproven-confirmed --force" \
      "--unproven-confirmed --dry-run" "--dry-run --unproven-confirmed" \
      "--retire-record --unproven-confirmed --force" "--retire-record --unproven-confirmed --unproven-confirmed" \
      "--retire-record --dry-run --dry-run" "--retire-record --retire-record --unproven-confirmed"; do
    set +e
    # shellcheck disable=SC2086 # each case is a deliberate word list
    run_teardown "$dir" old-r1 $args > "$dir/bad.out" 2>&1
    rc=$?
    set -e
    expect_code 2 "$rc" "teardown old-r1 $args"
  done
  assert_present "$dir/home/state/old-r1.meta" "a malformed request changed state"
  [ ! -s "$dir/runtime.log" ] || fail "a malformed request reached the runtime: $(cat "$dir/runtime.log")"
  pass "fm-teardown: rejects unknown or conflicting options, --unproven-confirmed anywhere but with --retire-record among them, before touching anything"
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
  RECORD_WORKTREE="$dir/pool/2/repo" write_record "$dir" old-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off"
  write_record "$dir" new-r1 scout "$NEW_GEN"
  populate_task_state "$dir" new-r1
  write_presentation_rows "$dir" old-r1 new-r1
  set +e
  out=$(run_teardown "$dir" new-r1 --force 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "tearing down a record with no recorded claim"$'\n'"$out"
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
  pass "fm-teardown: a record with no recorded claim on a copy no other record names tears down normally, as before durable leases, and drops every per-task record, watcher markers included"
}

# The pre-lease shape: two records with no recorded claim on one working copy,
# under the process-bound reservation treehouse clears once its owner dies.
make_claimless_pair_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  write_pool "$dir" ',"owner_pid":999999,"owner_started_at":1789026475860'
  write_record "$dir" stale-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "pr=https://github.com/example/repo/pull/829"
  write_record "$dir" holder-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off"
  populate_task_state "$dir" stale-r1
  populate_task_state "$dir" holder-r1
  write_presentation_rows "$dir" stale-r1 holder-r1
  printf '%s\n' "$dir"
}

# The transition shape: a record with no recorded claim on a copy the pool now
# durably leases to a later record's own claim.
make_claimless_under_lease_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$NEW_CLAIM\""
  write_record "$dir" legacy-r1 ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "pr=https://github.com/example/repo/pull/829"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$NEW_CLAIM"
  populate_task_state "$dir" legacy-r1
  populate_task_state "$dir" new-r1
  write_presentation_rows "$dir" legacy-r1 new-r1
  printf '%s\n' "$dir"
}

# Ordinary teardown of <id>, plain and --force, refuses on the recorded fact
# <evidence>, names --unproven-confirmed and what it is for, and reaches
# neither treehouse nor tmux.
assert_ordinary_teardown_refuses_unproven() {  # <case> <id> <evidence> <label>
  local dir=$1 id=$2 evidence=$3 label=$4 mode
  for mode in plain force; do
    : > "$dir/runtime.log"
    if [ "$mode" = force ]; then
      assert_refused_without_mutation "$dir" "$id" "could not be proven" "$label ($mode)" --force
    else
      assert_refused_without_mutation "$dir" "$id" "could not be proven" "$label ($mode)"
    fi
    assert_contains "$REFUSAL_OUTPUT" "$evidence" "$label ($mode): the refusal did not name the recorded fact"
    assert_contains "$REFUSAL_OUTPUT" "bin/fm-teardown.sh $id --retire-record --unproven-confirmed" \
      "$label ($mode): the refusal did not name the acknowledgement flag"
    assert_contains "$REFUSAL_OUTPUT" "whose ownership could not be proven" \
      "$label ($mode): the refusal did not say what the flag is for"
    [ ! -s "$dir/runtime.log" ] \
      || fail "$label ($mode): the refusal reached the runtime: $(cat "$dir/runtime.log")"
    assert_present "$dir/home/state/.hash-firstmate_fm-$id" "$label ($mode): the refusal removed watcher state"
  done
}

test_ordinary_teardown_refuses_both_records_of_a_claimless_pair() {
  local dir
  dir=$(make_claimless_pair_case claimless-pair)
  assert_ordinary_teardown_refuses_unproven "$dir" stale-r1 "holder-r1 also name" \
    "ordinary teardown of the stale record of a claimless pair"
  assert_ordinary_teardown_refuses_unproven "$dir" holder-r1 "stale-r1 also name" \
    "ordinary teardown of the record still holding the copy of a claimless pair"
  pass "fm-teardown: refuses, with or without --force, both records of a pre-lease pair that name one working copy without a claim, naming --unproven-confirmed"
}

test_ordinary_teardown_refuses_a_claimless_record_under_another_claims_lease() {
  local dir rc out
  dir=$(make_claimless_under_lease_case claimless-under-lease)
  assert_ordinary_teardown_refuses_unproven "$dir" legacy-r1 \
    "task new-r1's own recorded claim on that same working copy" \
    "ordinary teardown of a claimless record whose copy is leased to another claim"
  # The holder's own claim is what the pool leases, so its teardown proceeds.
  set +e
  out=$(run_teardown "$dir" new-r1 --force 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "tearing down the record the pool leases the copy to"$'\n'"$out"
  assert_grep "treehouse <return> <--force> <$dir/pool/1/repo>" "$dir/runtime.log" \
    "the lease holder's teardown did not return its slot"
  assert_grep "kill-window" "$dir/runtime.log" "the lease holder's endpoint was not closed"
  assert_present "$dir/home/state/legacy-r1.meta" "the lease holder's teardown touched the claimless record"
  assert_absent "$dir/home/state/new-r1.meta" "the lease holder's record survived its teardown"
  pass "fm-teardown: refuses a claimless record whose copy the pool leases to another record's claim, while that holder's own teardown proceeds"
}

# Every planned removal is printed before the first removal.
assert_plan_precedes_removal() {  # <output> <label>
  local out=$1 label=$2 plan_last removed_first
  plan_last=$(printf '%s\n' "$out" | grep -n 'retire-record: will remove ' | tail -n 1 | cut -d: -f1)
  removed_first=$(printf '%s\n' "$out" | grep -n 'retire-record: removed ' | head -n 1 | cut -d: -f1)
  [ -n "$plan_last" ] && [ -n "$removed_first" ] && [ "$plan_last" -lt "$removed_first" ] \
    || fail "$label: the planned removals were not all printed before the first removal"$'\n'"$out"
}

# assert_confirmed_retire <case> <id> <other-id> <evidence>: --retire-record
# --unproven-confirmed prints the verdict and the complete plan, then removes
# exactly teardown's state set for <id>, leaving <other-id>'s records, the
# working copy, the pool, and every endpoint alone.
assert_confirmed_retire() {
  local dir=$1 id=$2 other=$3 evidence=$4 before rc out path
  before=$(cksum < "$dir/pool/treehouse-state.json")
  set +e
  out=$(run_teardown "$dir" "$id" --retire-record --unproven-confirmed 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "retiring $id with --unproven-confirmed"$'\n'"$out"
  assert_contains "$out" "could not be proven" "retiring $id did not print the verdict"
  assert_contains "$out" "$evidence" "retiring $id did not print the recorded fact"
  while IFS= read -r path; do
    assert_contains "$out" "retire-record: will remove $path" "the plan for $id did not list $path"
    assert_contains "$out" "retire-record: removed $path" "the removal of $path was not reported"
    assert_absent "$path" "retiring $id left $path behind"
  done <<EOF
$(task_paths "$dir" "$id")
EOF
  assert_contains "$out" "retire-record: will remove $id's row from $dir/home/state/.status-presentation-cursor" \
    "the plan for $id did not list the presentation row"
  assert_plan_precedes_removal "$out" "retiring $id"
  assert_no_grep "$id"$'\t' "$dir/home/state/.status-presentation-cursor" \
    "retiring $id kept its presentation row"
  while IFS= read -r path; do
    case "$path" in */.pr-check-quarantine/*) continue ;; esac
    assert_present "$path" "retiring $id removed $other's $path"
  done <<EOF
$(task_paths "$dir" "$other")
EOF
  assert_present "$dir/home/state/.pr-check-quarantine/$other.diagnostic.ambiguous" \
    "retiring $id removed $other's quarantine entry"
  assert_grep "$other"$'\t' "$dir/home/state/.status-presentation-cursor" \
    "retiring $id dropped $other's presentation row"
  assert_copy_and_pool_untouched "$dir" "$before" "retiring $id with --unproven-confirmed"
}

test_retire_unproven_confirmed_retires_a_claimless_record() {
  local dir before rc out path args
  dir=$(make_claimless_under_lease_case unproven-confirmed)
  before=$(cksum < "$dir/pool/treehouse-state.json")

  # Without the acknowledgement the record stays.
  assert_refused_without_mutation "$dir" legacy-r1 "carries no lease claim" \
    "a claimless record without the acknowledgement" --retire-record

  # A dry run with the flag, in either order, prints the verdict and the planned
  # removals and changes nothing.
  for args in "--retire-record --unproven-confirmed --dry-run" "--unproven-confirmed --dry-run --retire-record"; do
    set +e
    # shellcheck disable=SC2086 # each case is a deliberate word list
    out=$(run_teardown "$dir" legacy-r1 $args 2>&1)
    rc=$?
    set -e
    expect_code 0 "$rc" "a dry run with --unproven-confirmed ($args)"$'\n'"$out"
    assert_contains "$out" "could not be proven" "the dry run ($args) did not print the verdict"
    assert_contains "$out" "task new-r1's own recorded claim on that same working copy" \
      "the dry run ($args) did not print the recorded fact"
    assert_contains "$out" "dry run: would remove $dir/home/state/legacy-r1.meta" \
      "the dry run ($args) did not list the records it would remove"
    assert_not_contains "$out" "retire-record: removed" "the dry run ($args) removed something"
    while IFS= read -r path; do
      assert_present "$path" "the dry run ($args) removed $path"
    done <<EOF
$(task_paths "$dir" legacy-r1)
EOF
    assert_grep "legacy-r1"$'\t' "$dir/home/state/.status-presentation-cursor" \
      "the dry run ($args) dropped the presentation row"
    assert_copy_and_pool_untouched "$dir" "$before" "dry run ($args)"
  done

  # The real run, on the copy the pool leases to another record's claim.
  assert_confirmed_retire "$dir" legacy-r1 new-r1 \
    "task new-r1's own recorded claim on that same working copy"

  # And on the pre-lease pair, where the only recorded fact is the other
  # claimless record naming the same copy.
  dir=$(make_claimless_pair_case unproven-confirmed-pair)
  assert_confirmed_retire "$dir" stale-r1 holder-r1 "holder-r1 also name"
  pass "fm-teardown --retire-record --unproven-confirmed: retires a claimless record after printing the complete plan, in a dry run changes nothing, and leaves the copy, the pool, every endpoint, and every other record alone"
}

test_retire_unproven_confirmed_keeps_every_other_refusal() {
  local dir label=fm-task:own-r1:l1789000000.4242.17 artifact
  # A record the pool leases to its own claim would strand that lease.
  dir=$(make_case own-lease-confirmed)
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$label\""
  write_record "$dir" own-r1 ship s1789000003.4242.18 "mode=direct-PR" "yolo=off" "lease_holder=$label"
  assert_refused_without_mutation "$dir" own-r1 "still owns its working copy" \
    "a record holding its own lease under --unproven-confirmed" --retire-record --unproven-confirmed
  assert_refused_without_mutation "$dir" own-r1 "still owns its working copy" \
    "a dry run of a record holding its own lease under --unproven-confirmed" \
    --retire-record --dry-run --unproven-confirmed
  # An armed PR merge poll or registered watcher check on a claimless record.
  dir=$(make_claimless_pair_case armed-confirmed)
  for artifact in check.sh pr-poll pr-poll-registration check-trust; do
    (umask 077 && printf 'armed\n' > "$dir/home/state/stale-r1.$artifact")
  done
  assert_refused_without_mutation "$dir" stale-r1 "still has an armed PR merge poll" \
    "an armed PR merge poll under --unproven-confirmed" --retire-record --unproven-confirmed
  assert_contains "$REFUSAL_OUTPUT" "https://github.com/example/repo/pull/829" \
    "the refusal did not name the watched PR"
  for artifact in check.sh pr-poll pr-poll-registration check-trust; do
    assert_present "$dir/home/state/stale-r1.$artifact" "the refusal removed the poll's $artifact"
  done
  rm -f "$dir/home/state/stale-r1.pr-poll" "$dir/home/state/stale-r1.pr-poll-registration"
  assert_refused_without_mutation "$dir" stale-r1 "registered watcher check" \
    "an armed custom check under --unproven-confirmed" --retire-record --unproven-confirmed
  pass "fm-teardown --retire-record --unproven-confirmed: still refuses a record that owns its lease and one with an armed PR merge poll or registered watcher check"
}

test_retire_removes_an_idle_task_temp_root() {
  local dir id tmpdir rc out
  id="retire-tmp-$$"
  tmpdir="/tmp/fm-$id"
  dir=$(make_case idle-tasktmp)
  write_pool "$dir" ",\"leased\":true,\"lease_holder\":\"$NEW_CLAIM\""
  RECORD_TASKTMP=$tmpdir write_record "$dir" "$id" ship "$OLD_GEN" "mode=direct-PR" "yolo=off" \
    "lease_holder=fm-task:$id:l1788765990.150863.30112"
  write_record "$dir" new-r1 ship "$NEW_GEN" "mode=direct-PR" "yolo=off" "lease_holder=$NEW_CLAIM"
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
test_retire_dry_run_refuses_exactly_where_a_real_run_would
test_retire_refuses_a_record_that_owns_its_lease
test_retire_refuses_an_unproven_re_lease
test_retire_refuses_a_record_without_a_recorded_claim
test_retire_follows_a_lease_to_a_secondmate_home
test_retire_refuses_an_armed_pr_merge_poll
test_retire_refuses_a_live_agent
test_retire_refuses_secondmate_and_orca_records
test_retire_rejects_malformed_requests
test_ordinary_teardown_refuses_a_re_leased_slot
test_ordinary_teardown_lets_the_current_holder_through
test_ordinary_teardown_refuses_both_records_of_a_claimless_pair
test_ordinary_teardown_refuses_a_claimless_record_under_another_claims_lease
test_retire_unproven_confirmed_retires_a_claimless_record
test_retire_unproven_confirmed_keeps_every_other_refusal
test_retire_removes_an_idle_task_temp_root

echo "# all fm-teardown-retire-record tests passed"
