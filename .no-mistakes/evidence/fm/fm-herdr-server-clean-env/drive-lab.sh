#!/usr/bin/env bash
# Live driver: start a guarded fm-lab-* Herdr session through the adapter's real
# start path (fm_backend_herdr_server_ensure / container_ensure / create_task),
# from inside a Claude session, and record which variables a worker pane sees.
# usage: drive-lab.sh <worktree> <adapter herdr.sh to source> <private-tmp-dir> <report-file> <label>
set -u
WT=$1 ADAPTER=$2 TMPD=$3 REPORT=$4 LABEL=$5
LAB="$WT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
S=$("$LAB" name "$LABEL")
"$LAB" prepare "$S" || { echo "prepare failed" >&2; exit 1; }
trap '"$LAB" teardown "$S" && echo "teardown: $S removed, default-session tripwire intact" >> "$REPORT"' EXIT
export HERDR_SESSION=$S

# Planted on the primary that starts the server.
export CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent PI_CODING_AGENT=1 FM_PI_HARNESS=1 GROK_AGENT=1
export https_proxy=http://proxy.example:3128 SSL_CERT_FILE=/etc/ssl/fake-corp-ca.pem XAUTHORITY=/tmp/fake-xauth
export FM_ENVTEST_ORDINARY=keep-me NOT_CLAUDE_VAR=keep-me CLAUDEX=keep-me
readonly CLAUDE_PID   # exported AND readonly, start runs under set -e below

# shellcheck source=/dev/null
. "$ADAPTER"
{
  echo "lab session: $S   adapter: $ADAPTER"
  echo "starter (primary) env has: $(compgen -e | grep -E '^(CLAUDE|CLAUDECODE$|AI_AGENT$|TMUX)' | sort | tr '\n' ' ')"
} > "$REPORT"

set -e
fm_backend_herdr_server_ensure "$S"
set +e
echo "server_ensure under set -e with readonly exported CLAUDE_PID: rc=0" >> "$REPORT"

raw=$(fm_backend_herdr_container_ensure "$TMPD" launcher-home) || { echo "container_ensure failed" >> "$REPORT"; exit 1; }
container=${raw%%$'\t'*} seeded=${raw#*$'\t'}
# Variables set only on the client that creates the tab (spawn path).
ids=$(FM_CLIENT_ONLY=client-side CLAUDE_TAB_CLIENT_MARKER=client-side \
  fm_backend_herdr_create_task "$container" fm-envtest "$TMPD" "$seeded") || { echo "create_task failed" >> "$REPORT"; exit 1; }
pane=${ids#* }
echo "container=$container task tab/pane=$ids" >> "$REPORT"
fm_backend_herdr_send_text_line "$S:$pane" "env | sort > $TMPD/pane.env.tmp && mv $TMPD/pane.env.tmp $TMPD/pane.env"
for _ in $(seq 1 60); do [ -s "$TMPD/pane.env" ] && break; sleep 0.25; done
[ -s "$TMPD/pane.env" ] || { echo "pane never wrote its env" >> "$REPORT"; exit 1; }

{
  echo "--- worker pane sees (names only) matching CLAUDE*/AI_AGENT/CURSOR*/PI_*/FM_PI_HARNESS/GROK*/TMUX*/FM_CLIENT_ONLY:"
  cut -d= -f1 "$TMPD/pane.env" | grep -E '^(CLAUDE|AI_AGENT$|CURSOR_|PI_CODING|FM_PI_HARNESS$|GROK_|TMUX|FM_CLIENT_ONLY$)' | sort | sed 's/^/  /'
  echo "--- pass-through checks (whole-line match in pane env):"
  for kv in "HOME=$HOME" "https_proxy=http://proxy.example:3128" "SSL_CERT_FILE=/etc/ssl/fake-corp-ca.pem" \
            "XAUTHORITY=/tmp/fake-xauth" "FM_ENVTEST_ORDINARY=keep-me" "NOT_CLAUDE_VAR=keep-me" "CLAUDEX=keep-me"; do
    if grep -qxF -- "$kv" "$TMPD/pane.env"; then echo "  present ${kv%%=*}"; else echo "  MISSING ${kv%%=*}"; fi
  done
} >> "$REPORT"
