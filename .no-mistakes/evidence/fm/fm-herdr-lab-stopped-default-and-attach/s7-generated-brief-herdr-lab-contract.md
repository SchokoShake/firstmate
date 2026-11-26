# Herdr isolation - HARD SAFETY CONTRACT
This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.
On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.
A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.

1. Set `HERDR_LAB_HELPER='{run-worktree}/bin/fm-herdr-lab.sh'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name brief-herdr-lab-live)`.
   Install `trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.
2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.
   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.
3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.
   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.
4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.
5. If the task needs a full Herdr UI client on the lab, run `"$HERDR_LAB_HELPER" attach "$HERDR_LAB_SESSION"` inside a pane of a throwaway tmux server (`tmux -L <name>`); it runs only `herdr --session "$HERDR_LAB_SESSION"` and only while the lab is running.
6. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, `herdr --remote`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.
7. The helper records the default session's state, running or stopped, before provisioning and verifies the identical fleet state after teardown.
   A missing or changed default session is a hard tripwire failure, never a cleanup warning to ignore.

Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.
The captain fleet uses the `default` session; never attach to, start, or stop it.

