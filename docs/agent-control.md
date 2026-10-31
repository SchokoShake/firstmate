# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `revive`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's per-adapter tables, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |
| `revive` | Bring back a ship or scout whose agent stopped - the machine or its terminal server restarted, or the agent exited - in its recorded endpoint and worktree, on its recorded harness, model, and effort. | The worker is alive on the recorded endpoint, and a resumed one is proven to run its recorded conversation. An agent already running is reported and left alone. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and pi, pi-signed, kimi, cursor, and muse have no verified pane-resume contract.
`revive` resumes a recorded conversation only where a capture-and-resume path is verified, today claude's, and everywhere else relies on the brief on disk - not a harness-private session - as the durable instruction, as `relaunch` does.
An agent-view pilot worker is the one case where `relaunch` resumes the real conversation, because Claude Code keeps that worker's session by id; [Agent-view pilot workers](#agent-view-pilot-workers) owns how.

## Agent-view pilot workers

An agent-view pilot worker ([tmux backend](tmux-backend.md#agent-view-pilot)) is a Claude Code background session that its window only views.
Every verb therefore acts on the session by its recorded id and reads the session's state from Claude Code's session list rather than from the window.

- `interrupt` first proves the window's viewer is showing the worker's own session, then delivers the same Escape as for any Claude Code worker, and it refuses without sending anything when the window shows something else.
- `exit` stops the session with `claude stop <id>` and does not interrupt first, because stopping a background session ends its turn; it then ends any viewer client left in the window, so the window is back at its shell.
  Its postcondition is the session list reporting the session stopped, and an already-stopped session is idempotent success.
- `relaunch` keeps the conversation rather than replacing it, choosing its plan from the session's state and the window's:
  - a running session whose window no longer shows it is re-attached by running `claude attach <id>` in the window again, which changes no durable record and so skips the transaction below;
  - a running session that its window still shows is stopped and resumed, a restart of the same conversation;
  - a stopped session is resumed by `claude attach <id>`, which restarts it with its own conversation and settings;
  - only a session that no longer exists is replaced by a fresh background session from the instructions on disk.
- Only that last plan takes `--note`, and the others refuse one, because they keep the whole conversation; steer a resumed worker with `bin/fm-send.sh` instead.
- `--harness`, `--model`, and `--effort` are refused, because a pilot record relaunches only as itself, on the profile its session was started with.

Every plan but re-attach runs the transaction below unchanged, including its lease proof and merge-poll re-arm.

## Transactional relaunch

`relaunch` and `revive` are the verbs that change durable records, so each runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress or restart note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a ship or scout on a treehouse-backed backend, the pool's durable lease must prove the record still owns that worktree (`bin/fm-slot-lib.sh` owns that verdict), and a released or unproven record is refused here, before the note is written or the agent is stopped, so its live agent keeps running.
   That refusal names the verdict's evidence and the deliberate path instead: stop the agent with `bin/fm-control.sh <id> exit`, then retire only a re-leased record with `bin/fm-teardown.sh <id> --retire-record` or spawn the task afresh from its branch through `bin/fm-spawn.sh`, which takes a durable lease under the task's own claim.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   An agent-view pilot worker that keeps its conversation is the exception, and its plans own when a note applies.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Re-arm the merge poll.**
   A task that records `pr=` has its merge poll rebuilt through its owner, `bin/fm-pr-check.sh`, while the old agent is still running.
   The watcher refuses to run a poll that is not bound to the PR lines ending the task's record, and the migration every watcher start runs quarantines it, so a relaunch must never publish a record that unbinds it.
   A task without `pr=` skips this step.
5. **Stop the old agent** through the `exit` verb, with its postcondition.
6. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   Nothing it adds to the record lands after the recorded PR's lines, so the re-armed poll stays bound at every moment the watcher could read the record.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical, with one exception: a merge poll that cannot be re-armed.
- That refusal also comes before the agent is stopped: it leaves the agent untouched, restores the instructions byte-exact, and marks the journal `failed:rearming`.
  The poll owner may already have rewritten the record's PR lines or revoked the poll, so the refusal names the `bin/fm-pr-check.sh` command to run before relaunching again.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Revive after a stop

`revive` is the one supported step that brings stopped workers back, and nothing runs it on its own: after a machine restart, the session-start digest lists the workers the restart stopped and prints the exact command, and a person or firstmate decides to run it.
`bin/fm-restart-lib.sh` owns restart detection and that list, and `bin/fm-control.sh`'s header owns the verb's exact forms and output.

- **What it brings back.**
  A ship or scout, by id, several ids in turn, or every task the last recorded restart stopped that is still stopped.
  A task whose busy generation a deliberate stop had already retired before the restart, or whose harness keeps no busy generation so that cannot be told, is listed apart in the digest and comes back only by its own id.
  A secondmate is left to the startup secondmate check, which already brings back a secondmate whose agent stopped.
- **Its own conversation where the harness allows it.**
  A worker's turn-boundary hooks rewrite a small record of its harness session at every turn (`bin/fm-harness-session.sh` owns it), because a machine can stop without running any shutdown step, so whatever was saved last is what survives.
  When that record belongs to the current agent, ran in the task's worktree, and its conversation file still exists, and the adapter's resume is verified, revive resumes that conversation; otherwise it starts a fresh agent from the instructions and says why, and `--fresh` chooses that deliberately.
  A resume counts only once the resumed session's own hook records the same session id under the new busy generation, and a resume that fails is never silently replaced by a fresh start.
- **What it tells the worker.**
  Every revive writes a restart note: the worker was stopped and brought back into the same local copy, anything running there may have been ended, and, for a no-mistakes ship, what no-mistakes says to do first, quoting its own recovery command when the stopped validation run still holds the branch.
  A resumed conversation receives the note as its next message, and a fresh agent reads it appended to its instructions.
  A resumed agent-view pilot session has the note typed in through `bin/fm-send.sh` once it runs, whose guard first proves the window shows that session.
  A note not confirmed delivered there is reported with what is left to do, and a later revive reports the session as running without typing the note again.
- **Where it runs.**
  A gone endpoint is reopened under its recorded identity with its shell in the recorded worktree, on tmux alone (`fm_backend_recreate_task` in `bin/fm-backend.sh`); every other backend refuses a gone endpoint by name.
  The new shell starts beside the worktree and is moved in with a typed `cd`, as a fresh spawn's is, and nothing launches until it reads idle there twice in a row, because a new shell can read idle and still have a program from its startup files to run.
  An endpoint that is still there with no agent in it is reused, and when its idle shell is outside the worktree, as after a reopen whose typed `cd` a startup program swallowed, its line is cleared and the same `cd` is typed and waited for.
- **What it proves first.**
  Relaunch's checkpoint runs unchanged before anything is reopened, written, or launched, so a worktree whose lease is released or unproven is refused with the same deliberate paths.
- **Idempotent and recoverable.**
  An agent already running is reported as running, and the same note is never appended twice in a row, so a second revive starts nothing and a revive that failed part way is simply run again.
  It runs relaunch's journaled transaction with `action=revive` and three phases of its own, `reopening`, `resuming`, and `delivering`, and every failure names what is left to do.
- An agent-view pilot worker gets its window back and then the pilot relaunch plan above, which keeps its background session, and a resumed session gets the restart note typed in as described above.

`relaunch` refuses a gone endpoint before anything is written and names `revive`, because there is no agent to replace and nowhere to launch one.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit`, `relaunch`, and `revive` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- An agent-view pilot record acts only as a claude worker on tmux with a recorded session id.
  A record whose launch is still in flight and a session the list cannot read both refuse.
  A stopped or missing session also refuses while any other running session works in its worktree, so no verb treats that copy as agent-free while an agent may still be working in it.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free and its shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work.
  On a treehouse-backed backend it also relaunches a ship or scout only when the pool's durable lease proves the record still owns its worktree (`bin/fm-slot-lib.sh` owns that verdict), so a replacement can never start inside another task's working copy.
  A re-leased slot names `bin/fm-teardown.sh <id> --retire-record` instead, and an unproven one, including every record that carries no recorded lease claim, names what a person can confirm by hand, because ownership is never inferred, and then the supported paths: ordinary teardown once the work has landed, a fresh spawn from the branch, or `bin/fm-teardown.sh <id> --retire-record --unproven-confirmed`, the flag for a record whose ownership could not be proven.
  `fm-control.sh relaunch` applies the same verdict at its checkpoint, before anything is stopped, so the launch owner's check is a backstop rather than the first line.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for every verified harness, the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and a recorded PR's merge poll staying armed at every record publication, including the refusal when it cannot be re-armed.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-agent-view-pilot.test.sh` - the agent-view pilot verbs on real tmux against a stand-in Claude Code: re-attach, interrupt behind the viewer proof, exit by session id, every relaunch plan, and the refusals.
- `tests/fm-agent-view-pilot-live-e2e.test.sh` - the same lifecycle against the installed Claude Code, opted in with `FM_AGENT_VIEW_PILOT_LIVE=1`.
- `tests/fm-restart-recovery.test.sh` - restart recovery on real tmux against a stand-in Claude Code: the record the hooks keep, the restart digest after a killed server, the printed bring-back command, resume with the restart note, idempotence, the fresh fallbacks, and the refusals.
- `tests/fm-restart-recovery-live-e2e.test.sh` - the same restart and resume against the installed Claude Code, opted in with `FM_RESTART_RECOVERY_LIVE=1`.
