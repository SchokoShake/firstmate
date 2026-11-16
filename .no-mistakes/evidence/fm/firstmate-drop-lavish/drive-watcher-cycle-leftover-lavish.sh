#!/usr/bin/env bash
# Live watcher drive: a home armed a Lavish review with the BASE commit (fake
# blocking lavish-axi, so no real Lavish server is touched) and holds one
# captured-but-unhandled feedback result. Then THIS branch's real bin/fm-watch.sh
# runs its ordinary cycle against that home (fake tmux with no windows).
#
# Usage: drive-watcher-cycle-leftover-lavish.sh <scratch-dir> <base-root> <target-root>
set -u
T=$1 BASE=$2 TARGET=$3
export HOME="$T/home" FM_HOME="$T/fmhome" FM_PROCEVENT_CLAIM_ROOT="$T/claims"
unset XDG_STATE_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
export PATH="$T/fakebin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME" "$FM_HOME/state" "$T/fakebin" "$T/art"
STATE="$FM_HOME/state"
cat > "$T/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
f=$2
while [ ! -e "$f.trigger" ]; do sleep 0.1; done
rm -f "$f.trigger"
printf 'session:\n  status: feedback\n  file: %s\nprompts[1]:\n  - "captain: tighten the copy"\n' "$f"
SH
printf '#!/usr/bin/env bash\n[ "${1-}" = list-windows ] && exit 0\nexit 1\n' > "$T/fakebin/tmux"
printf '#!/usr/bin/env bash\necho "state: unknown · source: none · fake"\n' > "$T/fakebin/fm-crew-state.sh"
chmod +x "$T/fakebin/"*
printf '<html>c</html>\n' > "$T/art/review-c.html"
wait_for() { local i; for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
sup_needed() {
  bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo "supervision needed: yes" || echo "supervision needed: no"' _ "$TARGET" "$STATE"
}

echo "### BASE: arm a Lavish review, capture one feedback result, restart its runner"
"$BASE/bin/fm-procevent-lavish.sh" arm "$T/art/review-c.html"
C=$("$BASE/bin/fm-procevent-lavish.sh" source-id "$T/art/review-c.html")
"$BASE/bin/fm-procevent.sh" reconcile
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$C.claim"; sleep 0.5
touch "$T/art/review-c.html.trigger"
wait_for "$STATE/procevent-inbox/$C.1.result"; sleep 1
"$BASE/bin/fm-procevent.sh" reconcile
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$C.claim"; sleep 0.5
P=$(sed -n 2p "$FM_PROCEVENT_CLAIM_ROOT/$C.claim")
"$BASE/bin/fm-procevent.sh" list
echo "runner $P: $(kill -0 "$P" 2>/dev/null && echo alive || echo gone)"
sup_needed
rm -f "$STATE/.wake-queue"   # pretend the earlier wake was drained but never handled

echo
echo "### UPGRADE: run this branch's real watcher (bin/fm-watch.sh) on its ordinary cycle"
FM_CREW_STATE_BIN="$T/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout 30 "$TARGET/bin/fm-watch.sh" > "$T/watch.out" 2>&1
echo "watcher exit: $?"
echo "watcher output:"; sed 's/^/  /' "$T/watch.out"
echo "runner $P: $(kill -0 "$P" 2>/dev/null && echo alive || echo gone)"
echo "fake 'lavish-axi poll' children blocking: $(pgrep -f "$T/fakebin/lavish-axi poll" | wc -l)"
echo "registration: $([ -e "$STATE/procevent/$C.source" ] && echo present || echo removed); claim: $([ -e "$FM_PROCEVENT_CLAIM_ROOT/$C.claim" ] && echo present || echo released)"
"$TARGET/bin/fm-procevent.sh" list
sup_needed
echo "pending result kept: $([ -e "$STATE/procevent-inbox/$C.1.result" ] && echo yes || echo no); handled marker: $([ -e "$STATE/procevent-inbox/$C.1.handled" ] && echo yes || echo no)"
"$TARGET/bin/fm-procevent.sh" handled "$C" 1
