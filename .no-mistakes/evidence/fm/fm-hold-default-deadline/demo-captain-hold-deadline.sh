#!/usr/bin/env bash
# End-to-end demo: real bin scripts + real tasks-axi against a scratch home.
set -u
ROOT=$1
H=$(mktemp -d /tmp/nm-hold-demo.XXXXXX)
mkdir -p "$H/data/sample-route-review" "$H/state" "$H/config" "$H/projects"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
cat > "$H/data/backlog.md" <<'EOF'
## In flight
- [ ] sample-route-review - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued
- [ ] old-open-question - Pre-branch captain question with no deadline (repo: sample) (hold: waiting on captain) (hold-kind: captain)
- [ ] old-dated-question - Pre-branch captain question already lapsed (repo: sample) (hold: captain must pick a vendor) (hold-kind: captain) (hold-until: 2026-08-01)
- [ ] live-question - Captain question still inside its window (repo: sample) (hold: captain must pick a colour) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] s1 - Time gated ship work (repo: sample) (kind: ship) (hold: waiting on release) (hold-until: 2000-01-01)
- [ ] plain-work - Ordinary ready work (repo: sample) (kind: ship)
- [ ] main-thread - Main-side thread that needs the captain (repo: sample)

## Done
- [x] answered-question - Answered captain question with surviving markers (repo: sample) (hold: captain must pick a name) (hold-kind: captain) (hold-until: 2026-08-01)
EOF
run() { { printf '\n$ %s\n' "$*"; ( cd "$H" && env -u FM_HOME FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$@" ) 2>&1; printf '[exit %s]\n' "$?"; } | sed "s|$H|<scratch-home>|g; s|$ROOT/||g"; }
line() { printf '\n# backlog line for %s:\n' "$1"; grep -E "^- \[[ x]\] $1 -" "$H/data/backlog.md"; }
DH="$ROOT/bin/fm-decision-hold.sh"; CH="$ROOT/bin/fm-captain-hold.sh"
cp "$H/data/backlog.md" "$H/backlog.before"

echo "===== today (local clock): $(date +%Y-%m-%d)  expected default deadline: today + 7 days ====="

echo; echo "===== 1. DEFAULT APPLIED: fm-decision-hold.sh hold with no --hold-until ====="
run "$DH" hold sample-route-review route --title "Pick the sample route" --reason "captain must choose route A or B" --repo sample
line sample-route-review-decision-route

echo; echo "===== 2. EXPLICIT OVERRIDE HONOURED ====="
run "$DH" hold sample-route-review access --title "Grant sample access" --reason "captain must approve access" --repo sample --hold-until 2026-12-01
line sample-route-review-decision-access

echo; echo "===== 3. NO-DEADLINE OPT-OUT HONOURED (--hold-until none) ====="
run "$DH" hold sample-route-review vision --title "Open-ended product vision" --reason "captain is thinking it over" --repo sample --hold-until none
line sample-route-review-decision-vision

echo; echo "===== 4. IDEMPOTENT RE-HOLD keeps an unreached deadline (2026-12-01 must survive) ====="
run "$DH" hold sample-route-review access --title "Grant sample access" --reason "captain must approve access" --repo sample
line sample-route-review-decision-access

echo; echo "===== 5. bin/fm-captain-hold.sh (main-side thread / stow producer) ====="
run "$CH" main-thread --reason "captain must confirm the rollout"
line main-thread
run "$CH" main-thread --reason "captain must confirm the rollout" --hold-until 2026-02-30
run "$CH" main-thread --reason "captain must confirm the rollout" --hold-until 2026-01-01
run "$CH" main-thread --reason
run "$CH" answered-question --reason "new question on a done row"
run "$CH" no-such-item --reason "x"

echo; echo "===== 6. EXISTING HOLDS UNTOUCHED: pre-existing rows byte-identical after all writes above ====="
for id in old-open-question old-dated-question live-question s1 plain-work answered-question; do
  b=$(grep -E "^- \[[ x]\] $id -" "$H/backlog.before"); a=$(grep -E "^- \[[ x]\] $id -" "$H/data/backlog.md")
  if [ "$b" = "$a" ]; then echo "unchanged: $a"; else echo "CHANGED: $id"; echo "  before: $b"; echo "  after:  $a"; fi
done

echo; echo "===== 7. LAPSE IS DEMOTION: tasks-axi's own view of the lapsed captain hold ====="
run tasks-axi show old-dated-question --full

echo; echo "===== 8. READY PATH: raw tasks-axi ready (offers the lapsed captain hold) vs bin/fm-ready.sh ====="
run tasks-axi ready
run "$ROOT/bin/fm-ready.sh"

echo; echo "===== 9. FLEET SNAPSHOT held / lapsed flags (captain-only scope, done-row guard) ====="
printf '\n$ bin/fm-fleet-snapshot.sh --json | jq <id,state,hold_kind,hold_until,held,lapsed,captain_actionable>\n'
( cd "$H" && FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" PATH="$H/fakebin:$PATH" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>&1 ) \
  | jq -r '.backlog.records[] | select(.id != null) | [.id, .state, (.hold_kind // "-"), (.hold_until // "-"), "held=\(.held)", "lapsed=\(.lapsed)", "captain_actionable=\(.captain_actionable)"] | @tsv' | column -t

echo; echo "===== 10. RE-HOLD of a LAPSED hold takes a fresh default; nothing was closed or unheld ====="
run "$CH" old-dated-question --reason "captain must pick a vendor"
line old-dated-question
run "$ROOT/bin/fm-ready.sh"
rm -rf "$H"
