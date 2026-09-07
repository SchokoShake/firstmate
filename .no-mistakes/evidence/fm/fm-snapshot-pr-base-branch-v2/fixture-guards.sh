#!/usr/bin/env bash
# Proves the two guards in tests/fm-snapshot-branch-parent-contract.test.sh fire,
# plus that a wrong expectation is caught: each run mutates a copy of
# tests/fixtures/snapshot-branch-parent/cases.json in an exported copy of HEAD
# and runs the real contract test there.
set -u
ROOT=$(pwd)
TREE=$(mktemp -d /tmp/fm-guardcheck.XXXXXX); trap 'rm -rf "$TREE"' EXIT
git -C "$ROOT" archive HEAD | tar -x -C "$TREE"
FIX="$TREE/tests/fixtures/snapshot-branch-parent/cases.json"
ORIG="$ROOT/tests/fixtures/snapshot-branch-parent/cases.json"
run_case() {  # <label> <jq-mutation>
  printf '\n### %s\n$ jq %s cases.json > cases.json; bash tests/fm-snapshot-branch-parent-contract.test.sh\n' "$1" "$2"
  jq "$2" "$ORIG" > "$FIX"
  (cd "$TREE" && bash tests/fm-snapshot-branch-parent-contract.test.sh 2>&1; echo "[exit $?]")
}
printf '### control: the untouched fixture passes in the exported tree\n'
cp "$ORIG" "$FIX"; (cd "$TREE" && bash tests/fm-snapshot-branch-parent-contract.test.sh 2>&1; echo "[exit $?]")
run_case "guard 1: a divergence the fixture records has quietly converged" \
  '(.cases[] | select(.name=="restacked-pr-base-wins") | .peer) |= {status:"diverge", expect:{pr_base:"feature/stack-1"}, note:"peer reads the same value"}'
run_case "guard 2: a peer status outside the fixture vocabulary (would make guard 1 inert)" \
  '(.cases[] | select(.name=="both-agree") | .peer.status) = "agreed"'
run_case "expectation drift: fixture claims pr_base wins by being copied into base" \
  '(.cases[] | select(.name=="restacked-pr-base-wins") | .expect.base) = "feature/stack-1"'
run_case "shape drift: fixture expects null for an unknown parent" \
  '(.cases[] | select(.name=="neither-known") | .expect.pr_base) = null'
