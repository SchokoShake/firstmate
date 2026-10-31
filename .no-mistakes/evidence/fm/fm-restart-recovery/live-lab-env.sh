export LAB=/tmp/fm-livedrive.ZI6xnC ROOT=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M697GED6EN42RZE328GDKWK0
export REAL_TMUX=/usr/bin/tmux REAL_PS=/usr/bin/ps SOCKET=fm-livedrive-ZI6xnC
export HOME=/tmp/fm-livedrive.ZI6xnC/home CLAUDE_CONFIG_DIR=/tmp/fm-livedrive.ZI6xnC/home/.claude SHELL=/bin/bash
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
unset TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT NO_MISTAKES_GATE \
  CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT \
  ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
export PATH=/tmp/fm-livedrive.ZI6xnC/shim:/tmp/fm-livedrive.ZI6xnC/bin:/tmp/fm-livedrive.ZI6xnC/home/.local/bin:/home/metoo/.local/share/jdk-17.0.13+11/bin:/home/metoo/.deno/bin:/home/metoo/.local/bin:/home/metoo/.local/bin:/home/metoo/.local/lib/nodejs/current/bin:/home/metoo/.local/bin:/home/metoo/.local/share/jdk-17.0.13+11/bin:/home/metoo/.deno/bin:/home/metoo/.local/bin:/home/metoo/.local/bin:/home/metoo/.local/lib/nodejs/current/bin:/home/metoo/.local/bin:/home/metoo/go/bin:/home/metoo/.cargo/bin:/home/metoo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/snap/bin:/home/metoo/.claude/skills/lookout/bin
export HOME_DIR=/tmp/fm-livedrive.ZI6xnC/fmhome STATE_DIR=/tmp/fm-livedrive.ZI6xnC/fmhome/state PROJ_DIR=/tmp/fm-livedrive.ZI6xnC/proj SS_ROOT=/tmp/fm-livedrive.ZI6xnC/ssroot BOOT_FILE=/tmp/fm-livedrive.ZI6xnC/boot-id
export FAKE_NM_STATUS=/tmp/fm-livedrive.ZI6xnC/nm-status
export FM_GATE_REFUSE_BYPASS=1
fm_env() { env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_LAUNCH_WAIT=90 FM_CONTROL_NM_TIMEOUT=5 "$@"; }
run_session_start() { env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$SS_ROOT" \
  FM_BOOT_ID_FILE="$BOOT_FILE" FM_FAKE_HARNESS_PID=$$ FM_STARTUP_NETWORK_TIMEOUT=10 \
  FM_RESTART_NM_TIMEOUT=5 PATH="$LAB/ssbin:$PATH" "$ROOT/bin/fm-session-start.sh" 2>&1; }
cd "$LAB/cwd"
lock_here() { printf '%s\n' "$$" > "$STATE_DIR/.lock"; printf '%s off\n' "$$" > "$STATE_DIR/.trace-context-effective"; }
meta_get() { sed -n "s/^$2=//p" "$STATE_DIR/$1.meta" | tail -n 1; }
rec_get() { sed -n "s/^$2=//p" "$STATE_DIR/$1.harness-session" 2>/dev/null | tail -n 1; }
screen() { tmux capture-pane -p -t "$(meta_get "$1" window)" 2>/dev/null; }
write_leases() {
  : > "$LAB/pool/treehouse-state.lock"
  jq -n --arg p1 "$LAB/pool/1/wt" --arg h1 "${1:-$(meta_get alpha lease_holder)}" --arg p2 "$LAB/pool/2/wt" --arg h2 "${2:-$(meta_get bravo lease_holder 2>/dev/null)}" \
    '{worktrees:[{name:"1",path:$p1,leased:true,lease_holder:$h1},{name:"2",path:$p2,leased:true,lease_holder:$h2}]}' > "$LAB/pool/treehouse-state.json"
}
ss() { bash -c '. /tmp/fm-livedrive.ZI6xnC/env.sh; lock_here; run_session_start'; }
