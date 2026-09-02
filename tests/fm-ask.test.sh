#!/usr/bin/env bash
# tests/fm-ask.test.sh - the captain-ask identity survives every rewrite, and only
# a deliberate re-ask moves it.
#
# The defect these pin: a question identity derived from the hold reason meant that
# firstmate rewriting that reason - which is what recording an answer does - minted
# a new question, and the captain's answer no longer settled the card that came
# back. So every case here asserts an IDENTITY across an operation, not the
# operation's own output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$ROOT/bin/fm-ask.sh"
DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_ask() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ASK" "$@"
}

run_decision_hold() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$DECISION_HOLD" "$@"
}

# The identity the SNAPSHOT publishes for <id>, which is what a board consumes.
published_ask_id() {  # <home> <id>
  FM_HOME="$1" "$SNAPSHOT" --json \
    | jq -r --arg id "$2" '.backlog.records[] | select(.id == $id) | .ask_id'
}

published_ask_revision() {  # <home> <id>
  FM_HOME="$1" "$SNAPSHOT" --json \
    | jq -r --arg id "$2" '.backlog.records[] | select(.id == $id) | .ask_revision'
}

compose_action_card() {  # <home> <id>
  local home=$1 id=$2
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain >/dev/null
}

# --- a reason rewrite preserves identity and revision ------------------------

test_reason_rewrite_preserves_the_identity() {
  local home id before after
  home=$(make_home rewrite)
  id=placement-axes-p3
  compose_action_card "$home" "$id"
  before=$(run_ask "$home" id "$id") || fail "fm-ask.sh id failed on a fresh captain hold"
  [ "$before" = "$(published_ask_id "$home" "$id")" ] \
    || fail "fm-ask.sh and the published snapshot disagree about the identity of $id"

  # The exact rewrite that used to re-ask: recording the captain's answer rewrites
  # the reason into an action-first sentence carrying different options.
  axi "$home" hold "$id" --reason "ship the axes now; Recommended: Friday train. Alternatives: next release" \
    --kind captain >/dev/null
  after=$(run_ask "$home" id "$id")
  [ "$before" = "$after" ] || fail "a reason rewrite changed the question identity: $before -> $after"
  [ "$after" = "$(published_ask_id "$home" "$id")" ] \
    || fail "the published identity moved on a reason rewrite"
  [ "$(run_ask "$home" revision "$id")" = 1 ] || fail "a reason rewrite moved the revision"
  assert_absent "$home/data/ask-revisions" \
    "a reason rewrite wrote the revision ledger; only a deliberate re-ask may"
  pass "a rewritten hold reason keeps the same captain-ask identity and revision"
}

test_a_hold_refresh_preserves_the_identity() {
  local home id before
  home=$(make_home refresh)
  id=placement-axes-p4
  compose_action_card "$home" "$id"
  before=$(run_ask "$home" id "$id")
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain >/dev/null
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain >/dev/null
  [ "$before" = "$(run_ask "$home" id "$id")" ] || fail "re-applying the same hold changed the identity"
  [ "$before" = "$(published_ask_id "$home" "$id")" ] || fail "the published identity moved on a hold refresh"
  pass "an idempotent hold refresh keeps the same captain-ask identity"
}

# --- the explicit re-ask bumps it -------------------------------------------

test_again_bumps_the_identity_and_writes_the_new_question() {
  local home id before after row
  home=$(make_home again)
  id=placement-axes-p5
  compose_action_card "$home" "$id"
  before=$(run_ask "$home" id "$id")
  after=$(run_ask "$home" again "$id" --reason "the Friday train closed; pick the next window") \
    || fail "the deliberate re-ask failed"
  [ "$before" != "$after" ] || fail "the deliberate re-ask did not change the identity"
  [ "$after" = "$(run_ask "$home" id "$id")" ] || fail "fm-ask.sh again printed an identity it did not record"
  [ "$after" = "$(published_ask_id "$home" "$id")" ] || fail "the published identity did not follow the re-ask"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the re-ask did not bump the revision to 2"
  [ "$(published_ask_revision "$home" "$id")" = 2 ] || fail "the published revision did not follow the re-ask"

  row=$(grep -F -- "- [ ] $id " "$home/data/backlog.md") || fail "the re-asked row vanished from the backlog"
  assert_contains "$row" "the Friday train closed" "the re-ask did not write the new question as the hold reason"
  assert_grep "$id=2" "$home/data/ask-revisions" "the revision ledger did not record the re-ask"

  run_ask "$home" again "$id" --reason "the next window slipped too; hold until the release train is picked" >/dev/null \
    || fail "a second deliberate re-ask failed"
  [ "$(run_ask "$home" revision "$id")" = 3 ] || fail "a second re-ask did not reach revision 3"
  pass "the deliberate re-ask bumps the revision, moves the identity, and writes the new question"
}

test_again_refuses_without_a_new_question() {
  local home id before out rc
  home=$(make_home again-refusals)
  id=placement-axes-p6
  compose_action_card "$home" "$id"
  before=$(run_ask "$home" id "$id")

  rc=0; out=$(run_ask "$home" again "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask with no --reason"
  assert_contains "$out" "--reason is required" "a re-ask with no --reason must say what is missing"

  rc=0; out=$(run_ask "$home" again "$id" --reason "confirm the rollout window" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask restating the same reason"
  assert_contains "$out" "is not a re-ask" "restating the same question must be refused as a nag"

  [ "$before" = "$(run_ask "$home" id "$id")" ] || fail "a refused re-ask still moved the identity"
  assert_absent "$home/data/ask-revisions" "a refused re-ask wrote the revision ledger"
  pass "a re-ask that states no new question is refused and moves nothing"
}

# --- decision holds: a durable subject, re-asked by a new key ----------------

test_decision_hold_identity_survives_its_reason_rewrite() {
  local home origin id before
  home=$(make_home decision)
  origin=route-scout-o1
  mkdir -p "$home/data/$origin"
  printf '# report\n' > "$home/data/$origin/report.md"
  id=$(run_decision_hold "$home" hold "$origin" gesture-guard \
    --title "Pick the gesture guard" \
    --reason "choose the guard; Recommended: debounce. Alternatives: long-press" --repo myapp) \
    || fail "could not create the decision hold"
  [ "$id" = "$origin-decision-gesture-guard" ] || fail "unexpected decision-hold identity: $id"
  before=$(run_ask "$home" id "$id")
  assert_contains "$before" "$origin-decision-gesture-guard" \
    "the published identity must name the durable decision subject"

  run_decision_hold "$home" hold "$origin" gesture-guard \
    --title "Pick the gesture guard" \
    --reason "choose the guard now; Recommended: debounce on release. Alternatives: long-press" \
    --repo myapp >/dev/null || fail "could not rewrite the decision-hold reason"
  [ "$before" = "$(run_ask "$home" id "$id")" ] \
    || fail "rewriting a decision-hold reason changed its question identity"
  [ "$before" = "$(published_ask_id "$home" "$id")" ] \
    || fail "the published decision-hold identity moved on a reason rewrite"
  pass "a decision hold keeps its durable identity through a reason rewrite"
}

test_again_refuses_a_decision_hold() {
  local home origin id before out rc
  home=$(make_home decision-again)
  origin=route-scout-o2
  mkdir -p "$home/data/$origin"
  printf '# report\n' > "$home/data/$origin/report.md"
  id=$(run_decision_hold "$home" hold "$origin" gesture-guard \
    --title "Pick the gesture guard" --reason "choose the guard" --repo myapp)
  before=$(run_ask "$home" id "$id")
  rc=0; out=$(run_ask "$home" again "$id" --reason "a different question about the guard" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask aimed at a decision hold"
  assert_contains "$out" "fm-decision-hold.sh hold" \
    "refusing a decision hold must name the command that re-asks it"
  [ "$before" = "$(run_ask "$home" id "$id")" ] || fail "the refused decision-hold re-ask still moved the identity"
  pass "a decision hold is re-asked with a new decision key, not by bumping a revision"
}

# --- resolve, decline and repair leave it alone ------------------------------
#
# Each of these rewrites the hold body and closes the hold, which is the moment
# the old design minted a new identity. The ledger must be byte-identical after.

test_close_paths_leave_the_revision_alone() {
  local home origin id decision ledger_before routed
  home=$(make_home close-paths)
  origin=route-scout-o3
  mkdir -p "$home/data/$origin"
  printf '# report\n' > "$home/data/$origin/report.md"
  decision="$TMP_ROOT/decision.txt"
  printf 'debounce on release\n' > "$decision"

  # A re-asked action card gives the ledger real content to preserve.
  compose_action_card "$home" placement-axes-p7
  run_ask "$home" again placement-axes-p7 --reason "the Friday train closed; pick the next window" >/dev/null
  ledger_before=$(cat "$home/data/ask-revisions")

  id=$(run_decision_hold "$home" hold "$origin" decline-me --title "Declined decision" \
    --reason "choose the guard" --repo myapp)
  run_decision_hold "$home" decline "$origin" decline-me --decision-file "$decision" >/dev/null \
    || fail "decline failed"
  [ "$ledger_before" = "$(cat "$home/data/ask-revisions")" ] || fail "decline changed the revision ledger"
  [ "$(published_ask_id "$home" "$id")" = null ] \
    || fail "a closed decision still publishes a live question identity"

  run_decision_hold "$home" repair "$origin" decline-me --decision-file "$decision" >/dev/null \
    || fail "repair failed"
  [ "$ledger_before" = "$(cat "$home/data/ask-revisions")" ] || fail "repair changed the revision ledger"

  id=$(run_decision_hold "$home" hold "$origin" resolve-me --title "Routed decision" \
    --reason "choose the routed guard" --repo myapp)
  routed=route-guard-fix-r1
  axi "$home" add "$routed" "apply the chosen guard" --kind ship --repo myapp --blocked-by "$id" >/dev/null
  run_decision_hold "$home" resolve "$origin" resolve-me --decision-file "$decision" --routed-to "$routed" >/dev/null \
    || fail "resolve failed"
  [ "$ledger_before" = "$(cat "$home/data/ask-revisions")" ] || fail "resolve changed the revision ledger"

  [ "$(run_ask "$home" revision placement-axes-p7)" = 2 ] \
    || fail "the re-asked card lost its revision across the close paths"
  pass "resolve, decline and repair leave the revision ledger and the identity alone"
}

# --- what the snapshot publishes --------------------------------------------

test_snapshot_publishes_an_identity_only_for_an_open_captain_ask() {
  local home records
  home=$(make_home published)
  compose_action_card "$home" held-for-captain-h1
  axi "$home" add plain-work-w1 "ordinary work" --kind ship --repo myapp --start >/dev/null
  axi "$home" add externally-held-e1 "waiting on a vendor" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold externally-held-e1 --reason "vendor has not shipped the SDK" --kind external >/dev/null
  axi "$home" add closed-ask-c1 "answered already" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold closed-ask-c1 --reason "confirm the rollout window" --kind captain >/dev/null
  axi "$home" "done" closed-ask-c1 >/dev/null

  records=$(FM_HOME="$home" "$SNAPSHOT" --json | jq -c '
    [ .backlog.records[] | select(.structured) | {id, ask_id, ask_revision} ] | sort_by(.id)')

  assert_contains "$records" '{"id":"held-for-captain-h1","ask_id":"fm-ask/1:held-for-captain-h1:captain:1","ask_revision":1}' \
    "an open captain hold must publish its question identity"
  assert_contains "$records" '{"id":"plain-work-w1","ask_id":null,"ask_revision":null}' \
    "an unheld row must publish no question identity"
  assert_contains "$records" '{"id":"externally-held-e1","ask_id":null,"ask_revision":null}' \
    "a hold that is not the captain's question must publish no question identity"

  # A Done row keeps its "(hold: ...) (hold-kind: captain)" markers on the item
  # line, so this is the case that proves the published identity tracks the ask
  # rather than the leftover marker.
  assert_grep "hold-kind: captain" "$home/data/backlog.md" "the fixture lost the hold markers it is testing"
  assert_contains "$records" '{"id":"closed-ask-c1","ask_id":null,"ask_revision":null}' \
    "a closed row still carrying hold markers must publish no live question identity"
  pass "the snapshot publishes a question identity for exactly the open captain asks"
}

test_a_malformed_ledger_entry_degrades_to_revision_one() {
  local home id
  home=$(make_home malformed-ledger)
  id=placement-axes-p8
  compose_action_card "$home" "$id"
  cat > "$home/data/ask-revisions" <<EOF
# a hand-edit that went wrong
$id=not-a-number
other/subject=4
EOF
  [ "$(run_ask "$home" revision "$id")" = 1 ] || fail "a malformed revision was trusted"
  [ "$(published_ask_id "$home" "$id")" = "fm-ask/1:$id:captain:1" ] \
    || fail "a malformed ledger entry produced an identity instead of falling back to revision 1"
  pass "a malformed ledger entry is ignored rather than minting an identity"
}

test_reason_rewrite_preserves_the_identity
test_a_hold_refresh_preserves_the_identity
test_again_bumps_the_identity_and_writes_the_new_question
test_again_refuses_without_a_new_question
test_decision_hold_identity_survives_its_reason_rewrite
test_again_refuses_a_decision_hold
test_close_paths_leave_the_revision_alone
test_snapshot_publishes_an_identity_only_for_an_open_captain_ask
test_a_malformed_ledger_entry_degrades_to_revision_one

echo "# fm-ask.test.sh: all assertions passed"
