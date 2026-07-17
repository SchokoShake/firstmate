# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Worktree capture (why `treehouse get --lease`, not a pane poll)

`fm-spawn.sh` records the crew's isolated worktree in `state/<id>.meta` and installs the turn-end hook into it, so that recorded path must be exact.
It is captured authoritatively: `fm-spawn.sh` runs `treehouse get --lease` from the project directory, whose stdout is only the leased `~/.treehouse/...` path, and then sends the pane a `cd` into that path (`bin/fm-spawn.sh`, backlog `fm-spawn-wt-batch-x5`).

This replaced an earlier design that sent `treehouse get` into the pane and polled `#{pane_current_path}` until it differed from the project directory, taking that first differing path as the worktree.
That poll mis-recorded `worktree=$FM_HOME` (the primary firstmate checkout) on every `projects/*` spawn, forcing a manual repair each time, while firstmate-self spawns were immune.

Root cause, verified 2026-07-15 with tmux 3.6 on this reference host (tmux server started from `$FM_HOME=/home/metoo/firstmate`):
immediately after `tmux new-window -c <project>`, the pane's process is still the forked tmux-server child (the login shell has not yet `exec`'d and `chdir`'d), so `#{pane_current_path}` transiently reports the **tmux server's own cwd**, which is `$FM_HOME`, before settling on the `-c` project directory a fraction of a second later.

Reproduce it directly (a detached window whose `-c` start dir is a fresh temp project):

```
$ tmux new-window -dP -F '#{window_id}' -t "$S:" -c /tmp/proj      # -> @51
$ tmux display-message -p -t @51 'start=#{pane_start_path} cur=#{pane_current_path} cmd=#{pane_current_command}'
start=/tmp/proj cur=/home/metoo/firstmate cmd=tmux                 # cur = the SERVER cwd, cmd still "tmux"
# ~0.5-1s later the shell execs and chdir's:
$ tmux display-message -p -t @51 '#{pane_current_path}'
/tmp/proj
```

The poll's exit condition was "any path != project dir", so on a `projects/*` spawn (`$FM_HOME` != `$FM_HOME/projects/<repo>`) it latched that transient `$FM_HOME` on its very first iteration, before `treehouse get` had even run.
A firstmate-self spawn (`$FM_HOME` == the project dir) never satisfied the condition and kept polling until the real worktree appeared - the exact projects/*-only signature.
The stable-`#{window_id}` targeting from #134 could not fix this: targeting was never wrong, but the correctly targeted pane transiently reports the server cwd.
Leasing from `fm-spawn.sh` itself removes pane timing from capture entirely.

The lease is durable (`treehouse get --lease` reserves the worktree in treehouse's persistent state) and released by `fm-teardown.sh`'s `treehouse return --force <worktree=>`, exactly like every crew worktree before - `treehouse return` handles leased and subshell-held worktrees alike.
`validate_spawn_worktree` also asserts the resolved worktree is not the primary checkout (`$FM_HOME`/`$FM_ROOT`), so any future capture regression aborts the spawn loudly instead of silently recording `worktree=$FM_HOME` again.
Verified by `tests/fm-tangle-guard.test.sh` (leased-worktree capture, meta records the real path, and the `$FM_HOME` backstop abort).

### Respawn: reuse the recorded worktree, never lease a second

Because the lease is durable, a respawn over a live task id must not lease again: the meta write would overwrite the only record of the first worktree, stranding the crew's branch, commits, and uncommitted work behind a lease `prune` can never reclaim.
So a respawn reuses the `worktree=` already in `state/<id>.meta` - a surviving meta means the task was never torn down, since `fm-teardown.sh` releases the worktree and removes the meta together.
Reuse is a treehouse-pool contract, so it covers every backend except orca, which owns its own worktree and never leases from the pool; the identity gate's `backend=` check below is what keeps that exclusion from becoming the hole it would otherwise be.
`bin/fm-spawn.sh`'s header owns the resulting contract; the three non-obvious parts of it are worth the why:

- **Why a respawn refuses on a `project=`/`kind=` mismatch.** Reuse trusts one meta field, so the meta must first be proven to describe the task being spawned, and `project=`/`kind=` are that proof. `fm-spawn.sh <id> projects/bar` over a meta recording `projects/foo` would otherwise launch the crew into foo's worktree carrying bar's brief - invisible to `validate_spawn_worktree`, because foo's worktree is a real git toplevel that is neither `projects/bar` nor `$FM_HOME` - and then record a `project=`/`worktree=` pair `fm-teardown.sh` can never release, since treehouse resolves the pool from the working directory and refuses a worktree from another pool. A `kind=secondmate` meta is worse: its `worktree=` is a HOME path. Falling back to a fresh lease is not the answer either, as that meta write is itself what strands the other task's worktree; a mismatch means firstmate lost track of the task, so it stops.
- **Why `backend=` is part of that same proof, but only across the orca boundary.** Orca's worktree exclusion makes the recorded backend load-bearing exactly when one side of the respawn is orca, and both such crossings lose a worktree. A non-orca meta respawned `--backend orca` passes a project/kind-only gate, then skips reuse entirely and overwrites `worktree=` with orca's own - stranding the leased pool worktree the reuse exists to protect. An orca meta respawned on any other backend is the mirror: the orca worktree is a real git toplevel that clears every `validate_spawn_worktree` clause, so reuse adopts it, `treehouse status` (correctly) reports it unreserved, and the rewritten meta drops `backend=orca` and `orca_worktree_id=` - leaving `fm-teardown.sh` to run `treehouse return` against a path treehouse never owned and orphaning the Orca worktree with its id gone from the record. The gate reads the field through `fm_backend_of_meta`, which owns the absent-means-tmux contract, so a default tmux meta still compares equal to a tmux spawn. A non-orca `<->` non-orca crossing is deliberately NOT refused: both sides borrow the same pool, so reuse adopts the recorded `worktree=` unchanged and only `window=` is rewritten. Nothing is stranded, and that crossing is ordinary recovery - a `config/backend` edit, or a session started under a different auto-detected runtime - which `bin/fm-bootstrap.sh`'s secondmate liveness sweep depends on, since it respawns with no `--backend` at all. Switching a task across the orca boundary mid-flight therefore means tearing the recorded task down first, which is what closing the old backend's window or terminal needs anyway.
- **Why an unreserved worktree warns instead of re-leasing.** The meta does not imply treehouse still reserves the path: a task spawned before this capture landed recorded a worktree held only by the old pane-side `treehouse get` subshell, which reserves nothing once that subshell dies. Reuse asks `treehouse status` and treats `leased` or `in-use` as reserved (`available` means the next `get` may hand it out and hard-reset it). treehouse v2.0.0 has no verb to lease an existing path (`get`/`return`/`prune`/`destroy`/`status` only), so warning is the whole remedy: the crew's work is IN that worktree, a fresh lease abandons it, and the launch makes the path `in-use` within seconds. This case self-closes once pre-fix tasks turn over.

`treehouse status` has no machine-readable mode, so the reservation check parses its table (`<name>  <state>  <path>  [(held by <holder>)]`).
Two properties of that output, verified against treehouse v2.0.0, are load-bearing: `$HOME` is printed abbreviated to `~`, so a raw compare against an absolute `worktree=` silently never matches, and a worktree's process list is an indented continuation line that can never match a reserved state plus the path.

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
