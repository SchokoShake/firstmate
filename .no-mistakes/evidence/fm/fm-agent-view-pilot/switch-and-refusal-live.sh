#!/usr/bin/env bash
# Live check (no-mistakes test phase): drives the REAL bin/fm-spawn.sh of the
# base commit (main, 6fc9a0e) and of the change, on a private tmux socket, with
# the REAL installed claude launched in the window from an isolated, logged-out
# Claude Code store (scratch HOME + CLAUDE_CONFIG_DIR), so no account is used.
# The tmux wrapper only routes to the private socket and logs every send-keys
# argument before running it for real.
#   A. switch absent on main vs absent / `off` on the change: typed input,
#      record, and hooks must be byte-identical; the window runs an ordinary
#      interactive claude.
#   B. switch empty / `yes`: the eligible spawn refuses before anything exists.
#   C. switch on, worktree of a repository the store does not trust: the real
#      `claude --bg` refuses; firstmate records no session id and lists none.
# Usage: switch-and-refusal-live.sh <scratch-root> <base-tree> <target-tree> <evidence-dir>
set -u
S=$1 BASE=$2 TARGET=$3 E=$4
REAL_TMUX=$(command -v tmux)
REAL_CLAUDE=$(command -v claude)
ID=avoff1
LAB=$S/offlab
CFG=$S/cfg-off
SOCK=fm-avoff-$$
export GIT_AUTHOR_NAME=avlive GIT_AUTHOR_EMAIL=avlive@example.invalid GIT_COMMITTER_NAME=avlive GIT_COMMITTER_EMAIL=avlive@example.invalid
unset TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT CLAUDECODE CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED \
  CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT
mkdir -p "$CFG" "$S/offhome"
R=$(cd "$S/repo" && pwd -P)
printf '{"hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$R" > "$CFG/.claude.json"
printf '{"skipDangerousModePermissionPrompt":true}\n' > "$CFG/settings.json"
[ -d "$S/untrusted" ] || git clone -q "$S/origin.git" "$S/untrusted"

store() { env -i HOME="$S/offhome" PATH="$PATH" CLAUDE_CONFIG_DIR="$CFG" "$REAL_CLAUDE" "$@"; }

setup() {  # <repo>
  rm -rf "$LAB" "/tmp/fm-$ID"
  mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/pool/1" "$LAB/fmhome/data/$ID" "$LAB/fmhome/projects" "$LAB/fmhome/state" "$LAB/fmhome/config"
  WT=$LAB/pool/1/wt
  git -C "$1" worktree add --quiet --detach "$WT" HEAD
  REPO=$1
  cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  skip=
  for a in "\${@:2}"; do
    if [ -n "\$skip" ]; then skip=; continue; fi
    case "\$a" in -t) skip=1 ;; -l) ;; *) printf '%s\n' "\$a" >> "$LAB/typed.log" ;; esac
  done
fi
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
SH
  cat > "$LAB/shim/claude" <<SH
#!/usr/bin/env bash
keep=(HOME=$S/offhome PATH=$(printf %q "$PATH"))
for v in TERM LANG USER LOGNAME SHELL CLAUDE_CONFIG_DIR; do [ -z "\${!v:-}" ] || keep+=("\$v=\${!v}"); done
exec env -i "\${keep[@]}" /bin/bash -c 'exec -a claude "\$0" "\$@"' $(printf %q "$REAL_CLAUDE") "\$@"
SH
  cat > "$LAB/bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --lease ]; then printf '%s\n' "$FM_FAKE_PANE_PATH"; fi
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/no-mistakes"
  chmod +x "$LAB/shim/tmux" "$LAB/shim/claude" "$LAB/bin/treehouse" "$LAB/bin/no-mistakes"
  : > "$LAB/typed.log"
  H=$LAB/fmhome
  printf 'claude\n' > "$H/config/crew-harness"
  printf '%s\n' "$$" > "$H/state/.lock"
  printf '%s off\n' "$$" > "$H/state/.trace-context-effective"
  touch "$H/state/.last-watcher-beat"
  printf '# brief\n\nReply with the single word ready.\n' > "$H/data/$ID/brief.md"
  PATH="$LAB/shim:$LAB/bin:$PATH" CLAUDE_CONFIG_DIR="$CFG" tmux new-session -d -s lab -n w0 "bash --norc --noprofile"
  PATH="$LAB/shim:$LAB/bin:$PATH" tmux set-option -g default-command "bash --norc --noprofile"
}

spawn() {  # <tree> -> stdout+stderr of fm-spawn; rc in SPAWN_RC
  SPAWN_OUT=$(env PATH="$LAB/shim:$LAB/bin:$PATH" CLAUDE_CONFIG_DIR="$CFG" FM_ROOT_OVERRIDE='' FM_HOME="$H" \
    FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects" \
    FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" FM_AGENT_VIEW_LAUNCH_WAIT=60 \
    "$1/bin/fm-spawn.sh" "$ID" "$REPO" --mode local-only --yolo off --model haiku 2>&1)
  SPAWN_RC=$?
}

teardown() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  sleep 1
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune
  rm -rf "/tmp/fm-$ID"
}

collect() {  # <label> <tree>: the firstmate install root is normalized to <FM_ROOT>, since the two trees live at different paths
  local d="$S/collect/$1" root=$2
  mkdir -p "$d"
  sed -e "s#$root/#<FM_ROOT>/#g" "$LAB/typed.log" > "$d/typed.log"
  [ ! -f "$H/state/$ID.meta" ] || sed -e '/^lease_holder=/d' -e '/^busy_gen=/d' -e '/^spawn_gen=/d' "$H/state/$ID.meta" > "$d/meta"
  [ ! -f "$WT/.claude/settings.local.json" ] || sed -e 's/--gen [^ ]*/--gen N/g' -e "s#$root/#<FM_ROOT>/#g" "$WT/.claude/settings.local.json" > "$d/hooks.json"
  printf '%s\n' "$SPAWN_OUT" | sed -e 's/lease_holder=[^ ]*//' > "$d/spawn.out"
  echo "$SPAWN_RC" > "$d/spawn.rc"
  PATH="$LAB/shim:$PATH" tmux list-windows -a -F '#{window_name}' > "$d/windows" 2>/dev/null || true
}

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

# --- A. switch off is today's launch, byte for byte ---------------------------
for run in base:absent target:absent target:off; do
  tree=${run%%:*} sw=${run#*:}
  [ "$tree" = base ] && dir=$BASE || dir=$TARGET
  setup "$S/repo"
  [ "$sw" = absent ] || printf '%s\n' "$sw" > "$H/config/agent-view-workers"
  spawn "$dir"
  sleep 8
  PATH="$LAB/shim:$PATH" tmux capture-pane -p -t "firstmate:fm-$ID" > "$E/screen-switch-$tree-$sw.txt" 2>/dev/null || true
  fg=$(PATH="$LAB/shim:$PATH" tmux display-message -p -t "firstmate:fm-$ID" '#{pane_current_command}' 2>/dev/null)
  echo "# $tree switch=$sw: fm-spawn rc=$SPAWN_RC; window foreground: $fg; $(printf '%s' "$SPAWN_OUT" | grep '^spawned' | sed 's/lease_holder=[^ ]*//')"
  collect "$tree-$sw" "$dir"
  teardown
done
for c in target-absent target-off; do
  for f in typed.log meta hooks.json spawn.out spawn.rc; do
    check "switch off: $c $f is byte-identical to main's" "cmp -s '$S/collect/base-absent/$f' '$S/collect/$c/$f'"
  done
done
check "switch off: main's typed launch exports GOTMPDIR and starts no background session" \
  "grep -q '^export GOTMPDIR=' '$S/collect/base-absent/typed.log' && ! grep -q -- '--bg' '$S/collect/base-absent/typed.log'"
check "switch off: the record names no agent-view session" "! grep -q '^agent_view_id=' '$S/collect/target-off/meta'"
cp "$S/collect/target-off/typed.log" "$E/switch-off-typed-input.txt"

# --- B. an invalid switch refuses before anything exists ----------------------
for v in empty yes; do
  setup "$S/repo"
  if [ "$v" = empty ]; then : > "$H/config/agent-view-workers"; else printf 'yes\n' > "$H/config/agent-view-workers"; fi
  spawn "$TARGET"
  echo "# switch=$v: fm-spawn rc=$SPAWN_RC: $SPAWN_OUT"
  check "invalid switch ($v): the spawn refuses" "[ $SPAWN_RC -ne 0 ] && printf '%s' \"\$SPAWN_OUT\" | grep -q 'must say on or off'"
  check "invalid switch ($v): no record, no window, nothing typed" \
    "[ ! -e '$H/state/$ID.meta' ] && ! PATH='$LAB/shim:$PATH' tmux list-windows -a -F '#{window_name}' | grep -qx 'fm-$ID' && [ ! -s '$LAB/typed.log' ]"
  teardown
done

# --- C. Claude Code refuses the background launch -----------------------------
setup "$S/untrusted"
printf 'on\n' > "$H/config/agent-view-workers"
spawn "$TARGET"
echo "# untrusted workspace: fm-spawn rc=$SPAWN_RC"
printf '%s\n' "$SPAWN_OUT" | sed 's/^/#   /'
sleep 1
PATH="$LAB/shim:$PATH" tmux capture-pane -p -t "firstmate:fm-$ID" > "$E/screen-untrusted-launch.txt" 2>/dev/null || true
cp "$LAB/typed.log" "$E/pilot-launch-typed-input.txt"
cp "$H/state/$ID.meta" "$E/untrusted-launch-record.meta" 2>/dev/null || true
cp "$H/state/$ID.status" "$E/untrusted-launch-status.txt" 2>/dev/null || true
check "refused launch: fm-spawn fails and quotes Claude Code's own reason" \
  "[ $SPAWN_RC -ne 0 ] && printf '%s' \"\$SPAWN_OUT\" | grep -q 'Claude Code refused the agent-view launch of $ID' && printf '%s' \"\$SPAWN_OUT\" | grep -q 'Workspace not trusted'"
check "refused launch: the record names no session (no agent_view_id line, not pending)" "[ -f '$H/state/$ID.meta' ] && ! grep -q '^agent_view_id=' '$H/state/$ID.meta'"
check "refused launch: the task status records the failure" "grep -q '^failed: Claude Code refused' '$H/state/$ID.status'"
check "refused launch: the store lists no session" "[ \"\$(store agents --json --all | jq length)\" = 0 ]"
check "pilot launch line: claude --bg named fm-$ID, environment via --settings, tmux identity dropped" \
  "grep -q -- \"env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u TMUX -u TMUX_PANE claude --bg --name 'fm-$ID' --settings\" '$LAB/typed.log' && grep -q 'FM_AGENT_VIEW_TASK\":\"$ID' '$LAB/typed.log' && grep -q 'GOTMPDIR\":\"/tmp/fm-$ID/gotmp' '$LAB/typed.log' && grep -q 'TRACEPARENT\":\"\"' '$LAB/typed.log'"
check "pilot launch: nothing is exported into the window's shell" "! grep -q '^export ' '$LAB/typed.log'"
check "pilot hooks: every claude hook is gated on the worker's marker" \
  "[ \"\$(jq -r '.hooks[][].hooks[].command' '$WT/.claude/settings.local.json' | grep -c '^\[ \"\${FM_AGENT_VIEW_TASK:-}\" = '\\''$ID'\\'' \] || exit 0; ')\" = 4 ]"

# --- D. records no lifecycle path may act on ----------------------------------
fmrun() {  # <script> <args...> -> RUN_OUT, RUN_RC
  RUN_OUT=$(env PATH="$LAB/shim:$LAB/bin:$PATH" CLAUDE_CONFIG_DIR="$CFG" FM_ROOT_OVERRIDE='' FM_HOME="$H" \
    FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects" \
    FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" "$TARGET/bin/$1" "${@:2}" 2>&1)
  RUN_RC=$?
  echo "#   $1 ${*:2} -> rc=$RUN_RC: $(printf '%s' "$RUN_OUT" | tail -n 2 | tr '\n' ' ')"
}
M=$H/state/$ID.meta
cp "$M" "$S/meta.orig"
printf 'agent_view_id=pending\n' >> "$M"
: > "$LAB/typed.log"
fmrun fm-send.sh "$ID" "please continue"
check "pending record: fm-send refuses, launch may be in flight" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'launch may still be in flight; nothing was sent'"
fmrun fm-control.sh "$ID" exit
check "pending record: fm-control exit refuses" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'launch may still be in flight'"
fmrun fm-teardown.sh "$ID" --force
check "pending record: fm-teardown --force refuses and keeps the record" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'REFUSED' && [ -f '$M' ] && [ -d '$WT' ]"
check "pending record: nothing was typed into the window" "[ ! -s '$LAB/typed.log' ]"
sed -e 's/^kind=.*/kind=secondmate/' "$S/meta.orig" > "$M"; printf 'agent_view_id=0123abcd\n' >> "$M"
for verb in exit interrupt relaunch; do
  fmrun fm-control.sh "$ID" $verb
  check "secondmate record naming a pilot session: fm-control $verb refuses" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'secondmates are never piloted'"
done
cp "$S/meta.orig" "$M"; printf 'agent_view_id=0123abcd\n' >> "$M"
fmrun fm-control.sh "$ID" relaunch --model sonnet
check "pilot record: relaunch --model refuses" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'relaunches only as itself'"
for cmd in /background /bg /exit /quit; do
  fmrun fm-send.sh "$ID" "$cmd"
  check "pilot record: fm-send '$cmd' refuses as a viewer detach" "[ $RUN_RC -ne 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q 'would detach'"
done
fmrun fm-send.sh "$ID" "/no-mistakes"
check "pilot record: a skill command is not a detach, but a window not showing the session still refuses it" \
  "[ $RUN_RC -ne 0 ] && ! printf '%s' \"\$RUN_OUT\" | grep -q 'would detach' && printf '%s' \"\$RUN_OUT\" | grep -q 'viewer state: detached'"
check "pilot record: nothing was typed by any refusal" "[ ! -s '$LAB/typed.log' ]"
fmrun fm-control.sh "$ID" exit
check "pilot record whose session no longer exists: exit reads the session list and reports already-stopped" \
  "[ $RUN_RC -eq 0 ] && printf '%s' \"\$RUN_OUT\" | grep -q '^already-stopped $ID'"
teardown

# --- E. switch on, but a raw launch command is never piloted -------------------
setup "$S/repo"
printf 'on\n' > "$H/config/agent-view-workers"
SPAWN_OUT=$(env PATH="$LAB/shim:$LAB/bin:$PATH" CLAUDE_CONFIG_DIR="$CFG" FM_ROOT_OVERRIDE='' FM_HOME="$H" \
  FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects" \
  FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" \
  "$TARGET/bin/fm-spawn.sh" "$ID" "$S/repo" --mode local-only --yolo off --harness "claude --dangerously-skip-permissions" 2>&1)
SPAWN_RC=$?
echo "# raw launch command with the switch on: fm-spawn rc=$SPAWN_RC"
printf '%s\n' "$SPAWN_OUT" | grep -E 'agent-view pilot|^spawned|error' | sed 's/^/#   /'
check "raw launch command: launched as an ordinary worker with a plain notice" \
  "[ $SPAWN_RC -eq 0 ] && printf '%s' \"\$SPAWN_OUT\" | grep -q 'agent-view pilot: $ID uses a raw launch command, which is never piloted; launching it as an ordinary worker'"
check "raw launch command: no background session, no agent_view_id" \
  "! grep -q -- '--bg' '$LAB/typed.log' && ! grep -q '^agent_view_id=' '$H/state/$ID.meta' && ! printf '%s' \"\$SPAWN_OUT\" | grep -q 'agent_view='"
teardown
store daemon status 2>/dev/null | sed -n 1p | sed 's/^/# store service after the run: /'
echo "# failures: $fails"
[ "$fails" -eq 0 ]
