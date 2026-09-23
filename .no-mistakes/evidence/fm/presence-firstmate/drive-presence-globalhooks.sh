#!/usr/bin/env bash
# Manual product driver, part 2: the two GLOBAL turn-end hooks (grok, kimi),
# which are shared by every task, and the crewmates-and-scouts-only boundary.
set -u
ROOT=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M37BVYP4KRZEJ5GFH74YYCV4
# shellcheck source=/dev/null
. "$ROOT/tests/secondmate-helpers.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-presence-global)

hr() { printf '\n========== %s ==========\n' "$*"; }
sub() { printf '\n-- %s\n' "$*"; }
show_beats() {
  printf 'board saw:\n'
  if [ -s "$1" ]; then sed 's/^/    agent-presence /' "$1"; else printf '    (nothing)\n'; fi
}

##############################################################################
hr "GROK: one global Stop hook, shared by every task"
CASE="$TMP_ROOT/grok"
HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"; GHOME="$CASE/grok-home"
ID=presence-grok-1
FAKEBIN=$(fm_fakebin "$CASE/fake")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" gh-axi gh
fm_fake_treehouse "$FAKEBIN"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$GHOME"
printf 'brief\n' > "$HOME_DIR/data/$ID/brief.md"
fm_git_worktree "$PROJ" "$WT" "fm/$ID"
touch "$HOME_DIR/state/.last-watcher-beat"
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" \
  TMUX="fake,1,0" GROK_HOME="$GHOME" PATH="$FAKEBIN:$PATH" \
  "$SPAWN" "$ID" "$PROJ" grok --mode no-mistakes --yolo off 2>&1 | tail -1

HOOK="$GHOME/hooks/fm-turn-end.sh"
sub "generated global hook body ($HOOK)"
sed 's/^/  /' "$HOOK"
BIN="$CASE/presence-bin"; LOG="$CASE/presence.log"
fm_fake_agent_presence "$BIN" "$LOG"
sub "authorised workspace (this task's registry token) fires the hook"
out=$(PATH="$BIN:$PATH" GROK_WORKSPACE_ROOT="$WT" bash "$HOOK" 2>&1); rc=$?
printf '  exit=%s stdout+stderr=%s turn-end marker=%s\n' "$rc" "$(printf '%q' "$out")" \
  "$([ -f "$HOME_DIR/state/$ID.turn-ended" ] && echo written || echo missing)"
show_beats "$LOG"
printf '  the beat ran in: %s\n  the task worktree is: %s\n' "$(cat "$LOG.pwd")" "$(cd "$WT" && pwd -P)"

sub "ADVERSARIAL: an UNAUTHORISED workspace (forged pointer, no registry token)"
EVIL="$CASE/evil"; mkdir -p "$EVIL"; printf 'token=%s\n' not-a-token > "$EVIL/.fm-grok-turnend"
: > "$LOG"
out=$(PATH="$BIN:$PATH" GROK_WORKSPACE_ROOT="$EVIL" bash "$HOOK" 2>&1); rc=$?
printf '  exit=%s stdout+stderr=%s\n' "$rc" "$(printf '%q' "$out")"
show_beats "$LOG"

##############################################################################
hr "KIMI: the global hook body whose version bump this change required"
KHOME="$TMP_ROOT/kimi-home"
mkdir -p "$KHOME/.kimi-code" "$KHOME/state"
printf 'default_model = "test"\n' > "$KHOME/.kimi-code/config.toml"
cp "$KHOME/.kimi-code/config.toml" "$TMP_ROOT/kimi-config.original"
HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" install && printf 'install: ok\n'
KHOOK="$KHOME/.kimi-code/fm-turn-end.sh"
sub "the beat line the installer wrote into the global hook"
grep -n 'agent-presence' "$KHOOK" | sed 's/^/  /'
KWT="$TMP_ROOT/kimi-wt"; mkdir -p "$KWT"
TARGET="$KHOME/state/kimi-task.turn-ended"
TOKEN=fm.driveabc1234
printf '%s\n' "$TARGET" > "$KHOME/.kimi-code/fm-turn-end.d/$TOKEN"
printf 'token=%s\n' "$TOKEN" > "$KWT/.fm-kimi-turnend"
BIN="$TMP_ROOT/kimi-presence-bin"; LOG="$TMP_ROOT/kimi-presence.log"
fm_fake_agent_presence "$BIN" "$LOG"
sub "a real Kimi Stop payload for the authorised workspace"
out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$KWT" \
  | HOME="$KHOME" PATH="$BIN:$PATH" bash "$KHOOK" 2>&1); rc=$?
printf '  exit=%s stdout+stderr=%s turn-end marker=%s\n' "$rc" "$(printf '%q' "$out")" \
  "$([ -f "$TARGET" ] && echo written || echo missing)"
show_beats "$LOG"
printf '  the beat ran in: %s\n  the task worktree is: %s\n' "$(cat "$LOG.pwd")" "$(cd "$KWT" && pwd -P)"

sub "ADVERSARIAL: a Kimi session in a workspace with no Firstmate token"
: > "$LOG"
out=$(printf '{"hook_event_name":"Stop","session_id":"x","cwd":"%s","stop_hook_active":false}\n' "$TMP_ROOT" \
  | HOME="$KHOME" PATH="$BIN:$PATH" bash "$KHOOK" 2>&1); rc=$?
printf '  exit=%s stdout+stderr=%s\n' "$rc" "$(printf '%q' "$out")"
show_beats "$LOG"

sub "VERSION BUMP: a hook body written by an OLDER firstmate (no beat in it)"
OLD="$TMP_ROOT/older-firstmate-hook.sh"
{ head -n 2 "$KHOOK"; printf 'exit 0\n'; } > "$OLD"
cp "$OLD" "$KHOOK"; chmod 0700 "$KHOOK"
printf '  hook on disk before upgrade: %s lines, beat present=%s\n' \
  "$(wc -l < "$KHOOK")" "$(grep -c agent-presence "$KHOOK")"
HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" install && printf '  install upgraded it: ok\n'
printf '  hook on disk after upgrade:  %s lines, beat present=%s\n' \
  "$(wc -l < "$KHOOK")" "$(grep -c agent-presence "$KHOOK")"
cp "$OLD" "$KHOOK"; chmod 0700 "$KHOOK"
HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" remove && printf '  remove excised an older firstmate hook: ok (hook present=%s)\n' \
  "$([ -e "$KHOOK" ] && echo yes || echo no)"
cmp -s "$TMP_ROOT/kimi-config.original" "$KHOME/.kimi-code/config.toml" \
  && printf '  config.toml restored byte-for-byte: yes\n' || printf '  config.toml restored byte-for-byte: NO\n'

sub "ADVERSARIAL: a hook at that path firstmate does NOT own must still be refused"
HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" install >/dev/null
printf '#!/usr/bin/env bash\n# Someone else owns this path.\nexit 0\n' > "$KHOOK"; chmod 0700 "$KHOOK"
out=$(HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" install 2>&1); rc=$?
printf '  install rc=%s msg=%s\n' "$rc" "$out"
out=$(HOME="$KHOME" "$ROOT/bin/fm-kimi-turnend-hook.sh" remove 2>&1); rc=$?
printf '  remove  rc=%s msg=%s\n' "$rc" "$out"
printf '  foreign hook left intact: %s\n' "$(grep -c 'Someone else owns this path' "$KHOOK")"

##############################################################################
hr "SECONDMATE: a direct report that must NEVER appear on the crew presence board"
SHOME="$TMP_ROOT/main-home"; SUB="$TMP_ROOT/design-home"
mkdir -p "$SHOME/projects" "$SHOME/data" "$SHOME/state"
fm_git_init_commit "$SHOME/projects/alpha"
fm_git_add_origin "$SHOME/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$SHOME/data/projects.md"
SFAKE=$(make_fake_tmux "$TMP_ROOT/sm-fake")
make_fake_no_mistakes "$TMP_ROOT/sm-fake" >/dev/null
fm_fake_exit0 "$SFAKE" claude
export FM_BACKEND=tmux
FM_SECONDMATE_SCOPE='design scope' \
  scaffold_secondmate_charter "$SHOME" design 'design charter' alpha || printf 'charter scaffold failed\n'
PATH="$SFAKE:$PATH" FM_HOME="$SHOME" "$ROOT/bin/fm-home-seed.sh" design "$SUB" alpha >/dev/null \
  || printf 'seed failed\n'
SMLOG="$TMP_ROOT/sm-tmux.log"; SMPANE="$TMP_ROOT/sm-pane.txt"; printf '❯\n' > "$SMPANE"
: > "$SMLOG"
PATH="$SFAKE:$PATH" FM_HOME="$SHOME" FM_FAKE_TMUX_LOG="$SMLOG" FM_FAKE_TMUX_CAPTURE="$SMPANE" \
  "$ROOT/bin/fm-spawn.sh" design "$SUB" claude --secondmate 2>&1 | tail -1
sub "turn-boundary wiring installed in the secondmate's own home"
printf '  claude hook settings (.claude/settings.local.json): %s\n' \
  "$(find "$SUB" -name 'settings.local.json' 2>/dev/null | wc -l)"
printf '  opencode plugins / pi extensions / grok hooks: %s\n' \
  "$(find "$SUB" \( -name 'fm-busy-state.js' -o -name '*.pi-ext.ts' -o -name 'fm-turn-end.sh' \) 2>/dev/null | wc -l)"
sub "every file under the secondmate home that mentions agent-presence at all"
grep -rl 'agent-presence' "$SUB" 2>/dev/null | sed "s|^$SUB/|  |"
printf '  ... all of which are the firstmate SOURCE tree the seed clones, not generated wiring:\n'
grep -rl 'agent-presence' "$SUB" 2>/dev/null | sed "s|^$SUB/||" | sed 's|/.*||' | sort -u | sed 's/^/    top-level dir: /' 
sub "the launch command fm-spawn sent for the secondmate"
grep -o 'send-keys.*' "$SMLOG" | head -2 | cut -c1-200 | sed 's/^/  /'
printf '  launch command mentions agent-presence: %s\n' \
  "$(grep -c 'agent-presence' "$SMLOG")"
