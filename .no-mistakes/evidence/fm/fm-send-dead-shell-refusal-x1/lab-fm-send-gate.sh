#!/usr/bin/env bash
# Disposable real-tmux lab for bin/fm-send.sh's exited-agent gate.
# usage: lab-fm-send-gate.sh <fm-root> <label>
# Runs a private tmux server (own socket, -f /dev/null) with real shells, a
# stand-in agent (argv0 `claude`), and an unidentifiable foreground (python3),
# records task metas in a scratch FM_HOME, drives the real fm-send.sh, and
# prints a transcript: exit codes, stderr, pane captures, and side-effect files.
set -u
ROOT=$1
LABEL=$2
LAB=$(mktemp -d /tmp/fm-gate-lab.XXXXXX)
LAB=$(cd "$LAB" && pwd -P)
SOCK="fm-gate-lab-$$"
REAL_TMUX=$(command -v tmux)
cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/bin" "$LAB/hh"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCK" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
unset TMUX TMUX_PANE
export PATH="$LAB/shim:$PATH" HOME="$LAB/hh" FM_HOME="$LAB/home" FM_SEND_SETTLE=0 FM_GATE_REFUSE_BYPASS=1
[ "$(command -v tmux)" = "$LAB/shim/tmux" ] || { echo "shim does not shadow tmux"; exit 2; }

# Stand-in agent: a composer box, one submitted line per Enter logged.
cat > "$LAB/bin/agent.sh" <<'SH'
#!/bin/bash
draw() { printf '\033[2J\033[H\342\225\255%s\342\225\256\n\342\224\202%40s\342\224\202\n\342\225\260%s\342\225\257\033[2;3H' \
  "$(printf '\342\224\200%.0s' $(seq 40))" '' "$(printf '\342\224\200%.0s' $(seq 40))"; }
draw
while IFS= read -r l; do printf 'line:%s\n' "$l" >> "$1"; draw; done
SH
chmod +x "$LAB/bin/agent.sh"

tmux new-session -d -s lab -n ship-dead -x 120 -y 30 "env PS1='zsh%% ' HOME=$LAB/hh /bin/zsh -f"
tmux new-window -t lab -n ship-pending "env PS1='bash\$ ' HOME=$LAB/hh /bin/bash --norc --noprofile"
tmux new-window -t lab -n mate-dead "env PS1='bash\$ ' HOME=$LAB/hh /bin/bash --norc --noprofile"
tmux new-window -t lab -n ship-alive "/bin/bash -c 'exec -a claude /bin/bash $LAB/bin/agent.sh $LAB/agent.log'"
tmux new-window -t lab -n ship-odd "python3 -u -c 'import sys
for l in sys.stdin: open(sys.argv[1], \"a\").write(repr(l) + \"\\n\")' $LAB/odd.log"
sleep 1.5

meta() {  # <id> <window> <kind>
  printf 'window=lab:%s\nkind=%s\nharness=claude\nbackend=tmux\n' "$2" "$3" > "$FM_HOME/state/$1.meta"
}
meta s1 ship-dead ship
meta s2 ship-pending ship
meta m1 mate-dead secondmate
printf 'home=%s/mate\nprojects=%s/mate/projects\n' "$LAB" "$LAB" >> "$FM_HOME/state/m1.meta"
mkdir -p "$LAB/mate/projects" "$LAB/mate/state"
meta s3 ship-alive ship
meta s4 ship-odd ship

send() {  # <args...>
  local out rc
  out=$("$ROOT/bin/fm-send.sh" "$@" 2>&1)
  rc=$?
  printf '$ fm-send.sh %s\n' "$*"
  printf '%s\n' "$out" | sed 's/^/  | /'
  printf '  exit=%s\n' "$rc"
}
pane() {  # <window>
  printf -- '--- pane lab:%s (capture) ---\n' "$1"
  tmux capture-pane -p -t "lab:$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed 's/^/  > /'
}
state() {  # <window>
  printf '  classifier: %s\n' "$(cd "$ROOT" && . bin/fm-backend.sh && fm_backend_agent_state tmux "lab:$1")"
}
exists() {  # <file>
  if [ -e "$1" ]; then printf '  side effect: %s EXISTS\n' "${1##*/}"; else printf '  side effect: %s absent\n' "${1##*/}"; fi
}

echo "=== $LABEL: fm-send against a real tmux lab (root=$ROOT) ==="
echo
echo "## A. ship s1, agent exited, zsh at its prompt: a steer that is a shell command"
state ship-dead
send s1 "touch $LAB/steer-ran"
sleep 0.5
exists "$LAB/steer-ran"
echo
echo "## B. same shell, a steer with an apostrophe"
send s1 "don't do that, keep the tests green"
sleep 0.5
pane ship-dead
echo
echo "## C. explicit backend target lab:ship-dead (matched back to s1's meta)"
send lab:ship-dead "touch $LAB/explicit-ran"
sleep 0.5
exists "$LAB/explicit-ran"
echo
echo "## D. ship s2, bash with a pending typed line, --key Enter"
tmux send-keys -t lab:ship-pending -l "touch $LAB/pending-ran"
sleep 0.3
state ship-pending
send s2 --key Enter
sleep 0.5
exists "$LAB/pending-ran"
pane ship-pending
echo
echo "## E. secondmate m1, agent exited, bash at its prompt"
state mate-dead
send m1 "status please"
sleep 0.5
printf '  pending-replies: %s\n' "$(ls -A "$FM_HOME/state/pending-replies" 2>/dev/null | wc -l | tr -d ' ') file(s)"
pane mate-dead
echo
echo "## F. ship s3, live stand-in agent (argv0 claude)"
state ship-alive
send s3 "carry on with the plan"
sleep 0.3
send s3 --key Enter
sleep 0.3
printf '  agent received:\n'; sed 's/^/    /' "$LAB/agent.log" 2>/dev/null || echo "    (nothing)"
echo
echo "## G. ship s4, unidentifiable foreground (python3 reader)"
state ship-odd
send s4 "carry on"
sleep 0.3
pane ship-odd
send s4 --key Enter
sleep 0.5
printf '  reader received:\n'; sed 's/^/    /' "$LAB/odd.log" 2>/dev/null || echo "    (nothing)"
