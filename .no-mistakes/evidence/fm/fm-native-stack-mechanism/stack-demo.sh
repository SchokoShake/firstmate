#!/usr/bin/env bash
# End-to-end CLI demonstration of the native-stack mechanism, run against the
# real bin/ scripts with a stubbed `gh` that serves pull request JSON fixtures
# through the checker's own --jq program using the real jq. Everything lives in
# a throwaway sandbox home; no live FM_HOME is read or written.
# Usage: stack-demo.sh <worktree-root> <base-commit-archive-root>
set -u
ROOT=$1
BASE_ROOT=$2
SANDBOX=$(mktemp -d /tmp/fm-stack-demo.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
HOME_DIR="$SANDBOX/home"
FAKEBIN="$SANDBOX/fakebin"
PULLS="$SANDBOX/pulls"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$FAKEBIN" "$PULLS" "$SANDBOX/root/bin" "$SANDBOX/wt"
REAL_JQ=$(command -v jq)
U=https://github.com/o/r/pull

cat > "$SANDBOX/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/gh.log"
if [ "\${1:-}" = api ]; then
  shift
  path= program=
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      -H) shift 2 ;;
      --jq) program=\$2; shift 2 ;;
      *) path=\$1; shift ;;
    esac
  done
  [ -f "$PULLS/\${path##*/}.json" ] || { echo "HTTP 404" >&2; exit 1; }
  exec "$REAL_JQ" -r "\$program" "$PULLS/\${path##*/}.json"
fi
case " \$* " in
  *" headRefOid "*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *" baseRefName "*) echo "\${DEMO_GH_BASE:-main}" ;;
  *" state "*) echo OPEN ;;
esac
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$SANDBOX/root/bin/fm-guard.sh" "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
: > "$SANDBOX/gh.log"

# pull <number> <base> <head> <merged> [<stack#> <position> <size> <stack-base>]
pull() {
  local number=$1 base=$2 head=$3 merged=$4 stack=null
  if [ "$#" -ge 8 ]; then
    stack=$(printf '{"id":9%s,"number":%s,"position":%s,"size":%s,"base":{"ref":"%s","sha":null}}' "$5" "$5" "$6" "$7" "$8")
  fi
  printf '{"number":%s,"merged":%s,"base":{"ref":"%s"},"head":{"ref":"%s"},"stack":%s}\n' \
    "$number" "$merged" "$base" "$head" "$stack" > "$PULLS/$number.json"
}

show() {  # print a command, run it, print its exit code
  printf '\n$ %s\n' "$*" | sed "s#$ROOT/##g; s#$SANDBOX#<sandbox>#g"
  "$@" 2>&1 | sed "s#$SANDBOX#<sandbox>#g"
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
}
check() { PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-stack-check.sh" "$@"; }
pr_check() {
  FM_ROOT_OVERRIDE="$SANDBOX/root" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-check.sh" "$@"
}
brief() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$@"; }
new_meta() {
  rm -f "$HOME_DIR/state/$1".*
  printf '%s\n' "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$SANDBOX/wt" \
    "project=$SANDBOX/project" "kind=ship" "mode=direct-PR" > "$HOME_DIR/state/$1.meta"
}

echo "################ 1. bin/fm-stack-check.sh ################"
echo "## 1a. Three open PRs GitHub reports as stack #50 on main -> proven"
pull 10 main feat/one false 50 1 3 main
pull 11 feat/one feat/two false 50 2 3 main
pull 12 feat/two feat/three false 50 3 3 main
show check $U/10 $U/11 $U/12

echo; echo "## 1b. The same stack given out of order -> each misplaced PR named"
show check $U/11 $U/10 $U/12

echo; echo "## 1c. One layer left off the command line -> size mismatch named"
show check $U/10 $U/11

echo; echo "## 1d. Bases merely chain, GitHub reports no stack (the 2026-09-17 failure) -> refused"
pull 30 main feat/a false
pull 31 feat/a feat/b false
show check $U/30 $U/31

echo; echo "## 1e. One PR belongs to a different stack -> named"
pull 40 main feat/x false 60 1 2 main
pull 41 feat/x feat/y false 61 2 2 main
show check $U/40 $U/41

echo; echo "## 1f. In one stack, but the upper PR targets the wrong base -> named"
pull 42 main feat/x false 62 1 2 main
pull 43 main feat/y false 62 2 2 main
show check $U/42 $U/43

echo; echo "## 1g. Lower layer merged, GitHub retargeted the upper PR onto the stack base -> still proven"
pull 44 main feat/x true 63 1 2 main
pull 45 main feat/y false 63 2 2 main
show check $U/44 $U/45

echo; echo "## 1h. Usage errors exit 2 before any GitHub call"
: > "$SANDBOX/gh.log"
show check $U/10
show check $U/10 https://gitlab.com/o/r/-/merge_requests/3
show check $U/10 https://github.com/o/other/pull/11
printf 'gh calls made during the usage errors: %s\n' "$(wc -l < "$SANDBOX/gh.log")"

echo; echo "################ 2. bin/fm-brief.sh --stack ################"
show brief demo-stack-k1 some-proj --mode direct-PR --stack
echo; echo "## Definition of done of the scaffolded stacked-chain brief:"
sed -n '/^# Definition of done/,$p' "$HOME_DIR/data/demo-stack-k1/brief.md" | sed "s#$ROOT#<fm-root>#g"
echo; echo "## Its rule 1:"
grep -m1 '^1\. Never push' "$HOME_DIR/data/demo-stack-k1/brief.md"

echo; echo "## --stack is refused outside direct-PR ship briefs"
show brief demo-stack-k2 some-proj --mode no-mistakes --stack
show brief demo-stack-k3 some-proj --mode local-only --stack
show brief demo-stack-k4 some-proj --scout --stack

echo; echo "## Ordinary briefs are byte-identical to the base commit (2804ff7)"
for mode in no-mistakes direct-PR local-only; do
  # Same home path for both runs, so only the script version differs.
  rm -rf "$SANDBOX/home-cmp"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SANDBOX/home-cmp" "$ROOT/bin/fm-brief.sh" plain-p1 some-proj --mode "$mode" >/dev/null 2>&1
  mv "$SANDBOX/home-cmp/data/plain-p1/brief.md" "$SANDBOX/new-$mode.md"
  rm -rf "$SANDBOX/home-cmp"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SANDBOX/home-cmp" "$BASE_ROOT/bin/fm-brief.sh" plain-p1 some-proj --mode "$mode" >/dev/null 2>&1
  if cmp -s "$SANDBOX/new-$mode.md" "$SANDBOX/home-cmp/data/plain-p1/brief.md"; then
    echo "mode=$mode: identical ($(wc -c < "$SANDBOX/new-$mode.md") bytes)"
  else
    echo "mode=$mode: DIFFERS"
  fi
done

echo; echo "################ 3. bin/fm-pr-check.sh hook ################"
echo "## 3a. Stacked task, chained-only PRs -> nothing recorded"
new_meta demo-stack-k1
show pr_check demo-stack-k1 $U/30 $U/31
echo "-- state/demo-stack-k1.meta pr lines after the refusal:"
grep '^pr[=_]' "$HOME_DIR/state/demo-stack-k1.meta" || echo "(none)"
echo "-- poll artifacts after the refusal:"
ls "$HOME_DIR/state" | grep -v '\.meta$' || echo "(none)"

echo; echo "## 3b. Stacked task recorded with a single PR URL before any proof -> refused"
show pr_check demo-stack-k1 $U/12
grep '^pr[=_]' "$HOME_DIR/state/demo-stack-k1.meta" || echo "(no pr recorded)"

echo; echo "## 3c. Proven stack -> proof line printed, recorded and armed on the TOP PR"
DEMO_GH_BASE=feat/two
export DEMO_GH_BASE
show pr_check demo-stack-k1 $U/10 $U/11 $U/12
echo "-- state/demo-stack-k1.meta pr lines:"
grep '^pr[=_]' "$HOME_DIR/state/demo-stack-k1.meta"
echo "-- merge poll sidecar (state/demo-stack-k1.pr-poll):"
cat "$HOME_DIR/state/demo-stack-k1.pr-poll" 2>/dev/null || echo "(missing)"

echo; echo "## 3d. Relaunch-style re-arm with the recorded top PR alone -> accepted"
show pr_check demo-stack-k1 $U/12

echo; echo "## 3e. A lower layer alone -> refused, recorded top PR named"
show pr_check demo-stack-k1 $U/11
echo "-- pr lines unchanged:"
grep '^pr=' "$HOME_DIR/state/demo-stack-k1.meta"

echo; echo "## 3f. An ordinary direct-PR task still records its single PR"
brief demo-plain-k5 some-proj --mode direct-PR >/dev/null 2>&1
new_meta demo-plain-k5
DEMO_GH_BASE=main
show pr_check demo-plain-k5 $U/10
grep '^pr[=_]' "$HOME_DIR/state/demo-plain-k5.meta"
