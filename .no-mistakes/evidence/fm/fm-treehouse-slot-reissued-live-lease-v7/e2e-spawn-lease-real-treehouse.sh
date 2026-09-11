#!/usr/bin/env bash
# Prevention half of fm-treehouse-slot-reissued-live-lease-v7, against the REAL
# treehouse binary and an isolated pool under a temp root: a fresh spawn takes
# a durable lease under its own label and records it, and a slot that another
# record in the home still names is held aside, never used, and handed back.
# Only the terminal is faked (a logging tmux that reports a chosen pane path).
set -u
ROOT=${ROOT:?}
SCEN=$(mktemp -d /tmp/fm-spawn-lease-e2e.XXXX)
step() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %d]\n' "$?"; }
th() { HOME=$SCEN/fakehome treehouse "$@"; }

step "1. A project with an origin remote and its own treehouse pool under $SCEN/th"
mkdir -p "$SCEN/fakehome" "$SCEN/project" "$SCEN/home/state" "$SCEN/home/projects" "$SCEN/home/config" "$SCEN/fakebin"
printf 'codex\n' > "$SCEN/home/config/crew-harness"
touch "$SCEN/home/state/.last-watcher-beat"
git init -q -b main "$SCEN/project"
printf 'base\n' > "$SCEN/project/README.md"
git -C "$SCEN/project" -c user.name=t -c user.email=t@example.invalid add README.md
git -C "$SCEN/project" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone -q --bare "$SCEN/project" "$SCEN/origin.git"
git -C "$SCEN/project" remote add origin "file://$SCEN/origin.git"
printf 'max_trees = 4\nroot = "%s"\n' "$SCEN/th" > "$SCEN/project/treehouse.toml"
# Learn the pool's slot paths by leasing and returning them once.
cd "$SCEN/project" || exit 1
S1=$(th get --lease --lease-holder probe-1 2>/dev/null)
S2=$(th get --lease --lease-holder probe-2 2>/dev/null)
th return --force "$S1" >/dev/null 2>&1; th return --force "$S2" >/dev/null 2>&1
echo "slot 1: $S1"; echo "slot 2: $S2"
run th status

cat > "$SCEN/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
cat > "$SCEN/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "\${FM_FAKE_TREEHOUSE_LOG:?}"
HOME=$SCEN/fakehome exec $(command -v treehouse) "\$@"
SH
chmod +x "$SCEN/fakebin"/*
spawn() {  # <id> <pane-path>
  local id=$1 pane=$2
  mkdir -p "$SCEN/home/data/$id"; printf 'brief for %s\n' "$id" > "$SCEN/home/data/$id/brief.md"
  : > "$SCEN/tmux-$id.log"; : > "$SCEN/treehouse-$id.log"
  FM_ROOT_OVERRIDE='' FM_HOME="$SCEN/home" FM_STATE_OVERRIDE="$SCEN/home/state" \
    FM_DATA_OVERRIDE="$SCEN/home/data" FM_PROJECTS_OVERRIDE="$SCEN/home/projects" \
    FM_CONFIG_OVERRIDE="$SCEN/home/config" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pane" FM_FAKE_TMUX_LOG="$SCEN/tmux-$id.log" \
    FM_FAKE_TREEHOUSE_LOG="$SCEN/treehouse-$id.log" PATH="$SCEN/fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$SCEN/project" --mode no-mistakes --yolo off 2>&1
}

step "2. PREVENTION: a pre-lease record stale-l2 still names slot 1, whose owner reservation died; the pool would hand slot 1 out first"
printf '%s\n' "window=firstmate:fm-stale-l2" "endpoint_task_id=stale-l2" "worktree=$S1" \
  "project=$SCEN/project" "kind=ship" "spawn_gen=s1788765996.150863.30112" > "$SCEN/home/state/stale-l2.meta"
run cat "$SCEN/home/state/stale-l2.meta"
run spawn lease-skip-l2 "$S2"
printf '\n$ grep worktree= lease-skip-l2.meta\n'; grep '^worktree=\|^lease_holder=' "$SCEN/home/state/lease-skip-l2.meta"
printf '\n$ cat treehouse-lease-skip-l2.log (every treehouse call spawn made)\n'; cat "$SCEN/treehouse-lease-skip-l2.log"
printf '\n$ grep "cd --" tmux-lease-skip-l2.log\n'; grep "cd -- " "$SCEN/tmux-lease-skip-l2.log"
run th status

step "3. A fresh spawn on the now-free slot 1 takes a durable lease under its own label and records it"
rm -f "$SCEN/home/state/stale-l2.meta"
run spawn lease-fresh-l1 "$S1"
printf '\n$ grep worktree=/lease_holder= lease-fresh-l1.meta\n'; grep '^worktree=\|^lease_holder=' "$SCEN/home/state/lease-fresh-l1.meta"
printf '\n$ cat treehouse-lease-fresh-l1.log\n'; cat "$SCEN/treehouse-lease-fresh-l1.log"
run th status
POOL=$(dirname "$(dirname "$S1")")
printf '\n$ cat %s/treehouse-state.json\n' "$POOL"; cat "$POOL/treehouse-state.json"

step "4. With both slots durably leased, a third spawn cannot be handed either of them (max_trees lowered to 2)"
printf 'max_trees = 2\nroot = "%s"\n' "$SCEN/th" > "$SCEN/project/treehouse.toml"
run spawn lease-third-l3 "$S1"
[ -f "$SCEN/home/state/lease-third-l3.meta" ] && echo "lease-third-l3 record: PUBLISHED" || echo "lease-third-l3 record: not published"
run th status

step "cleanup"
th return --force "$S1" >/dev/null 2>&1; th return --force "$S2" >/dev/null 2>&1
cd / && rm -rf "$SCEN" /tmp/fm-lease-skip-l2 /tmp/fm-lease-fresh-l1 /tmp/fm-lease-third-l3
echo "removed $SCEN"
