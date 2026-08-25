#!/usr/bin/env bash
# tests/fm-backlog-item-line-contract.test.sh - pins bin/fm-fleet-snapshot.sh's
# backlog_json against the shared contract fixture in
# tests/fixtures/backlog-item-line/.
#
# WHY A FIXTURE RATHER THAN ASSERTIONS IN THIS FILE. The AGENTS.md section 10
# item line is read twice: here, by the reader every firstmate surface is built
# from, and out of tree by the logbook connector, which reads the same lines
# through tasks-axi and its own title/id rules before putting them on a board the
# captain acts from. Two readers of one grammar drift silently, and consolidating
# them across a repo boundary is not possible. So the grammar is stated once, as
# data, and each side tests against it; this script is firstmate's half.
#
# The fixture's "peer" field records what the connector sees TODAY - agree,
# diverge with the value it observes instead, or dropped when the row never
# reaches it at all. Those are not assertions about the connector (it is not
# present here); they are the written-down disagreement the logbook side has to
# reconcile, and this script checks only that firstmate still answers what the
# fixture says it answers, and that a row marked as diverging still does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FIXTURE="$ROOT/tests/fixtures/backlog-item-line/cases.json"
[ -f "$FIXTURE" ] || fail "missing fixture: $FIXTURE"
jq -e . "$FIXTURE" >/dev/null 2>&1 || fail "fixture is not valid JSON: $FIXTURE"

TMP_ROOT=$(fm_test_tmproot fm-backlog-item-line-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

# The fixture is ordered; the sections are emitted in the order backlog_json
# reads them, so record N of the snapshot is case N of the fixture.
SECTIONS="In flight
Queued
Done"

{
  printf '# Backlog\n'
  while IFS= read -r section; do
    printf '\n## %s\n\n' "$section"
    jq -r --arg s "$section" '.cases[] | select(.section == $s) | .line, (.body // [])[]' "$FIXTURE"
  done <<EOS
$SECTIONS
EOS
} > "$HOME_DIR/data/backlog.md"

SNAP="$TMP_ROOT/snapshot.json"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$SNAP" 2>"$TMP_ROOT/snapshot.err" \
  || fail "fm-fleet-snapshot.sh --json failed: $(cat "$TMP_ROOT/snapshot.err")"

# --- every case parses to exactly the record the fixture states --------------

WANT_N=$(jq '.cases | length' "$FIXTURE")
GOT_N=$(jq '.backlog.records | length' "$SNAP")
[ "$WANT_N" = "$GOT_N" ] || \
  fail "the fixture states $WANT_N item lines but backlog_json produced $GOT_N records"
[ "$WANT_N" -ge 20 ] || fail "the backlog fixture went thin: only $WANT_N cases"

# The comparison is field-by-field against the fixture's own key set, so a field
# ADDED to the record later does not fail every case, while a field the contract
# names is compared exactly - including a null, which is a real answer here.
MISMATCH=$(jq -r --slurpfile snap "$SNAP" '
  ($snap[0].backlog.records) as $got
  | .cases
  | to_entries[]
  | .key as $i | .value as $c
  | ($got[$i]) as $r
  | [ ( if ($r.raw != $c.line)
        then "case \($c.name): raw is [\($r.raw)], want [\($c.line)]" else empty end ),
      ( ($c.section | if . == "In flight" then "in_flight" elif . == "Queued" then "queued" else "done" end) as $want_state
        | if ($r.state != $want_state)
          then "case \($c.name): state is \($r.state), want \($want_state)" else empty end ),
      ( $c.expect | to_entries[]
        | select(($r[.key]) != .value)
        | "case \($c.name): \(.key) is \($r[.key] | tojson), want \(.value | tojson)" )
    ][]
' "$FIXTURE")
[ -z "$MISMATCH" ] || fail "backlog_json no longer matches the contract fixture:
$MISMATCH"
pass "backlog_json parses all $WANT_N fixture item lines into exactly the records the contract states"

# --- the peer column still describes a real disagreement ---------------------
#
# A "diverge" case that quietly converged is a fixture row that has stopped
# saying anything, and a fixture that stopped saying anything is worse than none:
# it manufactures confidence that the two sides were compared. So every declared
# divergence must still differ from firstmate's answer on the field it names.
BAD_PEER=$(jq -r '
  .cases[]
  | . as $c
  | if ($c.peer.status == "diverge") then
      ( if ($c.peer.observed | type) != "object" or ($c.peer.observed | length) == 0
        then "case \($c.name): a diverge case must record what the peer observes instead"
        else ( $c.peer.observed | to_entries[]
               | select(($c.expect[.key]) == .value)
               | "case \($c.name): \(.key) no longer diverges from the peer; re-record it as an agreement" )
        end )
    elif ($c.peer.status == "agree" or $c.peer.status == "dropped") then empty
    else "case \($c.name): peer.status must be agree, diverge or dropped, got \($c.peer.status)"
    end
' "$FIXTURE")
[ -z "$BAD_PEER" ] || fail "the fixture's recorded divergences no longer describe the two sides:
$BAD_PEER"

N_AGREE=$(jq '[.cases[] | select(.peer.status == "agree")] | length' "$FIXTURE")
N_DIVERGE=$(jq '[.cases[] | select(.peer.status == "diverge")] | length' "$FIXTURE")
N_DROPPED=$(jq '[.cases[] | select(.peer.status == "dropped")] | length' "$FIXTURE")
[ "$N_DIVERGE" -ge 1 ] || fail "the fixture declares no divergence; the peer column has stopped saying anything"
[ "$N_DROPPED" -ge 1 ] || fail "the fixture records no dropped row; the id-grammar disagreement has stopped being tracked"
pass "the fixture's cross-repo record still holds: $N_AGREE agreements, $N_DIVERGE divergences, $N_DROPPED rows the logbook side never receives"

echo "# fm-backlog-item-line-contract.test.sh: all assertions passed"
