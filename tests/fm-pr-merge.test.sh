#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) the +captain-merge refusal holds on both signals, both merge paths, and on
#       the url and origin shapes tests/fixtures/pr-slug/ pins the slug parse for
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

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
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

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
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

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
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
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- +captain-merge merge policy ------------------------------------------------
#
# Some projects are the captain's to merge and no one else's. The refusal, not a
# missing button on some surface, is what makes that rule hold, so it is pinned here
# on both of firstmate's merge paths and on both of its independent signals.

# A home whose registry declares <project> with <flags>, plus a clone of <project>
# whose origin is <origin-url> so the URL signal has something to trace to.
make_policy_home() {  # <case-dir> <project> <bracket-or-empty> <origin-url>
  local case_dir=$1 project=$2 bracket=$3 origin=$4 home
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects/$project"
  if [ -n "$bracket" ]; then
    printf -- '- %s [%s] - a project (added 2026-01-01)\n' "$project" "$bracket" > "$home/data/projects.md"
  else
    printf -- '- %s - a project (added 2026-01-01)\n' "$project" > "$home/data/projects.md"
  fi
  git init -q "$home/projects/$project"
  git -C "$home/projects/$project" remote add origin "$origin"
  printf '%s\n' "$home"
}

run_pr_merge_in_home() {  # <case-dir> <home> <args...>
  local case_dir=$1 home=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_captain_merge_refused_from_the_tasks_own_record() {
  local case_dir home out rc
  case_dir=$(make_case captain-merge-signal1)
  add_gh_mocks "$case_dir" deadbeef
  home=$(make_policy_home "$case_dir" guarded "direct-PR +captain-merge" https://github.com/acme/guarded.git)
  # The task records the flagged project; the URL names an unrelated repo, so ONLY
  # signal 1 can decide.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/guarded" \
    "kind=ship" "mode=direct-PR"

  set +e
  out=$(run_pr_merge_in_home "$case_dir" "$home" task-x1 https://github.com/other/repo/pull/7 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "signal1: a +captain-merge project must not be merged"
  assert_contains "$out" "+captain-merge" "signal1: refusal did not name the policy"
  # BEFORE the recording step: a refused merge must leave no trace of being half-done.
  assert_no_grep "pr=" "$case_dir/state/task-x1.meta" "signal1: refused merge still recorded pr="
  [ ! -s "$case_dir/gh-axi.log" ] || fail "signal1: refused merge still called gh-axi: $(cat "$case_dir/gh-axi.log")"
  pass "a +captain-merge project is refused from the task's own record, before recording"
}

test_captain_merge_refused_from_the_pr_url_alone() {
  local case_dir home out rc
  case_dir=$(make_case captain-merge-signal2)
  add_gh_mocks "$case_dir" deadbeef
  home=$(make_policy_home "$case_dir" guarded "direct-PR +captain-merge" https://github.com/acme/guarded.git)
  # The task records an UNFLAGGED project, so signal 1 permits; only the URL, traced to
  # the flagged clone's own origin, can refuse. This is the backstop that survives
  # bookkeeping a hand-typed or mistaken request names wrongly.
  mkdir -p "$home/projects/loose"
  printf -- '- loose - unflagged (added 2026-01-01)\n' >> "$home/data/projects.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/loose" \
    "kind=ship" "mode=direct-PR"

  set +e
  out=$(run_pr_merge_in_home "$case_dir" "$home" task-x1 https://github.com/acme/guarded/pull/7 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "signal2: a PR whose repo is a flagged clone's origin must not be merged"
  assert_contains "$out" "guarded" "signal2: refusal did not name the project the url traced to"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "signal2: refused merge still called gh-axi"
  pass "a PR traced to a +captain-merge clone's origin is refused even when the task records another project"
}

test_unflagged_project_still_merges() {
  local case_dir home rc
  case_dir=$(make_case captain-merge-default-permissive)
  add_gh_mocks "$case_dir" deadbeef
  home=$(make_policy_home "$case_dir" loose "direct-PR" https://github.com/acme/loose.git)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/loose" \
    "kind=ship" "mode=direct-PR"

  set +e
  run_pr_merge_in_home "$case_dir" "$home" task-x1 https://github.com/acme/loose/pull/7 >/dev/null 2>&1
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "default-permissive: an unflagged project must merge exactly as before"
  assert_grep "pr merge 7" "$case_dir/gh-axi.log" "default-permissive: gh-axi merge was not called"
  pass "a project without the flag is exactly as mergeable as it was before the flag existed"
}

# The two slug tolerances that only matter END TO END. tests/fixtures/pr-slug/
# pins what fm_merge_slug answers for these shapes; what matters here is that the
# answer still reaches a REFUSAL through the real merge path, because that is the
# property a narrowing of the parse would silently take away. Only forms
# bin/fm-pr-lib.sh's fm_pr_url_parse actually admits can be pinned this way: a
# trailing-slash url is rejected before the guard is ever consulted, so it lives
# in the fixture and in the composition assertion beside it, not here.

test_captain_merge_refused_when_the_url_carries_a_git_component() {
  local case_dir home out rc
  case_dir=$(make_case captain-merge-url-dot-git)
  add_gh_mocks "$case_dir" deadbeef
  home=$(make_policy_home "$case_dir" guarded "direct-PR +captain-merge" https://github.com/acme/guarded.git)
  # fm_pr_url_parse accepts a ".git" repo component and would hand "acme/guarded.git"
  # straight to gh-axi. The task records an unflagged project, so ONLY the url can
  # refuse - and it can only refuse if the ".git" it carries is normalized away
  # before the clone origin is compared.
  mkdir -p "$home/projects/loose"
  printf -- '- loose - unflagged (added 2026-01-01)\n' >> "$home/data/projects.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/loose" \
    "kind=ship" "mode=direct-PR"

  set +e
  out=$(run_pr_merge_in_home "$case_dir" "$home" task-x1 https://github.com/acme/guarded.git/pull/7 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "url-dot-git: a .git url component must not carry a merge past the guard"
  assert_contains "$out" "guarded" "url-dot-git: refusal did not name the project the url traced to"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "url-dot-git: refused merge still called gh-axi"
  pass "a PR url naming its repo with a .git suffix is still traced to the flagged clone and refused"
}

test_captain_merge_refused_when_the_origin_ends_dot_git_slash() {
  local case_dir home out rc
  case_dir=$(make_case captain-merge-origin-dot-git-slash)
  add_gh_mocks "$case_dir" deadbeef
  # What "git clone https://github.com/acme/guarded.git/" records verbatim. The
  # trailing "/" has to come off before the ".git" behind it, or this clone resolves
  # to the repo "guarded.git", claims nothing, and its merge is permitted.
  home=$(make_policy_home "$case_dir" guarded "direct-PR +captain-merge" https://github.com/acme/guarded.git/)
  mkdir -p "$home/projects/loose"
  printf -- '- loose - unflagged (added 2026-01-01)\n' >> "$home/data/projects.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/loose" \
    "kind=ship" "mode=direct-PR"

  set +e
  out=$(run_pr_merge_in_home "$case_dir" "$home" task-x1 https://github.com/acme/guarded/pull/7 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "origin-dot-git-slash: a clone whose origin ends .git/ must still claim its PRs"
  assert_contains "$out" "guarded" "origin-dot-git-slash: refusal did not name the project the url traced to"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "origin-dot-git-slash: refused merge still called gh-axi"
  pass "a clone whose origin ends \".git/\" is still traced to by its PR url and its merge refused"
}

test_captain_merge_refuses_the_local_merge_too() {
  local case_dir home out rc
  case_dir=$(make_case captain-merge-local)
  home=$(make_policy_home "$case_dir" guarded "local-only +captain-merge" https://github.com/acme/guarded.git)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$home/projects/guarded" \
    "kind=ship" "mode=local-only"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$ROOT/bin/fm-merge-local.sh" task-x1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "local-merge: a +captain-merge project must not be merged locally either"
  assert_contains "$out" "+captain-merge" "local-merge: refusal did not name the policy"
  pass "the prohibition holds on firstmate's local-only merge path as well as its PR path"
}


test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_captain_merge_refused_from_the_tasks_own_record
test_captain_merge_refused_from_the_pr_url_alone
test_unflagged_project_still_merges
test_captain_merge_refused_when_the_url_carries_a_git_component
test_captain_merge_refused_when_the_origin_ends_dot_git_slash
test_captain_merge_refuses_the_local_merge_too
