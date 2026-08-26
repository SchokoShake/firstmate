#!/usr/bin/env bash
# Regression tests for the backlog PR-link convention: a task's PR URL lives in
# the item's `pr` field, never in its title, so a later title change cannot
# silently drop the link and the board card cannot lose its PR link and merge
# action.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKLOG_PR="$ROOT/bin/fm-backlog-pr.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-pr)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

PR_A=https://github.com/acme/widget/pull/42
PR_B=https://github.com/acme/widget/pull/77

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_backlog_pr() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$BACKLOG_PR" "$@"
}

# The item line as it sits on disk, which is what the board reads.
item_line() {  # <home> <id>
  grep -F -- "- [ ] $2 - " "$1/data/backlog.md" | head -1
}

recorded_links() {  # <home> <id>
  tasks_in "$1" show "$2" --full | sed -n 's/^  links: //p' | head -1 | tr -d '"'
}

recorded_title() {  # <home> <id>
  tasks_in "$1" show "$2" --full | sed -n 's/^  title: //p' | head -1 | tr -d '"'
}

# One unmistakable line naming the installed release, for a pinned upstream
# behaviour that the installed tasks-axi no longer shows.
upstream_notice() {  # <fact>
  local version
  version=$(tasks-axi --version 2>/dev/null | head -1)
  printf 'notice: tasks-axi %s %s\n' "${version:-<unknown version>}" "$1"
}

# The loss-pin's retirement clause. After a raw `tasks-axi update --title`, the
# installed tasks-axi either still drops a title-embedded link, which is the
# defect this suite measures, or it has started preserving it upstream. In the
# second case the pin no longer applies: say so, and return 0 so the caller
# passes instead of failing with a message that blames the wrong thing.
raw_title_update_now_preserves() {  # <home> <id> <link>
  case "$(recorded_links "$1" "$2")" in
    *"$3"*)
      upstream_notice "preserves links on --title; the loss-pin no longer applies - consider retiring fm-backlog-pr.sh's retitle path"
      return 0
      ;;
  esac
  return 1
}

# The accumulation-pin's retirement clause. Two raw `--pr` calls with different
# URLs leave both on the item in tasks-axi 0.2.5, which is what the owner has to
# normalize. Should upstream start replacing instead, say so and stage the
# two-URL item line by hand, in the persisted board line this suite already
# reads through item_line, so retitle and repair are still measured against a
# real accumulation.
ensure_accumulated_links() {  # <home> <id> <older-url> <newer-url>
  local links
  links=$(recorded_links "$1" "$2")
  case "$links" in
    *"pr:$3"*) ;;
    *)
      upstream_notice "replaces the pr link on --pr; the accumulation-pin no longer applies - the two-link item is staged by hand"
      if ! sed "/^- \\[ \\] $2 - /s# $4# $3 $4#" "$1/data/backlog.md" > "$1/data/backlog.md.tmp" \
        || ! mv "$1/data/backlog.md.tmp" "$1/data/backlog.md"; then
        fail "could not stage the accumulated links by hand"
      fi
      links=$(recorded_links "$1" "$2")
      ;;
  esac
  assert_contains "$links" "pr:$3" "$2 does not carry the older link"
  assert_contains "$links" "pr:$4" "$2 does not carry the newer link"
}

# The defect, stated as the behavior that must not come back: with the URL living
# in the title text, an ordinary title change takes the link with it. This pins
# the loss so the rest of the suite is measuring against a real failure, not a
# hypothetical one.
test_raw_title_update_loses_a_url_written_into_the_title() {
  local home
  home=$(make_home raw-loss)
  tasks_in "$home" add legacy-a1 "ship the widget $PR_A" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the legacy item"
  assert_contains "$(recorded_links "$home" legacy-a1)" "pr:$PR_A" \
    "a URL inside the title is not even read back as a pr link"

  tasks_in "$home" update legacy-a1 --title "ship the widget" >/dev/null \
    || fail "could not retitle the legacy item"
  if raw_title_update_now_preserves "$home" legacy-a1 "pr:$PR_A"; then
    pass "a raw title update no longer drops a title-embedded PR link, so the loss-pin is retired"
    return 0
  fi
  assert_contains "$(recorded_links "$home" legacy-a1)" none \
    "a raw title update neither kept nor dropped the PR link, so this suite is not measuring the real defect"
  assert_no_grep "$PR_A" "$home/data/backlog.md" \
    "a raw title update kept the PR URL on the item line"
  pass "a URL written into a title is silently dropped by an ordinary title update"
}

# record puts the URL in the field and leaves the title a plain sentence.
test_record_keeps_the_url_out_of_the_title() {
  local home out
  home=$(make_home record)
  tasks_in "$home" add ship-b2 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"

  out=$(run_backlog_pr "$home" record ship-b2 "$PR_A") \
    || fail "record failed on a plain item"
  assert_contains "$out" "recorded: ship-b2 pr=$PR_A" "record did not report the link it wrote"
  assert_contains "$(recorded_links "$home" ship-b2)" "pr:$PR_A" "record did not put the URL in the pr field"

  out=$(run_backlog_pr "$home" record ship-b2 "$PR_A") \
    || fail "record was not idempotent"
  assert_contains "$out" "unchanged: ship-b2 pr=$PR_A" "a repeated record rewrote the item"
  assert_contains "$(item_line "$home" ship-b2)" "$PR_A" "the item line lost its PR URL"
  pass "record writes the PR URL through the pr field and repeats idempotently"
}

# The acceptance case: the PR survives a title change made through the owner.
test_retitle_carries_the_pr_link_across_a_title_change() {
  local home out
  home=$(make_home retitle)
  tasks_in "$home" add ship-c3 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-c3 "$PR_A" >/dev/null || fail "record failed"

  out=$(run_backlog_pr "$home" retitle ship-c3 "ship the widget, second pass") \
    || fail "retitle failed"
  assert_contains "$out" "retitled: ship-c3 pr=$PR_A" "retitle did not report the carried link"
  assert_contains "$(recorded_links "$home" ship-c3)" "pr:$PR_A" \
    "the PR link did not survive a title change through the owner"
  assert_contains "$(recorded_title "$home" ship-c3)" "second pass" "the new title was not applied"
  assert_grep "$PR_A" "$home/data/backlog.md" "the item line lost its PR URL across a retitle"
  pass "a title change through the owner carries the recorded PR link with it"
}

# A URL the caller glues onto the new title is the link they meant; it is taken
# as the link rather than left in the title where the next change would drop it.
test_retitle_moves_a_pasted_url_into_the_field() {
  local home
  home=$(make_home retitle-pasted)
  tasks_in "$home" add ship-d4 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-d4 "$PR_A" >/dev/null || fail "record failed"

  run_backlog_pr "$home" retitle ship-d4 "ship the widget again $PR_B" >/dev/null \
    || fail "retitle with a pasted URL failed"
  assert_contains "$(recorded_links "$home" ship-d4)" "pr:$PR_B" \
    "a pasted URL did not become the recorded link"
  assert_not_contains "$(recorded_links "$home" ship-d4)" "pr:$PR_A" \
    "the superseded link was left behind next to the new one"
  pass "a URL pasted into a new title becomes the recorded link, not title text"
}

# A scout's report link lives in the same item line by the same mechanism, so a
# title change through the owner has to carry it the same way: alone, and next
# to the PR link once the scout is promoted and ships.
test_retitle_carries_a_report_link_across_a_title_change() {
  local home out links report=data/scout-l3/report.md
  home=$(make_home retitle-report)
  tasks_in "$home" add scout-l3 "scout the widget" --kind scout --repo widget --start >/dev/null \
    || fail "could not seed the scout item"
  tasks_in "$home" update scout-l3 --report "$report" >/dev/null \
    || fail "could not record the report link"

  out=$(run_backlog_pr "$home" retitle scout-l3 "scout the widget, second pass") \
    || fail "retitle failed on a scout item"
  assert_contains "$out" "retitled: scout-l3 report=$report" \
    "retitle did not report the carried report link"
  assert_contains "$(recorded_links "$home" scout-l3)" "report:$report" \
    "the report link did not survive a title change through the owner"
  assert_contains "$(recorded_title "$home" scout-l3)" "second pass" "the new title was not applied"

  run_backlog_pr "$home" record scout-l3 "$PR_A" >/dev/null || fail "record failed on a scout item"
  out=$(run_backlog_pr "$home" retitle scout-l3 "scout the widget, shipped") \
    || fail "retitle failed once the scout carried both links"
  assert_contains "$out" "retitled: scout-l3 pr=$PR_A report=$report" \
    "retitle did not report both carried links"
  links=$(recorded_links "$home" scout-l3)
  assert_contains "$links" "pr:$PR_A" "the PR link did not survive a title change beside a report link"
  assert_contains "$links" "report:$report" "the report link did not survive a title change beside a PR link"
  pass "a title change through the owner carries a scout's report link, alone and beside a PR link"
}

# Recording a different PR replaces the link instead of accumulating a second
# one, so the board never has to guess which of two URLs is current.
test_record_replaces_rather_than_accumulates() {
  local home links
  home=$(make_home replace)
  tasks_in "$home" add ship-e5 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-e5 "$PR_A" >/dev/null || fail "first record failed"
  run_backlog_pr "$home" record ship-e5 "$PR_B" >/dev/null || fail "second record failed"

  links=$(recorded_links "$home" ship-e5)
  assert_contains "$links" "pr:$PR_B" "the replacement link was not recorded"
  assert_not_contains "$links" "pr:$PR_A" "the superseded link was kept alongside the new one"
  pass "recording a different PR replaces the link instead of accumulating one"
}

# repair is the compatibility read for an item whose link was already lost: the
# task metadata firstmate owns is the durable record it comes back from.
test_repair_restores_a_lost_link_from_task_metadata() {
  local home out
  home=$(make_home repair)
  tasks_in "$home" add ship-f6 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-f6 "$PR_A" >/dev/null || fail "record failed"
  fm_write_meta "$home/state/ship-f6.meta" "kind=ship" "mode=no-mistakes" "pr=$PR_A"

  tasks_in "$home" update ship-f6 --title "ship the widget" >/dev/null \
    || fail "could not simulate the raw title update"
  if raw_title_update_now_preserves "$home" ship-f6 "pr:$PR_A"; then
    # The loss repair exists for must then be staged by hand, in the item line
    # the board reads, so repair is still measured against a real gap.
    if ! sed "s# $PR_A##" "$home/data/backlog.md" > "$home/data/backlog.md.tmp" \
      || ! mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"; then
      fail "could not stage the lost link by hand"
    fi
  fi
  assert_contains "$(recorded_links "$home" ship-f6)" none "the link was not lost before repair ran"

  out=$(run_backlog_pr "$home" repair ship-f6) || fail "repair failed"
  assert_contains "$out" "recorded: ship-f6 pr=$PR_A" "repair did not report the restored link"
  assert_contains "$(recorded_links "$home" ship-f6)" "pr:$PR_A" \
    "repair did not restore the link from the task metadata"
  pass "repair restores a lost backlog link from the task's own durable record"
}

# A merge request pasted into a new title can be stored nowhere but the title
# text, which is exactly where the next title change would drop it, so the
# retitle is refused outright and the item is left as it was.
test_retitle_refuses_a_pasted_merge_request() {
  local home before rc
  home=$(make_home retitle-pasted-mr)
  tasks_in "$home" add ship-r2 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-r2 "$PR_A" >/dev/null || fail "record failed"
  before=$(item_line "$home" ship-r2)

  run_backlog_pr "$home" retitle ship-r2 \
    "ship the widget https://gitlab.com/acme/widget/-/merge_requests/9" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "retitle accepted a merge request pasted into the title"
  [ "$(item_line "$home" ship-r2)" = "$before" ] || fail "the refused retitle still changed the item line"
  assert_no_grep "merge_requests" "$home/data/backlog.md" "the merge request URL reached the backlog"
  assert_contains "$(recorded_links "$home" ship-r2)" "pr:$PR_A" "the refused retitle lost the recorded PR link"
  pass "retitle refuses a pasted merge request rather than storing it as title text"
}

# A home on the default backend whose tasks-axi is unusable is told that, not
# that it opted out.
test_record_reports_an_unusable_tasks_axi_rather_than_an_opt_out() {
  local home out
  home=$(make_home unusable-tasks-axi)
  tasks_in "$home" add ship-s3 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  mkdir -p "$home/nobin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/nobin/tasks-axi"
  chmod +x "$home/nobin/tasks-axi"

  out=$(PATH="$home/nobin:$PATH" run_backlog_pr "$home" record ship-s3 "$PR_A") \
    || fail "record failed with an unusable tasks-axi"
  assert_contains "$out" "skipped: tasks-axi is absent or older than" \
    "record did not name the unusable tasks-axi as the reason"
  assert_not_contains "$out" "does not use tasks-axi" "record reported an opt-out the home never made"
  assert_not_contains "$(item_line "$home" ship-s3)" "$PR_A" "the backlog was written through an unusable tasks-axi"
  pass "record reports an unusable tasks-axi rather than a backend opt-out"
}

# A task tracked on GitLab has a merge request in its meta that tasks-axi cannot
# store, which means there is no PR link to carry, never that the title stays
# as it was.
test_retitle_changes_the_title_of_a_gitlab_task() {
  local home out report=data/ship-m4/report.md
  home=$(make_home retitle-gitlab)
  tasks_in "$home" add ship-m4 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  tasks_in "$home" update ship-m4 --report "$report" >/dev/null || fail "could not record the report link"
  fm_write_meta "$home/state/ship-m4.meta" "kind=ship" "mode=no-mistakes" \
    "pr=https://gitlab.com/acme/widget/-/merge_requests/9"

  out=$(run_backlog_pr "$home" retitle ship-m4 "ship the widget, second pass") \
    || fail "retitle failed on a GitLab task"
  assert_not_contains "$out" "skipped:" "retitle skipped a GitLab task instead of changing its title"
  assert_contains "$out" "retitled: ship-m4 report=$report" "retitle did not report the carried report link"
  assert_contains "$(recorded_title "$home" ship-m4)" "second pass" \
    "the new title was not applied to a GitLab task"
  assert_contains "$(recorded_links "$home" ship-m4)" "report:$report" \
    "the report link did not survive retitling a GitLab task"
  assert_no_grep "merge_requests" "$home/data/backlog.md" \
    "the merge request URL was written into the backlog"
  pass "retitle changes the title of a GitLab task and keeps its other links"
}

# An item that accumulated two PR links outside the owner must settle on the
# same URL whichever subcommand touches it next: the one firstmate itself
# recorded when there is one, else the newest of the two, never the stale one.
test_accumulated_links_normalize_the_same_way_through_retitle_and_repair() {
  local home id links
  home=$(make_home accumulated)
  for id in ship-n5 ship-n6 ship-n7 ship-n8; do
    tasks_in "$home" add "$id" "ship the widget" --kind ship --repo widget --start >/dev/null \
      || fail "could not seed $id"
    tasks_in "$home" update "$id" --pr "$PR_A" >/dev/null || fail "could not record the first link on $id"
    tasks_in "$home" update "$id" --pr "$PR_B" >/dev/null || fail "could not record the second link on $id"
    ensure_accumulated_links "$home" "$id" "$PR_A" "$PR_B"
  done
  fm_write_meta "$home/state/ship-n5.meta" "kind=ship" "mode=no-mistakes" "pr=$PR_B"
  fm_write_meta "$home/state/ship-n6.meta" "kind=ship" "mode=no-mistakes" "pr=$PR_B"

  run_backlog_pr "$home" retitle ship-n5 "ship the widget, revised" >/dev/null || fail "retitle failed"
  run_backlog_pr "$home" repair ship-n6 >/dev/null || fail "repair failed"
  run_backlog_pr "$home" retitle ship-n7 "ship the widget, revised" >/dev/null \
    || fail "retitle failed without task metadata"
  run_backlog_pr "$home" repair ship-n8 >/dev/null || fail "repair failed without task metadata"
  for id in ship-n5 ship-n6 ship-n7 ship-n8; do
    links=$(recorded_links "$home" "$id")
    assert_contains "$links" "pr:$PR_B" "$id did not settle on the current link"
    assert_not_contains "$links" "pr:$PR_A" "$id kept the stale accumulated link"
  done
  pass "an item with accumulated PR links settles on the recorded or newest one through retitle and repair alike"
}

# A recorded merge request tasks-axi cannot store does not mean the item's own
# GitHub link may be dropped: the title changes and that link is carried.
test_retitle_keeps_an_item_link_when_the_recorded_url_is_unstorable() {
  local home out
  home=$(make_home retitle-unstorable-meta)
  tasks_in "$home" add ship-p9 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-p9 "$PR_A" >/dev/null || fail "record failed"
  fm_write_meta "$home/state/ship-p9.meta" "kind=ship" "mode=no-mistakes" \
    "pr=https://gitlab.com/acme/widget/-/merge_requests/9"

  out=$(run_backlog_pr "$home" retitle ship-p9 "ship the widget, second pass") || fail "retitle failed"
  assert_contains "$out" "retitled: ship-p9 pr=$PR_A" "retitle did not report the carried item link"
  assert_contains "$(recorded_links "$home" ship-p9)" "pr:$PR_A" \
    "the item's own PR link was dropped because the recorded URL was unstorable"
  assert_contains "$(recorded_title "$home" ship-p9)" "second pass" "the new title was not applied"
  pass "retitle carries the item's own PR link when the recorded URL cannot be stored"
}

# A home that never uses tasks-axi is told about its own opt-out, not about a
# tasks-axi field limitation it will never meet.
test_record_reports_the_backend_opt_out_before_the_field_limit() {
  local home out
  home=$(make_home manual-backend)
  printf 'manual\n' > "$home/config/backlog-backend"
  tasks_in "$home" add ship-q1 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  out=$(run_backlog_pr "$home" record ship-q1 "https://gitlab.com/acme/widget/-/merge_requests/9") \
    || fail "record failed on a manual-backend home"
  assert_contains "$out" "skipped: this home does not use tasks-axi" \
    "record did not name the backend opt-out as the reason"
  assert_not_contains "$out" "stores only" "record named a tasks-axi limitation on a home that opted out"
  pass "record reports the backend opt-out rather than a tasks-axi field limitation"
}

test_repair_is_quiet_when_nothing_is_recorded() {
  local home out
  home=$(make_home repair-empty)
  tasks_in "$home" add ship-g7 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  out=$(run_backlog_pr "$home" repair ship-g7) || fail "repair failed on an item with no PR"
  assert_contains "$out" "skipped: no PR URL is recorded for ship-g7" \
    "repair did not report that there was nothing to restore"
  pass "repair reports, rather than invents, a missing PR link"
}

# A merge request cannot be stored in the field at all, so it is reported instead
# of being written into the title, which is the loss this owner exists to prevent.
test_a_merge_request_is_reported_not_written_into_the_title() {
  local home out
  home=$(make_home gitlab)
  tasks_in "$home" add ship-h8 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  out=$(run_backlog_pr "$home" record ship-h8 "https://gitlab.com/acme/widget/-/merge_requests/9") \
    || fail "recording a merge request was treated as an error"
  assert_contains "$out" "skipped:" "a merge request was not reported as unstorable"
  assert_no_grep "merge_requests" "$home/data/backlog.md" \
    "a merge request URL was written into the backlog title"
  pass "a merge request is reported as unstorable rather than glued into a title"
}

test_a_task_outside_the_backlog_is_skipped_not_failed() {
  local home out
  home=$(make_home absent)
  out=$(run_backlog_pr "$home" record ship-i9 "$PR_A") \
    || fail "a task outside the backlog was treated as an error"
  assert_contains "$out" "skipped: ship-i9 is not an item in this home's backlog" \
    "an absent item was not reported as skipped"
  pass "a task firstmate tracks outside the backlog is skipped, not failed"
}

test_a_flag_shaped_task_id_is_refused() {
  local home rc
  home=$(make_home flag-id)
  run_backlog_pr "$home" record "--full" "$PR_A" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a flag-shaped task id was accepted"
  pass "a task id that looks like a flag is refused before it reaches tasks-axi"
}

test_an_invalid_url_is_refused() {
  local home rc
  home=$(make_home invalid)
  tasks_in "$home" add ship-j1 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  run_backlog_pr "$home" record ship-j1 "not-a-url" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid URL was accepted"
  assert_no_grep "not-a-url" "$home/data/backlog.md" "an invalid URL reached the backlog"
  pass "an invalid PR URL is refused before anything is written"
}

# The convention has to hold on the path firstmate actually takes when a PR
# becomes ready, not only when the owner is called by hand.
test_pr_check_records_the_backlog_link() {
  local home out
  home=$(make_home pr-check)
  tasks_in "$home" add ship-k2 "ship the widget" --kind ship --repo widget --start >/dev/null \
    || fail "could not seed the item"
  fm_write_meta "$home/state/ship-k2.meta" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$home/state/ship-k2.meta"

  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_GUARD_LOG="$home/guard.log" "$PR_CHECK" ship-k2 "$PR_A" 2>&1) \
    || fail "fm-pr-check failed"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "armed:" "fm-pr-check did not arm the merge poll"
  assert_grep "pr=$PR_A" "$home/state/ship-k2.meta" "fm-pr-check did not record the durable pr="
  assert_contains "$(recorded_links "$home" ship-k2)" "pr:$PR_A" \
    "fm-pr-check did not record the backlog PR link"

  # And the link then survives the title change that used to wipe it.
  run_backlog_pr "$home" retitle ship-k2 "ship the widget, revised" >/dev/null \
    || fail "retitle failed after fm-pr-check"
  assert_contains "$(recorded_links "$home" ship-k2)" "pr:$PR_A" \
    "the link fm-pr-check recorded did not survive a title change"
  pass "fm-pr-check records the backlog PR link and it survives a later title change"
}

test_raw_title_update_loses_a_url_written_into_the_title
test_record_keeps_the_url_out_of_the_title
test_retitle_carries_the_pr_link_across_a_title_change
test_retitle_moves_a_pasted_url_into_the_field
test_retitle_carries_a_report_link_across_a_title_change
test_retitle_refuses_a_pasted_merge_request
test_record_replaces_rather_than_accumulates
test_repair_restores_a_lost_link_from_task_metadata
test_retitle_changes_the_title_of_a_gitlab_task
test_accumulated_links_normalize_the_same_way_through_retitle_and_repair
test_retitle_keeps_an_item_link_when_the_recorded_url_is_unstorable
test_record_reports_the_backend_opt_out_before_the_field_limit
test_record_reports_an_unusable_tasks_axi_rather_than_an_opt_out
test_repair_is_quiet_when_nothing_is_recorded
test_a_merge_request_is_reported_not_written_into_the_title
test_a_task_outside_the_backlog_is_skipped_not_failed
test_a_flag_shaped_task_id_is_refused
test_an_invalid_url_is_refused
test_pr_check_records_the_backlog_link
