#!/usr/bin/env bash
# Adversarial digest drive: hand-written backlog edge cases on the real script,
# for new code and base code, tasks-axi backend and manual backend.
# Usage: drive-adversarial.sh <worktree> <base-sha> <lab>
set -u
WT=$1 BASE=$2 LAB=$3
mkdir -p "$LAB/shims" "$LAB/tmux"; chmod 700 "$LAB/tmux"
for name in gh gh-axi quota-axi no-mistakes lavish-axi treehouse chrome-devtools-axi curl wget npm npx brew psql supabase; do
  printf '#!/usr/bin/env bash\necho "$(basename "$0") $*" >> %q; exit 1\n' "$LAB/denied-calls.log" > "$LAB/shims/$name"; chmod +x "$LAB/shims/$name"
done
LONG_UTF8=$(printf 'Ünïcödé title with "quotes", commas, and a tail past the cap: %s' "$(printf 'é%.0s' $(seq 1 40))")
for v in new old; do
  rm -rf "$LAB/$v"; mkdir -p "$LAB/$v"
  if [ "$v" = new ]; then (cd "$WT" && git ls-files -z | tar --null -T - -cf -) | (cd "$LAB/$v" && tar -xf -)
  else (cd "$WT" && git archive "$BASE") | (cd "$LAB/$v" && tar -xf -); fi
  mkdir -p "$LAB/$v/data" "$LAB/$v/state" "$LAB/$v/config"
  cat > "$LAB/$v/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] f-lapsed - Flight whose captain hold lapsed (repo: harbor) (kind: ship) (since 2026-10-01) (hold: Pick A or B. Details that should stay out) (hold-kind: captain) (hold-until: 2020-01-01)
- [ ] f-utf8 - $LONG_UTF8 (repo: lantern) (kind: ship) (since 2026-10-01)
- [ ] f-live - Live captain hold in flight (repo: keel) (kind: scout) (since 2026-10-01) (hold: Which way, left or right? More detail follows.) (hold-kind: captain) (hold-until: 2099-01-01)
  BODY-LINE-MUST-NOT-APPEAR in flight body

## Queued
- [ ] q-kindless - Kindless open-ended hold (repo: harbor) (kind: ship) (since 2026-10-01) (hold: Wait on it)
- [ ] q-gate - Real time gate (repo: harbor) (kind: ship) (since 2026-10-01) (hold: Wait till June) (hold-until: 2099-06-01)
- [ ] q-parked - Parked wish (repo: keel) (kind: ship) (since 2026-10-01) (hold: Someday maybe) (hold-kind: parked)
- [ ] q-lapsed - Lapsed queued decision (repo: keel) (kind: ship) (since 2026-10-01) (hold: Choose now. Extra) (hold-kind: captain) (hold-until: 2020-01-02)
- [ ] q-dec - Decision title, with "quote" and comma (repo: keel) (kind: ship) (since 2026-10-01) (hold: Should we ship v2, or wait?! Then more text here.) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] q-ready - A ready row (repo: quill) (kind: ship) (since 2026-10-01)
  BODY-LINE-MUST-NOT-APPEAR in queued body
- [ ] q-blocked - Blocked row blocked-by: f-live (repo: keel) (kind: ship) (since 2026-10-01)

## Done
- [x] d-1 - DONE-ROW-MUST-NOT-APPEAR (repo: harbor) (kind: ship) (since 2026-10-01)
EOF
  printf 'window=firstmate:fm-f-live\nworktree=/fixture/pool/keel/f-live\nharness=claude\nkind=scout\nmode=no-mistakes\nyolo=off\nmodel=claude-opus-5-5\nbusy_gen=SHOULD-NOT-APPEAR-BUSYGEN\npr=https://example.invalid/pull/1\nmode=direct-PR\n' > "$LAB/$v/state/f-live.meta"
  printf 'working: older line one OLDER-LINE-1\nworking: older line two OLDER-LINE-2\nnote: captain answered: keep the v1 reader\n' > "$LAB/$v/state/f-live.status"
  printf -- '- harbor [direct-PR +yolo] - Harbor app; with a long tail of prose after the clause. And more.\n  sub harbor-board | board | feat/board\nFree prose line in the registry\n' > "$LAB/$v/data/projects.md"
done
UNSET=(-u FM_HOME)
while IFS= read -r n; do UNSET+=(-u "$n"); done < <(compgen -e | grep -E '^(FM_|NO_MISTAKES|CLAUDE|TMUX)')
run() { (cd "$LAB/$1" && env "${UNSET[@]}" CLAUDECODE=1 TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/shims:$PATH" bin/fm-session-start.sh); }
run new > "$LAB/digest-new.txt" 2>"$LAB/digest-new.err"; echo "new exit=$?"
run old > "$LAB/digest-old.txt" 2>"$LAB/digest-old.err"; echo "old exit=$?"
# manual backend on the new code (fresh lock: remove state lock between runs)
rm -f "$LAB/new/state/.lock"; printf 'manual\n' > "$LAB/new/config/backlog-backend"
run new > "$LAB/digest-new-manual.txt" 2>&1; echo "new manual exit=$?"
