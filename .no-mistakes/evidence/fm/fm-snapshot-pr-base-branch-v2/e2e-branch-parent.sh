#!/usr/bin/env bash
# End-to-end walk of the branch-parent change as an operator would drive it:
# real bin/fm-spawn.sh, bin/fm-pr-check.sh and bin/fm-fleet-snapshot.sh against
# an isolated home, a real git worktree, a fake tmux and a fake forge CLI.
set -u
ROOT=$(pwd)
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"

TMP=$(fm_test_tmproot fm-e2e-branch-parent)
HOME_DIR="$TMP/home"; PROJ="$TMP/project"; WT="$TMP/wt"
FAKE="$TMP/fake"; FAKEBIN="$FAKE/fakebin"; FAKEROOT="$TMP/root"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN" "$FAKEROOT/bin"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
touch "$HOME_DIR/state/.last-watcher-beat"
fm_git_worktree "$PROJ" "$WT" wt-e2e

# fake tmux: pane path query answers with the task worktree, everything else ok
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
fm_fake_exit0 "$FAKEBIN" treehouse
# fake gh: the forge. FM_TEST_GH_BASE is the PR's current base branch.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' "0123456789abcdef0123456789abcdef01234567" ;;
  *" baseRefName "*) [ "${FM_TEST_GH_BASE_ABSENT:-0}" = 0 ] || exit 1; printf '%s\n' "${FM_TEST_GH_BASE:-main}" ;;
  *" state "*) printf 'OPEN\n' ;;
esac
SH
cat > "$FAKEBIN/glab" <<'SH'
#!/usr/bin/env bash
printf 'title:\tfixture merge request\nstate:\topened\nauthor:\tsomeone\n'
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEROOT/bin/fm-guard.sh"
chmod +x "$FAKEBIN"/* "$FAKEROOT/bin/fm-guard.sh"

spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
  FM_BACKEND=tmux FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}
prcheck() {
  FM_ROOT_OVERRIDE="$FAKEROOT" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-pr-check.sh" "$@" 2>&1
}
snap() {  # print the branch-parent view of every task row
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
    | jq -c '.tasks[] | {id, base, pr_base, pr: .pr.url}'
}
meta() { sed -n '/^base=/p;/^pr=/p;/^pr_head=/p;/^pr_base=/p' "$HOME_DIR/state/$1.meta"; }
brief() { mkdir -p "$HOME_DIR/data/$1"; printf 'brief for %s\n\n# Definition of done\nDelivery contract: mode=%s\n' "$1" "${2:-no-mistakes}" > "$HOME_DIR/data/$1/brief.md"; }
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

say "1. Spawn a ship task with --base release/2026.09 (the Setup line's branch-from)"
brief tree-ship-a1
run spawn tree-ship-a1 "$PROJ" claude --mode no-mistakes --yolo off --base release/2026.09
printf '$ state/tree-ship-a1.meta (branch-parent keys)\n'; meta tree-ship-a1

say "2. Snapshot before any PR exists: base declared, pr_base empty string (not null, not missing)"
run snap

say "3. Record the PR; the forge (gh pr view --json baseRefName) says its base is release/2026.09"
FM_TEST_GH_BASE=release/2026.09 run prcheck tree-ship-a1 https://github.com/o/r/pull/11
printf '$ state/tree-ship-a1.meta (branch-parent keys)\n'; meta tree-ship-a1
run snap

say "4. Restack: the same PR is retargeted onto main; re-running fm-pr-check refreshes pr_base and keeps base as declared"
FM_TEST_GH_BASE=main run prcheck tree-ship-a1 https://github.com/o/r/pull/11
printf '$ state/tree-ship-a1.meta (branch-parent keys)\n'; meta tree-ship-a1
run snap

say "5. Forge cannot answer baseRefName: pr= and pr_head= still recorded, pr_base omitted"
brief tree-ship-b2
run spawn tree-ship-b2 "$PROJ" claude --mode no-mistakes --yolo off
FM_TEST_GH_BASE_ABSENT=1 run prcheck tree-ship-b2 https://github.com/o/r/pull/12
printf '$ state/tree-ship-b2.meta (branch-parent keys)\n'; meta tree-ship-b2

say "6. GitLab merge request: no pr_base, exactly like no pr_head; the declared base is what remains"
brief tree-ship-c3 direct-PR
run spawn tree-ship-c3 "$PROJ" claude --mode direct-PR --yolo off --base main
run prcheck tree-ship-c3 https://gitlab.com/g/p/-/merge_requests/4
printf '$ state/tree-ship-c3.meta (branch-parent keys)\n'; meta tree-ship-c3

say "7. Scout spawn with --base, and a spawn with no --base at all"
brief tree-scout-d4
run spawn tree-scout-d4 "$PROJ" claude --scout --base feature/stack-1
printf '$ state/tree-scout-d4.meta (branch-parent keys)\n'; meta tree-scout-d4

say "8. The snapshot every consumer reads: one row per task, both fields always present strings"
run snap
printf '$ every task row has both keys as strings:\n'
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
  | jq -c '[.tasks[] | {id, base_type: (.base|type), pr_base_type: (.pr_base|type)}]'

say "9. Refusals: a --base that is not a plain branch name never writes metadata"
for bad in 'main..topic' '-topic' 'window=unexpected' 'release/' 'topic.lock' 'two words'; do
  brief tree-bad-x9
  run spawn tree-bad-x9 "$PROJ" claude --mode no-mistakes --yolo off --base="$bad"
  [ -e "$HOME_DIR/state/tree-bad-x9.meta" ] && echo "!! meta was written" || echo "(no state/tree-bad-x9.meta written)"
done
printf '$ --base with an embedded newline (would forge a second meta key)\n'
run spawn tree-bad-x9 "$PROJ" claude --mode no-mistakes --yolo off --base "$(printf 'main\nwindow=unexpected')"
[ -e "$HOME_DIR/state/tree-bad-x9.meta" ] && echo "!! meta was written" || echo "(no state/tree-bad-x9.meta written)"

say "10. Refusals where --base has no meaning: a secondmate spawn and a relaunch"
run spawn tree-sm-e5 "$HOME_DIR" --secondmate --base main
run spawn tree-ship-a1 --relaunch --base main

say "11. Batch dispatch forwards the shared --base to every pair"
brief tree-batch-f6; brief tree-batch-g7
run spawn "tree-batch-f6=$PROJ" "tree-batch-g7=$PROJ" --harness claude --mode no-mistakes --yolo off --base release/2026.09
printf '$ state/tree-batch-f6.meta / tree-batch-g7.meta (branch-parent keys)\n'; meta tree-batch-f6; meta tree-batch-g7

say "12. BEFORE the change: the base commit's snapshot on the very same home has no base / pr_base at all"
BASE_TREE="$TMP/base-tree"; mkdir -p "$BASE_TREE"
git -C "$ROOT" archive 31235bd | tar -x -C "$BASE_TREE"
printf '$ (base commit 31235bd) fm-fleet-snapshot.sh --json | jq tasks{id,base,pr_base}\n'
FM_HOME="$HOME_DIR" "$BASE_TREE/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[] | {id, base, pr_base, has_base_key: has("base"), has_pr_base_key: has("pr_base")}'
printf '$ (base commit) the new contract test against the old snapshot:\n'
cp "$ROOT/tests/fm-snapshot-branch-parent-contract.test.sh" "$BASE_TREE/tests/"
mkdir -p "$BASE_TREE/tests/fixtures/snapshot-branch-parent"
cp "$ROOT/tests/fixtures/snapshot-branch-parent/cases.json" "$BASE_TREE/tests/fixtures/snapshot-branch-parent/"
(cd "$BASE_TREE" && bash tests/fm-snapshot-branch-parent-contract.test.sh 2>&1 | head -6; echo "[exit ${PIPESTATUS[0]}]")
