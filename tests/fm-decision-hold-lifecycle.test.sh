#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# HOLD_NOW pins the deadline clock so a test can assert an exact date. It has to
# be a date the real clock has not passed, because tasks-axi decides whether a
# hold is still gating from the system date and a hold born lapsed is refused.
HOLD_NOW=''

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CAPTAIN_HOLD_NOW="$HOLD_NOW" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

run_captain_hold() {  # <home> <id> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_CAPTAIN_HOLD_NOW="$HOLD_NOW" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_ready() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-ready.sh" "$@"
}

hold_row() {  # <home> <id>
  grep -E "^- \[ \] $2 -" "$1/data/backlog.md"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# A captain who declines a held decision leaves no follow-up work to route, so the
# routed close path cannot express the answer. The unrouted close path must record
# that answer durably while still refusing to release work the hold blocks.
test_declined_decision_closes_without_routed_work() {
  local home id hold routed_hold json show
  home=$(make_home declined-decision)
  id=sample-benchmark-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample benchmarks" --kind scout --repo sample --start >/dev/null \
    || fail "could not create declined-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample benchmark review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" half-run \
    --title "Choose the sample half run" --reason "captain half-run choice pending" --repo sample) \
    || fail "could not register the declinable hold"
  run_decisions "$home" complete "$id" half-run >/dev/null \
    || fail "completion failed for the declinable hold"

  printf '' > "$home/empty-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/empty-decision.txt" \
    > "$home/empty-decline.out" 2> "$home/empty-decline.err"; then
    fail "decline accepted an empty captain decision"
  fi
  if run_decisions "$home" decline "$id" half-run > "$home/bare-decline.out" 2> "$home/bare-decline.err"; then
    fail "decline accepted a close with no captain decision file at all"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused decline closed the hold"
  assert_contains "$show" "held: yes" "a refused decline released the hold"

  printf 'Declined: do not run the sample half benchmark.\n' > "$home/half-run-decision.txt"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "decline could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "declined hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "declined hold lost the decision record"
  assert_contains "$show" "Resolution mode: declined" "declined hold did not record its close path"
  assert_contains "$show" "Declined: do not run the sample half benchmark." \
    "declined hold did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a declined decision did not satisfy the completion gate"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "identical decline retry was not idempotent"
  printf 'Declined for a different reason.\n' > "$home/drifted-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/drifted-decision.txt" \
    > "$home/drifted-decline.out" 2> "$home/drifted-decline.err"; then
    fail "decline retry accepted a different captain decision"
  fi
  json=$(run_bearings "$home") || fail "Bearings failed after a declined decision"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
  ' >/dev/null || fail "a declined decision remained an open Captain's Call: $json"

  routed_hold=$(run_decisions "$home" hold "$id" upstream \
    --title "Choose the sample upstream target" --reason "captain upstream choice pending" --repo sample) \
    || fail "could not register the routed-work hold"
  tasks_in "$home" add sample-upstream-work "Apply the sample upstream choice" \
    --kind ship --repo sample --blocked-by "$routed_hold" >/dev/null \
    || fail "could not route work behind the second hold"
  if run_decisions "$home" decline "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/routed-decline.out" 2> "$home/routed-decline.err"; then
    fail "decline released work that was still routed behind the hold"
  fi
  assert_grep "still blocks routed work" "$home/routed-decline.err" \
    "decline must name the routed work it refuses to release"
  show=$(tasks_in "$home" show "$routed_hold" --full)
  assert_contains "$show" "state: queued" "refused routed decline closed the hold"
  show=$(tasks_in "$home" show sample-upstream-work --full)
  assert_contains "$show" "blocked: yes" "refused routed decline released dependent work"
  if run_decisions "$home" resolve "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/unrouted-resolve.out" 2> "$home/unrouted-resolve.err"; then
    fail "the routed close path accepted a resolution with no routed work"
  fi
  pass "a declined decision closes with a recorded answer and no routed work"
}

# The exact incident: two declined captain decisions were closed with a direct
# tasks-axi done, so the durable resolution attestation this gate reads was never
# written and the investigation could no longer be cleaned up.
test_out_of_band_close_is_repairable_before_teardown() {
  local home id hold show
  home=$(make_home out-of-band-close)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band-close origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" submission \
    --title "Choose the sample submission" --reason "captain submission choice pending" --repo sample) \
    || fail "could not register the out-of-band hold"
  run_decisions "$home" complete "$id" submission >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not reproduce the direct out-of-band close"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the out-of-band close shape was not reproduced"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "the out-of-band close must leave no durable resolution record"
  if run_decisions "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain decision closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain decision had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  if run_decisions "$home" repair "$id" submission > "$home/bare-repair.out" 2> "$home/bare-repair.err"; then
    fail "repair recorded a resolution with no captain decision file"
  fi
  printf '' > "$home/empty-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/empty-repair.txt" \
    > "$home/empty-repair.out" 2> "$home/empty-repair.err"; then
    fail "repair recorded a resolution from an empty captain decision file"
  fi
  if run_decisions "$home" verify "$id" > "$home/still-broken.out" 2> "$home/still-broken.err"; then
    fail "a refused repair still satisfied the completion gate"
  fi

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission-decision.txt"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "repair could not record the missing durable resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "repair reopened a closed captain decision"
  assert_contains "$show" "Resolution mode: repaired" "repair did not record its close path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "repair did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the repaired decision did not satisfy the completion gate"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "identical repair retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/drifted-repair.txt" \
    > "$home/drifted-repair.out" 2> "$home/drifted-repair.err"; then
    fail "repair retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the decision was repaired: $(cat "$home/teardown.err")"
  pass "a decision closed outside the script is repairable and then clears teardown"
}

# The unrouted close paths must not become a way past the gate. An unanswered
# decision keeps blocking cleanup, and neither new path can manufacture an answer.
test_unanswered_decision_still_blocks_completion_and_teardown() {
  local home id hold show
  home=$(make_home unanswered-decision)
  id=sample-open-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate an open sample choice" --kind scout --repo sample --start >/dev/null \
    || fail "could not create unanswered-decision origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=open-choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample open review\n\nThe captain has not chosen yet.\n' > "$home/data/$id/report.md"
  printf 'An answer the captain never gave.\n' > "$home/invented-decision.txt"

  if run_decisions "$home" complete "$id" open-choice > "$home/open-complete.out" 2> "$home/open-complete.err"; then
    fail "completion accepted an unresolved decision with no captain hold"
  fi
  if run_decisions "$home" verify "$id" > "$home/open-verify.out" 2> "$home/open-verify.err"; then
    fail "verification accepted an unresolved decision with no captain hold"
  fi
  if run_teardown "$home" "$id" > "$home/open-teardown.out" 2> "$home/open-teardown.err"; then
    fail "teardown erased an investigation whose decision was never inventoried"
  fi
  assert_grep "REFUSED" "$home/open-teardown.err" "teardown refusal must be explicit"
  if run_decisions "$home" decline "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-decline.out" 2> "$home/absent-decline.err"; then
    fail "decline invented a resolution for a decision that has no hold"
  fi
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-repair.out" 2> "$home/absent-repair.err"; then
    fail "repair invented a resolution for a decision that has no hold"
  fi

  tasks_in "$home" add "$id-decision-never-held" "An ordinary captain-kind task" \
    --kind captain --repo sample >/dev/null \
    || fail "could not create the never-held captain-kind fixture"
  tasks_in "$home" "done" "$id-decision-never-held" >/dev/null \
    || fail "could not close the never-held captain-kind fixture"
  if run_decisions "$home" repair "$id" never-held --decision-file "$home/invented-decision.txt" \
    > "$home/never-held-repair.out" 2> "$home/never-held-repair.err"; then
    fail "repair turned an ordinary captain-kind task into a resolved captain decision"
  fi
  assert_grep "never held for the captain" "$home/never-held-repair.err" \
    "repair must say the identity carries no captain-hold provenance"
  show=$(tasks_in "$home" show "$id-decision-never-held" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a refused never-held repair wrote a resolution record"

  hold=$(run_decisions "$home" hold "$id" open-choice \
    --title "Choose the sample option" --reason "captain option choice pending" --repo sample) \
    || fail "could not register the unanswered hold"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/held-repair.out" 2> "$home/held-repair.err"; then
    fail "repair closed a decision that is still actively held and unanswered"
  fi
  assert_grep "still open" "$home/held-repair.err" "repair must say the hold is still open"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused repair closed the live hold"
  assert_contains "$show" "held: yes" "a refused repair released the live hold"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused repair wrote a resolution record"
  run_decisions "$home" complete "$id" open-choice >/dev/null \
    || fail "an inventoried unanswered decision could not complete its review"
  pass "an unanswered decision still blocks completion and resists both unrouted close paths"
}

# The whole point of the default: before it, 0 of 77 captain holds carried a
# deadline, so a question the captain had chosen not to answer sat in the
# needs-you feed forever beside questions they had never seen. The clock is
# pinned to a far-future date so the expected deadlines are literals here rather
# than date arithmetic reimplemented from the code under test.
test_captain_holds_carry_a_default_deadline() {
  local home id row
  home=$(make_home default-deadline)
  id=sample-deadline-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample deadline review\n\nFour choices remain.\n' > "$home/data/$id/report.md"

  HOLD_NOW=2099-01-01
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "could not register a hold with the default deadline"
  row=$(hold_row "$home" "$id-decision-route")
  assert_contains "$row" "(hold-until: 2099-01-08)" \
    "a captain hold was written without the default deadline"

  run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample \
    --hold-until 2099-06-30 >/dev/null \
    || fail "could not register a hold with an explicit deadline"
  row=$(hold_row "$home" "$id-decision-access")
  assert_contains "$row" "(hold-until: 2099-06-30)" \
    "an explicit --hold-until did not override the default"

  run_decisions "$home" hold "$id" charter \
    --title "Choose the sample charter" --reason "captain charter choice pending" --repo sample \
    --hold-until none >/dev/null \
    || fail "could not register an open-ended hold"
  row=$(hold_row "$home" "$id-decision-charter")
  assert_contains "$row" "(hold-kind: captain)" "the open-ended hold was not held for the captain"
  case "$row" in
    *hold-until*) fail "--hold-until none still wrote a deadline: $row" ;;
  esac

  # The default has to survive a month and a year boundary, because a wrong
  # answer there is a deadline that lands in the past and a hold born lapsed.
  HOLD_NOW=2099-12-28
  run_decisions "$home" hold "$id" rollover \
    --title "Choose the sample rollover" --reason "captain rollover choice pending" --repo sample >/dev/null \
    || fail "could not register a hold across a year boundary"
  assert_contains "$(hold_row "$home" "$id-decision-rollover")" "(hold-until: 2100-01-04)" \
    "the default deadline did not roll over into the next year"

  HOLD_NOW=2099-02-25
  run_decisions "$home" hold "$id" calendar \
    --title "Choose the sample calendar" --reason "captain calendar choice pending" --repo sample >/dev/null \
    || fail "could not register a hold across a month boundary"
  assert_contains "$(hold_row "$home" "$id-decision-calendar")" "(hold-until: 2099-03-04)" \
    "the default deadline did not roll over into the next month"

  # A retry with no flag must not quietly shorten a window the captain was given.
  HOLD_NOW=2099-01-01
  run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample >/dev/null \
    || fail "could not retry a hold that already carries a deadline"
  assert_contains "$(hold_row "$home" "$id-decision-access")" "(hold-until: 2099-06-30)" \
    "an idempotent retry shortened an explicitly chosen deadline"
  run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample \
    --hold-until 2099-03-31 >/dev/null || fail "could not move an existing deadline explicitly"
  assert_contains "$(hold_row "$home" "$id-decision-access")" "(hold-until: 2099-03-31)" \
    "an explicit --hold-until could not move an existing deadline"

  for bad in 2099-01-01 2098-12-31 2099-02-30 soon; do
    if run_decisions "$home" hold "$id" rejected \
      --title "Choose the rejected sample" --reason "captain rejected choice pending" --repo sample \
      --hold-until "$bad" > "$home/rejected.out" 2> "$home/rejected.err"; then
      fail "an unusable deadline was accepted: $bad"
    fi
    assert_no_grep "$id-decision-rejected" "$home/data/backlog.md" \
      "a refused deadline still wrote a captain hold: $bad"
  done
  HOLD_NOW=''
  pass "captain holds carry a default deadline, an override, and an opt-out"
}

# AGENTS.md section 10's other captain hold: a main-side thread with no
# investigation behind it. It goes through the same default so the deadline is
# not an option nobody passes.
test_main_side_captain_hold_uses_the_same_default() {
  local home row
  home=$(make_home main-side-hold)
  tasks_in "$home" add sample-relay-thread "Sample relay reminder" --kind captain --repo sample >/dev/null \
    || fail "could not create the main-side backlog fixture"

  HOLD_NOW=2099-01-01
  run_captain_hold "$home" sample-relay-thread --reason "captain reply pending" >/dev/null \
    || fail "could not hold a main-side thread for the captain"
  row=$(hold_row "$home" sample-relay-thread)
  assert_contains "$row" "(hold-kind: captain)" "the main-side thread was not held for the captain"
  assert_contains "$row" "(hold-until: 2099-01-08)" \
    "a main-side captain hold was written without the default deadline"

  run_captain_hold "$home" sample-relay-thread --reason "captain reply pending" \
    --hold-until 2099-05-05 >/dev/null || fail "could not re-hold with an explicit deadline"
  assert_contains "$(hold_row "$home" sample-relay-thread)" "(hold-until: 2099-05-05)" \
    "an explicit --hold-until did not override the main-side default"

  run_captain_hold "$home" sample-relay-thread --reason "captain reply pending" \
    --hold-until none >/dev/null || fail "could not re-hold without a deadline"
  case "$(hold_row "$home" sample-relay-thread)" in
    *hold-until*) fail "--hold-until none still wrote a main-side deadline" ;;
  esac

  run_captain_hold "$home" sample-relay-thread --reason "captain reply pending" \
    --hold-until 2099-05-05 >/dev/null || fail "could not restore an explicit deadline"
  run_captain_hold "$home" sample-relay-thread --reason "captain reply pending" >/dev/null \
    || fail "could not re-hold a main-side thread that already carries a deadline"
  assert_contains "$(hold_row "$home" sample-relay-thread)" "(hold-until: 2099-05-05)" \
    "re-holding a main-side thread shortened an explicitly chosen deadline"

  if run_captain_hold "$home" sample-absent-thread --reason "captain reply pending" \
    > "$home/absent-hold.out" 2> "$home/absent-hold.err"; then
    fail "a main-side hold was written for a backlog item that does not exist"
  fi
  assert_no_grep "sample-absent-thread" "$home/data/backlog.md" \
    "a refused main-side hold created a backlog row"

  # tasks-axi applies a hold to a done row too, and every surface that reports a
  # captain hold requires a queued one, so holding a settled item asks a question
  # nothing will ever show the captain.
  tasks_in "$home" add sample-settled-thread "Sample settled thread" --kind captain --repo sample >/dev/null \
    || fail "could not create the settled backlog fixture"
  tasks_in "$home" "done" sample-settled-thread >/dev/null \
    || fail "could not settle the backlog fixture"
  if run_captain_hold "$home" sample-settled-thread --reason "captain reply pending" \
    > "$home/settled-hold.out" 2> "$home/settled-hold.err"; then
    fail "a main-side hold was written onto a done backlog item"
  fi
  assert_contains "$(tasks_in "$home" show sample-settled-thread --full)" 'hold_kind: "-"' \
    "a refused main-side hold still wrote captain hold metadata onto a done item"
  HOLD_NOW=''
  pass "a main-side captain hold takes the same deadline default"
}

# Lapse is demotion, never deletion. Past its deadline a hold stops gating
# dispatch and keeps its reason, kind and date, so it is still a captain hold
# with an answer owed: it must keep blocking teardown and must still be
# answerable, and it must survive teardown exactly as an unlapsed hold does.
# Giving holds a clock without this makes a late answer unrecordable.
test_lapsed_hold_is_demoted_not_deleted() {
  local home id show
  home=$(make_home lapsed-hold)
  id=sample-lapsed-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample lapsed review\n\nOne choice remains.\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" route \
    --title "Choose the lapsed sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "could not register the hold that is about to lapse"

  tasks_in "$home" hold "$id-decision-route" --reason "captain route choice pending" \
    --kind captain --until 2000-01-01 >/dev/null || fail "could not lapse the fixture hold"
  show=$(tasks_in "$home" show "$id-decision-route" --full)
  assert_contains "$show" "held: no" "the fixture hold did not lapse"
  assert_contains "$show" "hold_kind: captain" "the lapsed hold lost its captain provenance"
  assert_contains "$show" "hold_reason: captain route choice pending" \
    "the lapsed hold lost its reason"
  assert_contains "$show" "hold_until: 2000-01-01" "the lapsed hold lost its deadline"

  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "a lapsed decision was not accepted as a durable inventory entry"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a lapsed decision failed the teardown verification gate"
  run_teardown "$home" "$id" >/dev/null 2> "$home/lapsed-teardown.err" \
    || fail "reviewed teardown failed over a lapsed decision: $(cat "$home/lapsed-teardown.err")"
  show=$(tasks_in "$home" show "$id-decision-route" --full)
  assert_contains "$show" "hold_kind: captain" "teardown erased a lapsed captain hold"
  assert_contains "$show" "hold_until: 2000-01-01" "teardown rewrote a lapsed hold's deadline"

  HOLD_NOW=2099-01-01
  run_decisions "$home" hold "$id" route \
    --title "Choose the lapsed sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "a lapsed decision could not be re-asked"
  assert_contains "$(hold_row "$home" "$id-decision-route")" "(hold-until: 2099-01-08)" \
    "re-asking a lapsed decision did not give it a fresh deadline"
  assert_contains "$(tasks_in "$home" show "$id-decision-route" --full)" "held: yes" \
    "re-asking a lapsed decision did not put it back in front of the captain"
  HOLD_NOW=''

  tasks_in "$home" hold "$id-decision-route" --reason "captain route choice pending" \
    --kind captain --until 2000-01-01 >/dev/null || fail "could not lapse the re-asked hold"
  assert_contains "$(tasks_in "$home" show "$id-decision-route" --full)" "held: no" \
    "the re-asked hold did not lapse again"
  printf 'The captain finally chose route north.\n' > "$home/lapsed-decision.md"
  run_decisions "$home" decline "$id" route --decision-file "$home/lapsed-decision.md" >/dev/null \
    || fail "the captain's late answer could not be recorded on a lapsed hold"
  assert_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "answering a lapsed hold recorded no durable decision"
  pass "a lapsed captain hold is demoted, survives teardown, and still takes an answer"
}

# A hold that predates the default carries no deadline at all. Nothing may
# rewrite it, and every lifecycle path must keep working on it unchanged.
test_existing_holds_without_a_deadline_are_untouched() {
  local home id row before
  home=$(make_home legacy-hold)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample legacy review\n\nOne choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" add "$id-decision-route" "Choose the legacy sample route" \
    --kind captain --repo sample >/dev/null || fail "could not create the legacy fixture"
  tasks_in "$home" hold "$id-decision-route" --reason "captain route choice pending" \
    --kind captain >/dev/null || fail "could not hold the legacy fixture"
  row=$(hold_row "$home" "$id-decision-route")
  case "$row" in *hold-until*) fail "the legacy fixture was not deadline-free: $row" ;; esac

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "a deadline-free hold failed the completion gate"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a deadline-free hold failed the teardown verification gate"
  [ "$before" = "$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')" ] \
    || fail "reviewing a deadline-free hold rewrote the backlog"
  case "$(hold_row "$home" "$id-decision-route")" in
    *hold-until*) fail "an existing deadline-free hold was given a deadline" ;;
  esac

  printf 'The captain chose route south.\n' > "$home/legacy-decision.md"
  run_decisions "$home" decline "$id" route --decision-file "$home/legacy-decision.md" >/dev/null \
    || fail "a deadline-free hold could not be closed with the captain's answer"
  pass "captain holds written before the default keep working untouched"
}

# Giving every hold a clock makes lapsing reachable, and tasks-axi's own `ready`
# set counts a lapsed captain hold as startable work. Forking tasks-axi is out of
# bounds, so firstmate withholds it on its own side, in one owned ready path that
# every reader of dispatchable work goes through. Withholding is presentation
# only: the hold stays queued, keeps its reason, kind and deadline, and is
# disclosed rather than dropped silently.
test_lapsed_hold_is_never_offered_as_dispatchable_work() {
  local home before raw ready show disclosed
  home=$(make_home ready-withholding)
  tasks_in "$home" add sample-ready-work "Ship the sample route" --kind ship --repo sample >/dev/null \
    || fail "could not create the dispatchable fixture"
  tasks_in "$home" add sample-live-question "Choose the live sample route" \
    --kind captain --repo sample >/dev/null || fail "could not create the live-hold fixture"
  tasks_in "$home" add sample-lapsed-question "Choose the lapsed sample route, and more" \
    --kind captain --repo sample >/dev/null || fail "could not create the lapsed-hold fixture"
  run_captain_hold "$home" sample-live-question --reason "captain live choice pending" >/dev/null \
    || fail "could not hold the live question"
  tasks_in "$home" hold sample-lapsed-question --reason "captain lapsed choice pending" \
    --kind captain --until 2000-01-01 >/dev/null || fail "could not lapse the fixture hold"

  # The defect, reproduced against the real tool rather than assumed: `ready`
  # offers the unanswered question. If this ever stops holding, the withholding
  # below has stopped proving anything.
  raw=$(cd "$home" && tasks-axi ready --file "$home/data/backlog.md") \
    || fail "could not read the raw dispatchable set"
  assert_contains "$raw" "sample-lapsed-question" \
    "tasks-axi no longer offers a lapsed captain hold, so this fixture proves nothing"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  ready=$(run_ready "$home") || fail "firstmate's dispatchable set failed: $ready"
  assert_contains "$ready" "sample-ready-work,queued,ship,sample,Ship the sample route" \
    "withholding the lapsed hold also dropped genuinely dispatchable work"
  assert_not_contains "$ready" "sample-lapsed-question" \
    "an unanswered captain question was offered as dispatchable work"
  assert_not_contains "$ready" "sample-live-question" \
    "a live captain hold was offered as dispatchable work"
  assert_contains "$ready" "count: 1" "the dispatchable count still included the withheld hold"
  assert_contains "$ready" "ready[1]{" "the dispatchable header still counted the withheld hold"
  # The disclosure must name surfaces that really show the withheld rows, and its
  # query must carry the SAME backlog this run filtered so it resolves from any
  # directory rather than whichever backlog the cwd happens to select.
  assert_contains "$ready" "(1 lapsed captain hold(s) withheld from this group; each is still an unanswered captain hold, shown in session start's held group and by tasks-axi list --file $home/data/backlog.md --state queued --fields hold_kind,hold_until,held)" \
    "the dispatchable set withheld a lapsed hold without a pointer that resolves"
  # Run the disclosed query verbatim from an unrelated directory: it has to show
  # the withheld row from there, with no cd and no reliance on FM_HOME.
  disclosed=$(cd / && tasks-axi list --file "$home/data/backlog.md" --state queued \
    --fields hold_kind,hold_until,held)
  assert_contains "$disclosed" "sample-lapsed-question" \
    "the disclosed query did not show the withheld hold from another directory"

  [ "$before" = "$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')" ] \
    || fail "reading the dispatchable set rewrote the backlog"
  show=$(tasks_in "$home" show sample-lapsed-question --full)
  assert_contains "$show" "state: queued" "the withheld hold was closed rather than demoted"
  assert_contains "$show" "hold_kind: captain" "the withheld hold lost its captain provenance"
  assert_contains "$show" "hold_reason: captain lapsed choice pending" \
    "the withheld hold lost its reason"
  assert_contains "$show" "hold_until: 2000-01-01" "the withheld hold lost its deadline"
  pass "a lapsed captain hold stays held and is never offered as dispatchable work"
}

# Under `set -eu` a flag typed as the final token consumes the shift meant for
# its own value, so the loop-bottom shift fails and the script dies with exit 1
# and no diagnostic at all, before its own validation can report the real
# mistake. Every flag on both hold paths must report instead.
test_a_flag_without_its_value_reports_rather_than_exiting_mute() {
  local home id
  home=$(make_home flag-without-value)
  id=sample-flag-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample flag review\n\nOne choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" add sample-flag-thread "Sample flag reminder" --kind captain --repo sample >/dev/null \
    || fail "could not create the main-side backlog fixture"

  if run_captain_hold "$home" sample-flag-thread --reason \
    > "$home/no-reason.out" 2> "$home/no-reason.err"; then
    fail "a main-side hold accepted --reason with no value"
  fi
  assert_grep "--reason requires a value" "$home/no-reason.err" \
    "a main-side --reason with no value exited without saying why"

  if run_captain_hold "$home" sample-flag-thread --reason "captain reply pending" --hold-until \
    > "$home/no-until.out" 2> "$home/no-until.err"; then
    fail "a main-side hold accepted --hold-until with no value"
  fi
  assert_grep "--hold-until requires a value" "$home/no-until.err" \
    "a main-side --hold-until with no value exited without saying why"
  assert_no_grep "hold-kind: captain" "$home/data/backlog.md" \
    "a refused flag still wrote a captain hold"

  if run_decisions "$home" hold "$id" route --reason "captain route choice pending" --title \
    > "$home/no-title.out" 2> "$home/no-title.err"; then
    fail "a decision hold accepted --title with no value"
  fi
  assert_grep "--title requires a value" "$home/no-title.err" \
    "a decision --title with no value exited without saying why"

  if run_decisions "$home" hold "$id" route --title "Choose the sample route" --hold-until \
    > "$home/no-decision-until.out" 2> "$home/no-decision-until.err"; then
    fail "a decision hold accepted --hold-until with no value"
  fi
  assert_grep "--hold-until requires a value" "$home/no-decision-until.err" \
    "a decision --hold-until with no value exited without saying why"
  assert_no_grep "$id-decision-route" "$home/data/backlog.md" \
    "a refused flag still created a captain decision item"
  pass "a flag missing its value fails with a diagnostic instead of exiting mute"
}

# The same rule through a real write path: re-holding a lapsed question puts it
# back in front of the captain with a fresh clock, and re-holding one that
# predates the default finally gives it one.
test_reholding_a_lapsed_question_comes_back_with_a_fresh_clock() {
  local home show
  home=$(make_home rehold-lapsed)
  tasks_in "$home" add sample-lapsed-thread "Sample lapsed reminder" --kind captain --repo sample >/dev/null \
    || fail "could not create the lapsed-thread fixture"
  tasks_in "$home" hold sample-lapsed-thread --reason "captain reply pending" \
    --kind captain --until 2000-01-01 >/dev/null || fail "could not lapse the fixture hold"
  show=$(tasks_in "$home" show sample-lapsed-thread --full)
  assert_contains "$show" "held: no" "the fixture hold did not lapse"

  HOLD_NOW=2099-01-01
  run_captain_hold "$home" sample-lapsed-thread --reason "captain reply still pending" >/dev/null \
    || fail "could not re-hold the lapsed question"
  assert_contains "$(hold_row "$home" sample-lapsed-thread)" "(hold-until: 2099-01-08)" \
    "re-holding a lapsed question carried its past deadline forward"
  show=$(tasks_in "$home" show sample-lapsed-thread --full)
  assert_contains "$show" "held: yes" "a re-held lapsed question stayed lapsed"
  assert_contains "$show" "hold_reason: captain reply still pending" \
    "the re-held question kept the superseded wording"

  # A hold written before the default carries none, and a re-hold is the moment
  # it finally gets one rather than staying open-ended forever.
  tasks_in "$home" add sample-legacy-thread "Sample legacy reminder" --kind captain --repo sample >/dev/null \
    || fail "could not create the legacy-thread fixture"
  tasks_in "$home" hold sample-legacy-thread --reason "captain reply pending" \
    --kind captain >/dev/null || fail "could not hold the legacy fixture"
  case "$(hold_row "$home" sample-legacy-thread)" in
    *hold-until*) fail "the legacy fixture was not deadline-free" ;;
  esac
  run_captain_hold "$home" sample-legacy-thread --reason "captain reply pending" >/dev/null \
    || fail "could not re-hold the deadline-free question"
  assert_contains "$(hold_row "$home" sample-legacy-thread)" "(hold-until: 2099-01-08)" \
    "re-holding a deadline-free question left it unable to ever lapse"
  HOLD_NOW=''
  pass "re-holding a lapsed or deadline-free question gives it a fresh clock"
}

# The lapse query needs held, hold_kind and hold_until as list fields, which the
# tasks-axi floor in bin/fm-tasks-axi-lib.sh is what guarantees. A build under
# that floor must refuse rather than hand back a dispatchable listing nothing
# screened, because an unscreened ready set is exactly what this path replaces.
test_a_build_below_the_tasks_axi_floor_refuses_rather_than_degrades() {
  local home out rc
  home=$(make_home below-floor)
  tasks_in "$home" add sample-ready-work "Ship the sample route" --kind ship --repo sample >/dev/null \
    || fail "could not create the dispatchable fixture"
  tasks_in "$home" add sample-lapsed-question "Choose the lapsed sample route" \
    --kind captain --repo sample >/dev/null || fail "could not create the lapsed-hold fixture"
  tasks_in "$home" hold sample-lapsed-question --reason "captain choice pending" \
    --kind captain --until 2000-01-01 >/dev/null || fail "could not lapse the fixture hold"
  # Everything else about this build is fine; only its version is under the floor.
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.4'
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  out=$(run_ready "$home" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a build below the tasks-axi floor was accepted: $out"
  assert_contains "$out" "compatible tasks-axi is required" \
    "the refusal did not say what was wrong: $out"
  assert_not_contains "$out" "sample-ready-work" \
    "the refused build still emitted a dispatchable listing"
  assert_not_contains "$out" "sample-lapsed-question" \
    "the refused build degraded into an unscreened ready set"
  pass "a tasks-axi below the floor refuses the dispatchable set, never degrades into it"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_declined_decision_closes_without_routed_work
test_out_of_band_close_is_repairable_before_teardown
test_unanswered_decision_still_blocks_completion_and_teardown
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_captain_holds_carry_a_default_deadline
test_main_side_captain_hold_uses_the_same_default
test_lapsed_hold_is_demoted_not_deleted
test_existing_holds_without_a_deadline_are_untouched
test_lapsed_hold_is_never_offered_as_dispatchable_work
test_a_flag_without_its_value_reports_rather_than_exiting_mute
test_reholding_a_lapsed_question_comes_back_with_a_fresh_clock
test_a_build_below_the_tasks_axi_floor_refuses_rather_than_degrades
