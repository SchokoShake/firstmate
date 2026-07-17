#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh: the PR-ready record. It arms the watcher's merge poll
# and writes the PR down TWICE, because the two records outlive each other by design -
# state/<id>.meta dies with the crew at teardown, while the backlog is firstmate's
# durable record (AGENTS.md sections 7 and 10). The durable half is what the logbook
# board reads a torn-down, captain-held task's PR from, which is exactly the moment the
# meta no longer exists.
#
# The recording case drives the REAL tasks-axi (the same precedent as
# tests/fm-backlog-handoff.test.sh, and why CI installs it), because only the real tool
# can prove the url lands in the structured link position compose actually harvests. A
# test that hand-writes that url into a backlog fixture proves nothing about whether
# firstmate ever writes it. The gating cases use stubs, since asserting "no call was
# made" and simulating an incompatible version need one.
#
# Matrix:
#   (a) the default backend records the PR on the backlog item AND in the meta, and arms
#   (b) that durable record alone still composes a Merge card after the crew is gone
#   (c) config/backlog-backend=manual makes no tasks-axi call, and still arms - reporting
#       the record it skips, but only for an item that is actually there and still open,
#       since neither an untracked nor an already-Done item leaves a card to lose a PR
#   (d) an incompatible tasks-axi makes no update call, and still arms
#   (e) tasks-axi absent from PATH is non-fatal, and still arms
#   (f) a task the backlog has not caught up to is non-fatal, still arms, and stays quiet
#   (g) a record that fails for any OTHER reason is reported rather than swallowed, and
#       still never fails the arm
#   (h) re-arming the same PR does not record it twice
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The real jq and git, wherever they are installed: compose (case b) needs both.
for tool in jq git; do
  d=$(command -v "$tool" 2>/dev/null) && BASE_PATH="$(dirname "$d"):$BASE_PATH"
done
# The real tasks-axi, which cases (a), (b), (f), and (g) delegate to for real.
TASKS_AXI_DIR=""
if d=$(command -v tasks-axi 2>/dev/null); then
  TASKS_AXI_DIR=$(dirname "$d")
  BASE_PATH="$TASKS_AXI_DIR:$BASE_PATH"
fi

# make_home <name> [id]: a firstmate home with a real tasks-axi backlog holding one
# in-flight task and a live crew meta for it. Echoes the home path.
make_home() {
  local name=$1 id=${2:-ship-a1} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  # This repo's own root .tasks.toml shape, which is the only one tasks-axi reads: a
  # top-level backend key plus a [markdown] table with archive (not archive_path). In any
  # other shape the file parses as nothing, the tool silently falls back to its defaults,
  # and the fixture home configures none of what it appears to.
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  if [ -n "$TASKS_AXI_DIR" ]; then
    PATH="$BASE_PATH" tasks-axi add "$id" "Ship the widget endpoint" \
      --kind ship --repo alpha --start --file "$home/data/backlog.md" >/dev/null 2>&1
  fi
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt" \
    "project=$home/projects/alpha" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$home"
}

# make_tasks_axi_stub <home> <version>: a tasks-axi that logs every invocation to
# $home/tasks-axi.log and answers the shared compatibility probe
# (fm-tasks-axi-lib.sh) with <version> plus the --archive-body / [<id>...] help
# markers it greps for. Shadowing the real tool on PATH is the only way to assert that
# a call was NOT made, or to present a version this repo treats as incompatible.
make_tasks_axi_stub() {
  local home=$1 version=$2 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/tasks-axi.log"
case "\${1:-}" in
  --version|-v|-V) printf '%s\n' 'tasks-axi $version'; exit 0 ;;
  update) case " \$* " in *--help*) printf '%s\n' '  --archive-body   archive the previous body'; exit 0 ;; esac ;;
  mv) case " \$* " in *--help*) printf '%s\n' 'usage: tasks-axi mv [<id>...] --to <path>'; exit 0 ;; esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

# hand_backlog <home> <id> <section>: the shape a manual home actually keeps - an item
# written by hand rather than by the tool, because under that backend nothing else ever
# writes it. <section> is the heading it sits under, which is what decides whether a
# record this script cannot make is still owed.
hand_backlog() {
  local home=$1 id=$2 section=$3 bl in_flight="" done_item=""
  bl="$home/data/backlog.md"
  mkdir -p "$home/data"
  if [ "$section" = Done ]; then
    done_item="- [x] $id - Ship the widget endpoint - https://github.com/acme/alpha/pull/42 (merged 2026-07-17)"
  else
    in_flight="- [ ] $id - Ship the widget endpoint (repo: alpha) (hold-kind: captain) (hold: review-ready - your call)"
  fi
  printf '# Backlog\n\n## In flight\n\n%s\n\n## Queued\n\n## Done\n\n%s\n' \
    "$in_flight" "$done_item" > "$bl"
}

# The task's own PR, in the repo its project pushes to - so nothing but the presence of
# the record can decide whether the board offers a Merge for it.
URL=https://github.com/acme/alpha/pull/42

test_records_the_pr_on_the_durable_backlog() {
  local home out
  home=$(make_home records)
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1) \
    || fail "fm-pr-check must succeed on the default backend"$'\n'"$out"
  # THE producer. Without this the logbook board's headline capability - a review-ready
  # Merge card that outlives its crew - has nothing feeding it, because the only other
  # record (the meta) is deleted by teardown at exactly that moment.
  assert_grep "ship-a1 - Ship the widget endpoint $URL" "$home/data/backlog.md" \
    "fm-pr-check must record the PR on the backlog item, in the structured link position"
  # The live-crew half still happens, unchanged.
  assert_grep "pr=$URL" "$home/state/ship-a1.meta" \
    "fm-pr-check must still record pr= in the live crew's meta"
  # And the actual job of the script.
  assert_present "$home/state/ship-a1.check.sh" "fm-pr-check must arm the merge poll"
  pass "fm-pr-check records the PR on the durable backlog as well as the crew's meta"
}

test_the_durable_record_survives_the_crew() {
  local home out
  home=$(make_home survives)
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1) \
    || fail "fm-pr-check must succeed on the default backend"$'\n'"$out"
  # The documented review-ready end-state (AGENTS.md section 7): the crew finished, so
  # fm-teardown removed its meta AND status, and the task sits on a captain hold. The
  # ONLY surviving record of the PR is the one fm-pr-check just wrote to the backlog.
  rm -f "$home/state/ship-a1.meta" "$home/state/ship-a1.status" "$home/state/ship-a1.check.sh"
  PATH="$BASE_PATH" tasks-axi hold ship-a1 --reason 'review-ready - your call' --kind captain \
    --file "$home/data/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: tasks-axi hold must succeed"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
EOF
  git init -q "$home/projects/alpha"
  git -C "$home/projects/alpha" remote add origin https://github.com/acme/alpha.git
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 "$ROOT/bin/fm-logbook-compose.sh") \
    || fail "compose must succeed"
  # The payoff, end to end and with nothing hand-written: what fm-pr-check wrote is what
  # the board reads back as a one-click Merge, long after the crew is gone.
  printf '%s' "$out" | jq -e --arg url "$URL" '.items[] | select(.id=="ship-a1")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)
      and (.source.pr==$url)' >/dev/null \
    || fail "fm-pr-check's backlog record must compose a Merge card after teardown"$'\n'"$out"
  pass "fm-pr-check's durable record still composes a Merge card once the crew is torn down"
}

test_manual_backend_does_not_touch_the_backlog() {
  local home fakebin out
  home=$(make_home manual)
  fakebin=$(make_tasks_axi_stub "$home" 0.2.2)
  # Pre-create the log so "no update call" is a claim about its CONTENT. An absent file
  # would satisfy the assertion for the wrong reason - including if the stub were never
  # on PATH at all - and quietly stop testing anything.
  : > "$home/tasks-axi.log"
  # config/backlog-backend=manual is the captain's opt-out: routine backlog updates are
  # hand-edited (AGENTS.md section 10). Reusing the shared probe is what keeps this
  # honest, so assert the opt-out actually reaches the tool.
  printf 'manual\n' > "$home/config/backlog-backend"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1) \
    || fail "fm-pr-check must succeed under the manual backend"$'\n'"$out"
  assert_no_grep 'update ship-a1' "$home/tasks-axi.log" \
    "the manual backend must make no tasks-axi update call"
  assert_no_grep "$URL" "$home/data/backlog.md" \
    "the manual backend must leave the backlog item untouched"
  assert_present "$home/state/ship-a1.check.sh" \
    "the manual backend must not stop fm-pr-check arming the merge poll"
  pass "fm-pr-check leaves the backlog alone under config/backlog-backend=manual"
}

test_manual_backend_reports_the_skipped_record() {
  local home fakebin out rc
  home=$(make_home manual-reports)
  fakebin=$(make_tasks_axi_stub "$home" 0.2.2)
  printf 'manual\n' > "$home/config/backlog-backend"

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "the manual backend must not fail fm-pr-check"
  assert_present "$home/state/ship-a1.check.sh" \
    "reporting the skipped record must not stop fm-pr-check arming the merge poll"
  # Skipping the write is correct here - the captain opted out of the tool. Skipping it in
  # SILENCE is not: nothing else records an open item's PR under this backend (teardown's
  # reminder prompts the Done move, never this), so an unreported skip is the card losing
  # its PR link and its Merge the moment teardown sweeps the meta, with nobody told why.
  assert_contains "$out" 'not recorded on backlog item ship-a1' \
    "a record skipped because the backend is not in use must be reported"
  assert_contains "$out" 'by hand' \
    "the report must tell firstmate what to do instead"
  pass "fm-pr-check reports the record it cannot make under config/backlog-backend=manual"
}

test_manual_backend_untracked_id_is_quiet() {
  local home fakebin out rc
  home=$(make_home manual-untracked)
  fakebin=$(make_tasks_axi_stub "$home" 0.2.2)
  printf 'manual\n' > "$home/config/backlog-backend"
  # A real hand-maintained backlog that simply does not carry this id - the window
  # between fm-spawn and the backlog write.
  hand_backlog "$home" other-x9 'In flight'

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ghost-z9 "$URL" 2>&1)
  rc=$?
  set -e

  # The same rule the tasks-axi path reads out of "code: NOT_FOUND", asked of the FILE so
  # the backend that is never consulted can answer it too: no item means no card to lose a
  # PR link, so nothing is owed and the warning would send firstmate hand-editing a line
  # that is not there.
  expect_code 0 "$rc" "an untracked id must not fail fm-pr-check under the manual backend"
  assert_present "$home/state/ghost-z9.check.sh" \
    "an untracked id must not stop fm-pr-check arming the merge poll"
  assert_not_contains "$out" 'not recorded on backlog item' \
    "an id a manual backlog never carried is not a record to report"
  pass "fm-pr-check does not report a skipped record for an id a manual backlog never carried"
}

test_manual_backend_done_item_is_quiet() {
  local home fakebin out rc
  home=$(make_home manual-done)
  fakebin=$(make_tasks_axi_stub "$home" 0.2.2)
  printf 'manual\n' > "$home/config/backlog-backend"
  # Already closed by hand: the merge landed and firstmate moved the item itself.
  hand_backlog "$home" ship-a1 Done

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1)
  rc=$?
  set -e

  # A Done item composes no card at all (fm-logbook-compose.sh returns early on it), so
  # there is no PR link left for the board to lose and the warning would be a false alarm.
  expect_code 0 "$rc" "an already-closed item must not fail fm-pr-check"
  assert_not_contains "$out" 'not recorded on backlog item' \
    "an item already in Done is not a record to report"
  pass "fm-pr-check does not report a skipped record for an item already in Done"
}

test_incompatible_tasks_axi_does_not_touch_the_backlog() {
  local home fakebin out
  home=$(make_home incompatible)
  # Older than the 0.1.1 floor the shared probe enforces: its verbs are not the ones
  # this repo relies on, so recording is skipped rather than attempted blind.
  fakebin=$(make_tasks_axi_stub "$home" 0.1.0)
  : > "$home/tasks-axi.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1) \
    || fail "fm-pr-check must survive an incompatible tasks-axi"$'\n'"$out"
  # The stub WAS reachable - the probe version-checked it - so the absent update call is
  # the gate working, not the stub going unused.
  assert_grep '--version' "$home/tasks-axi.log" \
    "fixture: the probe must have reached the stubbed tasks-axi"
  assert_no_grep 'update ship-a1' "$home/tasks-axi.log" \
    "an incompatible tasks-axi must not be handed an update --pr"
  assert_no_grep "$URL" "$home/data/backlog.md" \
    "an incompatible tasks-axi must leave the backlog item untouched"
  assert_present "$home/state/ship-a1.check.sh" \
    "an incompatible tasks-axi must not stop fm-pr-check arming the merge poll"
  pass "fm-pr-check skips the backlog record when tasks-axi is incompatible"
}

test_absent_tasks_axi_is_not_fatal() {
  local home out rc no_axi_path
  home=$(make_home absent)
  # BASE_PATH minus the tasks-axi dir, so absence is the only thing that changed.
  no_axi_path=${BASE_PATH#"$TASKS_AXI_DIR:"}
  command -v tasks-axi >/dev/null 2>&1 && [ "$no_axi_path" = "$BASE_PATH" ] \
    && fail "fixture: could not remove tasks-axi from the test PATH"
  # Arming the merge poll is this script's job; the durable record is best-effort. With
  # no tasks-axi at all the backlog falls back to hand-editing, and the poll must still
  # be armed - a merged PR that never wakes firstmate is a far worse failure.
  out=$(PATH="$no_axi_path" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-pr-check must exit 0 with no tasks-axi on PATH"
  assert_present "$home/state/ship-a1.check.sh" \
    "a missing tasks-axi must not stop fm-pr-check arming the merge poll"
  assert_grep "pr=$URL" "$home/state/ship-a1.meta" \
    "a missing tasks-axi must not stop fm-pr-check recording pr= in the meta"
  pass "fm-pr-check still arms the merge poll when tasks-axi is absent"
}

test_unknown_task_is_not_fatal() {
  local home out rc
  home=$(make_home unknown)
  # The backlog may not have caught up to the task yet (the window between fm-spawn and
  # the backlog write). tasks-axi rejects the unknown id; that must not take the poll
  # down with it.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ghost-z9 "$URL" 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-pr-check must exit 0 for a task the backlog does not have"
  assert_present "$home/state/ghost-z9.check.sh" \
    "an unknown task must not stop fm-pr-check arming the merge poll"
  # Tolerated means quiet: this is the one failure that is genuinely nothing to report, so
  # it must not be lumped in with the store errors that ARE a real loss.
  assert_not_contains "$out" 'could not record' \
    "an id the backlog has not caught up to yet is not a failure to report"
  pass "fm-pr-check tolerates a task the backlog has not caught up to yet"
}

# A tasks-axi whose backend probe passes but whose "update" fails for a reason that is not
# the backlog simply not carrying the id - a store or config error.
make_failing_tasks_axi() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v|-V) printf '%s\n' 'tasks-axi 0.2.2'; exit 0 ;;
  update)
    case " $* " in
      *--help*) printf '%s\n' '  --archive-body   archive the previous body'; exit 0 ;;
    esac
    printf 'error: "backlog store is locked"\ncode: IO_ERROR\n' >&2
    exit 1
    ;;
  mv) case " $* " in *--help*) printf '%s\n' 'usage: tasks-axi mv [<id>...] --to <path>'; exit 0 ;; esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

test_failed_record_is_reported_not_swallowed() {
  local home fakebin out rc
  home=$(make_home record-fails)
  fakebin=$(make_failing_tasks_axi "$home")

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" 2>&1)
  rc=$?
  set -e

  # Best-effort is about not failing the ARM, which is this script's actual job - never
  # about hiding why the durable record is missing.
  expect_code 0 "$rc" "a failed backlog record must not fail fm-pr-check"
  assert_present "$home/state/ship-a1.check.sh" \
    "a failed backlog record must not stop fm-pr-check arming the merge poll"
  # Swallowed, this loss surfaces nowhere near here and long after: the card looks right
  # while the crew lives (compose reads pr= from the meta), and silently loses its PR link
  # and its Merge the moment teardown sweeps that meta - which is exactly when the captain
  # needs it.
  assert_contains "$out" 'could not record' \
    "a failed backlog record must be reported, not swallowed"
  assert_contains "$out" 'IO_ERROR' \
    "the report must carry the backend's own reason"
  pass "fm-pr-check reports a failed durable record without failing the arm"
}

test_rearming_does_not_duplicate_the_record() {
  local home count
  home=$(make_home rearm)
  # fm-pr-merge.sh re-runs fm-pr-check for every merge, so re-arming is the normal path,
  # not an edge case: the record must converge, not accumulate.
  PATH="$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" >/dev/null 2>&1 \
    || fail "fm-pr-check must succeed on the first arm"
  PATH="$BASE_PATH" FM_HOME="$home" "$PR_CHECK" ship-a1 "$URL" >/dev/null 2>&1 \
    || fail "fm-pr-check must succeed on the second arm"
  count=$(grep -c -F "$URL" "$home/data/backlog.md")
  expect_code 1 "$count" "re-arming the same PR must not record it on the backlog twice"
  count=$(grep -c -F "pr=$URL" "$home/state/ship-a1.meta")
  expect_code 1 "$count" "re-arming the same PR must not record it in the meta twice"
  pass "fm-pr-check's records converge when the same PR is re-armed"
}

if [ -z "$TASKS_AXI_DIR" ]; then
  echo "skip: tasks-axi not found (required by the delegated backlog-record path)"
  exit 0
fi

test_records_the_pr_on_the_durable_backlog
test_the_durable_record_survives_the_crew
test_manual_backend_does_not_touch_the_backlog
test_manual_backend_reports_the_skipped_record
test_manual_backend_untracked_id_is_quiet
test_manual_backend_done_item_is_quiet
test_incompatible_tasks_axi_does_not_touch_the_backlog
test_absent_tasks_axi_is_not_fatal
test_unknown_task_is_not_fatal
test_failed_record_is_reported_not_swallowed
test_rearming_does_not_duplicate_the_record
