#!/usr/bin/env bash
# Behavior tests for bin/fm-stack-check.sh: only PRs that GitHub itself reports
# as one native stack, in the given order and with chained bases, are proven.
# A stubbed gh serves pull request JSON fixtures and applies the checker's own
# --jq program to them with the real jq, so the program under test is exercised.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the gh stub applies the checker's --jq program with it)"; exit 0; }

CHECK="$ROOT/bin/fm-stack-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-stack-check)
U=https://github.com/o/r/pull

make_case() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/pulls"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
[ "$1" = api ] || exit 1
shift
path= jq_program= version=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) version=$2; shift 2 ;;
    --jq) jq_program=$2; shift 2 ;;
    *) path=$1; shift ;;
  esac
done
[ "$version" = "X-GitHub-Api-Version: 2026-03-10" ] || exit 1
number=${path##*/}
[ -f "$FM_TEST_PULLS/$number.json" ] || { echo "HTTP 404" >&2; exit 1; }
jq -r "$jq_program" "$FM_TEST_PULLS/$number.json"
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

# pull <case-dir> <number> <base> <head> <merged> [<stack#> <position> <size> <stack-base>]
pull() {
  local dir=$1 number=$2 base=$3 head=$4 merged=$5 stack=null
  if [ "$#" -ge 9 ]; then
    stack=$(printf '{"id":9%s,"number":%s,"position":%s,"size":%s,"base":{"ref":"%s","sha":null}}' \
      "$6" "$6" "$7" "$8" "$9")
  fi
  printf '{"number":%s,"merged":%s,"base":{"ref":"%s"},"head":{"ref":"%s"},"stack":%s}\n' \
    "$number" "$merged" "$base" "$head" "$stack" > "$dir/pulls/$number.json"
}

run_check() {
  local dir=$1
  shift
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_PULLS="$dir/pulls" PATH="$dir/fakebin:$PATH" \
    "$CHECK" "$@" > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
}

error_count() {
  grep -c '^error: ' "$1/stderr" || true
}

# Three open PRs GitHub reports as stack #50 on main, bottom to top.
native_stack() {
  local dir=$1
  pull "$dir" 10 main feat/one false 50 1 3 main
  pull "$dir" 11 feat/one feat/two false 50 2 3 main
  pull "$dir" 12 feat/two feat/three false 50 3 3 main
}

test_native_stack_is_proven() {
  local dir
  dir=$(make_case proven)
  native_stack "$dir"
  run_check "$dir" "$U/10" "$U/11" "$U/12"
  expect_code 0 "$RC" "a native stack in order"
  [ "$(cat "$dir/stdout")" = "stack ok: #50 base=main size=3: $U/10 $U/11 $U/12" ] \
    || fail "the proof line was not the one-line stack summary: $(cat "$dir/stdout")"
  [ ! -s "$dir/stderr" ] || fail "a proven stack wrote diagnostics: $(cat "$dir/stderr")"
  [ "$(wc -l < "$dir/gh.log")" -eq 3 ] || fail "the checker did not read every PR exactly once"
  pass "fm-stack-check: PRs GitHub reports as one stack in order are proven"
}

test_chained_bases_without_a_stack_are_refused() {
  local dir
  dir=$(make_case chained)
  pull "$dir" 10 main feat/one false
  pull "$dir" 11 feat/one feat/two false
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "chained bases with no stack"
  assert_grep "error: $U/10 (given position 1 of 2): GitHub reports no stack for this PR" "$dir/stderr" \
    "the bottom PR was not named as outside any stack"
  assert_grep "error: $U/11 (given position 2 of 2): GitHub reports no stack for this PR" "$dir/stderr" \
    "the top PR was not named as outside any stack"
  # Correctly chained bases are not a problem of their own; an empty stack
  # field must not shift the base fields into the wrong place either.
  [ "$(error_count "$dir")" -eq 2 ] || fail "chained bases reported more than the missing stack: $(cat "$dir/stderr")"
  assert_grep "not proven:" "$dir/stderr" "no closing summary for an unproven stack"
  [ ! -s "$dir/stdout" ] || fail "an unproven stack printed a proof line"
  pass "fm-stack-check: bases that merely chain, with no GitHub stack, are refused"
}

test_order_and_membership_problems_name_the_pr() {
  local dir
  dir=$(make_case reordered)
  native_stack "$dir"
  run_check "$dir" "$U/10" "$U/12" "$U/11"
  expect_code 1 "$RC" "a stack given out of order"
  assert_grep "error: $U/12 (given position 2 of 3): GitHub places it at position 3 of stack #50" "$dir/stderr" \
    "a PR out of place was not named with its real position"
  assert_grep "error: $U/11 (given position 3 of 3): GitHub places it at position 2 of stack #50" "$dir/stderr" \
    "the swapped PR was not named with its real position"
  assert_no_grep "$U/10 (given" "$dir/stderr" "the PR that was in place was reported"

  dir=$(make_case missing-layer)
  native_stack "$dir"
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "a stack with its top layer left off"
  assert_grep "error: $U/10 (given position 1 of 2): stack #50 holds 3 PRs, but 2 were given" "$dir/stderr" \
    "a missing layer was not reported against the stack size"

  dir=$(make_case two-stacks)
  pull "$dir" 10 main feat/one false 50 1 2 main
  pull "$dir" 11 feat/one feat/two false 51 2 2 main
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "PRs from two different stacks"
  assert_grep "error: $U/11 (given position 2 of 2): in stack #51, but $U/10 is in stack #50" "$dir/stderr" \
    "a PR in another stack was not named"

  dir=$(make_case one-outside)
  pull "$dir" 10 main feat/one false 50 1 2 main
  pull "$dir" 11 feat/one feat/two false
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "a stack whose top PR is not in it"
  assert_grep "error: $U/11 (given position 2 of 2): GitHub reports no stack for this PR" "$dir/stderr" \
    "the one PR outside the stack was not named"
  [ "$(error_count "$dir")" -eq 1 ] || fail "only the PR outside the stack should be reported: $(cat "$dir/stderr")"
  pass "fm-stack-check: out-of-order, missing, and foreign PRs are each named"
}

test_bases_must_chain_inside_the_stack() {
  local dir
  dir=$(make_case middle-base)
  native_stack "$dir"
  pull "$dir" 11 main feat/two false 50 2 3 main
  run_check "$dir" "$U/10" "$U/11" "$U/12"
  expect_code 1 "$RC" "a mid-stack PR targeting the trunk"
  assert_grep "error: $U/11 (given position 2 of 3): targets 'main', not 'feat/one', the branch of $U/10 below it" \
    "$dir/stderr" "a mid-stack PR on the wrong base was not named"
  [ "$(error_count "$dir")" -eq 1 ] || fail "only the misbased PR should be reported: $(cat "$dir/stderr")"

  dir=$(make_case bottom-base)
  native_stack "$dir"
  pull "$dir" 10 develop feat/one false 50 1 3 main
  run_check "$dir" "$U/10" "$U/11" "$U/12"
  expect_code 1 "$RC" "a bottom PR off the stack base"
  assert_grep "error: $U/10 (given position 1 of 3): targets 'develop', not the stack base 'main'" "$dir/stderr" \
    "a bottom PR off the stack base was not named"
  pass "fm-stack-check: each PR must target the branch below it, and the bottom the stack base"
}

test_merged_lower_layers_retarget_to_the_stack_base() {
  local dir
  dir=$(make_case merged-bottom)
  pull "$dir" 10 main feat/one true 50 1 2 main
  pull "$dir" 11 main feat/two false 50 2 2 main
  run_check "$dir" "$U/10" "$U/11"
  expect_code 0 "$RC" "an open PR retargeted onto the stack base after the PR below merged"

  # The allowance belongs only above a merged PR.
  dir=$(make_case unmerged-bottom)
  pull "$dir" 10 main feat/one false 50 1 2 main
  pull "$dir" 11 main feat/two false 50 2 2 main
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "a PR on the stack base above an unmerged PR"
  assert_grep "error: $U/11 (given position 2 of 2): targets 'main', not 'feat/one'" "$dir/stderr" \
    "a PR skipping an unmerged layer below it was accepted"
  pass "fm-stack-check: only a merged lower layer lets the PR above target the stack base"
}

test_unreadable_pr_is_not_proven() {
  local dir
  dir=$(make_case unreadable)
  pull "$dir" 10 main feat/one false 50 1 2 main
  run_check "$dir" "$U/10" "$U/11"
  expect_code 1 "$RC" "a PR GitHub could not return"
  assert_grep "error: $U/11 (given position 2 of 2): could not read the PR from GitHub" "$dir/stderr" \
    "an unreadable PR was not named"
  pass "fm-stack-check: a PR that cannot be read from GitHub is never proven"
}

test_usage_errors_make_no_github_call() {
  local dir
  dir=$(make_case usage)
  native_stack "$dir"

  run_check "$dir" "$U/10"
  expect_code 2 "$RC" "a single PR"
  assert_grep "at least two PR URLs" "$dir/stderr" "a single PR was not refused as too few for a stack"

  run_check "$dir" "$U/10" https://gitlab.com/g/p/-/merge_requests/11
  expect_code 2 "$RC" "a GitLab merge request"

  run_check "$dir" "$U/10" "$U/11 "
  expect_code 2 "$RC" "a malformed URL"

  run_check "$dir" "$U/10" https://github.com/o/other/pull/11
  expect_code 2 "$RC" "PRs from two repositories"
  assert_grep "must be in one repository" "$dir/stderr" "a cross-repository chain was not refused"

  [ ! -s "$dir/gh.log" ] || fail "a usage error still called gh"
  pass "fm-stack-check: too few, non-GitHub, malformed, or cross-repository URLs stop before GitHub"
}

set -e
test_native_stack_is_proven
test_chained_bases_without_a_stack_are_refused
test_order_and_membership_problems_name_the_pr
test_bases_must_chain_inside_the_stack
test_merged_lower_layers_retarget_to_the_stack_base
test_unreadable_pr_is_not_proven
test_usage_errors_make_no_github_call
