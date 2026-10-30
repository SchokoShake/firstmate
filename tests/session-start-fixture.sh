#!/usr/bin/env bash
# tests/session-start-fixture.sh - a sanitized operational home shaped like a
# busy real one, for measuring and replaying the session-start digest.
#
# Sourced by tests/fm-session-start.test.sh (the portable digest-size bound) and
# tests/fm-session-start-replay-live-e2e.test.sh (the opt-in model replay).
#
# Every byte is synthetic and deterministic: project names, ids, titles,
# reasons, status lines, and memory entries come from a fixed word list and a
# seeded generator, never from a live home, so the fixture carries no private
# captain data, credentials, project names, or backlog text. Only the SHAPE is
# taken from a real busy home: how many rows sit in each backlog group, how long
# titles, hold reasons, bodies, meta files, and status lines run, how many tasks
# are under way, and how large the registry and memory files are.
#
# fm_ssfix_build <fm-root> <home>
#   Writes data/, state/, and config/ under <home> and seeds two durable wakes
#   through <fm-root>/bin/fm-wake-lib.sh. Every task meta records a tmux window,
#   so a caller that points TMUX_TMPDIR at an empty directory and unsets TMUX
#   sees every endpoint dead without touching a real tmux server.
#   FM_SSFIX_MEMORY=today (the default) sizes data/captain.md and
#   data/learnings.md like the busy home's uncurated files; FM_SSFIX_MEMORY=budget
#   sizes them to fit config/startup-memory-budget's default allowance, the
#   state a /stow curation pass is required to reach.
#   FM_SSFIX_POOL (default /fixture/pool) is the directory every meta's
#   worktree path sits under; the fixture never creates it.
#   FM_SSFIX_WAKES=0 skips the two seeded wakes, for a caller that queues its own.
#
# Shape, per group: 20 in-flight rows (3 held for a captain decision, 5
# parked), 15 live captain decisions, 20 lapsed captain holds, 69 parked and 1
# external queued rows, 4 time gates, 8 blocked rows, 21 ready rows, 10 done
# rows; 32 task metas with every field a real spawn, relaunch, and PR record
# writes; 20 registered projects.

fm_ssfix_build() {
  local root=$1 home=$2 memory=${FM_SSFIX_MEMORY:-today} pool=${FM_SSFIX_POOL:-/fixture/pool}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" || return 1
  printf '7500\n' > "$home/config/startup-memory-budget"
  LC_ALL=C awk -v home="$home" -v memory="$memory" -v pool="$pool" '
    function rnd(n) { seed = (seed * 16807) % 2147483647; return seed % n }
    function word() {
      if (rnd(9) == 0) return tokens[rnd(ntokens) + 1]
      return words[rnd(nwords) + 1]
    }
    # About <len> bytes of sentence-shaped text: a capitalized first word,
    # commas now and then, and a period every eight to twenty words.
    function text(len,    s, w, run, gap) {
      s = ""; run = 0; gap = 8 + rnd(13)
      while (length(s) < len) {
        w = word()
        if (run == 0) w = toupper(substr(w, 1, 1)) substr(w, 2)
        s = s (s == "" ? "" : " ") w
        run++
        if (run >= gap) { s = s "."; run = 0; gap = 8 + rnd(13) }
        else if (rnd(7) == 0) s = s ","
      }
      if (run > 0) s = s "."
      return s
    }
    function between(lo, hi) { return lo + rnd(hi - lo + 1) }
    function repo_for(i) { return repos[(i * 7 + rnd(3)) % nrepos + 1] }
    function body(n,    i) {
      for (i = 1; i <= n; i++) printf "  %s\n", text(between(140, 260)) > backlog
    }
    function row(box, id, title, repo, kind, since, extra) {
      printf "- [%s] %s - %s (repo: %s) (kind: %s) (since %s)%s\n", box, id, title, repo, kind, since, extra > backlog
    }
    function hold(reason, kind, until,    s) {
      s = " (hold: " reason ")"
      if (kind != "") s = s " (hold-kind: " kind ")"
      if (until != "") s = s " (hold-until: " until ")"
      return s
    }
    function ask() {
      return asks[rnd(nasks) + 1] " " words[rnd(nwords) + 1] " " words[rnd(nwords) + 1] "?"
    }
    function memory_file(path, bytes, marker,    total, entry, n) {
      printf "# %s\n<!-- memory tiers: see the stow skill -->\n\n", (marker == "" ? "Captain" : "Learnings") > path
      total = 0; n = 0
      while (total < bytes) {
        n++
        entry = "- " text(between(220, 460))
        if (marker != "") entry = entry " <!--" marker ":2026-09-" sprintf("%02d", between(1, 28)) "-->"
        print entry > path
        total += length(entry) + 1
      }
      close(path)
    }
    BEGIN {
      seed = 20261030
      nwords = split("board worker review branch fixture preview rollout migration staging cache window " \
        "pipeline queue schema render toggle export import sync refresh retry timeout gate digest " \
        "summary decision option report section step release version config layout route token " \
        "field row column filter label badge panel view map tile marker tour stop photo audio text " \
        "layer the a of to and with for on in from after before when while still now only " \
        "captain worker check build deploy local remote clone harbor ledger signal anchor " \
        "keeps runs waits stops opens closes lands ships moves reads writes holds clears " \
        "first second third last next every single shared private public default", words, " ")
      ntokens = split("PR v1.62.0 0a94b21f https://example.invalid/fleet/pull/412 " \
        "/fixture/pool/slot-7/repo staging.example.invalid ci-2 #4471 S3 step-9 2026-10-28 " \
        "--file key=alpha-gate tasks-axi no-mistakes 13:13 UTC", tokens, " ")
      nrepos = split("harbor lantern compass rigging keel mast beacon tiller ledger quarry " \
        "orchard meadow foundry kiln loom spindle anvil prism vellum quill", repos, " ")
      nasks = split("Which way for the|Keep or drop the|Ship now or wait on the|One or two|" \
        "Merge or split the|Where should the", asks, "|")
      backlog = home "/data/backlog.md"
      printf "# Backlog\n\n## In flight\n" > backlog
      for (i = 1; i <= 20; i++) {
        id = sprintf("%s-flight-f%d", repos[(i - 1) % nrepos + 1], i)
        flight[i] = id
        extra = ""
        if (i <= 3) extra = hold(text(between(300, 560)), "captain", "2099-12-31")
        else if (i <= 8) extra = hold(text(between(150, 380)), "parked", "")
        row(" ", id, text(between(120, 240)), repos[(i - 1) % nrepos + 1], (i % 4 == 0) ? "scout" : "ship", "2026-10-2" (i % 10), extra)
        body(between(2, 5))
      }
      printf "\n## Queued\n" > backlog
      for (i = 1; i <= 15; i++) {
        row(" ", sprintf("%s-decision-d%d", repo_for(i), i), ask(), repo_for(i), "captain", "2026-10-27",
          hold(text(between(250, 560)), "captain", "2099-12-31"))
        body(between(1, 3))
      }
      for (i = 1; i <= 20; i++) {
        row(" ", sprintf("%s-lapsed-l%d", repo_for(i + 3), i), ask(), repo_for(i + 3), "captain", "2026-09-30",
          hold(text(between(250, 560)), "captain", sprintf("2020-01-%02d", i)))
        body(between(1, 3))
      }
      for (i = 1; i <= 69; i++) {
        # Weighted like a home whose own repo carries most of the parked wishlist.
        r = (i <= 40) ? repos[1] : repo_for(i)
        row(" ", sprintf("%s-parked-p%d", r, i), text(between(100, 240)), r, (i % 5 == 0) ? "scout" : "ship",
          "2026-10-0" (i % 10), hold(text(between(150, 420)), "parked", ""))
        body(between(2, 4))
      }
      row(" ", "keel-external-x1", text(160), "keel", "ship", "2026-10-11", hold(text(200), "external", ""))
      for (i = 1; i <= 4; i++) {
        row(" ", sprintf("%s-gate-g%d", repo_for(i), i), text(between(100, 200)), repo_for(i), "ship", "2026-10-15",
          hold(text(between(80, 160)), "", "2099-06-01"))
        body(1)
      }
      for (i = 1; i <= 8; i++) {
        printf "- [ ] %s - %s blocked-by: %s (repo: %s) (kind: ship) (since 2026-10-26)\n",
          sprintf("%s-blocked-b%d", repo_for(i), i), text(between(120, 240)), flight[i + 8], repo_for(i) > backlog
        body(between(1, 3))
      }
      for (i = 1; i <= 21; i++) {
        row(" ", sprintf("%s-ready-r%d", repo_for(i + 5), i), text(between(100, 300)), repo_for(i + 5),
          (i % 3 == 0) ? "scout" : "ship", "2026-10-1" (i % 10), "")
        body(between(1, 3))
      }
      printf "\n## Done\n" > backlog
      for (i = 1; i <= 10; i++) {
        row("x", sprintf("%s-done-z%d", repo_for(i), i), text(between(100, 200)), repo_for(i), "ship", "2026-10-20", "")
      }
      close(backlog)

      projects = home "/data/projects.md"
      printf "# Fleet project registry (firstmate-private)\n\n" > projects
      split("direct-PR +yolo|no-mistakes +yolo|no-mistakes-prod-only|direct-PR +captain-merge|no-mistakes +captain-merge", postures, "|")
      for (i = 1; i <= nrepos; i++) {
        printf "- %s [%s] - %s (added 2026-0%d-1%d)\n", repos[i], postures[(i - 1) % 5 + 1], text(between(420, 700)), (i % 9) + 1, i % 10 > projects
        if (i % 6 == 1) printf "  sub %s-%s | %s | feat/%s\n", repos[i], words[i], words[i + 3], words[i] > projects
      }
      close(projects)

      if (memory == "budget") { captain_bytes = 8000; learnings_bytes = 13500 }
      else { captain_bytes = 19800; learnings_bytes = 28000 }
      memory_file(home "/data/captain.md", captain_bytes, "")
      memory_file(home "/data/learnings.md", learnings_bytes, "a")

      states[1] = "working: "; states[2] = "needs-decision: [key=%s-gate] "; states[3] = "resolved [key=%s-gate]: answered: "
      states[4] = "done: PR https://example.invalid/fleet/pull/%d checks green "; states[5] = "paused: "
      for (t = 1; t <= 32; t++) {
        id = (t <= 20) ? flight[t] : sprintf("%s-done-z%d", repo_for(t - 20), t - 20)
        r = (t <= 20) ? repos[(t - 1) % nrepos + 1] : repo_for(t - 20)
        meta = home "/state/" id ".meta"
        printf "window=firstmate:fm-%s\nendpoint_task_id=%s\n", id, id > meta
        printf "worktree=%s/%s-b38575/%d/%s\nproject=%s/projects/%s\nharness=claude\n", pool, r, t, r, home, r > meta
        printf "kind=%s\nmode=%s\nyolo=%s\ntasktmp=/tmp/fm-%s\nmodel=claude-opus-5-5\neffort=%s\n",
          (t % 4 == 0) ? "scout" : "ship", (t % 3 == 0) ? "direct-PR" : "no-mistakes", (t % 2) ? "off" : "on", id,
          (t % 5 == 0) ? "max" : "high" > meta
        printf "busy_gen=g1792396010.83%04d.27087\nspawn_gen=s1792396010.83%04d.21844\n", t, t > meta
        printf "control_relaunch_tx=830313.20261019T0746%02dZ.5833\nlease_holder=fm-task:%s:l1791983169.1908906.211%02d\n", t, id, t > meta
        if (t % 9 != 0) printf "pr=https://example.invalid/fleet/%s/pull/%d\npr_head=%08x%08x%08x%08x%08x\npr_base=main\n",
          r, 400 + t, t * 7919, t * 104729, t * 1299709, t * 15485863, t * 32452843 > meta
        if (t % 3 == 0) printf "decision_keys=%s-gate\ndecisions_reviewed=%s-gate\nbase=main\n", id, id > meta
        close(meta)
        status = home "/state/" id ".status"
        # Routine lines are working, done, and paused events. Tasks 1-3 end on an
        # open decision and tasks 4-6 opened one that was later resolved, so the
        # OPEN DECISIONS fold sees a realistic handful rather than every task.
        n = between(8, 14)
        for (k = 1; k <= n; k++) {
          pick = (k % 2) ? 1 : ((k % 3) ? 4 : 5)
          if (k == n && t <= 3) pick = 2
          if (t >= 4 && t <= 6 && k == n - 1) pick = 2
          if (t >= 4 && t <= 6 && k == n) pick = 3
          s = states[pick]
          if (s ~ /%s/) s = sprintf(s, id); else if (s ~ /%d/) s = sprintf(s, 400 + t)
          print s text(between(60, 420)) > status
        }
        close(status)
      }
    }
  ' || return 1
  if [ "${FM_SSFIX_WAKES:-1}" = 0 ]; then
    return 0
  fi
  append_ssfix_wake() {
    FM_STATE_OVERRIDE="$home/state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      fm_wake_append "$2" "$3" "$4"
    ' _ "$root/bin/fm-wake-lib.sh" "$1" "$2" "$3"
  }
  append_ssfix_wake signal harbor-flight-f1 "needs-decision: [key=harbor-flight-f1-gate] the worker asks which way the rollout goes" || return 1
  append_ssfix_wake heartbeat fleet "heartbeat: hourly fleet review" || return 1
  unset -f append_ssfix_wake
}
