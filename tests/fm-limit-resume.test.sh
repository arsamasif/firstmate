#!/usr/bin/env bash
# tests/fm-limit-resume.test.sh - the usage-limit park and tokenless resume
# contract (task fm-usage-limit-resume; incident 2026-09-04).
#
# Owners under test: bin/fm-composer-lib.sh's fm_composer_claude_usage_limit
# (the ONE banner shape), bin/fm-limit-park-lib.sh (the park record, the
# banner/quota-axi cross-check, the outage record), bin/fm-limit-resume.sh (the
# tokenless resume owner and its scheduler install), bin/fm-crew-state.sh
# (paused-class verdict), bin/fm-watch.sh's pause_state_class and
# task_declares_wait (declared wait, never a wedge), the away-mode daemon's
# classify_stale, bin/fm-guard.sh's parked-outage notice, and the
# usage-window-reset operational-input kind. Every case runs against real
# scripts in a throwaway home with a fake tmux, a fake quota-axi, and fake
# schedulers; nothing here reaches the primary home, a real crontab, or a real
# systemd manager. Positive and negative controls are paired on every check.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-limit-park-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"

RESUME="$ROOT/bin/fm-limit-resume.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
GUARD="$ROOT/bin/fm-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-limit-resume)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The exact banner captured live on 2026-09-04 (recorded against Claude Code 2.1.261), inside a
# realistic idle Claude pane (transcript rule, bare prompt glyph, footer).
PARKED_PANE=$(cat <<'EOF'
  ⏺ Reading the stale path in the watcher.

  You've hit your session limit · resets 9pm (America/New_York)
  /upgrade or /usage-credits to finish what you're working on.

  ─────────────────────────────────────────────────────────────
  ⚠ /low-priority to continue now at lower priority · uses your weekly limit

  ❯
EOF
)
# The same pane minus every banner line: the negative control.
IDLE_PANE=$(cat <<'EOF'
  ⏺ Reading the stale path in the watcher.

  ─────────────────────────────────────────────────────────────

  ❯
EOF
)

# --- fixtures ----------------------------------------------------------------

# A throwaway home with one claude ship task t1 whose fake tmux pane renders
# FM_FAKE_PANE_FILE, a fake quota-axi driven by FM_FAKE_QUOTA_PCT and
# FM_FAKE_QUOTA_RESETS_AT (ISO), and fake schedulers.
make_home() {  # <name> -> echoes home dir
  local name=$1 dir home fb
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  fb="$dir/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data" "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    cat "${FM_FAKE_PANE_FILE:-/dev/null}"
    exit 0 ;;
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-7}"; exit 0 ;; esac; done
    printf '%%7\n'; exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_QUOTA_ABSENT:-0}" = 1 ] && exit 1
printf 'windows[1]{provider,id,label,percentRemaining,resetsAt,pace}:\n'
printf '  claude,five_hour,session,%s,"%s",ahead\n' "${FM_FAKE_QUOTA_PCT:-90}" "${FM_FAKE_QUOTA_RESETS_AT:-2030-01-01T00:00:00+00:00}"
SH
  cat > "$fb/crontab" <<'SH'
#!/usr/bin/env bash
set -u
f=${FM_FAKE_CRONTAB_FILE:?}
case "${1:-}" in
  -l) [ -s "$f" ] || exit 1; cat "$f" ;;
  -r) : > "$f" ;;
  -) cat > "$f" ;;
esac
exit 0
SH
  cat > "$fb/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_SYSTEMCTL_LOG:?}
printf '%s\n' "$*" >> "$log"
unit=${!#}
case "$*" in
  *is-system-running*) printf 'running\n'; exit 0 ;;
  *is-enabled*)
    if grep -qF "enable --now $unit" "$log" 2>/dev/null && ! grep -qF "disable --now $unit" "$log"; then
      printf 'enabled\n'; exit 0
    fi
    printf 'disabled\n'; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/quota-axi" "$fb/crontab" "$fb/systemctl" "$fb/sleep"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "worktree=$home/wt-t1"
  mkdir -p "$home/wt-t1"
  printf '%s\n' "$PARKED_PANE" > "$dir/parked.txt"
  printf '%s\n' "$IDLE_PANE" > "$dir/idle.txt"
  printf '%s\n' "$home"
}

# run_resume <home> <subcommand...>: the real resume owner in that home.
run_resume() {  # <home> <args...>
  local home=$1 dir
  shift
  dir=$(dirname "$home")
  env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_FAKE_SEND_LOG="$dir/send.log" FM_FAKE_CRONTAB_FILE="$dir/crontab.txt" \
    FM_FAKE_SYSTEMCTL_LOG="$dir/systemctl.log" XDG_CONFIG_HOME="$dir/xdg" \
    FM_SEND_SETTLE=0 FM_PRIMARY_HARNESS="${FM_PRIMARY_HARNESS_OVERRIDE:-claude}" \
    "$RESUME" "$@"
}

iso_epoch() {  # <offset-seconds> -> ISO 8601 UTC that many seconds from now
  date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%S+00:00'
}

# A live process whose command name is a verified harness, so the resume
# owner's session-liveness gate (fm_harness_pid_alive) sees a real primary.
# Echoes the pid; the caller kills it.
start_fake_harness() {  # <dir> -> pid
  local dir=$1
  cp "$(command -v sleep)" "$dir/fakebin/claude"
  chmod +x "$dir/fakebin/claude"
  # Detached from this substitution's stdout, or the caller would wait on it.
  "$dir/fakebin/claude" 300 >/dev/null 2>&1 &
  printf '%s' $!
}

inbox_records() {  # <home> <id> -> count of unhandled inbox records
  local n=0 f
  for f in "$1/state/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- 1. the shape: banner classifies as parked, its absence does not ----------

test_banner_fixture_classifies_parked() {
  local reset banner
  fm_composer_claude_usage_limit "$PARKED_PANE" reset banner \
    || fail "the live 2026-09-04 banner fixture did not classify as parked"
  [ "$reset" = "9pm (America/New_York)" ] \
    || fail "reset phrase was not parsed from the headline: '$reset'"
  case "$banner" in *"hit your session limit"*) ;; *) fail "banner line not reported: '$banner'" ;; esac
  # Styled capture (tmux -e) must classify identically.
  fm_composer_claude_usage_limit "$(printf '\033[2m%s\033[0m' "$PARKED_PANE")" reset banner \
    || fail "styled banner capture did not classify as parked"
  # Either signal alone carries the verdict.
  fm_composer_claude_usage_limit '  ⚠ /low-priority to continue now at lower priority' reset banner \
    || fail "the /low-priority hint alone did not classify as parked"
  [ -z "$reset" ] || fail "hint-only capture invented a reset phrase: '$reset'"
  pass "fm_composer_claude_usage_limit: the live banner fixture, styled or plain, classifies as parked with its reset phrase"
}

test_pane_without_banner_is_not_parked() {
  local reset
  ! fm_composer_claude_usage_limit "$IDLE_PANE" reset \
    || fail "the same pane minus the banner classified as parked"
  ! fm_composer_claude_usage_limit '  ⏺ Working… (esc to interrupt)' reset \
    || fail "a busy footer classified as parked"
  ! fm_composer_claude_usage_limit 'the session limit is generous today' reset \
    || fail "prose mentioning the limit classified as parked"
  pass "fm_composer_claude_usage_limit: the banner-free pane, a busy footer, and prose are not parked"
}

test_reset_phrase_parses_to_next_wall_clock() {
  local now epoch
  now=$(date +%s)
  fm_limit_park_parse_reset "9pm (America/New_York)" "$now" epoch \
    || fail "9pm (America/New_York) did not parse"
  [ "$epoch" -ge "$now" ] || fail "parsed reset is in the past: $epoch < $now"
  [ $(( epoch - now )) -le 86400 ] || fail "parsed reset is more than a day out: $epoch"
  [ "$(TZ=America/New_York date -d "@$epoch" '+%H:%M')" = "21:00" ] \
    || fail "parsed reset is not 21:00 New York: $(TZ=America/New_York date -d "@$epoch" '+%H:%M')"
  fm_limit_park_parse_reset "3:30am" "$now" epoch || fail "3:30am (local zone) did not parse"
  [ "$(date -d "@$epoch" '+%H:%M')" = "03:30" ] || fail "3:30am parsed to $(date -d "@$epoch" '+%H:%M')"
  ! fm_limit_park_parse_reset "soonish" "$now" epoch || fail "garbage parsed as a reset"
  [ -z "$epoch" ] || fail "garbage left a value in the result: $epoch"
  pass "fm_limit_park_parse_reset: zoned and local phrases resolve to the next such wall clock; garbage is refused"
}

# --- 2. the record: observe writes, clears, and cross-checks ------------------

test_observe_records_park_and_clears_when_banner_gone() {
  local home dir
  home=$(make_home observe); dir=$(dirname "$home")
  FM_FAKE_QUOTA_PCT=0 FM_FAKE_QUOTA_RESETS_AT=$(iso_epoch 600) FM_LIMIT_QUOTA_BIN="$dir/fakebin/quota-axi" \
    fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" || fail "observe did not report parked"
  assert_present "$home/state/t1.limit-park" "park record was not written"
  fm_limit_park_read "$home/state" t1 || fail "park record did not read back"
  [ -n "$FM_LIMIT_PARK_RESETS_AT" ] || fail "record carries no reconciled reset"
  [ "$FM_LIMIT_PARK_RESET_SOURCE" = banner ] \
    || fail "banner (9pm NY) should be later than quota (+10min) and win: source=$FM_LIMIT_PARK_RESET_SOURCE"
  case "$FM_LIMIT_PARK_NOTE" in *"trusting the later banner time"*) ;; *) fail "disagreement was not logged in the record: '$FM_LIMIT_PARK_NOTE'" ;; esac
  # Refresh keeps the episode.
  local episode=$FM_LIMIT_PARK_EPISODE
  FM_LIMIT_QUOTA_BIN="$dir/fakebin/quota-axi" fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" || fail "second observe not parked"
  fm_limit_park_read "$home/state" t1
  [ "$FM_LIMIT_PARK_EPISODE" = "$episode" ] || fail "refresh changed the episode identity"
  # Negative control: the banner-free pane clears the record.
  ! fm_limit_park_observe "$home/state" t1 "$IDLE_PANE" || fail "banner-free pane still reported parked"
  assert_absent "$home/state/t1.limit-park" "park record survived the banner clearing"
  pass "fm_limit_park_observe: writes the record with the later of banner and quota-axi, keeps the episode on refresh, clears when the banner is gone"
}

test_observe_trusts_later_quota_reset_and_says_so() {
  local home dir far
  home=$(make_home observe-quota-later); dir=$(dirname "$home")
  far=$(iso_epoch 172800)
  FM_FAKE_QUOTA_PCT=0 FM_FAKE_QUOTA_RESETS_AT=$far FM_LIMIT_QUOTA_BIN="$dir/fakebin/quota-axi" \
    fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" || fail "observe did not report parked"
  fm_limit_park_read "$home/state" t1
  [ "$FM_LIMIT_PARK_RESET_SOURCE" = quota ] || fail "quota (+2 days) should win over banner: $FM_LIMIT_PARK_RESET_SOURCE"
  case "$FM_LIMIT_PARK_NOTE" in *"trusting the later quota-axi time"*) ;; *) fail "quota-wins note missing: '$FM_LIMIT_PARK_NOTE'" ;; esac
  pass "fm_limit_park_observe: a later quota-axi reset wins over the banner and the note says which was trusted"
}

# --- 3. crew-state: paused-class verdict, never stale ---------------------------

test_crew_state_reports_parked_pane_as_paused() {
  local home dir out
  home=$(make_home crew-state); dir=$(dirname "$home")
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_FILE="$dir/parked.txt" FM_STATE_OVERRIDE="$home/state" "$CREW_STATE" t1)
  case "$out" in "state: paused"*"parked on the Claude usage limit"*) ;; *) fail "crew-state did not report paused for a parked pane: $out" ;; esac
  # Negative control: the banner-free pane with no run and no busy record is unknown, not paused.
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_PANE_FILE="$dir/idle.txt" FM_STATE_OVERRIDE="$home/state" "$CREW_STATE" t1)
  case "$out" in "state: paused"*) fail "banner-free pane reported paused: $out" ;; esac
  pass "fm-crew-state: a parked Claude pane reports paused with the park detail; the same pane without the banner does not"
}

test_watcher_treats_park_as_declared_wait_not_wedge() {
  local home dir out
  home=$(make_home watcher); dir=$(dirname "$home")
  FM_LIMIT_QUOTA_BIN="$dir/fakebin/quota-axi" fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" >/dev/null
  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_FAKE_PANE_FILE="$dir/parked.txt" bash -c '
    . "$1"
    task_declares_wait t1 || { echo "declares:no"; exit 0; }
    echo "declares:yes"
    printf "class:%s\n" "$(pause_state_class sess:fm-t1 t1)"
  ' _ "$ROOT/bin/fm-watch.sh")
  case "$out" in *"declares:yes"*) ;; *) fail "task_declares_wait did not admit the park record: $out" ;; esac
  case "$out" in *"class:paused"*) ;; *) fail "pause_state_class did not classify the park as paused: $out" ;; esac
  # Negative control: no record, no declaration.
  fm_limit_park_clear "$home/state" t1
  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    task_declares_wait t1 && echo "declares:yes" || echo "declares:no"
  ' _ "$ROOT/bin/fm-watch.sh")
  [ "$out" = "declares:no" ] || fail "task_declares_wait admitted a task with no record and no paused: line: $out"
  pass "fm-watch: an active park record is a declared wait (paused class) for the watcher; without it nothing is declared"
}

test_daemon_classifies_park_as_pause() {
  local home dir out
  home=$(make_home daemon); dir=$(dirname "$home")
  FM_LIMIT_QUOTA_BIN="$dir/fakebin/quota-axi" fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" >/dev/null
  out=$(FM_STATE_OVERRIDE="$home/state" FM_TEST_DAEMON_SOURCED=1 bash -c '
    . "$1"
    classify_stale sess:fm-t1 "$2"
  ' _ "$ROOT/bin/fm-supervise-daemon.sh" "$home/state")
  case "$out" in "pause|parked on the Claude usage limit"*) ;; *) fail "daemon classify_stale did not route the park as a pause: $out" ;; esac
  fm_limit_park_clear "$home/state" t1
  out=$(FM_STATE_OVERRIDE="$home/state" FM_TEST_DAEMON_SOURCED=1 bash -c '
    . "$1"
    classify_stale sess:fm-t1 "$2"
  ' _ "$ROOT/bin/fm-supervise-daemon.sh" "$home/state")
  case "$out" in "pause|"*) fail "daemon classify_stale paused a task with no record: $out" ;; esac
  pass "fm-supervise-daemon: classify_stale routes a park record as a declared pause and a bare stale as before"
}

# --- 4. the resume owner: exactly one steer per episode, only after the reset ---

test_run_sends_exactly_one_steer_after_reset() {
  local home dir n
  home=$(make_home run-once); dir=$(dirname "$home")
  # A park whose banner reset already passed: pin the record with a past reset.
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_QUOTA_RESETS_AT=$(iso_epoch 3600) FM_FAKE_PANE_FILE="$dir/parked.txt" \
    run_resume "$home" run || fail "run failed"
  # First sighting: the banner says 9pm New York, which is in the future, so
  # nothing is sent yet.
  [ "$(inbox_records "$home" t1)" = 0 ] || fail "a steer was sent before the reset"
  assert_present "$home/state/t1.limit-park" "run did not record the park"
  # Move the reconciled reset into the past (the window has now reset).
  sed -i 's/^resets_at=.*/resets_at=1/' "$home/state/t1.limit-park"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked.txt" run_resume "$home" run || fail "run failed"
  n=$(inbox_records "$home" t1)
  [ "$n" = 1 ] || fail "expected exactly one resume steer after the reset, found $n"
  assert_present "$home/state/t1.limit-park.resumed" "resumed marker was not written"
  grep -q 'no-mistakes axi status' "$home/state/t1.inbox"/*.msg || fail "the resume steer does not carry the standard resume text"
  # Second sweep inside the same episode: the banner still shows, nothing rings again.
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked.txt" run_resume "$home" run || fail "second run failed"
  n=$(inbox_records "$home" t1)
  [ "$n" = 1 ] || fail "a second sweep in the same episode sent another steer (found $n)"
  grep -q 'resumed t1 after the usage window reset' "$home/state/.limit-resume.log" || fail "log does not record the resume"
  pass "fm-limit-resume run: a reset in the past with a healthy window sends exactly one steer through fm-send, and a second sweep sends none"
}

test_run_sends_nothing_before_reset_or_with_exhausted_window() {
  local home dir
  home=$(make_home run-future); dir=$(dirname "$home")
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_QUOTA_RESETS_AT=$(iso_epoch 7200) FM_FAKE_PANE_FILE="$dir/parked.txt" \
    run_resume "$home" run || fail "run failed"
  [ "$(inbox_records "$home" t1)" = 0 ] || fail "a steer was sent while the reset is in the future"
  grep -q 'still parked until' "$home/state/.limit-resume.log" || fail "log does not explain the wait"
  # Reset passed but the window still reads exhausted: wait.
  sed -i 's/^resets_at=.*/resets_at=1/' "$home/state/t1.limit-park"
  FM_FAKE_QUOTA_PCT=5 FM_FAKE_PANE_FILE="$dir/parked.txt" run_resume "$home" run || fail "run failed"
  [ "$(inbox_records "$home" t1)" = 0 ] || fail "a steer was sent while the window reads 5%"
  grep -q 'reads 5%' "$home/state/.limit-resume.log" || fail "log does not explain the exhausted window"
  # Feature off: nothing at all, even when due.
  printf 'off\n' > "$home/config/limit-resume"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked.txt" run_resume "$home" run || fail "run failed"
  [ "$(inbox_records "$home" t1)" = 0 ] || fail "a steer was sent with config/limit-resume off"
  pass "fm-limit-resume run: a reset in the future, an exhausted window, and the off switch all send nothing"
}

test_run_never_touches_a_non_claude_or_unparked_task() {
  local home dir
  home=$(make_home run-negative); dir=$(dirname "$home")
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=codex" "worktree=$home/wt-t1"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/idle.txt" run_resume "$home" run || fail "run failed"
  assert_absent "$home/state/t1.limit-park" "an idle pane produced a park record"
  [ "$(inbox_records "$home" t1)" = 0 ] || fail "an idle claude task was steered"
  [ "$(inbox_records "$home" t2)" = 0 ] || fail "a codex task was steered"
  assert_absent "$home/state/t2.limit-park" "a codex task produced a park record"
  pass "fm-limit-resume run: idle Claude tasks and non-Claude tasks are left alone"
}

# --- 5. the primary: guarded injection or a durable wake ----------------------

test_run_injects_reset_into_recorded_primary_pane() {
  local home dir n typed kind harness_pid
  home=$(make_home primary-inject); dir=$(dirname "$home")
  rm -f "$home/state/t1.meta"
  harness_pid=$(start_fake_harness "$dir")
  printf '%s\n' "$harness_pid" > "$home/state/.lock"
  # Record the primary pane through the real record-primary path.
  FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux run_resume "$home" record-primary >/dev/null \
    || fail "record-primary failed"
  assert_present "$home/state/.primary-pane" "primary pane record was not written"
  # First sweep: parked, reset in the future -> nothing typed.
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_QUOTA_RESETS_AT=$(iso_epoch 3600) FM_FAKE_PANE_FILE="$dir/parked.txt" \
    FM_FAKE_TMUX_CURSOR_Y=8 run_resume "$home" run || fail "run failed"
  assert_present "$home/state/.primary.limit-park" "primary park was not recorded"
  assert_present "$home/state/.limit-park-outage" "outage record was not written for a parked primary"
  assert_absent "$dir/send.log" "text was typed into the primary before the reset"
  # Reset passed: the guarded injection types the usage-window-reset input.
  sed -i 's/^resets_at=.*/resets_at=1/' "$home/state/.primary.limit-park"
  # The fake pane keeps its empty composer after Enter, which is the backend's
  # submit confirmation (the typed text is observed through send.log instead).
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked.txt" FM_FAKE_TMUX_CURSOR_Y=8 \
    run_resume "$home" run || fail "run failed"
  kill "$harness_pid" 2>/dev/null || true
  assert_present "$dir/send.log" "nothing was typed into the primary after the reset"
  typed=$(head -1 "$dir/send.log")
  fm_operational_input_kind "$typed" kind || fail "typed text is not an operational input: $typed"
  [ "$kind" = usage-window-reset ] || fail "typed input kind is $kind, not usage-window-reset"
  assert_present "$home/state/.primary.limit-park.resumed" "primary resumed marker was not written"
  n=$(grep -c . "$dir/send.log")
  [ "$n" = 1 ] || fail "expected one typed input, found $n"
  # Durable wake for the same reset.
  grep -q "usage-window-reset" "$home/state/.wake-queue" || fail "no durable usage-window-reset wake was queued"
  pass "fm-limit-resume run: a parked, recorded primary receives exactly one guarded usage-window-reset input after the reset, plus one durable wake"
}

test_run_defers_primary_injection_while_composer_holds_text() {
  local home dir harness_pid
  home=$(make_home primary-defer); dir=$(dirname "$home")
  rm -f "$home/state/t1.meta"
  harness_pid=$(start_fake_harness "$dir")
  printf '%s\n' "$harness_pid" > "$home/state/.lock"
  FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux run_resume "$home" record-primary >/dev/null
  # A pane showing the banner AND a half-typed captain line under the prompt.
  { printf '%s\n' "$PARKED_PANE"; printf '  ❯ half typed by the captain\n'; } > "$dir/parked-pending.txt"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_QUOTA_RESETS_AT=$(iso_epoch 3600) FM_FAKE_PANE_FILE="$dir/parked-pending.txt" \
    FM_FAKE_TMUX_CURSOR_Y=9 run_resume "$home" run || fail "run failed"
  sed -i 's/^resets_at=.*/resets_at=1/' "$home/state/.primary.limit-park"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked-pending.txt" FM_FAKE_TMUX_CURSOR_Y=9 \
    run_resume "$home" run || fail "run failed"
  kill "$harness_pid" 2>/dev/null || true
  assert_absent "$dir/send.log" "the reset input was typed over pending captain text"
  assert_absent "$home/state/.primary.limit-park.resumed" "a deferred injection was recorded as resumed"
  grep -q 'primary resume deferred (composer:' "$home/state/.limit-resume.log" || fail "log does not record the composer deferral"
  pass "fm-limit-resume run: the composer guard defers the primary input while the composer holds text, and retries next sweep"
}

test_unrecorded_primary_gets_durable_wake_and_bootstrap_line() {
  local home dir out
  home=$(make_home primary-unrecorded); dir=$(dirname "$home")
  fm_limit_park_observe "$home/state" t1 "$PARKED_PANE" >/dev/null 2>&1 || true
  sed -i 's/^resets_at=.*/resets_at=1/' "$home/state/t1.limit-park"
  FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$dir/parked.txt" run_resume "$home" run || fail "run failed"
  [ "$(inbox_records "$home" t1)" = 1 ] || fail "the crew was not resumed while the primary is unrecorded"
  grep -q 'usage-window-reset' "$home/state/.wake-queue" || fail "no durable wake for the unrecorded primary"
  grep -q 'primary: unrecorded' "$home/state/.wake-queue" || fail "the wake does not name the primary's state"
  out=$(run_resume "$home" bootstrap-lines)
  case "$out" in *"LIMIT_RESUME: not armed"*) ;; *) fail "bootstrap-lines missing the not-armed line: $out" ;; esac
  case "$out" in *"cannot resume itself"*"tmux new -s firstmate"*) ;; *) fail "bootstrap-lines missing the plain launch guidance: $out" ;; esac
  # Negative control: a home with no Claude anywhere (codex primary, codex crew
  # harness pinned so the ambient test-runner ancestry cannot leak in, and no
  # Claude task) prints nothing.
  rm -f "$home/state/t1.meta"
  printf 'codex\n' > "$home/config/crew-harness"
  out=$(FM_PRIMARY_HARNESS_OVERRIDE=codex run_resume "$home" bootstrap-lines)
  [ -z "$out" ] || fail "a codex-only home printed usage-limit lines: $out"
  pass "fm-limit-resume: an unreachable primary still gets its crews resumed, a durable wake, and the plain-language bootstrap line"
}

# --- 6. install/uninstall: idempotent, one entry ------------------------------

test_install_cron_is_idempotent() {
  local home dir n out
  home=$(make_home install-cron); dir=$(dirname "$home")
  printf '0 6 * * * /usr/bin/true # unrelated\n' > "$dir/crontab.txt"
  run_resume "$home" install --scheduler cron >/dev/null || fail "first install failed"
  run_resume "$home" install --scheduler cron >/dev/null || fail "second install failed"
  n=$(grep -c 'firstmate-limit-resume home=' "$dir/crontab.txt")
  [ "$n" = 1 ] || fail "two installs left $n crontab entries"
  grep -q '^0 6 \* \* \* /usr/bin/true # unrelated$' "$dir/crontab.txt" || fail "the unrelated crontab line was lost"
  grep -q "fm-limit-resume.sh run" "$dir/crontab.txt" || fail "the crontab entry does not run the sweep"
  ! grep -q ' & ' "$dir/crontab.txt" || fail "the crontab entry uses shell &"
  out=$(run_resume "$home" status)
  case "$out" in *"armed (crontab entry)"*) ;; *) fail "status does not report the crontab arming: $out" ;; esac
  out=$(run_resume "$home" bootstrap-lines)
  case "$out" in *"BOOTSTRAP_INFO: usage-limit resume armed (crontab entry)"*) ;; *) fail "bootstrap-lines missing the armed fact: $out" ;; esac
  run_resume "$home" uninstall >/dev/null || fail "uninstall failed"
  ! grep -q 'firstmate-limit-resume' "$dir/crontab.txt" || fail "uninstall left the entry"
  grep -q 'unrelated' "$dir/crontab.txt" || fail "uninstall removed the unrelated line"
  run_resume "$home" uninstall >/dev/null || fail "second uninstall failed"
  pass "fm-limit-resume install --scheduler cron: two installs leave one tagged entry, foreign lines survive, uninstall is idempotent"
}

test_install_systemd_is_idempotent() {
  local home dir unit n out
  home=$(make_home install-systemd); dir=$(dirname "$home")
  run_resume "$home" install --scheduler systemd >/dev/null || fail "first systemd install failed"
  run_resume "$home" install --scheduler systemd >/dev/null || fail "second systemd install failed"
  n=$(find "$dir/xdg/systemd/user" -name 'firstmate-limit-resume-*.timer' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "two installs left $n timer units"
  unit=$(find "$dir/xdg/systemd/user" -name 'firstmate-limit-resume-*.timer')
  grep -q 'OnCalendar=\*:0/5' "$unit" || fail "timer does not fire every 5 minutes"
  grep -q "FM_HOME=$home" "${unit%.timer}.service" || fail "service does not pin FM_HOME"
  grep -q 'enable --now firstmate-limit-resume-' "$dir/systemctl.log" || fail "timer was not enabled"
  out=$(run_resume "$home" status)
  case "$out" in *"armed (systemd user timer firstmate-limit-resume-"*) ;; *) fail "status does not report the timer: $out" ;; esac
  run_resume "$home" uninstall >/dev/null || fail "uninstall failed"
  [ ! -e "$unit" ] || fail "uninstall left the timer unit"
  grep -q 'disable --now firstmate-limit-resume-' "$dir/systemctl.log" || fail "timer was not disabled"
  pass "fm-limit-resume install --scheduler systemd: two installs leave one timer, and uninstall removes it"
}

# --- 7. the outage is described truthfully, not as a lapsed watcher ----------

test_guard_describes_park_instead_of_lapsed_watcher() {
  local home dir out now
  home=$(make_home guard); dir=$(dirname "$home")
  now=$(date +%s)
  fm_limit_park_outage_write "$home/state" $((now - 3600)) $((now + 1800)) primary || fail "outage write failed"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_GUARD_GRACE=1 FM_SUPERVISION_MODEL=autoarm "$GUARD" 2>&1)
  case "$out" in *"PARKED ON THE CLAUDE USAGE LIMIT"*"parked on the Claude usage limit from"*) ;; *) fail "guard did not describe the park: $out" ;; esac
  case "$out" in *"WATCHER DOWN"*) fail "guard still alarmed about a lapsed watcher during the park: $out" ;; esac
  # Negative control: an expired outage record softens nothing (cleared first,
  # because outage_write extends an existing record rather than replacing it).
  fm_limit_park_outage_clear "$home/state"
  fm_limit_park_outage_write "$home/state" $((now - 90000)) $((now - 86400)) primary
  rm -f "$home/state/.guard-watcher-stale-banner"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_GUARD_GRACE=1 FM_SUPERVISION_MODEL=autoarm "$GUARD" 2>&1)
  case "$out" in *"WATCHER DOWN"*) ;; *) fail "an expired park record still softened the alarm: $out" ;; esac
  pass "fm-guard: a stale beacon inside a recorded park window reads as parked on the usage limit; an expired record alarms as before"
}

# --- 8. the operational-input kind is distinct -------------------------------

test_usage_window_reset_kind_is_registered_and_distinct() {
  local encoded kind
  fm_operational_input_encode usage-window-reset "reset at 21:00" encoded || fail "usage-window-reset did not encode"
  fm_operational_input_kind "$encoded" kind || fail "usage-window-reset did not parse"
  [ "$kind" = usage-window-reset ] || fail "kind parsed as $kind"
  [ "$kind" != away-supervisor ] || fail "kind collides with away-supervisor"
  ! fm_operational_input_kind "reset at 21:00" kind || fail "a plain captain message parsed as operational"
  pass "fm-operational-input: usage-window-reset is a registered kind distinct from a captain message and an away escalation"
}

test_banner_fixture_classifies_parked
test_pane_without_banner_is_not_parked
test_reset_phrase_parses_to_next_wall_clock
test_observe_records_park_and_clears_when_banner_gone
test_observe_trusts_later_quota_reset_and_says_so
test_crew_state_reports_parked_pane_as_paused
test_watcher_treats_park_as_declared_wait_not_wedge
test_daemon_classifies_park_as_pause
test_run_sends_exactly_one_steer_after_reset
test_run_sends_nothing_before_reset_or_with_exhausted_window
test_run_never_touches_a_non_claude_or_unparked_task
test_run_injects_reset_into_recorded_primary_pane
test_run_defers_primary_injection_while_composer_holds_text
test_unrecorded_primary_gets_durable_wake_and_bootstrap_line
test_install_cron_is_idempotent
test_install_systemd_is_idempotent
test_guard_describes_park_instead_of_lapsed_watcher
test_usage_window_reset_kind_is_registered_and_distinct
