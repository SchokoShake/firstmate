#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta
# before merging so fm-teardown.sh's landed-check has a PR reference to verify
# against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# That recording is owed only while there is still a crew to tear down, so the
# two halves are tested apart: with a meta, record-then-merge (a); with none -
# the torn-down task a board card outlives - merge from the URL alone (d).
#
# The no-meta half owes the bookkeeping fm-teardown.sh does after a PR-based teardown
# instead, because the teardown that would normally do it is what removed the meta:
# the DURABLE backlog's close (i), or the item recomposes the very Merge card the
# captain just answered; and the project clone's refresh (j), or it feeds a stale base
# to bin/fm-review-diff.sh and every follow-on dispatch until the next session start.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) a missing meta merges from the URL alone, recording and arming no state
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a missing meta closes the backlog item, but only on a merge that succeeded,
#       and never while a live meta leaves the close to teardown
#   (j) a missing meta refreshes the clone of the project the backlog names, and
#       never while a live meta leaves that to teardown
#   (k) a close that fails is reported rather than swallowed, and still never fails
#       a merge GitHub has already taken; an id the backlog never carried is not a
#       failure to report at all
#   (l) a close SKIPPED because the backlog is hand-maintained is reported on the same
#       terms - it is equally an item left open, and there is no teardown left to prompt
#       the hand-edit - while an untracked or already-Done item stays quiet, because
#       neither leaves a card to recompose
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# The backlog, config, and projects dir are pinned INTO the case dir: the durable half of
# the recording path (fm-pr-check.sh), the no-meta close, and the no-meta clone refresh
# all write through them, and left at their defaults they would resolve against
# FM_ROOT_OVERRIDE - this repo's own checkout. FM_PROJECTS_OVERRIDE is read by the
# fm-fleet-sync.sh child rather than by fm-pr-merge.sh itself, and reaches it by
# inheritance.
run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_PROJECTS_OVERRIDE="$case_dir/projects" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

# build_clone_behind_origin <case_dir> <name>: a real projects/<name> clone sitting one
# commit behind its origin - the shape a merged PR leaves this home's clone in. Echoes
# the origin's tip sha, which is what a refreshed clone must be at.
#
# fm-fleet-sync.sh is invoked by fm-pr-merge.sh as a sibling of itself (the "own bin/"
# rule of AGENTS.md section 2), so it cannot be stubbed on PATH the way gh-axi is. These
# cases drive the real script against a real clone instead, which is the stronger
# assertion anyway: that the clone is actually refreshed, not merely that a call was made.
build_clone_behind_origin() {
  local case_dir=$1 name=$2 work remote clone remote_abs
  work="$case_dir/work-$name"
  remote="$case_dir/remotes/$name.git"
  clone="$case_dir/projects/$name"
  mkdir -p "$case_dir/remotes" "$case_dir/projects"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf 'v0\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"

  # The merge lands on origin; this home's clone stays behind until something syncs it.
  printf 'v1\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm C1
  git -C "$work" push -q origin main

  git -C "$work" rev-parse HEAD
}

clone_head_of() {
  git -C "$1" rev-parse HEAD
}

# seed_backlog <case_dir> <id> <url>: a real tasks-axi backlog holding one in-flight,
# captain-held task carrying <url> in the structured link position - exactly what a
# torn-down review-ready task leaves behind, and what the board composes its Merge card
# from. Driving the real tool is the same precedent tests/fm-pr-check.test.sh sets: the
# assertion is about the item's real resulting STATE, which only the real backend can
# answer for. A no-op when tasks-axi is not installed, so the cases below assert on the
# backlog only when there is one.
seed_backlog() {
  local case_dir=$1 id=$2 url=$3
  local bl="$case_dir/data/backlog.md"
  mkdir -p "$case_dir/data" "$case_dir/config"
  command -v tasks-axi >/dev/null 2>&1 || return 0
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$bl"
  tasks-axi add "$id" "Ship the widget endpoint" --kind ship --repo alpha --start \
    --file "$bl" >/dev/null 2>&1 || true
  tasks-axi update "$id" --pr "$url" --file "$bl" >/dev/null 2>&1 || true
  tasks-axi hold "$id" --reason 'review-ready - your call' --kind captain \
    --file "$bl" >/dev/null 2>&1 || true
}

# The item's own section, so a close is asserted as the state change it is rather than
# by grepping for a marker that appears in every section alike.
backlog_section_of() {
  local bl=$1 id=$2
  awk -v id="$id" '
    /^## /  { section = substr($0, 4) }
    index($0, id) && /^- \[/ { print section; exit }
  ' "$bl"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_merges_from_the_url_alone() {
  local case_dir fakebin url=https://github.com/example/repo/pull/21
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"
  seed_backlog "$case_dir" missing-x1 "$url"

  # THE headline flow: the captain taps Merge on a board card whose crew was torn
  # down long ago, so there is no meta - which is the documented end-state for
  # review-ready work (AGENTS.md section 7), not a fault. Refusing here dead-ended
  # the one path the board's Merge option exists to drive.
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "missing-meta: fm-pr-merge must merge from the PR URL alone"$'\n'"$(cat "$case_dir/stderr")"

  grep -qxF 'pr merge 21 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "missing-meta: the URL alone must still parse to number + --repo"$'\n'"$(cat "$case_dir/gh-axi.log")"
  # The META record is skipped rather than tolerated-when-absent. It exists to serve a
  # later teardown, and teardown is what removed the meta: it has already run and will
  # never run again, so an armed poll would report this very merge forever.
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: no meta means teardown already swept this task - arming a merge poll would strand it"
  assert_absent "$case_dir/state/missing-x1.meta" \
    "missing-meta: a torn-down task's meta must not be resurrected by merging"
  pass "fm-pr-merge merges from the PR URL alone when a torn-down task has no meta"
}

test_missing_meta_closes_the_backlog_item() {
  local case_dir fakebin section url=https://github.com/example/repo/pull/24
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge backlog close (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir="$TMP_ROOT/missing-meta-closes"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"
  seed_backlog "$case_dir" missing-x1 "$url"

  section=$(backlog_section_of "$case_dir/data/backlog.md" missing-x1)
  [ "$section" = "In flight" ] \
    || fail "fixture: the item must start In flight, not '$section'"

  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "missing-meta-closes: fm-pr-merge failed"$'\n'"$(cat "$case_dir/stderr")"

  # Without this, resolving the card only clears the board until the next sync
  # recomposes the identical Merge card from the still-open backlog item - offering to
  # re-merge work that already landed. No teardown is left to prompt the close: it is
  # what removed the meta.
  section=$(backlog_section_of "$case_dir/data/backlog.md" missing-x1)
  [ "$section" = "Done" ] \
    || fail "missing-meta-closes: the merged item must land in Done, not '$section'"$'\n'"$(cat "$case_dir/data/backlog.md")"
  assert_grep "$url" "$case_dir/data/backlog.md" \
    "missing-meta-closes: the Done entry must keep the PR url it merged"
  pass "fm-pr-merge closes the backlog item when a torn-down task has no meta"
}

test_missing_meta_failed_merge_leaves_the_item_open() {
  local case_dir fakebin rc section url=https://github.com/example/repo/pull/25
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge failed-merge backlog guard (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir="$TMP_ROOT/missing-meta-merge-fails"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  seed_backlog "$case_dir" missing-x1 "$url"

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The close is a record OF the merge, so it must never outrun one: a card the captain
  # still owes a merge is the honest board.
  expect_code 1 "$rc" "missing-meta-merge-fails: the gh-axi merge failure must propagate"
  section=$(backlog_section_of "$case_dir/data/backlog.md" missing-x1)
  [ "$section" = "In flight" ] \
    || fail "missing-meta-merge-fails: a failed merge must leave the item open, not '$section'"
  pass "fm-pr-merge does not close the backlog item when the merge itself fails"
}

test_live_meta_leaves_the_close_to_teardown() {
  local case_dir section url=https://github.com/example/repo/pull/26
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge live-meta close guard (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir=$(make_case live-meta-no-close)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"
  seed_backlog "$case_dir" task-x1 "$url"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "live-meta-no-close: fm-pr-merge failed"

  # The close belongs to whoever is last: with a crew still standing, fm-teardown.sh is
  # what prompts it, and closing here would race its landed-check to the record.
  section=$(backlog_section_of "$case_dir/data/backlog.md" task-x1)
  [ "$section" = "In flight" ] \
    || fail "live-meta-no-close: a live crew's item is teardown's to close, not '$section'"
  pass "fm-pr-merge leaves a live crew's backlog item for teardown to close"
}

test_missing_meta_refreshes_the_project_clone() {
  local case_dir fakebin tip head url=https://github.com/example/repo/pull/27
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge no-meta clone refresh (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir="$TMP_ROOT/missing-meta-syncs"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"
  # seed_backlog names project "alpha", which is the only surviving record of which
  # clone this merge landed in: the meta that carried project= is gone.
  seed_backlog "$case_dir" missing-x1 "$url"
  tip=$(build_clone_behind_origin "$case_dir" alpha)

  [ "$(clone_head_of "$case_dir/projects/alpha")" != "$tip" ] \
    || fail "fixture: the clone must start behind origin"

  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "missing-meta-syncs: fm-pr-merge failed"$'\n'"$(cat "$case_dir/stderr")"

  # fm-teardown.sh is what normally refreshes the clone after a PR-based teardown, and it
  # is what removed the meta: it has already run and will never run again. Left stale, the
  # clone hands an out-of-date base to fm-review-diff.sh and to every follow-on dispatch.
  head=$(clone_head_of "$case_dir/projects/alpha")
  [ "$head" = "$tip" ] \
    || fail "missing-meta-syncs: the merged project's clone was left stale at $head, not refreshed to $tip"
  pass "fm-pr-merge refreshes the merged project's clone when a torn-down task has no meta"
}

test_live_meta_leaves_the_clone_refresh_to_teardown() {
  local case_dir tip head url=https://github.com/example/repo/pull/28
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge live-meta clone refresh guard (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir=$(make_case live-meta-no-sync)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"
  seed_backlog "$case_dir" task-x1 "$url"
  tip=$(build_clone_behind_origin "$case_dir" alpha)

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "live-meta-no-sync: fm-pr-merge failed"

  # Same division as the close: with a crew still standing, fm-teardown.sh does this
  # after its own landed-check, and syncing here would refresh a clone whose worktree
  # still holds the branch that check has to read.
  head=$(clone_head_of "$case_dir/projects/alpha")
  [ "$head" != "$tip" ] \
    || fail "live-meta-no-sync: a live crew's clone refresh is teardown's, not fm-pr-merge's"
  pass "fm-pr-merge leaves a live crew's clone refresh to teardown"
}

# The close must be governed by the home's own .tasks.toml - done_keep and the archive
# path - and tasks-axi reads that file from its OWN cwd, which --file does not redirect.
# AGENTS.md section 2 sanctions running bin/ from any cwd, so the caller's happens to be
# wherever firstmate last stood: this drives the merge from a foreign one, and gives that
# foreign cwd a competing .tasks.toml so "the home's rules won" is asserted against a
# stranger's actively trying to win instead of against nothing at all.
test_missing_meta_close_honors_the_homes_tasks_config() {
  local case_dir foreign rc url=https://github.com/example/repo/pull/33
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge no-meta close config guard (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir="$TMP_ROOT/missing-meta-config-cwd"
  foreign="$TMP_ROOT/missing-meta-config-cwd-foreign"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$case_dir/fakebin" \
    "$foreign/data"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  # The home's rules: keep one Done entry, archive the rest here.
  cat > "$case_dir/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 1
EOF
  # The stranger's: keep everything, and archive into the stranger's own tree.
  cat > "$foreign/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/stolen-archive.md"
done_keep = 99
EOF
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    '# Backlog' '' '## In flight' \
    "- [ ] missing-x1 - Ship the widget endpoint $url (repo: alpha) (hold-kind: captain)" \
    '' '## Queued' '' > "$case_dir/data/backlog.md"
  printf '%s\n%s\n' '## Done' \
    '- [x] older-w0 - An older shipped thing - https://github.com/example/repo/pull/1 (merged 2026-07-01)' \
    >> "$case_dir/data/backlog.md"

  set +e
  ( cd "$foreign" && run_pr_merge "$case_dir" missing-x1 "$url" ) \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-meta-config-cwd: the close must not fail the landed merge"
  grep -qxF 'pr merge 33 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "missing-meta-config-cwd: the merge itself must still have happened"
  # The close landing is the precondition, not the point: read from a cwd with no config
  # the item still closes, just by the tool's defaults - silently unpruned, unarchived.
  assert_grep 'missing-x1' "$case_dir/data/backlog.md" \
    "missing-meta-config-cwd: fixture: the item must still be recorded Done"
  assert_present "$case_dir/data/done-archive.md" \
    "missing-meta-config-cwd: the home's archive must receive the pruned entry"
  assert_grep 'older-w0' "$case_dir/data/done-archive.md" \
    "missing-meta-config-cwd: done_keep=1 must prune the older entry into the archive"
  assert_no_grep 'older-w0' "$case_dir/data/backlog.md" \
    "missing-meta-config-cwd: the pruned entry must leave the backlog"
  # Section 10 caps Done at 10 and tells firstmate not to hand-prune, so a close that
  # ignores the home's config grows Done unbounded with nobody left to trim it.
  assert_absent "$foreign/data/stolen-archive.md" \
    "missing-meta-config-cwd: a foreign cwd's .tasks.toml must never govern this close"
  pass "fm-pr-merge's no-meta close obeys the home's .tasks.toml from any cwd"
}

# A tasks-axi whose backend probe passes but whose "done" fails for a reason that is not
# the backlog simply not carrying the id - a store or config error, or an id shape a
# hand-maintained backlog carries that the tool rejects.
add_failing_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version "*|"--version") printf '0.2.2\n'; exit 0 ;;
  "update --help") printf 'usage: tasks-axi update <id>\n  --archive-body\n'; exit 0 ;;
  "mv --help") printf 'usage: tasks-axi mv [<id>...] <section>\n'; exit 0 ;;
  "done "*)
    printf 'error: "backlog store is locked"\ncode: IO_ERROR\n' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

test_missing_meta_failed_close_is_reported_not_swallowed() {
  local case_dir fakebin rc url=https://github.com/example/repo/pull/29
  case_dir="$TMP_ROOT/missing-meta-close-fails"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  add_failing_tasks_axi "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The close is best-effort BECAUSE the merge has already landed and cannot be undone by
  # exiting non-zero - which is a reason not to FAIL, never a reason to hide.
  expect_code 0 "$rc" "missing-meta-close-fails: bookkeeping must never fail a landed merge"
  grep -qxF 'pr merge 29 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "missing-meta-close-fails: the merge itself must still have happened"
  # Without a diagnostic the item this path exists to close stays open silently, and the
  # next sync recomposes the Merge card the captain just answered.
  assert_grep 'could not close backlog item missing-x1' "$case_dir/stderr" \
    "missing-meta-close-fails: a failed close must be reported, not swallowed"
  assert_grep 'IO_ERROR' "$case_dir/stderr" \
    "missing-meta-close-fails: the report must carry the backend's own reason"
  pass "fm-pr-merge reports a failed backlog close without failing the landed merge"
}

# A tasks-axi the shared probe REFUSES, so the close is skipped rather than attempted.
# config/backlog-backend=manual is the captain's documented opt-out (AGENTS.md section 10)
# and reaches the same skip through the same probe; stubbing the tool as well is what makes
# "no close was attempted" a claim about the gate rather than about the tool's absence.
add_manual_backend() {
  local case_dir=$1
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi.log"
case "\${1:-} \${2:-}" in
  "--version "*|"--version") printf '0.2.2\n'; exit 0 ;;
  "update --help") printf 'usage: tasks-axi update <id>\n  --archive-body\n'; exit 0 ;;
  "mv --help") printf 'usage: tasks-axi mv [<id>...] <section>\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# hand_backlog <case_dir> <id> <section> <url>: the shape a manual home actually keeps -
# a captain-held item carrying <url> in the structured link position, written by hand
# rather than by the tool, because under this backend nothing else ever writes it. The
# item is placed under <section>, the heading that decides whether anything is still owed.
hand_backlog() {
  local case_dir=$1 id=$2 section=$3 url=$4 bl in_flight="" done_item=""
  bl="$case_dir/data/backlog.md"
  mkdir -p "$case_dir/data" "$case_dir/config"
  if [ "$section" = Done ]; then
    done_item="- [x] $id - Ship the widget endpoint - $url (merged 2026-07-17)"
  else
    in_flight="- [ ] $id - Ship the widget endpoint $url (repo: alpha) (hold-kind: captain) (hold: review-ready - your call)"
  fi
  printf '# Backlog\n\n## In flight\n\n%s\n\n## Queued\n\n## Done\n\n%s\n' \
    "$in_flight" "$done_item" > "$bl"
}

test_missing_meta_manual_backend_reports_the_skipped_close() {
  local case_dir fakebin rc url=https://github.com/example/repo/pull/31
  case_dir="$TMP_ROOT/missing-meta-manual"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_manual_backend "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/tasks-axi.log"
  hand_backlog "$case_dir" missing-x1 'In flight' "$url"

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-meta-manual: the backlog backend must never fail a landed merge"
  grep -qxF 'pr merge 31 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "missing-meta-manual: the merge itself must still have happened"
  # The opt-out is honored: hand-editing means hand-editing, so nothing writes the backlog.
  assert_no_grep 'done missing-x1' "$case_dir/tasks-axi.log" \
    "missing-meta-manual: the manual backend must make no tasks-axi done call"
  # But the close is still OWED, and no teardown is left to prompt the hand-edit - a missing
  # meta is what says teardown has already run. Skipped in silence, the item stays open and
  # the next sync recomposes the very Merge card the captain just answered.
  assert_grep 'backlog item missing-x1 is still open' "$case_dir/stderr" \
    "missing-meta-manual: a close skipped because the backend is not in use must be reported"
  pass "fm-pr-merge reports the close it cannot perform under config/backlog-backend=manual"
}

test_missing_meta_manual_backend_untracked_id_is_quiet() {
  local case_dir fakebin rc url=https://github.com/example/repo/pull/32
  case_dir="$TMP_ROOT/missing-meta-manual-untracked"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  add_manual_backend "$case_dir"
  : > "$case_dir/gh-axi.log"
  # A real hand-maintained backlog that simply does not carry this id.
  hand_backlog "$case_dir" other-x9 'In flight' https://github.com/example/repo/pull/99

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # Same rule the tasks-axi path reads out of "code: NOT_FOUND", asked of the FILE so the
  # backend that is never consulted can answer it too: no open item means no card can
  # compose from one, so there is nothing to close and nothing to report.
  expect_code 0 "$rc" "missing-meta-manual-untracked: an untracked id must not fail the merge"
  assert_no_grep 'still open' "$case_dir/stderr" \
    "missing-meta-manual-untracked: an id the backlog never carried is not a close to report"
  pass "fm-pr-merge does not report a skipped close for an id a manual backlog never carried"
}

test_missing_meta_manual_backend_done_item_is_quiet() {
  local case_dir fakebin rc url=https://github.com/example/repo/pull/33
  case_dir="$TMP_ROOT/missing-meta-manual-done"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_manual_backend "$case_dir"
  : > "$case_dir/gh-axi.log"
  # Already closed by hand - the captain merged from a card composed before they did.
  hand_backlog "$case_dir" missing-x1 Done "$url"

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # A Done item composes no card at all (fm-logbook-compose.sh returns early on it), so
  # nothing is owed and the warning would be a false alarm.
  expect_code 0 "$rc" "missing-meta-manual-done: an already-closed item must not fail the merge"
  assert_no_grep 'still open' "$case_dir/stderr" \
    "missing-meta-manual-done: an item already in Done is not a close to report"
  pass "fm-pr-merge does not report a skipped close for an item already in Done"
}

test_missing_meta_untracked_id_closes_quietly() {
  local case_dir fakebin rc url=https://github.com/example/repo/pull/30
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "fm-pr-merge untracked-id quiet close (skipped: no tasks-axi on PATH)"
    return 0
  }
  case_dir="$TMP_ROOT/missing-meta-untracked"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"
  # A real backlog that simply does not carry this id.
  seed_backlog "$case_dir" other-x9 https://github.com/example/repo/pull/99

  set +e
  run_pr_merge "$case_dir" missing-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # An id the backlog never carried is nothing to close: no item is left open, so no card
  # can compose from one. Reporting it would send firstmate hunting for a phantom item.
  expect_code 0 "$rc" "missing-meta-untracked: an untracked id must not fail the merge"
  assert_no_grep 'could not close backlog item' "$case_dir/stderr" \
    "missing-meta-untracked: an id the backlog never carried is not a failure to report"
  pass "fm-pr-merge does not report a close for an id the backlog never carried"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_merges_from_the_url_alone
test_missing_meta_closes_the_backlog_item
test_missing_meta_failed_merge_leaves_the_item_open
test_live_meta_leaves_the_close_to_teardown
test_missing_meta_refreshes_the_project_clone
test_live_meta_leaves_the_clone_refresh_to_teardown
test_missing_meta_close_honors_the_homes_tasks_config
test_missing_meta_failed_close_is_reported_not_swallowed
test_missing_meta_manual_backend_reports_the_skipped_close
test_missing_meta_manual_backend_untracked_id_is_quiet
test_missing_meta_manual_backend_done_item_is_quiet
test_missing_meta_untracked_id_closes_quietly
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
