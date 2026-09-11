#!/usr/bin/env bash
# shellcheck disable=SC2034 # the verdict fields are output globals for sourcing callers.
# fm-slot-lib.sh - pool-slot ownership for firstmate task records.
#
# The single owner of how a ship or scout record durably holds its treehouse
# working copy, and of how firstmate tells a record that still owns that copy
# from one whose copy the pool has re-leased to another holder. Sourced by
# bin/fm-control.sh (the verdict its relaunch checkpoint requires to read own,
# refused before anything is stopped), bin/fm-spawn.sh (lease label, claimant
# scan, and the same verdict as --relaunch's backstop), and bin/fm-teardown.sh
# (the verdict behind its re-leased-slot refusal and --retire-record).
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
# Ownership verdict (fm_slot_verdict). Ownership is read from exactly two
# records - this record's own lease_holder= claim and the pool's durable lease
# on the recorded path - and never inferred from spawn generations, spawn
# order, relaunch markers, lease tokens, or what other records happen to name.
#   own       the pool leases the recorded path to this record's own claim.
#   released  the pool leases the path to a different label that another record
#             in this home carries as its own claim on that same path: its
#             lease_holder= is that label and its worktree= is that path, or it
#             is a secondmate home leased under its bare id whose home is that
#             path.
#   unproven  everything else: a record with no lease_holder= claim, which
#             predates durable leases so nothing recorded ties it to the slot;
#             a pool label no record in this home carries as its claim on that
#             path, including a label whose record names a different path; no
#             durable lease on the path; and a pool record that cannot be read.
# --retire-record and --relaunch refuse an unproven record and name what a
# person can confirm by hand instead; ordinary teardown refuses only released.
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

# The task in <state> other than <exclude-id> that carries the pool's holder
# <label> as its own claim on <path>: a record whose lease_holder= is that label
# and whose worktree= is that path, or a secondmate home leased under its bare
# id whose home is that path.
_fm_slot_label_claimant() {  # <state> <path> <label> <exclude-id>
  local state=$1 path=$2 label=$3 exclude=$4 want meta id claim
  [ -n "$label" ] || return 0
  want=$(fm_slot_canonical "$path")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    if [ "$(_fm_slot_meta "$meta" lease_holder)" = "$label" ]; then
      claim=$(_fm_slot_meta "$meta" worktree)
    elif [ "$id" = "$label" ] && [ "$(_fm_slot_meta "$meta" kind)" = secondmate ]; then
      claim=$(_fm_slot_meta "$meta" home)
      [ -n "$claim" ] || claim=$(_fm_slot_meta "$meta" worktree)
    else
      continue
    fi
    [ -n "$claim" ] || continue
    if [ "$claim" = "$path" ] || [ "$(fm_slot_canonical "$claim")" = "$want" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
}

# Sets FM_SLOT_VERDICT (own|released|unproven), FM_SLOT_EVIDENCE (one clause
# naming the evidence), and FM_SLOT_WORKTREE for the record <state>/<id>.meta.
# The header owns the rules. Returns 1 only when the record is missing.
fm_slot_verdict() {  # <state> <id>
  local state=$1 id=$2 meta wt holder record pool_holder owner
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
  if [ -z "$holder" ]; then
    FM_SLOT_EVIDENCE="the record carries no lease claim, so it predates durable leases and nothing recorded ties it to $wt, and ownership is not inferred"
    return 0
  fi
  record=$(fm_slot_pool_record "$wt")
  case "$record" in
    leased$'\t'*)
      pool_holder=${record#leased$'\t'}
      if [ "$pool_holder" = "$holder" ]; then
        FM_SLOT_VERDICT=own
        FM_SLOT_EVIDENCE="the pool leases $wt to this record's own claim $holder"
        return 0
      fi
      owner=$(_fm_slot_label_claimant "$state" "$wt" "$pool_holder" "$id")
      if [ -n "$owner" ]; then
        FM_SLOT_VERDICT=released
        FM_SLOT_EVIDENCE="the pool leases $wt to $pool_holder, task $owner's own recorded claim on that same working copy, not to this record's claim $holder"
        return 0
      fi
      FM_SLOT_EVIDENCE="the pool leases $wt to ${pool_holder:-an unlabelled holder} rather than to this record's claim $holder, and no record in this home carries that label as its claim on $wt"
      ;;
    unknown)
      FM_SLOT_EVIDENCE="the pool's record for $wt could not be read, so this record's claim $holder cannot be checked against it"
      ;;
    *)
      FM_SLOT_EVIDENCE="the pool holds no durable lease on $wt (it reports $record), so this record's claim $holder is not on it and no other record's claim explains the slot"
      ;;
  esac
  return 0
}
