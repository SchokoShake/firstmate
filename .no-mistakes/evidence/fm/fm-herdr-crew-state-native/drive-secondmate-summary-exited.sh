#!/usr/bin/env bash
# Evidence driver: real bin/fm-fleet-snapshot.sh --secondmate-home-summary of <root>
# over an isolated home whose one in-flight child sits in a Herdr lab pane with no
# agent, a leftover busy Claude record and a 'working:' status log.
# Usage: drive-secondmate-summary-exited.sh <firstmate-root> <lab-helper>
set -u
ROOT=$(cd "$1" && pwd -P); LAB_HELPER=$2; ORIGINAL_PATH=$PATH
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" "$@"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE
SESSION=$(lab name cssum); LAB=$(mktemp -d /tmp/fm-cssum.XXXXXX)
cleanup() { lab teardown "$SESSION" >/dev/null 2>&1 || echo "WARN: teardown failed"; rm -rf -- "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/home/data" "$LAB/home/state" "$LAB/home/config" "$LAB/home/projects"
cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
EOF
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "no-mistakes version v1.79.0 (fake)";; esac\nexit 0\n' > "$LAB/bin/no-mistakes"
chmod +x "$LAB/bin/herdr" "$LAB/bin/no-mistakes"; export PATH="$LAB/bin:$PATH"
WT="$LAB/home/projects/child"; git init -q -b fm/child "$WT" && git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
lab provision "$SESSION" >/dev/null || { echo FATAL; exit 1; }
P=$(lab run "$SESSION" workspace create --cwd "$WT" --no-focus | jq -r '.result.root_pane.pane_id')
S="$LAB/home/state"; ID=gone-child
cat > "$LAB/home/data/backlog.md" <<'EOF'
## In flight
- [ ] gone-child - Implement the parser (repo: child) (kind: ship)

## Queued

## Done
EOF
printf 'window=%s:%s\nworktree=%s\nproject=child\nharness=claude\nkind=ship\nmode=no-mistakes\nbackend=herdr\n' "$SESSION" "$P" "$WT" > "$S/$ID.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$S" "$ID"); "$ROOT/bin/fm-busy-event.sh" apply "$S" "$ID" busy --gen "$gen" --source claude-hook --event user-prompt-submit
printf 'working: implementing the parser\n' > "$S/$ID.status"
echo "# root=$ROOT  child pane $SESSION:$P native=$(lab run "$SESSION" agent get "$P" 2>&1 | jq -r '.error.code // .result.agent.agent_status')"
echo "# crew-state: $(FM_HOME="$LAB/home" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | head -1)"
FM_HOME="$LAB/home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary 2>&1 \
  | jq -c '{schema, valid, state, reason, invalidity, active_children:[.active_children[]?.id]}' 2>&1
