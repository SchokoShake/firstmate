#!/usr/bin/env bash
# Live bootstrap drive: run the real bin/fm-bootstrap.sh of the BASE commit and of
# THIS branch against one isolated firstmate home and one fake toolchain whose
# only gap is lavish-axi. PATH holds only the fake toolchain plus system dirs, and
# a recording fake npm, so no real install can run.
#
# Usage: drive-bootstrap-no-lavish.sh <base-root> <target-root>
set -u
BASE=$1 TARGET=$2
TB="$TARGET/tests/fm-bootstrap.test.sh"
# shellcheck source=/dev/null
. "$TARGET/tests/lib.sh"
eval "$(sed -n '/^make_fake_toolchain() {/,/^}/p; /^add_quota_axi() {/,/^}/p; /^add_tasks_axi() {/,/^}/p' "$TB")"
SYS=/usr/bin:/bin:/usr/sbin:/sbin
C=$(fm_test_tmproot fm-boot-drive)
mkdir -p "$C/home/config"
printf 'manual\n' > "$C/home/config/backlog-backend"
FB=$(make_fake_toolchain "$C")
printf '#!/usr/bin/env bash\nprintf "npm %%s\\n" "$*" >> "%s/npm.calls"\n' "$C" > "$FB/npm"
chmod +x "$FB/npm"
boot() {  # <root> [args...]
  local root=$1; shift
  HOME="$C/home" PATH="$FB:$SYS" FM_HOME="$C/home" FM_ROOT_OVERRIDE="$C/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$root/bin/fm-bootstrap.sh" "$@" 2>&1
  printf '[exit %s]\n' "$?"
}
echo "fake toolchain: $(ls "$FB" | tr '\n' ' ')"
echo "lavish-axi on PATH: $(PATH="$FB:$SYS" command -v lavish-axi || echo none)"

echo; echo "### BASE commit detect (lavish-axi absent)"
boot "$BASE"
echo; echo "### THIS branch detect (lavish-axi absent) - expect silence"
boot "$TARGET"

echo; echo "### THIS branch detect with an old lavish-axi 0.0.9 on PATH - expect no version complaint"
fm_fake_version_tool "$FB" lavish-axi FM_FAKE_LAVISH 0.0.9
echo "lavish-axi --version: $(PATH="$FB:$SYS" lavish-axi --version)"
boot "$TARGET"
echo "(same home on BASE for contrast)"
boot "$BASE"
rm -f "$FB/lavish-axi"

echo; echo "### THIS branch: explicit install request for lavish-axi"
boot "$TARGET" install lavish-axi
echo "### BASE commit: same request (fake npm only records)"
boot "$BASE" install lavish-axi
echo "fake npm calls recorded:"; sed 's/^/  /' "$C/npm.calls" 2>/dev/null || echo "  none"
