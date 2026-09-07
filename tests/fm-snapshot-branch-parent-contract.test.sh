#!/usr/bin/env bash
# tests/fm-snapshot-branch-parent-contract.test.sh - pins the base / pr_base pair
# on bin/fm-fleet-snapshot.sh's task rows against
# tests/fixtures/snapshot-branch-parent/cases.json, the shared statement of a
# task branch's parent. docs/architecture.md ("Cross-repo contracts are stated as
# fixtures") owns why that pairing lives in a fixture: the logbook board builds a
# branch tree from these two fields inside a 15-second loop and must never have
# to ask the forge for a PR's base.
#
# Every case declared as diverging is asserted to STILL diverge from the peer's
# recorded value, so a field that quietly converged fails instead of passing
# vacuously; the connector itself is not run here.
#
# This drives bin/fm-fleet-snapshot.sh --json, which needs jq, so it self-skips
# on a missing jq exactly like its snapshot-bearings siblings.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FIXTURE="$ROOT/tests/fixtures/snapshot-branch-parent/cases.json"
[ -f "$FIXTURE" ] || fail "missing fixture: $FIXTURE"
jq -e . "$FIXTURE" >/dev/null 2>&1 || fail "fixture is not valid JSON: $FIXTURE"

TMP_ROOT=$(fm_test_tmproot fm-snapshot-branch-parent)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects/repo"

# One task per case, named for the case, so a failure names the contract row it
# broke. The placeholder paths keep the fixture free of absolute paths that
# would rot; nothing in this contract depends on their targets existing.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  jq -r --arg n "$name" '.cases[] | select(.name == $n) | .meta[]' "$FIXTURE" \
    | sed -e "s#WORKTREE#$HOME_DIR/projects/repo#" -e "s#HOME#$HOME_DIR/second#" \
      -e "s#PROJECT#$HOME_DIR/projects/repo#" \
    > "$HOME_DIR/state/$name.meta"
done < <(jq -r '.cases[].name' "$FIXTURE")

SNAP="$TMP_ROOT/snapshot.json"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$SNAP" 2>"$TMP_ROOT/snapshot.err" \
  || fail "fm-fleet-snapshot.sh --json failed: $(cat "$TMP_ROOT/snapshot.err")"

# --- every case produces exactly the pair the fixture states ----------------

WANT_N=$(jq '.cases | length' "$FIXTURE")
GOT_N=$(jq '.tasks | length' "$SNAP")
[ "$WANT_N" = "$GOT_N" ] || \
  fail "the fixture states $WANT_N cases but the snapshot produced $GOT_N task rows"
[ "$WANT_N" -ge 6 ] || fail "the branch-parent fixture went thin: only $WANT_N cases"

# Compared field by field against the fixture's own key set, and both fields must
# be PRESENT strings: an absent key and a null are the failures this pins, since
# the consumer treats empty as a real answer rather than as missing data.
MISMATCH=$(jq -r --slurpfile snap "$SNAP" '
  ($snap[0].tasks) as $got
  | .cases[]
  | . as $c
  | ([ $got[] | select(.id == $c.name) ]) as $hits
  | if ($hits | length) != 1 then
      "case \($c.name): \($hits | length) task rows carry that id"
    else
      $hits[0] as $r
      | [ ( $c.expect | keys[]
            | . as $k
            | if ($r | has($k) | not) then "case \($c.name): the task row has no \($k) field"
              elif ($r[$k] | type) != "string" then
                "case \($c.name): \($k) is \($r[$k] | type), want string"
              elif $r[$k] != $c.expect[$k] then
                "case \($c.name): \($k) is \($r[$k] | tojson), want \($c.expect[$k] | tojson)"
              else empty end ) ][]
    end' "$FIXTURE")
[ -z "$MISMATCH" ] || fail "snapshot branch-parent contract mismatch:"$'\n'"$MISMATCH"
pass "every branch-parent case produces the pair the fixture states"

# --- a recorded divergence must still diverge -------------------------------

CONVERGED=$(jq -r '
  .cases[]
  | select(.peer.status == "diverge")
  | . as $c
  | ($c.peer.expect // {}) | to_entries[]
  | select(($c.expect[.key]) == .value)
  | "case \($c.name): \(.key) now matches the peer value \(.value | tojson) the fixture records as divergent"
' "$FIXTURE")
[ -z "$CONVERGED" ] || fail "a recorded divergence quietly converged:"$'\n'"$CONVERGED"

# A peer status the fixture's own vocabulary does not define would make the guard
# above silently inert.
UNKNOWN=$(jq -r '
  ["agree","diverge","dropped","planned"] as $known
  | .cases[]
  | (.peer.status // "") as $status
  | select(($known | index($status)) == null)
  | "case \(.name): unknown peer status \($status | tojson)"
' "$FIXTURE")
[ -z "$UNKNOWN" ] || fail "unknown peer status in the fixture:"$'\n'"$UNKNOWN"
pass "recorded peer divergences are still divergent"
