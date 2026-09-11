#!/usr/bin/env bash
# shellcheck disable=SC2034 # the verdict fields are output globals for sourcing callers.
# fm-slot-lib.sh - pool-slot ownership for firstmate task records.
#
# The single owner of how a ship or scout record durably holds its treehouse
# working copy, and of how firstmate tells a record that still owns that copy
# from one whose copy the pool has re-leased to another holder. Sourced by
# bin/fm-spawn.sh (lease label, claimant scan, and the verdict behind the
# --relaunch refusal of a re-leased slot) and bin/fm-teardown.sh (the
# ownership verdict behind its re-leased-slot refusal and --retire-record).
#
# Why a lease. treehouse offers two reservations. The interactive
# `treehouse get` subshell holds an owner reservation that lives exactly as long
# as that process: once the owner dies, treehouse treats the slot as free and
# clears the reservation at its next acquire or status call. A task record
# lives until teardown, so a record spawned under an owner reservation outlived
# it whenever its pane closed, its multiplexer died, or the host restarted, and
# the pool then correctly handed the same slot to the next spawn: two records
# named one working copy, and a routine teardown of the older record would
# reset and kill the newer holder's work. `treehouse get --lease` is the durable
# form: the lease survives with no process inside the slot and only
# `treehouse return` releases it. fm-spawn takes one for every fresh ship or
# scout and records its holder label as lease_holder= in state/<id>.meta, so the
# record and its reservation share one lifetime; relaunch preserves the field
# and teardown's return releases the lease.
#
# Holder label: fm-task:<task-id>:l<epoch>.<pid>.<random>, minted immediately
# before the acquire and compared byte for byte with the pool's record.
#
# Ownership verdict (fm_slot_verdict), evaluated in this order:
#   own       the pool durably leases the recorded path to this record's own
#             holder label, or, conservatively, to its bare task id.
#   released  the pool durably leases the path to any other holder: a record's
#             lease is released only by `treehouse return`, never relabelled,
#             and a record spawned before durable leases never held one.
#             Or, with no durable lease on the path, another record in this
#             home names the same working copy from a later acquisition. The
#             pool hands a slot to at most one live reservation at a time, and
#             a fresh spawn mints its spawn_gen= while its own reservation is
#             still live, so a later fresh generation on the same path proves
#             the pool reissued the slot after this record was last launched
#             into it. A claimant's acquisition epoch is its lease token when
#             it holds a lease (minted before the acquire, so a lower bound),
#             otherwise its spawn generation, used only when it carries no
#             control_relaunch_tx= because a relaunch mints a new generation
#             without acquiring anything. This record's side is its own spawn
#             generation, which never predates its acquisition.
#   unproven  anything else, including a record whose only evidence is its age.
# What the verdict cannot distinguish, each of which reads unproven: a reissue
# whose only later claimant has since been relaunched or carries no generation;
# a reissue to a holder outside this home's records (a hand-run treehouse get,
# another home) that left no durable lease; two acquisitions within the same
# second; and a wall clock stepped backwards between the two spawns.
#
# The pool record is treehouse's own treehouse-state.json in the pool directory
# two levels above the slot, where treehouse's own `return` resolves it, read
# under a shared flock of treehouse's treehouse-state.lock so a concurrent
# treehouse write is never read half-written. Every read failure - no file, a
# lock still contended after a few seconds, malformed JSON - reads as no lease
# evidence, never as a verdict.

_fm_slot_meta() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

# The physical form of <path> when it is an existing directory, the path itself
# otherwise, so a record naming a since-removed slot still compares by string.
fm_slot_canonical() {  # <path>
  local path=$1 real
  if [ -d "$path" ] && real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

fm_slot_lease_holder_new() {  # <task-id>
  printf 'fm-task:%s:l%s.%s.%s\n' "$1" "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

# The epoch in a generation token of the form <letter><epoch>.<pid>.<random>
# (s for a spawn generation, l for a lease token); fails on any other shape.
fm_slot_token_epoch() {  # <token>
  local epoch
  case "$1" in [sl][0-9]*.*) ;; *) return 1 ;; esac
  epoch=${1#?}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
}

# Every record in <state> other than <exclude-id> whose worktree= names the same
# working copy as <path>, one task id per line.
fm_slot_claimants() {  # <state> <path> [exclude-id]
  local state=$1 path=$2 exclude=${3:-} want meta id wt
  [ -n "$path" ] || return 0
  want=$(fm_slot_canonical "$path")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    wt=$(_fm_slot_meta "$meta" worktree)
    [ -n "$wt" ] || continue
    if [ "$wt" = "$path" ] || [ "$(fm_slot_canonical "$wt")" = "$want" ]; then
      printf '%s\n' "$id"
    fi
  done
}

# The pool's record for <path>, as one line:
#   leased<TAB><holder>  a durable lease (the holder may be empty)
#   held                 a process-bound owner reservation, live or stale
#   free                 a pool slot with no reservation
#   absent               the pool has no slot at that path
#   unknown              the pool record could not be read
fm_slot_pool_record() {  # <path>
  local path=$1 pool
  pool=$(dirname -- "$(dirname -- "$path")")
  if [ ! -f "$pool/treehouse-state.json" ] || [ -L "$pool/treehouse-state.json" ]; then
    printf 'unknown\n'
    return 0
  fi
  # shellcheck disable=SC2016 # the program is Perl, not shell
  perl -MJSON::PP -MFcntl=:flock -e '
    my ($pool, $path, $canon) = @ARGV;
    my $lockpath = "$pool/treehouse-state.lock";
    my $lock;
    if (-e $lockpath) {
      open($lock, "<", $lockpath) or exit 1;
      my $held = 0;
      for (1 .. 100) {
        if (flock($lock, LOCK_SH | LOCK_NB)) { $held = 1; last; }
        select(undef, undef, undef, 0.05);
      }
      exit 1 unless $held;
    }
    open(my $fh, "<", "$pool/treehouse-state.json") or exit 1;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->decode($raw) };
    exit 1 unless ref $doc eq "HASH" && ref $doc->{worktrees} eq "ARRAY";
    for my $wt (@{ $doc->{worktrees} }) {
      next unless ref $wt eq "HASH" && defined $wt->{path} && !ref $wt->{path};
      next unless $wt->{path} eq $path || $wt->{path} eq $canon;
      if ($wt->{leased}) {
        my $holder = $wt->{lease_holder};
        $holder = "" unless defined $holder && !ref $holder;
        $holder =~ s/[\t\r\n]/ /g;
        print "leased\t$holder\n";
      } elsif ($wt->{owner_pid}) {
        print "held\n";
      } else {
        print "free\n";
      }
      exit 0;
    }
    print "absent\n";
  ' "$pool" "$path" "$(fm_slot_canonical "$path")" 2>/dev/null || printf 'unknown\n'
}

# The epoch at or after which the record in <meta> acquired its working copy,
# for use only as the LATER side of a comparison; fails when that cannot be
# bounded (the verdict header owns why each source is sound).
fm_slot_acquired_epoch() {  # <meta>
  local meta=$1 holder
  holder=$(_fm_slot_meta "$meta" lease_holder)
  if [ -n "$holder" ]; then
    fm_slot_token_epoch "${holder##*:}"
    return
  fi
  [ -z "$(_fm_slot_meta "$meta" control_relaunch_tx)" ] || return 1
  fm_slot_token_epoch "$(_fm_slot_meta "$meta" spawn_gen)"
}

# The task in <state> other than <exclude-id> that a pool lease holder label
# names: a record with that lease_holder=, or a secondmate home leased under
# its bare id.
_fm_slot_label_owner() {  # <state> <label> <exclude-id>
  local state=$1 label=$2 exclude=$3 meta id
  [ -n "$label" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    if [ "$id" = "$label" ] || [ "$(_fm_slot_meta "$meta" lease_holder)" = "$label" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
}

# Sets FM_SLOT_VERDICT (own|released|unproven), FM_SLOT_EVIDENCE (one clause
# naming the evidence), and FM_SLOT_WORKTREE for the record <state>/<id>.meta.
# The header owns the rules. Returns 1 only when the record is missing.
fm_slot_verdict() {  # <state> <id>
  local state=$1 id=$2 meta wt holder gen epoch record pool_holder owner claimant cmeta cepoch
  FM_SLOT_VERDICT=unproven
  FM_SLOT_EVIDENCE=
  FM_SLOT_WORKTREE=
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  wt=$(_fm_slot_meta "$meta" worktree)
  if [ -z "$wt" ]; then
    FM_SLOT_EVIDENCE="the record names no working copy"
    return 0
  fi
  FM_SLOT_WORKTREE=$wt
  holder=$(_fm_slot_meta "$meta" lease_holder)
  gen=$(_fm_slot_meta "$meta" spawn_gen)
  record=$(fm_slot_pool_record "$wt")
  case "$record" in
    leased$'\t'*)
      pool_holder=${record#leased$'\t'}
      if { [ -n "$holder" ] && [ "$pool_holder" = "$holder" ]; } || [ "$pool_holder" = "$id" ]; then
        FM_SLOT_VERDICT=own
        FM_SLOT_EVIDENCE="the pool leases $wt to this record's own holder ${pool_holder}"
        return 0
      fi
      owner=$(_fm_slot_label_owner "$state" "$pool_holder" "$id")
      FM_SLOT_VERDICT=released
      FM_SLOT_EVIDENCE="the pool leases $wt to ${pool_holder:-an unlabelled holder}${owner:+ (task $owner)}, not to this record"
      return 0
      ;;
  esac
  epoch=$(fm_slot_token_epoch "$gen" 2>/dev/null) || epoch=
  if [ -n "$epoch" ]; then
    while IFS= read -r claimant; do
      [ -n "$claimant" ] || continue
      cmeta="$state/$claimant.meta"
      cepoch=$(fm_slot_acquired_epoch "$cmeta" 2>/dev/null) || continue
      [ "$cepoch" -gt "$epoch" ] || continue
      FM_SLOT_VERDICT=released
      FM_SLOT_EVIDENCE="task $claimant names the same working copy $wt from a later acquisition (epoch $cepoch, after this record's last launch $gen)"
      return 0
    done <<EOF
$(fm_slot_claimants "$state" "$wt" "$id")
EOF
  fi
  if [ -n "$holder" ]; then
    FM_SLOT_EVIDENCE="its lease $holder is no longer on $wt (the pool reports ${record%%$'\t'*}) and no later claimant in this home proves a re-lease"
  elif [ -z "$epoch" ]; then
    FM_SLOT_EVIDENCE="the record has no spawn generation to order against, and the pool holds no durable lease on $wt (it reports ${record%%$'\t'*})"
  else
    FM_SLOT_EVIDENCE="the pool holds no durable lease on $wt (it reports ${record%%$'\t'*}) and no later claimant in this home proves a re-lease"
  fi
  return 0
}
