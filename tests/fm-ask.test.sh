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

# tasks-axi judges hold activity on the real clock, so the pinned day sits far
# enough ahead that the deadline it yields is still live when this runs.
HOLD_NOW=2099-02-25
FRESH_UNTIL=2099-03-04

run_ask_on() {  # <today> <home> <args...>
  local today=$1
  shift
  FM_CAPTAIN_HOLD_NOW="$today" run_ask "$@"
}

run_ask_ledger_in() {  # <home> <ledger-dir> <args...>
  local home=$1 ledger_dir=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$ledger_dir" "$ASK" "$@"
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

# One field of the row as tasks-axi itself reports it.
shown_field() {  # <home> <id> <field>
  axi "$1" show "$2" --full | sed -n "s/^  $3: //p" | head -1
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

  rc=0; out=$(run_ask "$home" again "$id" --reason 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask whose --reason has no value"
  assert_contains "$out" "--reason is required" "a trailing --reason with no value must say what is missing"

  [ "$before" = "$(run_ask "$home" id "$id")" ] || fail "a refused re-ask still moved the identity"
  assert_absent "$home/data/ask-revisions" "a refused re-ask wrote the revision ledger"
  pass "a re-ask with no question to state is refused and moves nothing"
}

# The one write this script owns can fail for reasons only tasks-axi knows, and the
# ledger's presence is what says firstmate has re-asked in this home. The ledger
# lives in its own directory here so the backlog's can be made unwritable alone.
test_a_failed_re_ask_reports_why_and_leaves_the_ledger_as_it_found_it() {
  local home ledger_dir id other out rc before
  home=$(make_home write-failure)
  ledger_dir="$home/ledger"
  mkdir -p "$ledger_dir"
  id=placement-axes-p19
  compose_action_card "$home" "$id"

  rc=0; out=$(run_ask "$home" again "$id" --reason "   " 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask whose reason is only whitespace"
  assert_contains "$out" "--reason is required" "a blank reason states nothing and must say so"
  assert_absent "$home/data/ask-revisions" "a blank re-ask wrote the revision ledger"

  chmod 555 "$home/data"
  if [ -w "$home/data" ]; then
    chmod 755 "$home/data"
    pass "skipped: this user writes a mode-555 backlog directory anyway"
    return 0
  fi

  # tasks-axi cannot write the hold and says why on stdout.
  rc=0; out=$(run_ask_ledger_in "$home" "$ledger_dir" again "$id" --reason "the window moved" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask whose hold write tasks-axi cannot make"
  assert_contains "$out" "could not write the new question" "a failed re-ask must name what it could not do"
  assert_contains "$out" "permission denied" "a failed re-ask must carry what tasks-axi said about it"
  [ "$(run_ask_ledger_in "$home" "$ledger_dir" revision "$id")" = 1 ] || fail "the failed re-ask left the revision bumped"
  assert_absent "$ledger_dir/ask-revisions" \
    "a failed first re-ask left a revision ledger in a home that has never re-asked"

  chmod 755 "$home/data"
  other=placement-axes-p20
  compose_action_card "$home" "$other"
  run_ask_ledger_in "$home" "$ledger_dir" again "$other" --reason "the window moved; pick another" >/dev/null \
    || fail "the re-ask that gives the ledger its content failed"
  before=$(cat "$ledger_dir/ask-revisions")
  chmod 555 "$home/data"
  rc=0; run_ask_ledger_in "$home" "$ledger_dir" again "$id" --reason "the window moved" >/dev/null 2>&1 || rc=$?
  chmod 755 "$home/data"
  expect_code 1 "$rc" "a failed re-ask in a home that has re-asked before"
  [ "$before" = "$(cat "$ledger_dir/ask-revisions")" ] \
    || fail "a failed re-ask changed a ledger it did not create"
  pass "a re-ask that cannot be written says why and leaves the ledger as it found it"
}

# The bump is the first write, so its failure has to say where and why on its own.
test_a_failed_bump_names_the_ledger_and_the_cause() {
  local home id out rc
  home=$(make_home bump-failure)
  id=placement-axes-p23
  compose_action_card "$home" "$id"
  rc=0; out=$(run_ask_ledger_in "$home" "$home/no-such-dir" again "$id" --reason "the window moved" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask whose ledger directory does not exist"
  assert_contains "$out" "$home/no-such-dir/ask-revisions" "a failed bump must name the ledger it could not write"
  assert_contains "$out" "ledger directory does not exist" "a failed bump must say why the write failed"
  [ "$(shown_field "$home" "$id" hold_reason)" = "confirm the rollout window" ] \
    || fail "a re-ask whose bump failed still rewrote the question"
  pass "a revision bump that cannot be recorded names the ledger and the cause"
}

# tasks-axi reads a bare value beginning with -- as a flag, so the reason reaches it
# in the --reason=<value> form, which this script accepts too.
test_a_question_beginning_with_dashes_is_writable() {
  local home id
  home=$(make_home dashdash-reason)
  id=placement-axes-p21
  compose_action_card "$home" "$id"
  run_ask "$home" again "$id" --reason "--until is unset; pick a window" >/dev/null \
    || fail "a re-ask whose reason begins with -- was refused"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "a reason beginning with -- did not bump the revision"
  assert_grep "(hold: --until is unset; pick a window) (hold-kind: captain)" "$home/data/backlog.md" \
    "a reason beginning with -- was not written as the hold reason"

  run_ask "$home" again "$id" --reason="--kind was never the question; pick a window" >/dev/null \
    || fail "a re-ask in the --reason=<value> form was refused"
  [ "$(run_ask "$home" revision "$id")" = 3 ] || fail "the --reason=<value> form did not bump the revision"
  assert_grep "(hold: --kind was never the question; pick a window) (hold-kind: captain)" "$home/data/backlog.md" \
    "the --reason=<value> form did not write the hold reason"
  [ "$(shown_field "$home" "$id" hold_kind)" = captain ] || fail "a reason naming a flag changed the hold kind"
  pass "a question beginning with -- is written and bumps the revision in either --reason form"
}

# Running `again` is itself the declaration that this is a new question, so it
# re-asks on the author's word rather than on how much the prose changed.
test_again_re_asks_on_the_authors_word_not_on_changed_prose() {
  local home id before after
  home=$(make_home explicit-re-ask)
  id=placement-axes-p18
  compose_action_card "$home" "$id"
  before=$(run_ask "$home" id "$id")

  after=$(run_ask "$home" again "$id" --reason "confirm the rollout window") \
    || fail "a re-ask restating the current reason was refused"
  [ "$before" != "$after" ] || fail "the explicit re-ask did not move the identity"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the explicit re-ask did not bump the revision"
  [ "$(shown_field "$home" "$id" hold_reason)" = "confirm the rollout window" ] \
    || fail "the re-ask changed the question it was told to ask again"

  # The safe path is unchanged: only the explicit command moves the revision.
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain >/dev/null
  axi "$home" hold "$id" --reason "confirm the window before the Friday train" --kind captain >/dev/null
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "a hold rewrite moved the revision the author did not bump"

  run_ask "$home" again "$id" --reason "confirm the window before the Friday train" >/dev/null \
    || fail "a second re-ask on unchanged wording was refused"
  [ "$(run_ask "$home" revision "$id")" = 3 ] || fail "the second explicit re-ask did not bump the revision"
  pass "a re-ask bumps on the explicit command, and only that command bumps it"
}

# tasks-axi renders a reason holding a quote, a backslash, or a colon as a quoted,
# backslash-escaped TOON value, and a rewrite of one must still preserve the identity.
test_a_quoted_reason_rewrites_without_re_asking() {
  local home id reason before
  home=$(make_home quoted-reason)
  id=placement-axes-p9
  reason='ship "axes" from C:\builds\axes: this week'
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "$reason" --kind captain >/dev/null
  before=$(run_ask "$home" id "$id")

  axi "$home" hold "$id" --reason 'ship "axes" from D:\builds\axes: this week' --kind captain >/dev/null
  [ "$before" = "$(run_ask "$home" id "$id")" ] || fail "rewriting a quoted reason changed the question identity"
  assert_absent "$home/data/ask-revisions" "rewriting a quoted reason wrote the revision ledger"

  run_ask "$home" again "$id" --reason 'ship "axes" from D:\builds\axes: next week' >/dev/null \
    || fail "a re-ask with a quoted reason failed"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the re-ask of a quoted reason did not bump the revision"
  assert_grep 'D:\builds\axes: next week' "$home/data/backlog.md" "the quoted reason was not written as the hold reason"
  pass "a quoted reason rewrites without re-asking, and re-asks only on the explicit command"
}

test_concurrent_re_asks_keep_every_ledger_line() {
  local home i id pid
  local -a pids=()
  home=$(make_home concurrent)
  for i in 1 2 3 4 5 6; do
    compose_action_card "$home" "placement-axes-c$i"
  done
  for i in 1 2 3 4 5 6; do
    run_ask "$home" again "placement-axes-c$i" --reason "train $i closed; pick the next window" >/dev/null 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a concurrent re-ask failed"
  done
  for i in 1 2 3 4 5 6; do
    id="placement-axes-c$i"
    [ "$(run_ask "$home" revision "$id")" = 2 ] \
      || fail "$id lost its re-ask to a concurrent one; the ledger reads: $(cat "$home/data/ask-revisions")"
  done
  pass "concurrent re-asks in one home serialize on the ledger and none drops another's line"
}

# A re-ask is a new question, so it takes today plus the default window whatever
# the row carried. The earlier deadline lies beyond the fresh one, so keeping a
# deadline the clock has not reached would show up as the old date surviving.
test_again_writes_a_fresh_default_deadline() {
  local home id bare row
  home=$(make_home deadline)
  id=placement-axes-p13
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain --until 2099-12-31 >/dev/null
  [ "$(shown_field "$home" "$id" hold_until)" = 2099-12-31 ] || fail "the fixture lost its hold deadline"
  run_ask_on "$HOLD_NOW" "$home" again "$id" --reason "the Friday train closed; pick the next window" >/dev/null \
    || fail "the re-ask of a dated hold failed"
  [ "$(shown_field "$home" "$id" hold_until)" = "$FRESH_UNTIL" ] \
    || fail "the re-ask of a hold with a future deadline wrote $(shown_field "$home" "$id" hold_until), not the fresh default $FRESH_UNTIL"
  [ "$(shown_field "$home" "$id" held)" = yes ] || fail "the re-asked dated question is not a live hold"
  row=$(grep -F -- "- [ ] $id " "$home/data/backlog.md") || fail "the re-asked dated row vanished from the backlog"
  assert_contains "$row" "the Friday train closed" "the re-ask of a dated hold did not write the new question"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the re-ask of a dated hold did not bump the revision"

  bare=placement-axes-p25
  compose_action_card "$home" "$bare"
  row=$(grep -F -- "- [ ] $bare " "$home/data/backlog.md") || fail "the deadline-free fixture row is missing"
  assert_not_contains "$row" "hold-until:" "the fixture hold was not written without a deadline"
  run_ask_on "$HOLD_NOW" "$home" again "$bare" --reason "the Friday train closed; pick the next window" >/dev/null \
    || fail "the re-ask of a hold with no deadline failed"
  [ "$(shown_field "$home" "$bare" hold_until)" = "$FRESH_UNTIL" ] \
    || fail "the re-ask of a hold with no deadline wrote $(shown_field "$home" "$bare" hold_until), not the fresh default $FRESH_UNTIL"
  [ "$(shown_field "$home" "$bare" held)" = yes ] || fail "the re-asked deadline-free question is not a live hold"
  pass "a re-ask writes the fresh default deadline over a future deadline and over none"
}

# A default that cannot be computed must stop the re-ask before its first write,
# never fall back to a hold that cannot lapse.
test_an_uncomputable_default_deadline_fails_the_re_ask_before_any_write() {
  local home id other out rc backlog_before ledger_before
  home=$(make_home uncomputable-deadline)
  id=placement-axes-p26
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain --until 2099-12-31 >/dev/null
  backlog_before=$(cat "$home/data/backlog.md")

  rc=0; out=$(run_ask_on not-a-date "$home" again "$id" --reason "the Friday train closed; pick the next window" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask whose default deadline cannot be computed"
  assert_contains "$out" "could not compute the default hold deadline" \
    "a re-ask with no computable deadline must say why it stopped"
  assert_absent "$home/data/ask-revisions" "a re-ask with no computable deadline wrote the revision ledger"
  [ "$backlog_before" = "$(cat "$home/data/backlog.md")" ] \
    || fail "a re-ask with no computable deadline rewrote the backlog"
  [ "$(run_ask "$home" revision "$id")" = 1 ] || fail "a re-ask with no computable deadline moved the revision"

  other=placement-axes-p27
  compose_action_card "$home" "$other"
  run_ask_on "$HOLD_NOW" "$home" again "$other" --reason "the window moved; pick another" >/dev/null \
    || fail "the re-ask that gives the ledger its content failed"
  ledger_before=$(cat "$home/data/ask-revisions")
  backlog_before=$(cat "$home/data/backlog.md")
  rc=0; run_ask_on not-a-date "$home" again "$id" --reason "the Friday train closed" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a re-ask with no computable deadline in a home that has re-asked before"
  [ "$ledger_before" = "$(cat "$home/data/ask-revisions")" ] \
    || fail "a re-ask with no computable deadline changed the revision ledger"
  [ "$backlog_before" = "$(cat "$home/data/backlog.md")" ] \
    || fail "a re-ask with no computable deadline rewrote the backlog in a home that has re-asked before"
  [ "$(shown_field "$home" "$id" hold_until)" = 2099-12-31 ] \
    || fail "a re-ask with no computable deadline changed the deadline the row carried"
  pass "a re-ask whose default deadline cannot be computed fails before the ledger or the row is touched"
}

# "-" is a legal hold reason as well as how tasks-axi renders an absent field, and
# the row it makes is a captain question like any other.
test_a_hold_whose_reason_is_a_dash_is_still_a_question() {
  local home id before
  home=$(make_home dash-reason)
  id=placement-axes-p17
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "-" --kind captain >/dev/null
  before=$(run_ask "$home" id "$id") || fail "fm-ask.sh id refused a captain hold whose reason is a dash"
  [ "$before" = "$(published_ask_id "$home" "$id")" ] \
    || fail "fm-ask.sh and the published snapshot disagree about a dash-reason hold"
  run_ask "$home" again "$id" --reason "say what the window actually is" >/dev/null \
    || fail "the re-ask of a dash-reason hold failed"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the re-ask of a dash-reason hold did not bump the revision"
  pass "a captain hold whose reason is a dash is askable and re-askable"
}

# tasks-axi gates a dated hold by that date, so a hold whose --until has passed is
# lapsed while the item line keeps its hold markers. The row is still the same
# unanswered question, so both surfaces must still answer for it.
test_a_lapsed_hold_stays_askable_and_re_asks_live() {
  local home id unheld before out rc
  home=$(make_home lapsed)
  id=placement-axes-p14
  axi "$home" add "$id" "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold "$id" --reason "confirm the rollout window" --kind captain --until 2020-01-01 >/dev/null
  [ "$(shown_field "$home" "$id" hold_until)" = 2020-01-01 ] \
    || fail "the fixture lost the past deadline that makes it lapsed"

  before=$(run_ask "$home" id "$id") || fail "fm-ask.sh id refused a lapsed captain hold"
  [ "$before" = "$(published_ask_id "$home" "$id")" ] \
    || fail "fm-ask.sh and the published snapshot disagree about a lapsed hold's identity"
  [ "$(run_ask "$home" revision "$id")" = 1 ] || fail "a lapse moved the revision"
  assert_absent "$home/data/ask-revisions" "a lapse wrote the revision ledger"

  unheld=placement-axes-p15
  axi "$home" add "$unheld" "no question here" --kind ship --repo myapp --start >/dev/null
  rc=0; out=$(run_ask "$home" id "$unheld" 2>&1) || rc=$?
  expect_code 1 "$rc" "an identity asked of a row carrying no hold"
  assert_contains "$out" "is not held" "a row with no hold at all must still have no question identity"

  run_ask_on "$HOLD_NOW" "$home" again "$id" --reason "the rollout window lapsed; pick the next one" >/dev/null \
    || fail "the deliberate re-ask of a lapsed hold failed"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the re-ask of a lapsed hold did not bump the revision"
  [ "$(shown_field "$home" "$id" hold_until)" = "$FRESH_UNTIL" ] \
    || fail "the re-ask of a lapsed hold wrote $(shown_field "$home" "$id" hold_until), not the fresh default $FRESH_UNTIL"
  [ "$(shown_field "$home" "$id" held)" = yes ] \
    || fail "the re-asked question is not a live hold; it was asked already lapsed"
  pass "a lapsed captain hold keeps its identity, stays askable, and re-asks as a live question"
}

# The one direction the design guards against: a subject dropping back to an earlier
# revision lets an old answer settle a genuinely new question. An unreadable ledger
# is not an empty one.
test_an_unreadable_ledger_never_answers_revision_one() {
  local home id out rc published
  home=$(make_home unreadable-ledger)
  id=placement-axes-p16
  compose_action_card "$home" "$id"
  run_ask "$home" again "$id" --reason "the Friday train closed; pick the next window" >/dev/null \
    || fail "the re-ask that gives the ledger its content failed"
  [ "$(published_ask_revision "$home" "$id")" = 2 ] || fail "the re-asked subject is not published at revision 2"

  chmod 000 "$home/data/ask-revisions"
  if [ -r "$home/data/ask-revisions" ]; then
    chmod 600 "$home/data/ask-revisions"
    pass "skipped: this user reads a mode-000 ledger anyway"
    return 0
  fi

  rc=0; out=$(run_ask "$home" revision "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "a revision read of an unreadable ledger"
  assert_contains "$out" "could not read the revision ledger" \
    "an unreadable ledger must say so rather than answer 1"
  rc=0; out=$(run_ask "$home" id "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "an identity read of an unreadable ledger"
  published=$(published_ask_id "$home" "$id" 2>/dev/null)
  [ "$published" = null ] \
    || fail "an unreadable ledger published an identity instead of null: $published"

  chmod 600 "$home/data/ask-revisions"
  [ "$(run_ask "$home" revision "$id")" = 2 ] || fail "the readable ledger no longer answers revision 2"
  pass "an unreadable ledger refuses and publishes no identity instead of reverting to revision 1"
}

test_a_re_ask_keeps_human_annotations_in_the_ledger() {
  local home expected
  home=$(make_home annotated-ledger)
  compose_action_card "$home" placement-axes-p11
  compose_action_card "$home" placement-axes-p12
  cat > "$home/data/ask-revisions" <<'EOF'
# why p11 was re-asked: the Friday train closed

placement-axes-p11=2
other-subject=4
a line the ledger does not recognize
EOF
  run_ask "$home" again placement-axes-p11 --reason "the next window slipped too" >/dev/null \
    || fail "the re-ask of an annotated subject failed"
  expected='# why p11 was re-asked: the Friday train closed

placement-axes-p11=3
other-subject=4
a line the ledger does not recognize'
  [ "$(cat "$home/data/ask-revisions")" = "$expected" ] \
    || fail "the re-ask did not rewrite only its own line; the ledger reads:"$'\n'"$(cat "$home/data/ask-revisions")"
  [ "$(run_ask "$home" revision placement-axes-p11)" = 3 ] || fail "the in-place rewrite did not record revision 3"

  run_ask "$home" again placement-axes-p12 --reason "the rollout window moved" >/dev/null \
    || fail "the re-ask of a subject with no line failed"
  expected="$expected"$'\n''placement-axes-p12=2'
  [ "$(cat "$home/data/ask-revisions")" = "$expected" ] \
    || fail "a subject with no line was not appended after the annotations; the ledger reads:"$'\n'"$(cat "$home/data/ask-revisions")"
  pass "a re-ask keeps every comment and unrecognized line and rewrites only its own subject"
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

  # The close paths replace the hold body before the row is Done, and AGENTS.md
  # section 10 has an author replace a considered body with an updated note, so the
  # body cannot be what tells a decision hold apart from an ordinary captain ask.
  axi "$home" update "$id" --body "note: the guard question is still open" >/dev/null
  rc=0; out=$(run_ask "$home" again "$id" --reason "a third question about the guard" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask aimed at a decision hold whose body was rewritten"
  assert_contains "$out" "fm-decision-hold.sh hold" \
    "a rewritten body must not turn a decision hold into a re-askable captain ask"
  assert_absent "$home/data/ask-revisions" "the refused decision-hold re-ask wrote the revision ledger"
  pass "a decision hold is re-asked with a new decision key, not by bumping a revision"
}

# The refusal has to say which state it found, because "not held" sends an operator
# looking for a hold that is right there.
test_a_refusal_names_the_hold_it_found() {
  local home out rc
  home=$(make_home refusal-diagnostics)
  axi "$home" add kindless-hold-k1 "waiting on something" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold kindless-hold-k1 --reason "held with no kind at all" >/dev/null
  rc=0; out=$(run_ask "$home" id kindless-hold-k1 2>&1) || rc=$?
  expect_code 1 "$rc" "an identity asked of a hold with no kind"
  assert_not_contains "$out" "is not held" "a row that is held must not be refused as unheld"
  assert_contains "$out" "not for the captain" "a kindless hold must be refused for not being the captain's"

  axi "$home" add vendor-hold-v1 "waiting on a vendor" --kind ship --repo myapp --start >/dev/null
  axi "$home" hold vendor-hold-v1 --reason "vendor has not shipped the SDK" --kind external >/dev/null
  rc=0; out=$(run_ask "$home" id vendor-hold-v1 2>&1) || rc=$?
  expect_code 1 "$rc" "an identity asked of an external hold"
  assert_contains "$out" "held for external" "a non-captain hold must name the kind it is held for"
  pass "a refusal names the hold state the row is actually in"
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

# A malformed value on a valid subject is not an absent line: reading it as
# revision 1 would return a re-asked subject to an identity an old answer settles.
test_a_malformed_revision_value_publishes_no_identity() {
  local home id other absent out rc command expected
  home=$(make_home malformed-ledger)
  id=placement-axes-p8
  other=placement-axes-p22
  absent=placement-axes-p24
  compose_action_card "$home" "$id"
  compose_action_card "$home" "$other"
  compose_action_card "$home" "$absent"
  expected="# a hand-edit that went wrong
$id=four
$other=3
other/subject=4
a line the ledger does not recognize"
  printf '%s\n' "$expected" > "$home/data/ask-revisions"

  for command in id revision; do
    rc=0; out=$(run_ask "$home" "$command" "$id" 2>&1) || rc=$?
    expect_code 1 "$rc" "fm-ask.sh $command on a subject whose ledger value is malformed"
    assert_contains "$out" "$id=four" "fm-ask.sh $command must name the malformed ledger line"
    assert_contains "$out" "$home/data/ask-revisions" "fm-ask.sh $command must name the ledger holding the malformed line"
  done
  rc=0; out=$(run_ask "$home" again "$id" --reason "the Friday train closed; pick the next window" 2>&1) || rc=$?
  expect_code 1 "$rc" "a re-ask of a subject whose ledger value is malformed"
  assert_contains "$out" "$id=four" "a refused re-ask must name the malformed ledger line"
  [ "$(shown_field "$home" "$id" hold_reason)" = "confirm the rollout window" ] \
    || fail "a re-ask refused over a malformed revision still rewrote the question"
  [ "$(cat "$home/data/ask-revisions")" = "$expected" ] || fail "a refused re-ask rewrote the ledger"

  [ "$(published_ask_id "$home" "$id")" = null ] \
    || fail "a malformed revision value published an identity instead of null"
  [ "$(published_ask_revision "$home" "$id")" = null ] \
    || fail "a malformed revision value published a revision instead of null"
  [ "$(published_ask_id "$home" "$other")" = "fm-ask/1:$other:captain:3" ] \
    || fail "a malformed value on one subject took another subject's identity with it"
  [ "$(published_ask_id "$home" "$absent")" = "fm-ask/1:$absent:captain:1" ] \
    || fail "a subject with no ledger line stopped reading as revision 1"
  [ "$(run_ask "$home" revision "$absent")" = 1 ] || fail "an absent line stopped meaning revision 1"

  # The malformed line and the ignored ones survive another subject's re-ask.
  run_ask "$home" again "$other" --reason "the next window slipped too" >/dev/null \
    || fail "a malformed line for one subject blocked another subject's re-ask"
  expected=${expected/"$other=3"/"$other=4"}
  [ "$(cat "$home/data/ask-revisions")" = "$expected" ] \
    || fail "a re-ask did not preserve the lines it does not own; the ledger reads:"$'\n'"$(cat "$home/data/ask-revisions")"

  # The last line for a subject wins, so a later valid line is the correction.
  printf '%s=5\n' "$id" >> "$home/data/ask-revisions"
  [ "$(run_ask "$home" revision "$id")" = 5 ] || fail "a corrected line did not restore the subject's revision"
  [ "$(published_ask_id "$home" "$id")" = "fm-ask/1:$id:captain:5" ] \
    || fail "a corrected line did not restore the published identity"
  pass "a malformed revision value fails loudly and publishes null for that subject only"
}

test_a_leading_zero_revision_is_read_as_its_number() {
  local home id
  home=$(make_home leading-zero)
  id=placement-axes-p10
  compose_action_card "$home" "$id"
  printf '%s=08\n' "$id" > "$home/data/ask-revisions"
  [ "$(run_ask "$home" revision "$id")" = 8 ] || fail "a hand-written 08 was not read as revision 8"
  [ "$(published_ask_id "$home" "$id")" = "fm-ask/1:$id:captain:8" ] \
    || fail "the published identity kept the leading zero"
  [ "$(published_ask_revision "$home" "$id")" = 8 ] || fail "the published revision kept the leading zero"
  run_ask "$home" again "$id" --reason "the Friday train closed; pick the next window" >/dev/null \
    || fail "a re-ask after a hand-written 08 failed"
  [ "$(run_ask "$home" revision "$id")" = 9 ] || fail "the re-ask after 08 did not reach revision 9"
  assert_grep "$id=9" "$home/data/ask-revisions" "the ledger did not normalize the hand-written 08"
  pass "a hand-written leading zero reads as its number and a re-ask bumps from it"
}

# data/backlog.md is hand-maintainable, so one id can appear on a Done row and on
# an open row at once; only the open row is a question to the captain.
test_snapshot_publishes_no_identity_on_a_done_row_sharing_an_open_rows_id() {
  local home id row rows
  home=$(make_home duplicate-id)
  id=twice-listed-t1
  compose_action_card "$home" "$id"
  axi "$home" "done" "$id" >/dev/null
  row="- [ ] $id - asked again under a reused id (repo: myapp) (kind: ship) (since 2026-09-02) (hold: confirm the rollout window) (hold-kind: captain)"
  awk -v line="$row" '{ print } /^## In flight/ { print line }' "$home/data/backlog.md" > "$home/data/backlog.md.new" \
    && mv "$home/data/backlog.md.new" "$home/data/backlog.md"

  rows=$(FM_HOME="$home" "$SNAPSHOT" --json | jq -c --arg id "$id" '
    [ .backlog.records[] | select(.id == $id) | {state, ask_id} ] | sort_by(.state)')
  [ "$rows" = "[{\"state\":\"done\",\"ask_id\":null},{\"state\":\"in_flight\",\"ask_id\":\"fm-ask/1:$id:captain:1\"}]" ] \
    || fail "a Done row sharing an open row's id published the wrong identities: $rows"
  pass "a Done row publishes no identity even when an open row shares its id"
}

test_reason_rewrite_preserves_the_identity
test_a_hold_refresh_preserves_the_identity
test_again_bumps_the_identity_and_writes_the_new_question
test_again_refuses_without_a_new_question
test_again_re_asks_on_the_authors_word_not_on_changed_prose
test_a_failed_re_ask_reports_why_and_leaves_the_ledger_as_it_found_it
test_a_failed_bump_names_the_ledger_and_the_cause
test_a_question_beginning_with_dashes_is_writable
test_a_quoted_reason_rewrites_without_re_asking
test_concurrent_re_asks_keep_every_ledger_line
test_again_writes_a_fresh_default_deadline
test_an_uncomputable_default_deadline_fails_the_re_ask_before_any_write
test_a_lapsed_hold_stays_askable_and_re_asks_live
test_a_hold_whose_reason_is_a_dash_is_still_a_question
test_an_unreadable_ledger_never_answers_revision_one
test_a_re_ask_keeps_human_annotations_in_the_ledger
test_decision_hold_identity_survives_its_reason_rewrite
test_again_refuses_a_decision_hold
test_a_refusal_names_the_hold_it_found
test_close_paths_leave_the_revision_alone
test_snapshot_publishes_an_identity_only_for_an_open_captain_ask
test_a_malformed_revision_value_publishes_no_identity
test_a_leading_zero_revision_is_read_as_its_number
test_snapshot_publishes_no_identity_on_a_done_row_sharing_an_open_rows_id

echo "# fm-ask.test.sh: all assertions passed"
