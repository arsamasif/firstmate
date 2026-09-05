#!/usr/bin/env bash
# fm-limit-resume.sh - resume fleet work BY ITSELF after a Claude usage-window
# reset, with no model tokens, for parked crewmates AND the parked primary.
#
# The ONE tokenless resume owner (task fm-usage-limit-resume). It replaces the
# captain-private crontab stopgap of 2026-09-05 and closes the 2026-09-04
# incident: every Claude worker and the primary parked on the shared five-hour
# window at 7:56 PM, the primary's Stop-hook rewake was itself refused by the
# limit, and nothing re-armed anything for 7.9 hours.
#
# Usage:
#   fm-limit-resume.sh run                one tokenless sweep (what the scheduler runs)
#   fm-limit-resume.sh record-primary     record the pane this primary session runs in
#   fm-limit-resume.sh install [--scheduler systemd|cron]
#                                         arm the sweep every 5 minutes; idempotent
#   fm-limit-resume.sh uninstall          disarm it (both schedulers), idempotent
#   fm-limit-resume.sh status             human-readable armed/not-armed report
#   fm-limit-resume.sh bootstrap-lines    the BOOTSTRAP_INFO:/LIMIT_RESUME: lines
#                                         bin/fm-bootstrap.sh prints (empty = silent)
#   fm-limit-resume.sh --help
#
# `run` - for every task recorded in this home whose harness is claude and whose
# endpoint is local, it captures the pane, hands the capture to the ONE park
# record owner (bin/fm-limit-park-lib.sh, fm_limit_park_observe; the shape
# itself is bin/fm-composer-lib.sh's fm_composer_claude_usage_limit), and then,
# for a task that is parked:
#   1. reads the reconciled reset time (the later of the banner and quota-axi's
#      five_hour resetsAt; a record with neither rechecks quota-axi live: a
#      healthy live percentRemaining is ready on its own, because once the
#      park window has reset the live resetsAt already names the NEXT window,
#      and only an exhausted live read waits on that time);
#   2. waits until that reset has passed AND the window reads healthy
#      (quota-axi five_hour percentRemaining >= FM_LIMIT_RESUME_MIN_PCT,
#      default 40; an unreadable quota-axi is logged and the reset time alone
#      is trusted, because a resume that re-parks is harmless while a missed
#      one is the incident); a record on the WEEKLY window (window=weekly) is
#      never resumed here, this owner resumes the five-hour window only, and
#      the record's note says so;
#   3. sends exactly ONE resume steer for the park episode through
#      bin/fm-send.sh (durable inbox record plus the constant doorbell; never
#      raw send-keys) and writes the episode's resumed marker, so a second run
#      inside the same episode sends nothing; FM_LIMIT_RESUME_MIN_GAP_SECS
#      (default 1800) is a further backstop between two sends to one task.
# Then it looks at the primary itself through the pane recorded by
# `record-primary`:
#   - primary pane reachable and showing the banner: the park is recorded under
#     state/.primary.limit-park, the outage record is written (bin/fm-guard.sh
#     reads it so the stale beacon reads as "parked on the usage limit", not a
#     lapsed watcher), and after the reset one `usage-window-reset` operational
#     input (bin/fm-operational-input.sh) is typed through the SAME guarded
#     path the away-mode daemon uses (bin/fm-primary-inject-lib.sh: pane
#     exists, not busy, composer affirmatively empty, type once and retry only
#     Enter). A deferred delivery is retried on the next sweep; a confirmed one
#     writes the primary's resumed marker.
#   - primary pane not recorded, gone, or its session no longer alive: nothing
#     can be typed, so the crews are still resumed and one durable
#     `check: usage-window-reset` wake is appended (fm_wake_append) for the next
#     primary turn to present; bootstrap-lines tells the captain how to make
#     the primary self-resuming (launch it inside tmux).
# Every action and every deferral is logged to state/.limit-resume.log
# (size-capped, safe to delete). Nothing here interrupts, relaunches, tears
# down, forces, or discards anything, and the model is never asked to arm.
#
# `install` picks the scheduler: --scheduler, else FM_LIMIT_RESUME_SCHEDULER,
# else a running `systemctl --user` (systemd user timer, survives logouts with
# lingering enabled), else the user crontab. One entry per home, tagged by
# bin/fm-backend-hometag-lib.sh's home tag, rewritten in place on every
# install so two installs leave exactly one entry. The scheduler runs `run`
# with FM_HOME and the installing shell's PATH pinned, because a scheduler's
# own PATH rarely reaches quota-axi or tmux. `uninstall` removes the entry from
# both schedulers. config/limit-resume containing `off` makes `run` a no-op
# and silences bootstrap-lines, for a home that does not want the feature.
#
# Safety: fm-send stays the only steer transport; the primary injection is the
# shared guarded path with a distinct operational-input kind so the receiving
# session can tell it from a captain message and from an away escalation
# (AGENTS.md section 8 owns how it is handled). Away mode is never exited by
# this script. The scheduler entry never uses shell `&`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LOG="$STATE/.limit-resume.log"
LOG_MAX_BYTES=${FM_LIMIT_RESUME_LOG_MAX_BYTES:-200000}
MIN_GAP_SECS=${FM_LIMIT_RESUME_MIN_GAP_SECS:-1800}
GRACE=${FM_GUARD_GRACE:-300}
INJECT_RETRIES=${FM_LIMIT_RESUME_INJECT_RETRIES:-3}
INJECT_SLEEP=${FM_LIMIT_RESUME_INJECT_SLEEP:-0.5}
PRIMARY_ID=.primary
WAKE_KEY=usage-window-reset
case "$MIN_GAP_SECS" in ''|*[!0-9]*) MIN_GAP_SECS=1800 ;; esac

# shellcheck source=bin/fm-limit-park-lib.sh
. "$SCRIPT_DIR/fm-limit-park-lib.sh"
MIN_PCT=$FM_LIMIT_RESUME_MIN_PCT
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$SCRIPT_DIR/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-primary-inject-lib.sh
. "$SCRIPT_DIR/fm-primary-inject-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

log() {
  local size
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]') || size=0
  if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
}

feature_off() {
  [ -f "$CONFIG/limit-resume" ] || return 1
  [ "$(tr -d '[:space:]' < "$CONFIG/limit-resume" 2>/dev/null)" = off ]
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

beacon_age() {
  local m
  m=$(fm_path_mtime "$STATE/.last-watcher-beat" 2>/dev/null) || m=
  case "$m" in ''|*[!0-9]*) printf '%s' 999999; return ;; esac
  printf '%s' $(( $(date +%s) - m ))
}

# --- quota (lazy, once per sweep) --------------------------------------------
QUOTA_READ=0
QUOTA_OK=0
quota_once() {
  [ "$QUOTA_READ" -eq 0 ] || return 0
  QUOTA_READ=1
  if fm_limit_park_quota_window; then
    QUOTA_OK=1
    log "quota-axi five_hour: ${FM_LIMIT_QUOTA_PCT:-?}% remaining, resets $(fm_limit_park_fmt_epoch "${FM_LIMIT_QUOTA_RESETS_AT:-}")"
  else
    log "quota-axi five_hour window unavailable; trusting reset times alone this sweep"
  fi
}

# window_ready <id>: 0 once the record's reset has passed and the window reads
# healthy. Logs the reason when not ready.
window_ready() {  # <id>
  local id=$1 now resets pct=''
  now=$(date +%s)
  fm_limit_park_read "$STATE" "$id" || return 1
  if [ "$FM_LIMIT_PARK_WINDOW" = weekly ]; then
    log "$id is parked on the weekly limit${FM_LIMIT_PARK_RESETS_AT:+ until $(fm_limit_park_fmt_epoch "$FM_LIMIT_PARK_RESETS_AT")}; this owner resumes the five-hour window only, leaving it as a declared wait"
    return 1
  fi
  resets=$FM_LIMIT_PARK_RESETS_AT
  quota_once
  [ "$QUOTA_OK" -eq 1 ] && pct=$FM_LIMIT_QUOTA_PCT
  if [ -n "$resets" ]; then
    if [ "$now" -lt "$resets" ]; then
      log "$id still parked until $(fm_limit_park_fmt_epoch "$resets") ($FM_LIMIT_PARK_RESET_SOURCE)"
      return 1
    fi
  elif [ -z "$pct" ]; then
    log "$id parked with no reset time from the banner and no readable quota-axi window; waiting for either"
    return 1
  elif [ "$pct" -lt "$MIN_PCT" ] && [ -n "$FM_LIMIT_QUOTA_RESETS_AT" ] && [ "$now" -lt "$FM_LIMIT_QUOTA_RESETS_AT" ]; then
    log "$id still parked until $(fm_limit_park_fmt_epoch "$FM_LIMIT_QUOTA_RESETS_AT") (live quota, ${pct}% remaining)"
    return 1
  fi
  if [ -n "$pct" ] && [ "$pct" -lt "$MIN_PCT" ]; then
    log "$id reset passed but the five_hour window reads ${pct}% (< ${MIN_PCT}%); waiting"
    return 1
  fi
  [ -n "$FM_LIMIT_PARK_NOTE" ] && log "$id reset cross-check: $FM_LIMIT_PARK_NOTE"
  return 0
}

already_resumed() {  # <id>
  local id=$1 now
  if fm_limit_park_already_resumed "$STATE" "$id"; then
    return 0
  fi
  if fm_limit_park_resumed_read "$STATE" "$id" && [ -n "$FM_LIMIT_RESUMED_SENT_AT" ]; then
    now=$(date +%s)
    if [ $(( now - FM_LIMIT_RESUMED_SENT_AT )) -lt "$MIN_GAP_SECS" ]; then
      log "$id resumed $(( now - FM_LIMIT_RESUMED_SENT_AT ))s ago is inside the ${MIN_GAP_SECS}s minimum gap; not ringing again"
      return 0
    fi
  fi
  return 1
}

# --- crew sweep --------------------------------------------------------------
RESUMED=0
PARKED=0
resume_crews() {
  local meta id harness remote backend target screen out rc
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    harness=$(meta_value "$meta" harness)
    [ "$harness" = claude ] || continue
    remote=$(meta_value "$meta" remote_host)
    [ -z "$remote" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    screen=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null) || continue
    fm_limit_park_observe "$STATE" "$id" "$screen" || continue
    PARKED=$((PARKED + 1))
    if [ "$(beacon_age)" -gt "$GRACE" ]; then
      fm_limit_park_outage_write "$STATE" "$FM_LIMIT_PARK_OBSERVED_AT" "$FM_LIMIT_PARK_RESETS_AT" "crew:$id" || true
    fi
    window_ready "$id" || continue
    already_resumed "$id" && continue
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$id" "$(fm_limit_park_resume_text)" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      fm_limit_park_resumed_write "$STATE" "$id" "$FM_LIMIT_PARK_EPISODE" "$FM_LIMIT_PARK_RESETS_AT"
      RESUMED=$((RESUMED + 1))
      log "resumed $id after the usage window reset ($(fm_limit_park_fmt_epoch "$FM_LIMIT_PARK_RESETS_AT")): steer recorded"
    else
      log "resume steer to $id failed (rc=$rc): $(printf '%s' "$out" | tail -1)"
    fi
  done
}

# --- primary -----------------------------------------------------------------
# Verdicts: unrecorded | gone | dead-session | idle | parked | resumed | deferred
PRIMARY_VERDICT=unrecorded
resume_primary() {
  local backend target harness lockpid screen encoded verdict body
  if ! fm_limit_park_primary_read "$STATE"; then
    PRIMARY_VERDICT=unrecorded
    return 0
  fi
  backend=$FM_LIMIT_PRIMARY_BACKEND
  target=$FM_LIMIT_PRIMARY_TARGET
  harness=$FM_LIMIT_PRIMARY_HARNESS
  lockpid=$FM_LIMIT_PRIMARY_LOCK_PID
  if ! fm_backend_target_exists "$backend" "$target"; then
    PRIMARY_VERDICT=gone
    fm_limit_park_clear "$STATE" "$PRIMARY_ID"
    return 0
  fi
  screen=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || { PRIMARY_VERDICT=gone; return 0; }
  if ! fm_limit_park_observe "$STATE" "$PRIMARY_ID" "$screen"; then
    PRIMARY_VERDICT=idle
    return 0
  fi
  PRIMARY_VERDICT=parked
  fm_limit_park_outage_write "$STATE" "$FM_LIMIT_PARK_OBSERVED_AT" "$FM_LIMIT_PARK_RESETS_AT" primary || true
  case "$lockpid" in
    ''|*[!0-9]*) ;;
    *)
      if ! fm_harness_pid_alive "$lockpid"; then
        PRIMARY_VERDICT=dead-session
        log "primary pane $target shows the usage-limit banner but session pid $lockpid is no longer a live harness; leaving the durable wake for the next session"
        return 0
      fi
      ;;
  esac
  window_ready "$PRIMARY_ID" || return 0
  if already_resumed "$PRIMARY_ID"; then
    PRIMARY_VERDICT=resumed
    return 0
  fi
  body="The Claude usage window reset at $(fm_limit_park_fmt_epoch "$FM_LIMIT_PARK_RESETS_AT") and this session was parked on it. Drain the wake queue first (bin/fm-wake-drain.sh), resume any parked crewmate the tokenless resume owner has not already resumed (state/<id>.limit-park without a matching .resumed marker), then continue normal supervision. This is an operational input, not a captain message; away mode, if active, stays active."
  fm_operational_input_encode "$WAKE_KEY" "$body" encoded || return 0
  verdict=$(fm_primary_inject_guarded "$backend" "$target" "$harness" "$encoded" "$INJECT_RETRIES" "$INJECT_SLEEP" "$INJECT_SLEEP")
  case "$verdict" in
    submitted)
      fm_limit_park_resumed_write "$STATE" "$PRIMARY_ID" "$FM_LIMIT_PARK_EPISODE" "$FM_LIMIT_PARK_RESETS_AT"
      PRIMARY_VERDICT=resumed
      log "primary resumed: usage-window-reset input delivered to $backend pane $target"
      ;;
    *)
      PRIMARY_VERDICT=deferred
      log "primary resume deferred ($verdict); retrying next sweep"
      ;;
  esac
}

# One durable wake per sweep that acted, so a primary that could not be typed
# into (or that was typed into and then compacted) still presents the reset on
# its next turn. Never appended while an unacknowledged copy is queued.
append_reset_wake() {  # <summary>
  local queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  case "$queued" in
    *"$WAKE_KEY"*) return 0 ;;
  esac
  fm_wake_append check "$WAKE_KEY" "check: $WAKE_KEY: $1" || log "durable wake append failed"
}

cmd_run() {
  local append_wake
  [ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }
  # Durable wake queue (fm_wake_append) and fm_path_mtime for the beacon age.
  # Sourced here, not at load: the library creates the state directory when it
  # loads, and the read-only commands (bootstrap-lines under a detect-only
  # bootstrap, status) must leave a home without one untouched.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if feature_off; then
    exit 0
  fi
  resume_crews
  resume_primary
  case "$PRIMARY_VERDICT" in
    resumed|deferred|dead-session) append_wake=1 ;;
    *) append_wake=0 ;;
  esac
  [ "$RESUMED" -gt 0 ] && append_wake=1
  if [ "$append_wake" -eq 1 ]; then
    append_reset_wake "resumed $RESUMED parked worker(s) after the Claude usage window reset; primary: $PRIMARY_VERDICT. Drain, then continue supervision"
  fi
  if [ "$PARKED" -gt 0 ] || [ "$PRIMARY_VERDICT" = parked ] || [ "$PRIMARY_VERDICT" = deferred ]; then
    log "sweep: parked=$PARKED resumed=$RESUMED primary=$PRIMARY_VERDICT"
  fi
  exit 0
}

# --- record-primary ----------------------------------------------------------
cmd_record_primary() {
  local target backend harness lockpid
  mkdir -p "$STATE" 2>/dev/null || exit 1
  if ! target=$(discover_supervisor_target); then
    fm_limit_park_primary_clear "$STATE"
    echo "primary pane not reachable: no TMUX_PANE, HERDR_PANE_ID, or FM_SUPERVISOR_TARGET in this session's environment" >&2
    exit 1
  fi
  backend=$(discover_supervisor_backend) || backend=tmux
  harness=${FM_PRIMARY_HARNESS:-$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')}
  lockpid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lockpid" in ''|*[!0-9]*) lockpid= ;; esac
  fm_limit_park_primary_write "$STATE" "$backend" "$target" "$harness" "$lockpid" || exit 1
  printf 'primary pane recorded: %s %s (%s)\n' "$backend" "$target" "$harness"
}

# --- scheduler ---------------------------------------------------------------
unit_name() {
  printf 'firstmate-limit-resume-%s' "$(fm_backend_hometag)"
}
unit_dir() {
  printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"
}
cron_tag() {
  printf '# firstmate-limit-resume home=%s' "$FM_HOME"
}
run_cmd() {
  printf 'FM_HOME=%q %q run' "$FM_HOME" "$SCRIPT_DIR/fm-limit-resume.sh"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  case "$(systemctl --user is-system-running 2>/dev/null)" in
    running|degraded) return 0 ;;
  esac
  return 1
}

systemd_armed() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [ "$(systemctl --user is-enabled "$(unit_name).timer" 2>/dev/null)" = enabled ]
}

cron_armed() {
  command -v crontab >/dev/null 2>&1 || return 1
  crontab -l 2>/dev/null | grep -qF "$(cron_tag)"
}

install_systemd() {
  local dir name
  dir=$(unit_dir)
  name=$(unit_name)
  mkdir -p "$dir" || return 1
  cat > "$dir/$name.service" <<EOF
[Unit]
Description=Firstmate usage-limit resume sweep for $FM_HOME

[Service]
Type=oneshot
Environment="HOME=$HOME"
Environment="PATH=$PATH"
Environment="FM_HOME=$FM_HOME"
ExecStart=$SCRIPT_DIR/fm-limit-resume.sh run
EOF
  cat > "$dir/$name.timer" <<EOF
[Unit]
Description=Firstmate usage-limit resume sweep timer for $FM_HOME

[Timer]
OnCalendar=*:0/5
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || return 1
  systemctl --user enable --now "$name.timer" >/dev/null 2>&1 || return 1
  printf 'armed: systemd user timer %s.timer (every 5 minutes)\n' "$name"
}

uninstall_systemd() {
  local dir name
  command -v systemctl >/dev/null 2>&1 || return 0
  dir=$(unit_dir)
  name=$(unit_name)
  if [ -e "$dir/$name.timer" ] || [ -e "$dir/$name.service" ] || systemd_armed; then
    systemctl --user disable --now "$name.timer" >/dev/null 2>&1 || true
    rm -f "$dir/$name.timer" "$dir/$name.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    printf 'disarmed: systemd user timer %s.timer\n' "$name"
  fi
}

install_cron() {
  local existing tag line
  command -v crontab >/dev/null 2>&1 || { echo "error: crontab is not available" >&2; return 1; }
  tag=$(cron_tag)
  existing=$(crontab -l 2>/dev/null | grep -vF "$tag" || true)
  line="*/5 * * * * PATH=$PATH $(run_cmd) >/dev/null 2>&1 $tag"
  if [ -n "$existing" ]; then
    printf '%s\n%s\n' "$existing" "$line" | crontab - || return 1
  else
    printf '%s\n' "$line" | crontab - || return 1
  fi
  printf 'armed: crontab entry (every 5 minutes)\n'
}

uninstall_cron() {
  local existing tag
  command -v crontab >/dev/null 2>&1 || return 0
  tag=$(cron_tag)
  crontab -l 2>/dev/null | grep -qF "$tag" || return 0
  existing=$(crontab -l 2>/dev/null | grep -vF "$tag" || true)
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing" | crontab - || return 1
  else
    crontab -r 2>/dev/null || printf '' | crontab - || return 1
  fi
  printf 'disarmed: crontab entry\n'
}

cmd_install() {
  local scheduler=${FM_LIMIT_RESUME_SCHEDULER:-}
  while [ $# -gt 0 ]; do
    case "$1" in
      --scheduler) [ $# -ge 2 ] || { usage; exit 2; }; scheduler=$2; shift 2 ;;
      --scheduler=*) scheduler=${1#--scheduler=}; shift ;;
      *) usage; exit 2 ;;
    esac
  done
  if [ -z "$scheduler" ]; then
    if systemd_available; then scheduler=systemd
    elif command -v crontab >/dev/null 2>&1; then scheduler=cron
    else
      echo "error: neither a running systemd user manager nor crontab is available; nothing can schedule the sweep" >&2
      exit 1
    fi
  fi
  case "$scheduler" in
    systemd)
      systemd_available || { echo "error: systemctl --user is not running; use --scheduler cron" >&2; exit 1; }
      uninstall_cron >/dev/null || true
      install_systemd || { echo "error: could not arm the systemd user timer" >&2; exit 1; }
      ;;
    cron)
      uninstall_systemd >/dev/null || true
      install_cron || exit 1
      ;;
    *) echo "error: unknown scheduler '$scheduler' (systemd|cron)" >&2; exit 2 ;;
  esac
}

cmd_uninstall() {
  local rc=0
  uninstall_systemd || rc=1
  uninstall_cron || rc=1
  exit "$rc"
}

armed_how() {
  if systemd_armed; then
    printf 'systemd user timer %s.timer' "$(unit_name)"
    return 0
  fi
  if cron_armed; then
    printf 'crontab entry'
    return 0
  fi
  return 1
}

cmd_status() {
  local how
  if feature_off; then
    echo "usage-limit resume: off (config/limit-resume)"
  elif how=$(armed_how); then
    echo "usage-limit resume: armed ($how)"
  else
    echo "usage-limit resume: not armed (run bin/fm-limit-resume.sh install)"
  fi
  if fm_limit_park_primary_read "$STATE"; then
    echo "primary pane: $FM_LIMIT_PRIMARY_BACKEND $FM_LIMIT_PRIMARY_TARGET ($FM_LIMIT_PRIMARY_HARNESS)"
  else
    echo "primary pane: not recorded (this session cannot be resumed by typing; see bootstrap-lines)"
  fi
  if fm_limit_park_outage_read "$STATE"; then
    echo "outage record: $(fm_limit_park_outage_describe "$STATE")"
  fi
  exit 0
}

# claude_relevant: 0 when this home runs Claude anywhere the park can happen.
# The primary's harness is an explicit input (FM_PRIMARY_HARNESS, which session
# start passes from its own detection) rather than re-detected from this
# process's ancestry, so a bootstrap run from any shell prints the same lines
# the session-start digest prints and a test home stays silent unless it says
# claude somewhere itself.
claude_relevant() {
  local meta crew
  [ "${FM_PRIMARY_HARNESS:-}" = claude ] && return 0
  crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" 2>/dev/null || true)
  [ "$crew" = claude ] && return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(meta_value "$meta" harness)" = claude ] && return 0
  done
  return 1
}

cmd_bootstrap_lines() {
  local how lockpid
  feature_off && exit 0
  claude_relevant || exit 0
  if how=$(armed_how); then
    echo "BOOTSTRAP_INFO: usage-limit resume armed ($how); parked Claude workers resume by themselves after the window resets"
  else
    echo "LIMIT_RESUME: not armed - run bin/fm-limit-resume.sh install so parked Claude workers and this session resume by themselves after the usage window resets (config/limit-resume containing 'off' silences this)"
  fi
  if [ "${FM_PRIMARY_HARNESS:-}" = claude ]; then
    lockpid=$(cat "$STATE/.lock" 2>/dev/null || true)
    if ! fm_limit_park_primary_read "$STATE" || { [ -n "$lockpid" ] && [ "$FM_LIMIT_PRIMARY_LOCK_PID" != "$lockpid" ]; }; then
      echo "LIMIT_RESUME: this session cannot resume itself after a usage-window reset because it is not running inside a tmux or herdr pane the resume sweep can reach; parked workers still resume and a durable notification waits for your next message. To make the session self-resuming, launch firstmate inside tmux (README 'Install and launch'): \`tmux new -s firstmate\`, then \`claude\` from the firstmate home"
    fi
  fi
  exit 0
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  record-primary) shift; cmd_record_primary "$@" ;;
  install) shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  status) shift; cmd_status "$@" ;;
  bootstrap-lines) shift; cmd_bootstrap_lines "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
