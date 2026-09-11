#!/usr/bin/env bash
# Round-2 end-to-end demonstration for fm-treehouse-slot-reissued-live-lease-v7:
# the pre-lease double record (two records with no lease_holder= claim naming
# one pool slot, whose owner reservation treehouse already cleared), driven
# through the REAL treehouse binary and the real bin/fm-teardown.sh.
#
# Shows: (1) ordinary teardown of either claimless record, plain and --force,
# refuses before any worktree, process, or endpoint step and names
# --retire-record --unproven-confirmed; (2) --retire-record alone refuses;
# (3) --unproven-confirmed --dry-run prints the plan and changes nothing;
# (4) --unproven-confirmed prints the complete plan first, then removes exactly
# teardown's state set, with the copy, the pool, and endpoints untouched and the
# other record intact; (5) the flag anywhere but with --retire-record exits 2,
# and --force never implies it; (6) a record the pool leases to its own claim
# still refuses with the flag; (7) an armed PR merge poll still refuses with it.
set -u
ROOT=${ROOT:?}
SCEN=$(mktemp -d /tmp/fm-unproven-e2e.XXXX)
STATE=$SCEN/home/state
OWN_LABEL=fm-task:own-r1:l1789000000.4242.17
step() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %d]\n' "$?"; }
th() { HOME=$SCEN/fakehome treehouse "$@"; }

step "1. A project repo with its own treehouse pool"
mkdir -p "$SCEN/fakehome" "$SCEN/project" "$STATE" "$SCEN/home/data" "$SCEN/home/config" "$SCEN/fakebin"
cd "$SCEN/project" || exit 1
git init -q -b main . && printf 'base\n' > README.md
git -c user.name=t -c user.email=t@example.invalid add README.md
git -c user.name=t -c user.email=t@example.invalid commit -qm initial
printf 'max_trees = 4\nroot = "%s"\n' "$SCEN/th" > treehouse.toml

step "2. The pre-lease shape: slot 1 was handed out under the old owner reservation, which treehouse cleared when that process died; no durable lease exists"
P=$(th get --lease --lease-holder fm-bootstrap 2>/dev/null); POOL=$(dirname "$(dirname "$P")")
th return --force "$P" >/dev/null 2>&1
printf 'live uncommitted work of holder-r1\n' > "$P/live-work.txt"
run th status
printf '\n$ cat %s/treehouse-state.json\n' "$POOL"; cat "$POOL/treehouse-state.json"; echo

step "3. Two records with no lease_holder= claim name that slot: stale-r1 (finished, PR 829 merged) and holder-r1 (still working there)"
write_record() {  # <id> <gen> [extra...]
  local id=$1 gen=$2; shift 2
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$P" "project=$SCEN/project" \
    "harness=claude" "kind=ship" "tasktmp=$SCEN/tasktmp-$id" "spawn_gen=$gen" "mode=direct-PR" "yolo=off" "$@" > "$STATE/$id.meta"
}
populate() {  # <id>
  local id=$1 marker gen
  printf 'done: PR merged\n' > "$STATE/$id.status"
  : > "$STATE/$id.turn-ended"
  printf 'version=4\noffset=0\nident=1:1\n' > "$STATE/.$id.open-decisions-cursor"
  for marker in hash count stale paused paused-rechecked paused-resurfaced; do printf 'x\n' > "$STATE/.$marker-firstmate_fm-$id"; done
  printf 'x\n' > "$STATE/.seen-${id}_status"; printf 'x\n' > "$STATE/.seen-${id}_turn-ended"
  printf 'x\n' > "$STATE/.hb-surfaced-$id"; printf 'x\n' > "$STATE/.subsuper-paused-$id"
  mkdir -p "$STATE/.pr-check-quarantine"; chmod 700 "$STATE/.pr-check-quarantine"
  (umask 077 && printf 'neutralized\n' > "$STATE/.pr-check-quarantine/$id.diagnostic.ambiguous")
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id") || echo "could not arm busy state for $id"
  printf 'busy_gen=%s\n' "$gen" >> "$STATE/$id.meta"
}
write_record stale-r1 s1788765996.150863.30112
populate stale-r1
printf 'pr=https://github.com/example/repo/pull/829\n' >> "$STATE/stale-r1.meta"
write_record holder-r1 s1789026483.244338.3761
populate holder-r1
printf 'stale-r1\t1:1\t0\nholder-r1\t1:2\t0\n' > "$STATE/.status-presentation-cursor"
run cat "$STATE/stale-r1.meta"
printf '\n$ ls -A %s\n' "$STATE"; ls -A "$STATE" | sort

cat > "$SCEN/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in list-windows) printf '%s\n' unrelated-window ;; esac
exit 0
SH
cat > "$SCEN/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "\${FM_RUNTIME_LOG:?}"
HOME=$SCEN/fakehome exec $(command -v treehouse) "\$@"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCEN/fakebin/no-mistakes"; chmod +x "$SCEN/fakebin"/*; : > "$SCEN/runtime.log"
teardown() { FM_HOME="$SCEN/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 FM_GATE_REFUSE_BYPASS=1 FM_RUNTIME_LOG="$SCEN/runtime.log" PATH="$SCEN/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" "$@"; }
fingerprint() {
  { printf 'HEAD %s\n' "$(git -C "$P" rev-parse HEAD)"; printf 'git status --porcelain:\n'; git -C "$P" status --porcelain
    printf 'files:\n'; (cd "$P" && find . -type f -not -path './.git/*' | sort | xargs sha256sum)
    printf 'pool record: %s\n' "$(cksum < "$POOL/treehouse-state.json")"; } > "$1"
}
fingerprint "$SCEN/fp-before.txt"

step "4. Ordinary teardown of the STALE claimless record, plain and --force, must refuse and name the way through"
run teardown stale-r1
run teardown stale-r1 --force

step "5. Ordinary teardown of the claimless record that STILL HOLDS the copy, plain and --force, must refuse the same way"
run teardown holder-r1
run teardown holder-r1 --force
printf '\n$ cat runtime.log (every tmux/treehouse call so far)\n'; cat "$SCEN/runtime.log"; printf '(%s lines)\n' "$(wc -l < "$SCEN/runtime.log")"

step "6. The flag is valid only with --retire-record: each of these must exit 2 and touch nothing"
run teardown stale-r1 --unproven-confirmed
run teardown stale-r1 --force --unproven-confirmed
run teardown stale-r1 --unproven-confirmed --dry-run
run teardown stale-r1 --retire-record --force --unproven-confirmed
printf '\n$ FM_UNPROVEN_CONFIRMED=1 teardown stale-r1 --retire-record   (an environment variable must not turn it on)\n'
FM_UNPROVEN_CONFIRMED=1 teardown stale-r1 --retire-record; printf '[exit %d]\n' "$?"

step "7. --retire-record on the stale record refuses without the acknowledgement"
run teardown stale-r1 --retire-record --dry-run
run teardown stale-r1 --retire-record

step "8. --unproven-confirmed --dry-run, in either order, prints the verdict and the plan and changes nothing"
run teardown stale-r1 --retire-record --unproven-confirmed --dry-run
run teardown stale-r1 --dry-run --unproven-confirmed --retire-record
printf '\n$ ls -A %s (unchanged)\n' "$STATE"; ls -A "$STATE" | sort
fingerprint "$SCEN/fp-mid.txt"; printf '\n$ diff fp-before.txt fp-mid.txt\n'; diff "$SCEN/fp-before.txt" "$SCEN/fp-mid.txt" && echo "(no difference)"

step "9. --retire-record --unproven-confirmed on the stale record: prints the complete plan first, then removes exactly that"
run teardown stale-r1 --retire-record --unproven-confirmed

step "10. After: only holder-r1's records remain; copy, pool, and endpoints untouched"
printf '\n$ ls -A %s\n' "$STATE"; ls -A "$STATE" | sort
printf '\n$ cat %s/.status-presentation-cursor\n' "$STATE"; cat "$STATE/.status-presentation-cursor"
fingerprint "$SCEN/fp-after.txt"; printf '\n$ diff fp-before.txt fp-after.txt\n'; diff "$SCEN/fp-before.txt" "$SCEN/fp-after.txt" && echo "(no difference: HEAD, dirty status, every file hash, and the pool record are unchanged)"
[ -f "$P/live-work.txt" ] && echo "holder-r1's live-work.txt: still present" || echo "holder-r1's live-work.txt: DESTROYED"
run th status
printf '\n$ cat runtime.log (every tmux/treehouse call teardown made in steps 4-9)\n'; cat "$SCEN/runtime.log"
printf 'treehouse calls: %s; tmux kill-window calls: %s\n' "$(grep -c '^treehouse' "$SCEN/runtime.log")" "$(grep -c 'kill-window' "$SCEN/runtime.log")"

step "10b. The way through, completed: with stale-r1 gone, holder-r1 is uncontested and ordinary teardown of it works as before (dirty refusal, then --force returns the slot)"
: > "$SCEN/runtime.log"
run teardown holder-r1
run teardown holder-r1 --force
printf '\n$ cat runtime.log\n'; cat "$SCEN/runtime.log"
printf '\n$ ls -A %s\n' "$STATE"; ls -A "$STATE" | sort
run th status

step "11. A record whose own claim the pool still leases to it refuses even with the flag (dropping it would strand the lease)"
P2=$(th get --lease --lease-holder "$OWN_LABEL" 2>/dev/null)
echo "own-r1 leased: $P2"
printf '%s\n' "window=firstmate:fm-own-r1" "endpoint_task_id=own-r1" "worktree=$P2" "project=$SCEN/project" "harness=claude" "kind=ship" "tasktmp=$SCEN/tasktmp-own-r1" "spawn_gen=s1789000003.4242.18" "mode=direct-PR" "yolo=off" "lease_holder=$OWN_LABEL" > "$STATE/own-r1.meta"
printf 'done: PR merged\n' > "$STATE/own-r1.status"
run th status
run teardown own-r1 --retire-record --unproven-confirmed
run teardown own-r1 --retire-record --unproven-confirmed --dry-run
[ -f "$STATE/own-r1.meta" ] && echo "own-r1.meta: still present" || echo "own-r1.meta: REMOVED"
run th status

step "12. A claimless record with an armed PR merge poll still refuses with the flag"
write_record poll-r1 s1788765996.150863.30113 "pr=https://github.com/example/repo/pull/829"
printf 'done: PR merged\n' > "$STATE/poll-r1.status"
for a in check.sh pr-poll pr-poll-registration check-trust; do (umask 077 && printf 'armed\n' > "$STATE/poll-r1.$a"); done
run teardown poll-r1 --retire-record --unproven-confirmed
ls "$STATE"/poll-r1.* | sort

th return --force "$P2" >/dev/null 2>&1 || true
cd / && rm -rf "$SCEN"
