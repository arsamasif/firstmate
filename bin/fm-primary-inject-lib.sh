#!/usr/bin/env bash
# fm-primary-inject-lib.sh - the ONE guarded path for typing an operational
# input into the PRIMARY firstmate pane from a process that is not the captain.
#
# Two producers share it: the away-mode daemon's escalation digest
# (bin/fm-supervise-daemon.sh inject_msg, the worked example this was lifted
# from) and the usage-window reset delivery (bin/fm-limit-resume.sh). Both
# type into the same human-shared composer, so both must apply exactly the
# same guards, in the same order, and neither may hold a private copy of them:
#
#   1. target exists   - the recorded pane is still there (fm_backend_target_exists,
#                        a read-only probe that never starts a server).
#   2. busy guard      - never type into an agent mid-turn: the backend's native
#                        busy verdict when it has one (herdr), else the harness's
#                        verified rendered busy footer through the shared
#                        delivery matcher (fm_busy_lines_match in
#                        bin/fm-composer-lib.sh). A delivery guard only, never a
#                        recorded worker state (bin/fm-busy-lib.sh owns that).
#   3. composer guard  - type ONLY into an affirmatively `empty` genuine agent
#                        composer (fm_backend_composer_state -> the shared shape
#                        classifier). `pending` is a human's half-typed line or a
#                        swallowed prior injection, `unknown` is a bare dead-shell
#                        prompt or an unreadable pane; typing into either could
#                        merge with a human's text or execute in a shell, so every
#                        verdict but `empty` defers.
#   4. type once, Enter retried, never retyped, through the backend's verified
#      submit core; only an `empty` read-back after Enter counts as delivered.
#
# The message must already be the canonical typed envelope
# (bin/fm-operational-input.sh encode <kind>), so the receiving firstmate can
# tell the kind structurally; this library never constructs or inspects prose.
#
# Sourcing: bin/fm-backend.sh and bin/fm-composer-lib.sh must already be loaded
# by the caller (both daemon and resume owner do). set -u safe.

# fm_primary_pane_is_busy <backend> <target> <harness>
# 0 when the pane is busy by either signal; 1 when idle or unreadable (an
# unreadable pane is then refused by the composer guard, never typed into).
fm_primary_pane_is_busy() {  # <backend> <target> <harness>
  local backend=$1 target=$2 harness=${3:-} native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$native" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

# fm_primary_inject_busy <backend> <target> <harness>: the busy predicate the
# guard consults, defaulting to fm_primary_pane_is_busy. A producer that owns
# its own harness resolution (the away-mode daemon's pane_is_busy, which its
# tests stub) redefines this ONE name after sourcing; the guard order above is
# never redefined.
fm_primary_inject_busy() {  # <backend> <target> <harness>
  fm_primary_pane_is_busy "$@"
}

# fm_primary_inject_guarded <backend> <target> <harness> <encoded-message> <retries> <enter-sleep> [<settle>]
# Prints exactly one verdict token and returns 0 only for `submitted`:
#   submitted            the backend confirmed the submit
#   target-gone          the recorded pane no longer exists
#   busy                 the agent is mid-turn; try again later
#   composer:<state>     the composer was not affirmatively empty (<state> is the
#                        classifier's verdict: pending, pending-unproven, unknown)
#   unconfirmed:<verdict> typed and Enter sent, but the read-back never cleared;
#                        the text may still sit in the composer - never retype
fm_primary_inject_guarded() {  # <backend> <target> <harness> <encoded-message> <retries> <enter-sleep> [<settle>]
  local backend=$1 target=$2 harness=$3 msg=$4 retries=$5 sleep_s=$6 settle=${7:-$6} composer verdict
  if ! fm_backend_target_exists "$backend" "$target"; then
    printf 'target-gone'
    return 1
  fi
  if fm_primary_inject_busy "$backend" "$target" "$harness"; then
    printf 'busy'
    return 1
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    printf 'composer:%s' "${composer:-unknown}"
    return 1
  fi
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" "$retries" "$sleep_s" "$settle")
  if [ "$verdict" = empty ]; then
    printf 'submitted'
    return 0
  fi
  printf 'unconfirmed:%s' "${verdict:-unknown}"
  return 1
}
