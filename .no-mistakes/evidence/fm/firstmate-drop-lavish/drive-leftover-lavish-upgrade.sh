#!/usr/bin/env bash
# Live upgrade drive: a firstmate home armed Lavish review sources with the BASE
# commit's own Lavish adapter (against a fake blocking `lavish-axi` on PATH, so no
# real Lavish server is touched), then the same home is driven by THIS branch's
# runner, which no longer ships bin/fm-procevent-lavish.sh.
#
# Usage: drive-leftover-lavish-upgrade.sh <scratch-dir> <base-root> <target-root>
set -u
T=$1 BASE=$2 TARGET=$3

export HOME="$T/home" FM_HOME="$T/fmhome" FM_PROCEVENT_CLAIM_ROOT="$T/claims"
unset XDG_STATE_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
export PATH="$T/fakebin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME" "$FM_HOME/state" "$T/fakebin" "$T/art"
STATE="$FM_HOME/state"

cat > "$T/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Fake lavish-axi: `poll <file>` blocks until <file>.trigger appears, then prints
# the published poll shape with one feedback prompt.
[ "${1-}" = poll ] || exit 2
f=$2
while [ ! -e "$f.trigger" ]; do sleep 0.1; done
rm -f "$f.trigger"
printf 'session:\n  status: feedback\n  file: %s\nprompts[1]:\n  - "captain: move the legend left"\n' "$f"
SH
chmod +x "$T/fakebin/lavish-axi"
printf '<html>a</html>\n' > "$T/art/review-a.html"
printf '<html>b</html>\n' > "$T/art/review-b.html"

say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
wait_for() { local i; for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
sup_needed() {
  bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo "supervision needed: yes" || echo "supervision needed: no"' _ "$TARGET" "$STATE"
}
claim_pid() { sed -n 2p "$FM_PROCEVENT_CLAIM_ROOT/$1.claim" 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
fake_polls() { pgrep -f "$T/fakebin/lavish-axi poll" | wc -l; }

say "BASE commit: arm two Lavish reviews with the base adapter, start runners"
run "$BASE/bin/fm-procevent-lavish.sh" arm "$T/art/review-a.html"
run "$BASE/bin/fm-procevent-lavish.sh" arm "$T/art/review-b.html"
A=$("$BASE/bin/fm-procevent-lavish.sh" source-id "$T/art/review-a.html")
B=$("$BASE/bin/fm-procevent-lavish.sh" source-id "$T/art/review-b.html")
run "$BASE/bin/fm-procevent.sh" reconcile
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$A.claim"; wait_for "$FM_PROCEVENT_CLAIM_ROOT/$B.claim"
sleep 0.5

say "BASE commit: review-b returns captain feedback, captured as a pending result; runner restarted"
touch "$T/art/review-b.html.trigger"
wait_for "$STATE/procevent-inbox/$B.1.result" || echo "NO RESULT CAPTURED"
sleep 1
run "$BASE/bin/fm-procevent.sh" reconcile
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$B.claim"; sleep 0.5

say "BASE commit: also arm an unrelated 'when' watch that must survive the upgrade"
run "$BASE/bin/fm-procevent-when.sh" arm keepalive --interval 0.2 --stable 1 \
  --condition /usr/bin/test -e "$T/flag-keep" --action /usr/bin/touch "$T/keep-fired"
run "$BASE/bin/fm-procevent.sh" reconcile
wait_for "$FM_PROCEVENT_CLAIM_ROOT/when-keepalive.claim"; sleep 0.5
mkdir -p "$T/snap"; cp "$STATE/procevent/$A.source" "$T/snap/"
PA=$(claim_pid "$A"); PB=$(claim_pid "$B"); PW=$(claim_pid when-keepalive)
echo "runner pids: $A=$PA ($(alive "$PA"))  $B=$PB ($(alive "$PB"))  when-keepalive=$PW ($(alive "$PW"))"
echo "fake 'lavish-axi poll' children blocking: $(fake_polls)"
run "$BASE/bin/fm-procevent.sh" list
sup_needed
mv "$STATE/.wake-queue" "$T/wake-queue.base" 2>/dev/null

say "UPGRADE: same home, this branch's runner (no Lavish adapter installed)"
run ls "$TARGET/bin" | grep -c 'fm-procevent-lavish' || true
run "$TARGET/bin/fm-procevent.sh" reconcile
sleep 0.5
echo "runner pids after: $A=$PA ($(alive "$PA"))  $B=$PB ($(alive "$PB"))  when-keepalive=$PW ($(alive "$PW"))"
echo "fake 'lavish-axi poll' children blocking: $(fake_polls)"
for id in "$A" "$B"; do
  printf '%s: registration=%s claim=%s\n' "$id" \
    "$([ -e "$STATE/procevent/$id.source" ] && echo present || echo removed)" \
    "$([ -e "$FM_PROCEVENT_CLAIM_ROOT/$id.claim" ] && echo present || echo released)"
done
run "$TARGET/bin/fm-procevent.sh" list
echo "wake queue after upgrade reconcile:"; awk -F '\t' '{print "  " $5}' "$STATE/.wake-queue" 2>/dev/null

say "Handler reads the pending pre-removal result as plain evidence, then acknowledges generically"
run cat "$STATE/procevent-inbox/$B.1.result"
run "$TARGET/bin/fm-procevent.sh" handled "$B" 1
run "$TARGET/bin/fm-procevent.sh" handled "$B" 1
mv "$STATE/.wake-queue" "$T/wake-queue.upgrade" 2>/dev/null
run "$TARGET/bin/fm-procevent.sh" reconcile
echo "wake queue after acknowledgement: $(awk -F '\t' '{print $5}' "$STATE/.wake-queue" 2>/dev/null | wc -l) records"

say "ADVERSARIAL: a leftover Lavish registration reappears; start and register must refuse it"
cp "$T/snap/$A.source" "$STATE/procevent/"
run "$TARGET/bin/fm-procevent.sh" start "$A"
echo "claim after refused start: $([ -e "$FM_PROCEVENT_CLAIM_ROOT/$A.claim" ] && echo present || echo none); results: $(ls "$STATE/procevent-inbox/" | grep -c "^$A\." || true); fake polls: $(fake_polls)"
run "$TARGET/bin/fm-procevent.sh" register lavish lavish-new -- lavish-axi poll "$T/art/review-a.html"
run "$TARGET/bin/fm-procevent.sh" reconcile
echo "$A registration after reconcile: $([ -e "$STATE/procevent/$A.source" ] && echo present || echo removed)"

say "GENERIC machinery: the surviving when watch fires; a fresh when watch armed on this branch fires"
touch "$T/flag-keep"
wait_for "$STATE/procevent-inbox/when-keepalive.1.result" && echo "keepalive outcome: $("$TARGET/bin/fm-procevent-when.sh" classify "$STATE/procevent-inbox/when-keepalive.1.result")"
[ -e "$T/keep-fired" ] && echo "keepalive action ran: yes" || echo "keepalive action ran: NO"
run "$TARGET/bin/fm-procevent.sh" handled when-keepalive 1
run "$TARGET/bin/fm-procevent-when.sh" retire keepalive
run "$TARGET/bin/fm-procevent-when.sh" arm fresh --interval 0.2 --stable 1 \
  --condition /usr/bin/true --action /usr/bin/touch "$T/fresh-fired"
run "$TARGET/bin/fm-procevent.sh" reconcile
wait_for "$STATE/procevent-inbox/when-fresh.1.result" && echo "fresh outcome: $("$TARGET/bin/fm-procevent-when.sh" classify "$STATE/procevent-inbox/when-fresh.1.result")"
[ -e "$T/fresh-fired" ] && echo "fresh action ran: yes" || echo "fresh action ran: NO"
sleep 0.5
echo "wake queue:"; awk -F '\t' '{print "  " $5}' "$STATE/.wake-queue" 2>/dev/null
run "$TARGET/bin/fm-procevent.sh" handled when-fresh 1
run "$TARGET/bin/fm-procevent-when.sh" retire fresh

say "FINAL: home state after the upgrade"
run "$TARGET/bin/fm-procevent.sh" list
sup_needed
echo "fake 'lavish-axi poll' children still blocking: $(fake_polls)"
run "$TARGET/bin/fm-procevent.sh" sweep-home
