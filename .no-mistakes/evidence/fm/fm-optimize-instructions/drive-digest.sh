#!/usr/bin/env bash
# Validation driver: stand up an isolated firstmate checkout (new = worktree
# HEAD, old = base commit) in /tmp with a synthetic busy fixture home, then run
# the real bin/fm-session-start.sh in it the way the session-open hook does.
# Usage: drive-digest.sh <worktree> <base-sha> <lab> <memory: budget|today> [label]
set -u
WT=$1 BASE=$2 LAB=$3 MEM=$4
mkdir -p "$LAB/shims" "$LAB/tmux"
chmod 700 "$LAB/tmux"
for name in gh gh-axi quota-axi no-mistakes lavish-axi treehouse chrome-devtools-axi curl wget npm npx brew psql supabase; do
  real=$(command -v "$name" 2>/dev/null || true)
  cat > "$LAB/shims/$name" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in --version|-v|-V|version) [ -n "$real" ] && exec "$real" "\$@"; exit 127 ;; esac
if [ "\$(basename "\$0")" = gh ] && [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then echo "Logged in to github.com account val-lab"; exit 0; fi
echo "\$(basename "\$0") \$*" >> "$LAB/denied-calls.log"; echo "denied by validation lab" >&2; exit 1
EOF
  chmod +x "$LAB/shims/$name"
done
# Same short-name layout for both variants so paths line up.
for v in new old; do
  rm -rf "$LAB/$v"; mkdir -p "$LAB/$v"
  if [ "$v" = new ]; then
    (cd "$WT" && git ls-files -z | tar --null -T - -cf -) | (cd "$LAB/$v" && tar -xf -)
  else
    (cd "$WT" && git archive "$BASE") | (cd "$LAB/$v" && tar -xf -)
  fi
  # Fixture from the NEW tree (old base predates it); seeded, so identical data.
  ( . "$WT/tests/session-start-fixture.sh"; FM_SSFIX_MEMORY=$MEM fm_ssfix_build "$LAB/$v" "$LAB/$v" ) || { echo "fixture failed for $v"; exit 1; }
done
UNSET=(-u FM_HOME)
while IFS= read -r n; do UNSET+=(-u "$n"); done < <(compgen -e | grep -E '^(FM_|NO_MISTAKES|CLAUDE|TMUX)')
for v in new old; do
  (cd "$LAB/$v" && env "${UNSET[@]}" CLAUDECODE=1 TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/shims:$PATH" \
     bin/fm-session-start.sh) > "$LAB/digest-$v.txt" 2> "$LAB/digest-$v.err"
  echo "$v exit=$? bytes=$(LC_ALL=C wc -c < "$LAB/digest-$v.txt")"
done
