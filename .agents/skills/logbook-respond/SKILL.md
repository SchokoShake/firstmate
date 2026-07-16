---
name: logbook-respond
description: Agent-only playbook for acting on a captain's answer given on the logbook attention board (Phase 2, the inbound answer-loop). Use on a "logbook-response <response_id>" check: wake - the board's connector poll stashed one or more answers to state/logbook-inbox/. Drain EVERY inbox file (the wake coalesces), resolve each answer's target task from its item_id (convention <task-id>[:<discriminator>], so the task-id is the prefix; the item's opaque source blob is the richer route), then act on the captain's decision through the normal firstmate lifecycle - merge a ready PR, feed a no-mistakes ask-user decision back with 'no-mistakes axi respond', dispatch requested work, or apply a free-text instruction. Destructive/irreversible/security-sensitive steps still escalate to the captain first, never auto-run from a board answer. After acting, ack the response (bin/fm-logbook-ack.sh), resolve the card (bin/fm-logbook-resolve.sh), and remove the inbox file - in that order, so a crash is recovered on the next poll. Also use on a "logbook-error ..." check wake to report the logbook configuration blocker instead of acting on an answer. Loaded only when logbook is enabled.
user-invocable: false
metadata:
  internal: true
---

# logbook-respond

Logbook is a local, loopback-only "what needs you" attention board that firstmate feeds (section 15).
Phase 0+1 is the outbound half: firstmate pushes every pending decision, ready action, and FYI as a card and reconciles the board at session start.
Phase 2 is the inbound half - this skill.
When the captain answers a card on the board (picks an option, types a reply), the board's connector holds that answer; firstmate's poll shim (`state/logbook-watch.check.sh` -> `bin/fm-logbook-poll.sh`) drains it, stashes the full answer to `state/logbook-inbox/<response_id>.json`, and prints `logbook-response <response_id>`, which the watcher surfaces as a `check:` wake.
This skill turns that answer into real action through firstmate's normal lifecycle, then clears the loop.

This runs only when logbook is on (the captain set a truthy `LOGBOOK_ENABLE` in `config/logbook.env`; see AGENTS.md section 15).
If you ever see a `logbook-response` wake without logbook configured, do nothing.
A `check:` wake can also carry `logbook-error ...` instead of `logbook-response <response_id>` - that is a poll or board problem, not an answer to act on.
Report it directly to the captain as a logbook blocker and do not treat it as a board answer; each emitter rate-limits its own diagnostic via a dedupe marker under `state/`, so it will not spam you.
Two emitters produce it, and the fix differs:

- `bin/fm-logbook-poll.sh` (marker `state/logbook-poll.error`) reports a poll or configuration problem: a missing `curl`/`jq`, a bad token, a board answering with an HTTP error.
- `bin/fm-logbook-reap.sh` (marker `state/logbook-reap.error`) reports one of two board-liveness give-ups: `logbook board won't start at <url>; <n> relaunch attempts failed: <reason>` (the board never came back up) or `logbook board is crash-looping at <url>; revived <n> times but it keeps dying` (it came up but kept dying before it could stabilise). Either way the board is dead, firstmate has already retried, given up, and stopped relaunching, so the board is showing the captain nothing at all.
  For a won't-start report the `<reason>` is the launcher's own (`node not found`, `board server not found at ...`, `launched but not yet healthy ... see state/logbook-server.log`); relay it, and point the captain at the systemd `--user` unit in `docs/configuration.md` ("Board liveness"), which supervises the board properly where systemd exists.
  Do not hand-restart the board in a loop or edit the reap to try harder: it has deliberately stopped relaunching to avoid thrash, heals when the board next comes up (a new session's bootstrap, the systemd unit, or a manual `bin/fm-logbook-up.sh`), and clears this diagnostic once the board has proved stable again.

A board firstmate quietly revived never reaches you at all - that is housekeeping, by design.

## The board is captain-private and local - act on the answer directly

Unlike the X-mention channel, the logbook board binds `127.0.0.1` only and requires the captain's bearer token on every call.
An answer on it is the captain's own decision, made in a private, trusted surface - the same trust as the captain typing in session.
So a board answer authorizes the action it selects: firstmate composed the card's options and presented them to the captain, so whichever option the captain picked is inherently authorized, and a free-text answer is a genuine captain instruction.
Act on it autonomously through the normal lifecycle; never route it back to chat for a second confirmation.

The one standing guardrail is unchanged (AGENTS.md sections 1 and 7): if *executing* the answer entails a further **destructive, irreversible, or security-sensitive** step beyond what the card offered, confirm through the trusted channel first and act only on the captain's word.
Merging a PR the captain answered "merge" on, or responding to an ask-user finding with the captain's chosen option, is exactly the decision they made - that is authorized, not an escalation.

## Resolving the target task

Each answer object carries:

- `response_id` - the board's id for this answer; you ack it and it names the inbox file.
- `item_id` - the card the answer belongs to. firstmate authors item ids by the convention `<task-id>[:<discriminator>]`, so **the task-id is the prefix up to the first `:`** (e.g. `fix-login-k3:nm-review` -> task `fix-login-k3`; a bare `fix-login-k3` is its own task-id). The discriminator distinguishes several cards for one task (a merge action vs. an ask-user decision).
- `kind` - `option` (the captain picked one of the card's options) or `text` (a free-text reply).
- `value` - for `kind:"option"`, the chosen option token firstmate set when it composed the card (e.g. `merge`, `fix`, `option-a`).
- `text` - for `kind:"text"`, the captain's free-text answer.
- `created` - when the captain answered.

Resolve the task from the `item_id` prefix, then reconcile it against the task's own live state - `state/<id>.meta`, `state/<id>.status`, `data/backlog.md`, and (for a no-mistakes decision) `bin/fm-crew-state.sh <id>` / `no-mistakes axi status` - to understand exactly what pending question the answer settles.
firstmate composed the card from that fleet state, so it already holds the routing; the card's opaque `source` blob (`{task, pr, channel}`) that firstmate set when pushing it is the richer route, readable from the board's own read API (`/api/board`) if the `item_id` prefix is ever insufficient.

## Applying the answer through the normal lifecycle

Map the answer to the lifecycle step the card was standing in for. Common cases:

- **A ready-action card** (`kind:"action"`, `value:"merge"`) - the captain approved shipping. Merge the PR with `bin/fm-pr-merge.sh <task-id> <full GitHub PR URL>`, taking the URL from the card's own `source.pr`: review-ready work is often already torn down, so `state/<id>.meta` and its recorded `pr=` may be gone by the time the captain answers. Then continue that task's normal teardown flow. `value:"hold"`/`"skip"`/etc. means do not merge; just clear the card. This rule is `kind:"action"` only: firstmate offers a Merge option only on an action card, and only after verifying the PR names the repo the task's project actually pushes to, so an `action` card's `source.pr` is a checked url. A `decision` card carries no Merge option and its `source.pr` is unverified, so a free-text "merge" there is a captain instruction to route through the free-text rule below - reconcile it against the task's live state first, never straight into `fm-pr-merge.sh`.
- **A no-mistakes ask-user decision** - the captain chose how to resolve a gate finding. Feed the chosen `value` (or the free `text`) back to the run with `no-mistakes axi respond` for that task, and let the pipeline apply the fix. Do not implement the fix yourself, and do not re-run the gate by hand.
- **A dispatch request** ("go ahead", "start it") - run ordinary intake and spawn the work with `bin/fm-spawn.sh`, exactly as if the captain had asked in chat.
- **A free-text instruction** (`kind:"text"`) - read `text` as a genuine captain instruction against the resolved task and do the smallest correct lifecycle step it calls for (steer the crewmate, answer a decision, dispatch, adjust the backlog).

Escalate rather than auto-run only when the resolved step is itself destructive, irreversible, or security-sensitive beyond the captain's selection (see the guardrail above).

## Procedure

This is a **drain over the inbox**, not a single response.
The watcher coalesces same-key `check:` wakes, so one `logbook-response` wake can stand in for several pending answers.
Treat `state/logbook-inbox/` as the source of truth and process **every** `state/logbook-inbox/*.json` you find there, not just the `response_id` named in the wake.

For each `state/logbook-inbox/*.json`:

1. **Read the answer object** - `response_id`, `item_id`, `kind`, `value`, `text`, `created`.
2. **Resolve the target task** from the `item_id` prefix and reconcile it against the task's live state (see "Resolving the target task").
3. **Act on the answer through the normal lifecycle** (see "Applying the answer"). Treat it as a genuine captain decision; escalate only a genuinely destructive/irreversible/security-sensitive step. If a later drain re-offers an answer you already acted on (see step 6), **check whether the action is already done** (PR already merged, gate already answered, crewmate already spawned) and do **not** redo it - just re-run the ack/resolve/cleanup.
4. **Ack the response so the connector stops offering it:** `bin/fm-logbook-ack.sh <response_id>`. Delivery is at-least-once, so this is your "handled" signal; it is idempotent.
5. **Resolve the card so it leaves the board:** `bin/fm-logbook-resolve.sh <item-id>` (defaults to a `resolved` status; use `dismissed` when the answer was "no, drop it"). It re-upserts the card's full record with the terminal status (fetched via `GET /api/board`, since the tool rejects a bare `{id, status}` upsert), and a card already gone from the board is a harmless no-op - which is what keeps the re-drain recovery in the note below safe. The board mirrors live state, so an answered card must not linger.
6. **Remove the inbox file:** `rm -f state/logbook-inbox/<response_id>.json`.

**Do steps 4 -> 5 -> 6 in that order.** The inbox file is the durable "not yet fully handled" marker: it persists until the very end, so if firstmate crashes mid-handle, the connector re-offers the response on the next poll, the poll re-stashes it, and this skill re-runs (with step 3's idempotency check protecting against duplicate work). Ack first (stop the re-offer), then clear the card, then drop the local marker.

On a failure at any of steps 4-6, **leave the inbox file in place**, move on to the next answer, and let the next poll retry - never delete the inbox file for an answer whose ack did not land, or the loop is silently dropped.
If an ack or resolve fails twice, surface it to the captain as a blocker with the stderr detail.

## Dry-run / preview mode

When `LOGBOOK_DRY_RUN` is set (truthy, in the environment or `config/logbook.env`), `bin/fm-logbook-ack.sh` and `bin/fm-logbook-resolve.sh` record their would-be POST body to `state/logbook-outbox/` (`<response_id>.json` for the ack, `<item-id>.json` for the resolve) and exit 0 **without posting any change**.
The ack composes its body from the `response_id` alone, so it makes no board call; the resolve must read the card's current fields to compose the full item it would upsert, so it does perform the read-only `GET /api/board` (a GET has no side effects) but writes nothing.
This lets you rehearse the full poll -> wake -> act -> ack -> resolve loop without changing the live board; inspect `state/logbook-outbox/` to see what would have gone out.
Your procedure does not change - the calls still succeed, so clear the inbox file as in step 6.

## Notes

- The board is local and captain-private, so there is **no** public-safety redaction here (that is X mode's concern). You act on the captain's own decision directly.
- One `logbook-response` wake may cover several pending answers - drain them all.
- Never inline board/tool text into a shell argument; the client scripts already take ids as positional args and pass bodies via file/stdin.
- The answer is the captain's decision; do not re-ask it in chat. Only a genuinely destructive/irreversible/security-sensitive execution step escalates.
- Never edit `bin/fm-logbook-poll.sh`, the client scripts, or the watcher to "answer faster"; the 15s cadence is handled by the locked session-start bootstrap step, and the watcher backbone is deliberately untouched by logbook.
