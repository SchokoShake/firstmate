# Cross-session messaging: verified transport facts

Maintainer-verification record for the board-answer nudge (`bin/fm-inbox-post.sh`).
That script's header is the single owner of the frame, the published record, and the flags; this file records the empirical facts that guarantee is currently resting on, and the risk it is accepted under.

Verified 2026-08-27 on macOS 24.6.0 (arm64), Claude Code 2.1.247, single OS user.
The frame was first recovered from 2.1.228 on Linux/WSL and re-derived here on 2.1.246 on 2026-08-26; the 2.1.247 refresh ran the live guard green on all four of its claims with `peerProtocol` unchanged at `1`, which is why the peer-protocol guard in `bin/fm-inbox-post.sh` correctly does not stand the push down on this build.

Refresh this file after every Claude Code upgrade by running the live guard, which is the command that reproduces every claim below:

```
FM_INBOX_POST_LIVE_E2E=1 tests/fm-inbox-post-live-e2e.test.sh
```

Its most recent run, against 2.1.247 on 2026-08-27:

```
ok - a live 2.1.247 (Claude Code) session advertises an inbox on peer protocol 1
ok - the real publisher accepts a live session and records its inbox
ok - 2.1.247 (Claude Code) accepts and routes the nudge frame
ok - 2.1.247 (Claude Code) delivers the nudge into the session under its own name
```

## The frame is self-documenting in the running build

The vendor documents the socket, its environment variable, and that a script may post into a session, but specifies no payload and ships no CLI that emits one.
The running binary does document it, in its own debug log.
Any session started with `--debug` prints the injection recipe at startup:

```
[uds-messaging] Listening: /tmp/cc-socks/52197.sock
[uds-messaging] Inject messages (auth line optional here): { echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}'; echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } | socat - UNIX-CONNECT:/tmp/cc-socks/52197.sock
[uds-messaging] Connect when the data is ready (e.g. out=$(cmd); printf '%s\n' "$out" | nc -U "$CLAUDE_CODE_MESSAGING_SOCKET" - or the socat form above): a connection that sends no complete line within 30000 ms is closed
```

That printed recipe is the reproduction path for a future version, and it is preferred over reading the binary because it is emitted by the build actually installed.
It confirms the transport (one-shot AF_UNIX stream, newline-delimited JSON, optional auth line then one payload line), that the auth line is optional for an unauthenticated peer, that both `socat` and `nc -U` are supported senders, and that a connection sending no complete line within 30s is closed.

The recipe's own example frame carries neither `msgV` nor `msg_id`, and a frame of exactly that minimal shape was posted and delivered during this verification.
`msg_id` is therefore optional, which is what lets `bin/fm-inbox-post.sh` omit it on a home with no uuid source rather than losing the push entirely.

A frame the receiver cannot parse is dropped with a debug-log warning and no diagnostic anywhere the sender can see:

```
[uds-messaging] Client connected
[uds-messaging] Failed to parse JSON line: {"msgV":1,...,"content":"<cross-session-message from-name=\"firstmate-board\">\nBoard answers are pending on the "log
[uds-messaging] Client disconnected
```

That observation is why `bin/fm-inbox-post.sh` keeps its body free of quotes and backslashes rather than escaping them, and why the live guard reads the receiver's routing verdict instead of trusting the sender's exit status.

## The envelope's attribute order is load-bearing

The receiver matches an ordered pattern, so an out-of-order or unexpected attribute makes the whole envelope render as literal text rather than a peer message.
The order is `from`, `from-session`, `hop-chain`, `from-name`, `from-mode`, each optional.
`bin/fm-inbox-post.sh` sends `from-name` only, and `tests/fm-inbox-post.test.sh` pins the produced envelope against that same ordered pattern.

## Versioning signals

A live session advertises `peerProtocol` in its registry entry under `~/.claude/sessions/<pid>.json`, and the frame carries `msgV`.
Both read `1` on 2.1.247 and on 2.1.246, unchanged from the earlier 2.1.228 observation this work started from.
2.1.246 additionally advertises `peerFeatures: ["notify_idle","artifact_yield"]`, which the nudge does not use, and 2.1.247 advertises the same list.

`bin/fm-inbox-post.sh` refuses to publish or post when a session advertises a `peerProtocol` it was not verified against, because a bumped protocol is the only advance signal available that the frame may have changed shape.
Widen its supported list only together with a refreshed run of the live guard.

## The inbound permission matrix

Delivery is decided by the receiver's own permission class and the sender's self-asserted `from-mode`, unless an effective `crossSessionInbound` setting overrides both.
Verified by posting an unauthenticated, unattested frame into throwaway sessions, which is exactly the board's position:

| Receiver permission class | Effective `crossSessionInbound` | Result |
| --- | --- | --- |
| prompting | unset | delivered |
| bypasses prompts | unset | held for approval (`no-mode-asserted`) |
| bypasses prompts | `accept` at the user tier | delivered |
| bypasses prompts | `accept` in the home's own `.claude/settings.json` | **held** - a repo setting may only tighten |

The last row is the one that changed since the 2.1.228 scouting run, and it is the reason firstmate writes no such setting anywhere.
The matrix was derived on 2.1.246; the 2.1.247 refresh re-proved its first row through the live guard, which posts into a prompting throwaway session with the setting unset, and did not re-derive the other rows.
2.1.246 resolves `crossSessionInbound` from `policySettings`, `flagSettings`, and `userSettings` first, then lets `localSettings` and `projectSettings` apply only when they are MORE restrictive.
An `accept` placed in a home's project settings is therefore inert, and writing one would read as protection while providing none.
The receiver states this itself when a message is held:

```
This repository's settings set "crossSessionInbound" to "hold" (a repo may only tighten, so your own "accept" cannot override it)
```

The accepted values are `accept`, `hold`, and `refuse`.
`bin/fm-inbox-post.sh --status` reports the user-tier setting and names the file that can actually decide it.

An attested `from-mode` that does not match the receiver's class is held as a mismatch on this version, so attesting is not a workaround; it is a second way to be held, on top of being a false claim by a process that has no permission class.

## Why a held or dropped nudge is acceptable

Held is not lost.
The nudge carries no answer, so every failure mode above costs the board poll's ordinary latency and nothing else: the answer still arrives through `state/logbook-inbox/`, the poll shim, and the existing ack/resolve/delete ordering, which this feature does not touch.
That is the entire argument for accepting an undocumented transport, and it holds only while the nudge stays notification-only.

## Stability risk

Firstmate's other channels rest on surfaces stable for decades: tmux panes and the filesystem.
This one rests on a JSON frame with no compatibility promise, and it breaks silently.
Three things bound that risk, and all three must be kept:

- The push carries no content, so a break degrades to poll latency rather than a lost or duplicated answer.
- The peer-protocol guard refuses an unverified protocol instead of guessing.
- `tests/fm-inbox-post.test.sh` pins the produced frame portably in CI, and the live guard above proves an installed harness still accepts it.

The live guard is the one that catches a vendor change, and CI cannot run it: it needs a real harness binary and credentials.
Run it after every Claude Code upgrade.

One surface the live guard does not cover is the hook-time environment: `bin/fm-session-start.sh` calls `--publish` from the SessionStart hook, and a publish that silently does not happen leaves no record and no diagnostic.
Verified read-only on 2.1.247 on 2026-08-27 that a child process spawned by a live session carries `CLAUDE_CODE_MESSAGING_SOCKET`, that the path is a bound AF_UNIX socket, and that it equals the `messagingSocketPath` in that session's registry entry.
Whether the listener is bound before SessionStart hooks fire remains unverified, and the live guard injects the socket path from the registry rather than letting a hook publish it, so this is an accepted gap.
Its cost is bounded the same way as every failure above: a session that did not publish is never nudged, the board poll drains its answers at its ordinary latency, and no answer is lost or duplicated.
`bin/fm-inbox-post.sh --status` run inside a live session reports `inbox: live` when the hook did publish, which is the quick check after an upgrade.
