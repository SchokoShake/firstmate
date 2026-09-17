#!/usr/bin/env bash
# End-to-end demo in a throwaway FM_HOME: the REAL bin/fm-brief.sh --stack brief
# drives the REAL bin/fm-pr-check.sh hook, which runs the REAL
# bin/fm-stack-check.sh. Only `gh` is a fixture: it serves pull-request JSON
# through the checker's own --jq program with the real jq.
set -u
ROOT=$1
D=$(mktemp -d /tmp/fm-stack-demo.XXXXXX); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/home/state" "$D/home/data" "$D/home/config" "$D/wt" "$D/fakebin" "$D/root/bin" "$D/pulls"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/root/bin/fm-guard.sh"; chmod +x "$D/root/bin/fm-guard.sh"
JQ=$(command -v jq)
cat > "$D/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  path= program=
  while [ "$#" -gt 0 ]; do
    case "$1" in -H) shift 2 ;; --jq) program=$2; shift 2 ;; *) path=$1; shift ;; esac
  done
  [ -f "$DEMO_PULLS/${path##*/}.json" ] || exit 1
  exec "$DEMO_JQ" -r "$program" "$DEMO_PULLS/${path##*/}.json"
fi
case " $* " in
  *" headRefOid "*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *" baseRefName "*) echo fm/task-a-2 ;;
  *" state "*) echo OPEN ;;
esac
SH
chmod +x "$D/fakebin/gh"
pull() { # <n> <base> <head> [<stack#> <pos> <size> <stack-base>]
  local stack=null
  [ "$#" -lt 7 ] || stack="{\"number\":$4,\"position\":$5,\"size\":$6,\"base\":{\"ref\":\"$7\"}}"
  printf '{"number":%s,"merged":false,"base":{"ref":"%s"},"head":{"ref":"%s"},"stack":%s}\n' "$1" "$2" "$3" "$stack" > "$D/pulls/$1.json"
}
check() {
  echo "\$ bin/fm-pr-check.sh $*"
  FM_ROOT_OVERRIDE="$D/root" FM_HOME="$D/home" DEMO_PULLS="$D/pulls" DEMO_JQ="$JQ" \
    PATH="$D/fakebin:/usr/bin:/bin" "$ROOT/bin/fm-pr-check.sh" "$@" 2>&1 | sed "s#$D#<tmp>#g"
  echo "[exit ${PIPESTATUS[0]}]"
  echo "  state/task-a.meta pr lines: $(grep '^pr[=_]' "$D/home/state/task-a.meta" | tr '\n' ' ')"
  echo "  merge poll armed: $([ -e "$D/home/state/task-a.check.sh" ] && echo yes || echo no)"
  echo
}
U=https://github.com/o/r/pull

echo "## A. Scaffold the stacked-chain brief"
echo "\$ bin/fm-brief.sh task-a some-proj --mode direct-PR --stack"
FM_HOME="$D/home" "$ROOT/bin/fm-brief.sh" task-a some-proj --mode direct-PR --stack 2>&1 | sed "s#$D#<tmp>#g"
echo; echo "--- brief.md: rule 1 and definition of done ---"
grep -n '^1\. Never push' "$D/home/data/task-a/brief.md" | sed "s#$ROOT#<fm-root>#g"
sed -n '/^# Definition of done/,$p' "$D/home/data/task-a/brief.md" | sed "s#$ROOT#<fm-root>#g"
echo
echo "## B. --stack is refused outside direct-PR ship briefs"
for args in "t-b some-proj --mode no-mistakes --stack" "t-c some-proj --mode local-only --stack" "t-d some-proj --scout --stack"; do
  echo "\$ bin/fm-brief.sh $args"
  # shellcheck disable=SC2086
  FM_HOME="$D/home" "$ROOT/bin/fm-brief.sh" $args 2>&1 | sed "s#$D#<tmp>#g"; echo "[exit ${PIPESTATUS[0]}]"
done
echo
printf 'window=firstmate:fm-task-a\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\n' "$D/wt" "$D/project" > "$D/home/state/task-a.meta"

echo "## C. Worker opened two PRs whose bases chain, but GitHub reports no stack -> nothing recorded"
pull 21 main fm/task-a; pull 22 fm/task-a fm/task-a-2
check task-a $U/21 $U/22
echo "## D. Firstmate tries to record the stacked task as a lone PR -> refused"
check task-a $U/22
echo "## E. After gh stack link, GitHub reports stack #70 -> proven, recorded on the top PR, poll armed"
pull 21 main fm/task-a 70 1 2 main; pull 22 fm/task-a fm/task-a-2 70 2 2 main
check task-a $U/21 $U/22
echo "## F. Relaunch re-arm with the recorded top PR alone -> allowed"
check task-a $U/22
echo "## G. A lower layer alone -> refused, names the recorded PR"
check task-a $U/21
