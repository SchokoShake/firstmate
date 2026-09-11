#!/usr/bin/env bash
# Tests for fm-spawn's durable treehouse lease (bin/fm-slot-lib.sh owns why):
# a fresh ship or scout leases its worktree, records the holder label, moves the
# pane's shell into it with a top-level cd, never takes a slot another record in
# the home still names, and hands its lease back when it stops before
# publishing its record, unless the slot holds uncommitted work.
# These drive the real spawn path against a fake terminal and a fake treehouse
# that hands out slots from a queue and logs every call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease)

make_fakebin() {  # <dir> -> fakebin
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> -> case dir with a home, a project whose origin is a
# local bare repo, and two clean pool slots of that project.
make_case() {
  local dir="$TMP_ROOT/$1" id=$2 project
  project="$dir/project"
  mkdir -p "$dir/home/data/$id" "$dir/home/projects" "$dir/home/state" "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$dir/home/data/$id/brief.md"
  touch "$dir/home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$dir/origin.git"
  git -C "$project" remote add origin "file://$dir/origin.git"
  git -C "$project" worktree add --quiet --detach "$dir/pool/1/project" HEAD
  git -C "$project" worktree add --quiet --detach "$dir/pool/2/project" HEAD
  : > "$dir/treehouse.log"
  : > "$dir/tmux.log"
  make_fakebin "$dir/fake" >/dev/null
  printf '%s\n' "$dir"
}

run_spawn() {  # <case> <id> <pane-path> [spawn args...]
  local dir=$1 id=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pane" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TREEHOUSE_LOG="$dir/treehouse.log" \
    FM_FAKE_TREEHOUSE_QUEUE="$dir/queue" PATH="$dir/fake/fakebin:$PATH" \
    "$SPAWN" "$id" "$dir/project" "$@" 2>&1
}

test_fresh_spawn_takes_a_durable_lease() {
  local dir id=lease-fresh-l1 slot out rc holder
  dir=$(make_case fresh "$id")
  slot="$dir/pool/1/project"
  printf '%s\n' "$slot" > "$dir/queue"
  out=$(run_spawn "$dir" "$id" "$slot" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "a fresh spawn on a leased slot"$'\n'"$out"
  assert_grep "worktree=$slot" "$dir/home/state/$id.meta" "spawn did not record the leased worktree"
  holder=$(grep '^lease_holder=' "$dir/home/state/$id.meta" | cut -d= -f2-)
  case "$holder" in
    "fm-task:$id:l"[0-9]*.*.*) ;;
    *) fail "spawn recorded no well-formed lease holder, got '$holder'" ;;
  esac
  assert_grep "treehouse get --lease --lease-holder $holder" "$dir/treehouse.log" \
    "spawn did not take a durable lease under the holder it recorded"
  assert_grep "cd -- '$slot' Enter" "$dir/tmux.log" \
    "spawn did not move the pane's own shell into the leased worktree"
  assert_no_grep 'treehouse return' "$dir/treehouse.log" \
    "a successful spawn returned the lease its published record now owns"
  pass "fm-spawn: a fresh spawn takes a durable treehouse lease, records its holder, and cds the pane into it"
}

test_spawn_skips_a_slot_another_record_names() {
  local dir id=lease-skip-l2 slot1 slot2 out rc before
  dir=$(make_case skip "$id")
  slot1="$dir/pool/1/project"
  slot2="$dir/pool/2/project"
  # A record that predates durable leases still names slot 1, whose owner
  # reservation died with its pane, so the pool hands slot 1 out first.
  fm_write_meta "$dir/home/state/stale-l2.meta" \
    "window=firstmate:fm-stale-l2" "endpoint_task_id=stale-l2" \
    "worktree=$slot1" "project=$dir/project" "kind=ship" \
    "spawn_gen=s1788765996.150863.30112"
  before=$(cksum < "$dir/home/state/stale-l2.meta")
  printf '%s\n%s\n' "$slot1" "$slot2" > "$dir/queue"
  out=$(run_spawn "$dir" "$id" "$slot2" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "a spawn offered a slot another record names"$'\n'"$out"
  assert_grep "worktree=$slot2" "$dir/home/state/$id.meta" "spawn did not move on to a free slot"
  assert_contains "$out" "still named by task record(s) stale-l2" "spawn did not name the record holding the slot"
  assert_grep "treehouse return --force $slot1" "$dir/treehouse.log" \
    "spawn did not hand back the slot it held aside"
  assert_no_grep "treehouse return --force $slot2" "$dir/treehouse.log" "spawn returned its own slot"
  assert_no_grep "cd -- '$slot1'" "$dir/tmux.log" "spawn moved the pane into the slot another record names"
  [ "$(cksum < "$dir/home/state/stale-l2.meta")" = "$before" ] || fail "spawn changed the other record"
  pass "fm-spawn: a leased slot another record still names is held aside, handed back, and never used"
}

test_spawn_gives_up_when_every_leased_slot_is_named() {
  local dir id=lease-exhaust-l3 slot1 out rc
  dir=$(make_case exhaust "$id")
  slot1="$dir/pool/1/project"
  fm_write_meta "$dir/home/state/stale-l3.meta" \
    "window=firstmate:fm-stale-l3" "endpoint_task_id=stale-l3" \
    "worktree=$slot1" "project=$dir/project" "kind=ship"
  for _ in 1 2 3 4 5 6 7 8; do printf '%s\n' "$slot1"; done > "$dir/queue"
  out=$(run_spawn "$dir" "$id" "$slot1" --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded although every slot it leased was named"
  assert_contains "$out" "every pool slot leased for $id" "spawn did not explain why it gave up"
  assert_absent "$dir/home/state/$id.meta" "a spawn that found no free slot published a record"
  assert_grep "treehouse return --force $slot1" "$dir/treehouse.log" \
    "spawn kept the slots it held aside after giving up"
  pass "fm-spawn: gives up after a bounded search and hands back every slot it held aside"
}

test_aborted_spawn_hands_back_a_clean_lease() {
  local dir id=lease-abort-l4 slot out rc
  dir=$(make_case abort "$id")
  slot="$dir/pool/1/project"
  git -C "$slot" remote set-url origin "file://$dir/missing-origin.git"
  printf '%s\n' "$slot" > "$dir/queue"
  out=$(run_spawn "$dir" "$id" "$slot" --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" "spawn did not stop at the base refresh"
  assert_absent "$dir/home/state/$id.meta" "an aborted spawn published a record"
  assert_grep "treehouse return --force $slot" "$dir/treehouse.log" \
    "an aborted spawn kept the clean lease it took"
  pass "fm-spawn: a spawn that stops before publishing its record hands its clean lease back"
}

test_aborted_spawn_keeps_a_dirty_lease() {
  local dir id=lease-dirty-l5 slot out rc
  dir=$(make_case dirty "$id")
  slot="$dir/pool/1/project"
  printf 'keep this local work\n' > "$slot/uncommitted.txt"
  printf '%s\n' "$slot" > "$dir/queue"
  out=$(run_spawn "$dir" "$id" "$slot" --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "has uncommitted changes; it stays leased" \
    "an aborted spawn did not explain why it kept the lease"
  assert_no_grep 'treehouse return' "$dir/treehouse.log" \
    "an aborted spawn returned a slot with uncommitted work, whose reset would discard it"
  assert_grep 'keep this local work' "$slot/uncommitted.txt" "the uncommitted work was lost"
  pass "fm-spawn: an aborted spawn keeps the lease on a slot with uncommitted work rather than discarding it"
}

test_fresh_spawn_takes_a_durable_lease
test_spawn_skips_a_slot_another_record_names
test_spawn_gives_up_when_every_leased_slot_is_named
test_aborted_spawn_hands_back_a_clean_lease
test_aborted_spawn_keeps_a_dirty_lease

echo "# all fm-spawn-lease tests passed"
