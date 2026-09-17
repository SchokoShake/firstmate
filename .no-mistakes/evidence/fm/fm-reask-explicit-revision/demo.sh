#!/usr/bin/env bash
# End-to-end transcript of the captain-ask identity contract against a throwaway home.
set -u
ROOT=$1
HOME_DIR=$(mktemp -d /tmp/fm-ask-demo.XXXXXX)
mkdir -p "$HOME_DIR"/{data,state,config,projects}
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
unset FM_HOME
ask() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-ask.sh" "$@"; }
dh() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-decision-hold.sh" "$@"; }
snap() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq -c '.backlog.records[] | {id, state, hold_kind, hold_reason, ask_id, ask_revision}'; }
axi() { (cd "$HOME_DIR" && tasks-axi "$@"); }
step() { printf '\n$ %s\n' "$*"; "$@" 2>&1 | sed "s#$HOME_DIR#<home>#g"; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
ledger() { if [ -e "$HOME_DIR/data/ask-revisions" ]; then cat "$HOME_DIR/data/ask-revisions"; else echo "(data/ask-revisions absent)"; fi; }

echo "### 1. compose an ordinary captain hold"
axi add axes-p3 "adopt the new placement axes" --kind ship --repo myapp --start >/dev/null
axi add plain-row "a row that asks nothing" --kind ship --repo myapp >/dev/null
step axi hold axes-p3 --reason "confirm the rollout window" --kind captain
step ask id axes-p3
step ask revision axes-p3
step snap
step ledger

echo; echo "### 2. rewrite the reason, refresh the hold: identity must not move, ledger untouched"
step axi hold axes-p3 --reason "ship the axes now; Recommended: Friday train. Alternatives: next release" --kind captain
step axi hold axes-p3 --reason "ship the axes now; Recommended: Friday train. Alternatives: next release" --kind captain
step ask id axes-p3
step snap
step ledger

echo; echo "### 3. the one deliberate re-ask command"
step ask again axes-p3 --reason "the Friday train was cancelled; pick a new window"
step ask id axes-p3
step snap
step ledger

echo; echo "### 4. re-ask with unchanged wording still re-asks (no nag guard); a question starting with -- is writable"
step ask again axes-p3 --reason "the Friday train was cancelled; pick a new window"
step ask again axes-p3 "--reason=--force or --dry-run for the migration"
step axi show axes-p3 --full
step ask again axes-p3 --reason "--a bare value beginning with dashes"
step axi show axes-p3 --full
step ledger

echo; echo "### 5. --reason is required"
step ask again axes-p3
step ask again axes-p3 --reason
step ask again axes-p3 --reason "   "
step ask revision axes-p3

echo; echo "### 6. refusals: unheld row, decision hold"
step ask id plain-row
mkdir -p "$HOME_DIR/data/axes-p3"; printf "# report\n" > "$HOME_DIR/data/axes-p3/report.md"
step dh hold axes-p3 cutover --title "Cutover timing" --reason "cut over on Friday or wait" --repo myapp
step axi hold axes-p3-decision-cutover --reason "Decide: cut over Friday. Alternatives: wait a week" --kind captain
step ask id axes-p3-decision-cutover
step ask again axes-p3-decision-cutover --reason "something new"
step snap

echo; echo "### 7. close paths leave the ledger alone; a Done row publishes null"
before=$(ledger)
printf "cut over on Friday\n" > "$HOME_DIR/decision.txt"
step dh decline axes-p3 cutover --decision-file "$HOME_DIR/decision.txt"
after=$(ledger)
[ "$before" = "$after" ] && echo "ledger byte-identical across decline" || echo "LEDGER CHANGED ACROSS DECLINE"
step snap

echo; echo "### 8. human-edited ledger: comments survive, malformed value fails loudly, snapshot nulls that subject only"
axi add other-q "another question" --kind ship --repo myapp --start >/dev/null
axi hold other-q --reason "which vendor" --kind captain >/dev/null
printf '# captain note: keep this\naxes-p3=four\nnot a ledger line\n' >> "$HOME_DIR/data/ask-revisions"
step ledger
step ask id axes-p3
step ask again axes-p3 --reason "try anyway"
step ask id other-q
step snap
echo; echo "repair by hand to 08 (leading zero reads as 8):"
sed -i 's/^axes-p3=four$/axes-p3=08/' "$HOME_DIR/data/ask-revisions"
step ask id axes-p3
step ask again axes-p3 --reason "after the repair"
step ledger

echo; echo "### 9. failed hold write restores the revision and reports tasks-axi's output"
chmod 555 "$HOME_DIR/data"
mkdir -p "$HOME_DIR/ledger"; cp "$HOME_DIR/data/ask-revisions" "$HOME_DIR/ledger/ask-revisions"
ask2() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/ledger" "$ROOT/bin/fm-ask.sh" "$@"; }
step ask2 again other-q --reason "cannot be written"
step ask2 id other-q
echo; echo "and a bump that cannot be recorded names the ledger and the cause:"
step ask again other-q --reason "ledger dir is read-only"
chmod 755 "$HOME_DIR/data"
step ask id other-q
step ledger

echo; echo "### 10. unreadable ledger refuses instead of answering 1"
chmod 000 "$HOME_DIR/data/ask-revisions"
step ask id axes-p3
step snap
chmod 644 "$HOME_DIR/data/ask-revisions"
rm -rf "$HOME_DIR"
