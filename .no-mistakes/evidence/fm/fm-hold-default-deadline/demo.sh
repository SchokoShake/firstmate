#!/usr/bin/env bash
# End-to-end demo against a throwaway FM_HOME (never a live one).
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-hold-demo.XXXXXX)
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
axi() { (cd "$H" && tasks-axi "$@"); }
fm() { local s=$1; shift; FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" "$ROOT/bin/$s" "$@"; }
show() { axi show "$1" --full | grep -E '^  (held|hold_kind|hold_until|hold_reason):' ; }
step() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

echo "real local date: $(date +%Y-%m-%d)   tasks-axi $(tasks-axi --version)"

step "0. pre-existing holds written before this change (one with no deadline, one lapsed, one future)"
axi add old-open "legacy open-ended question" --kind ship --repo myapp >/dev/null
axi hold old-open --reason "legacy question, no deadline" --kind captain >/dev/null
axi add old-lapsed "legacy lapsed question" --kind ship --repo myapp >/dev/null
axi hold old-lapsed --reason "legacy question, lapsed" --kind captain --until 2020-01-01 >/dev/null
axi add old-future "legacy future question" --kind ship --repo myapp >/dev/null
axi hold old-future --reason "legacy question, long window" --kind captain --until 2099-12-31 >/dev/null
BEFORE=$(grep -E 'old-(open|lapsed|future)' "$H/data/backlog.md")
printf '%s\n' "$BEFORE"

step "1. fm-captain-hold.sh with NO --hold-until -> default today+7"
axi add thread-a "pick the rollout window" --kind ship --repo myapp >/dev/null
run fm fm-captain-hold.sh thread-a --reason "which rollout window?"
show thread-a

step "2. explicit --hold-until override"
axi add thread-b "pick the vendor" --kind ship --repo myapp >/dev/null
run fm fm-captain-hold.sh thread-b --reason "which vendor?" --hold-until 2026-12-01
show thread-b

step "3. documented opt-out: --hold-until none"
axi add thread-c "open-ended strategy question" --kind ship --repo myapp >/dev/null
run fm fm-captain-hold.sh thread-c --reason "long-term direction?" --hold-until none
show thread-c

step "4. fm-decision-hold.sh hold with NO --hold-until -> default today+7"
axi add scout-1 "scout the thing" --kind scout --repo myapp --start >/dev/null
run fm fm-decision-hold.sh hold scout-1 adopt-axes --title "Adopt the new axes?" --reason "adopt or defer"
DID=$(fm fm-decision-hold.sh id scout-1 adopt-axes); echo "decision hold id: $DID"
show "$DID"

step "5. fm-ask.sh again -> FRESH default, whatever the row carried (future / lapsed / none)"
for id in old-future old-lapsed old-open; do
  echo "-- $id before:"; show "$id"
done
# old-* rows above are the 'existing holds untouched' evidence; re-ask copies instead
for pair in "ask-future 2099-12-31" "ask-lapsed 2020-01-01" "ask-none -"; do
  set -- $pair
  axi add "$1" "re-ask fixture $1" --kind ship --repo myapp >/dev/null
  if [ "$2" = - ]; then axi hold "$1" --reason "first wording" --kind captain >/dev/null
  else axi hold "$1" --reason "first wording" --kind captain --until "$2" >/dev/null; fi
  echo "-- $1 before re-ask:"; show "$1"
  run fm fm-ask.sh again "$1" --reason "second wording, a new question"
  echo "-- $1 after re-ask (revision $(fm fm-ask.sh revision "$1")):"; show "$1"
done

step "6. contrast: idempotent re-hold through fm-captain-hold.sh KEEPS a future deadline"
run fm fm-captain-hold.sh thread-b --reason "which vendor?"
show thread-b

step "7. uncomputable default fails the re-ask before anything is written"
L1=$(cat "$H/data/ask-revisions"); B1=$(cat "$H/data/backlog.md")
printf '$ FM_CAPTAIN_HOLD_NOW=not-a-date fm-ask.sh again ask-future --reason x\n'
FM_CAPTAIN_HOLD_NOW=not-a-date fm fm-ask.sh again ask-future --reason "third wording"; echo "[exit $?]"
[ "$L1" = "$(cat "$H/data/ask-revisions")" ] && echo "ledger unchanged" || echo "LEDGER CHANGED"
[ "$B1" = "$(cat "$H/data/backlog.md")" ] && echo "backlog unchanged" || echo "BACKLOG CHANGED"

step "8. existing holds untouched by all of the above; lapsed hold is still a hold, not dispatchable"
AFTER=$(grep -E 'old-(open|lapsed|future)' "$H/data/backlog.md")
[ "$BEFORE" = "$AFTER" ] && echo "pre-existing hold rows byte-identical" || { echo "PRE-EXISTING ROWS CHANGED"; printf '%s\n' "$AFTER"; }
show old-lapsed
run fm fm-ready.sh

step "final backlog"
cat "$H/data/backlog.md"
rm -rf "$H"
