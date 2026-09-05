#!/usr/bin/env bash
# Incident replay for fm/fm-usage-limit-resume: drives the REAL scripts
# (bin/fm-crew-state.sh, bin/fm-limit-resume.sh, bin/fm-limit-park-lib.sh) in a
# throwaway home with a fake tmux, fake quota-axi, fake crontab. Nothing here
# touches the captain's home, a real crontab, or a real Claude session.
set -u
ROOT=${1:?repo root}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"; FB="$WORK/fakebin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$FB" "$HOME_DIR/wt-t1" "$HOME_DIR/wt-t2"

say() { printf '\n=== %s ===\n' "$*"; }
cmd() { printf '\n$ %s\n' "$*"; }

cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    tgt=; while [ $# -gt 0 ]; do case "$1" in -t) tgt=${2:-}; shift 2 ;; *) shift ;; esac; done
    per="${FM_FAKE_PANE_DIR:-}/${tgt##*fm-}.txt"
    if [ -n "${FM_FAKE_PANE_DIR:-}" ] && [ -f "$per" ]; then cat "$per"; else cat "${FM_FAKE_PANE_FILE:-/dev/null}"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-8}"; exit 0 ;; esac; done
    printf '%%7\n'; exit 0 ;;
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac; done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
cat > "$FB/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'windows[1]{provider,id,label,percentRemaining,resetsAt,pace}:\n'
printf '  claude,five_hour,session,%s,"%s",ahead\n' "${FM_FAKE_QUOTA_PCT:-90}" "${FM_FAKE_QUOTA_RESETS_AT:-2030-01-01T00:00:00+00:00}"
[ -n "${FM_FAKE_QUOTA_WEEKLY_PCT:-}" ] && printf '  claude,seven_day,weekly,%s,"%s",ahead\n' "$FM_FAKE_QUOTA_WEEKLY_PCT" "${FM_FAKE_QUOTA_WEEKLY_RESETS_AT:-2030-06-01T00:00:00+00:00}"
exit 0
SH
cat > "$FB/crontab" <<'SH'
#!/usr/bin/env bash
set -u
f=${FM_FAKE_CRONTAB_FILE:?}
case "${1:-}" in -l) [ -s "$f" ] || exit 1; cat "$f" ;; -r) : > "$f" ;; -) cat > "$f" ;; esac
exit 0
SH
cat > "$FB/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FB"/*

# The exact pane text captured live on 2026-09-04 (Claude Code 2.1.261).
cat > "$WORK/parked.txt" <<'EOF'
  ⏺ Reading the stale path in the watcher.

  You've hit your session limit · resets 9pm (America/New_York)
  /upgrade or /usage-credits to finish what you're working on.

  ─────────────────────────────────────────────────────────────
  ⚠ /low-priority to continue now at lower priority · uses your weekly limit

  ❯
EOF
cat > "$WORK/idle.txt" <<'EOF'
  ⏺ Reviewing the guard output.

  ─────────────────────────────────────────────────────────────

  ❯
EOF
# The hint alone, arriving as a grep result on a HEALTHY worker that happens to
# be reading this feature's own source.
cat > "$WORK/hint-only.txt" <<'EOF'
  ⏺ Bash(grep -n low-priority bin/fm-composer-lib.sh)
    ⎿  383:  ⚠ /low-priority to continue now at lower priority · uses your weekly limit

  ⏺ Found one match.

  ❯
EOF

meta() { printf 'window=%s\nkind=ship\nharness=%s\nworktree=%s\n' "$2" "$3" "$4" > "$HOME_DIR/state/$1.meta"; }
meta t1 sess:fm-t1 claude "$HOME_DIR/wt-t1"   # the parked crewmate
meta t2 sess:fm-t2 claude "$HOME_DIR/wt-t2"   # a healthy crewmate (control)
mkdir -p "$WORK/panes"
cp "$WORK/parked.txt" "$WORK/panes/t1.txt"
cp "$WORK/idle.txt"   "$WORK/panes/t2.txt"

resume() { env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  FM_FAKE_SEND_LOG="$WORK/send.log" FM_FAKE_CRONTAB_FILE="$WORK/crontab.txt" \
  XDG_CONFIG_HOME="$WORK/xdg" FM_SEND_SETTLE=0 FM_PRIMARY_HARNESS=claude \
  FM_FAKE_PANE_DIR="$WORK/panes" "${EXTRA[@]}" "$ROOT/bin/fm-limit-resume.sh" "$@"; }

inbox() { ls "$HOME_DIR/state/$1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' '; }

printf 'Incident replay - 2026-09-04: every Claude worker and the primary parked on the\n'
printf 'shared five-hour usage window and nothing resumed for 7.9 hours.\n'
printf 'Throwaway home: fake tmux, fake quota-axi, fake crontab. Real firstmate scripts.\n'

say "1. What the parked crewmate's pane shows (tmux capture-pane)"
cat "$WORK/parked.txt"

say "2. The fleet's own view of that worker: bin/fm-crew-state.sh t1"
cmd "bin/fm-crew-state.sh t1"
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$PATH" FM_FAKE_PANE_FILE="$WORK/parked.txt" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-crew-state.sh" t1
cmd "bin/fm-crew-state.sh t2      # the healthy crewmate, same command"
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$PATH" FM_FAKE_PANE_FILE="$WORK/idle.txt" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-crew-state.sh" t2

say "3. 8:05 PM - the scheduler's first sweep, while the window is still spent"
EXTRA=(FM_FAKE_QUOTA_PCT=0 "FM_FAKE_QUOTA_RESETS_AT=$(date -u -d '+50 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')")
cmd "bin/fm-limit-resume.sh run"
resume run
printf '\nstate/t1.limit-park (the durable park record):\n'
sed 's/^/  /' "$HOME_DIR/state/t1.limit-park"
printf '\nsteers delivered to t1 so far: %s\n' "$(inbox t1)"
printf 'park record for the healthy crewmate t2: %s\n' \
  "$([ -e "$HOME_DIR/state/t2.limit-park" ] && echo present || echo none)"
printf '\nstate/.limit-resume.log:\n'; sed 's/^/  /' "$HOME_DIR/state/.limit-resume.log"

say "4. 9:00 PM - the window resets (fast-forward the record's reconciled reset)"
sed -i "s/^resets_at=.*/resets_at=$(( $(date +%s) - 120 ))/" "$HOME_DIR/state/t1.limit-park"
EXTRA=(FM_FAKE_QUOTA_PCT=95 "FM_FAKE_QUOTA_RESETS_AT=$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%M:%S+00:00')")
cmd "quota-axi --full   # what the sweep now reads"
env PATH="$FB:$PATH" "${EXTRA[@]}" quota-axi --full
cmd "bin/fm-limit-resume.sh run"
resume run
printf '\nsteers delivered to t1: %s   (t2, never parked: %s)\n' "$(inbox t1)" "$(inbox t2)"
printf '\nThe resume steer as the crewmate receives it (state/t1.inbox/*.msg):\n'
sed 's/^/  /' "$HOME_DIR/state/t1.inbox"/*.msg
printf '\nthe doorbell bin/fm-send.sh typed into t1'"'"'s pane (tmux send-keys -l):\n'
sed 's/^/  /' "$WORK/send.log"

say "5. The scheduler fires again five minutes later - exactly one steer per episode"
cmd "bin/fm-limit-resume.sh run"
resume run
printf '\nsteers delivered to t1: %s (unchanged)\n' "$(inbox t1)"
printf '\nstate/.limit-resume.log:\n'; sed 's/^/  /' "$HOME_DIR/state/.limit-resume.log"

say "6. The primary itself, launched outside tmux (the 2026-09-04 shape)"
cmd "bin/fm-limit-resume.sh bootstrap-lines"
EXTRA=(FM_FAKE_QUOTA_PCT=95)
resume bootstrap-lines
printf '\ndurable wake queued for the primary (state/.wake-queue):\n'
sed 's/^/  /' "$HOME_DIR/state/.wake-queue" 2>/dev/null || printf '  (none)\n'

say "7. A primary that IS in a tmux pane: one typed usage-window-reset input"
: > "$WORK/send.log"
cp "$(command -v sleep)" "$FB/claude"; "$FB/claude" 60 >/dev/null 2>&1 & HPID=$!
printf '%s\n' "$HPID" > "$HOME_DIR/state/.lock"
cp "$WORK/parked.txt" "$WORK/panes/primary.txt"
EXTRA=(FM_SUPERVISOR_TARGET=%9 FM_SUPERVISOR_BACKEND=tmux)
cmd "bin/fm-limit-resume.sh record-primary"
resume record-primary
sed 's/^/  /' "$HOME_DIR/state/.primary-pane"
EXTRA=(FM_FAKE_QUOTA_PCT=0 "FM_FAKE_QUOTA_RESETS_AT=$(date -u -d '+50 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')" FM_FAKE_PANE_FILE="$WORK/parked.txt" FM_FAKE_TMUX_CURSOR_Y=8)
resume run >/dev/null
printf '\nprimary park recorded, before the reset - typed into the primary: %s\n' \
  "$([ -s "$WORK/send.log" ] && cat "$WORK/send.log" || echo '(nothing)')"
sed -i "s/^resets_at=.*/resets_at=$(( $(date +%s) - 120 ))/" "$HOME_DIR/state/.primary.limit-park"
EXTRA=(FM_FAKE_QUOTA_PCT=95 FM_FAKE_PANE_FILE="$WORK/parked.txt" FM_FAKE_TMUX_CURSOR_Y=8)
cmd "bin/fm-limit-resume.sh run    # after the reset"
resume run
kill "$HPID" 2>/dev/null || true
printf '\ntyped into the primary pane (tmux send-keys -l), verbatim:\n'
sed 's/^/  /' "$WORK/send.log"
printf 'lines typed: %s\n' "$(grep -c . "$WORK/send.log")"

say "8. The guard, while the primary is parked: not a WATCHER DOWN alarm"
printf '\nstate/.limit-park-outage (written by the sweep when it saw the primary parked):\n'
sed 's/^/  /' "$HOME_DIR/state/.limit-park-outage"
rm -f "$HOME_DIR/state/.guard-watcher-stale-banner"
cmd "bin/fm-guard.sh    # the watcher beacon is stale because the primary was parked"
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_HOME="$HOME_DIR" FM_GUARD_GRACE=1 FM_SUPERVISION_MODEL=autoarm "$ROOT/bin/fm-guard.sh" 2>&1 \
  | sed 's/^/  /'

say "9. Head-commit fix: a hint-only capture is judged against BOTH windows"
rm -f "$HOME_DIR/state/t1.limit-park" "$HOME_DIR/state/t1.limit-park.resumed"
cp "$WORK/hint-only.txt" "$WORK/panes/t1.txt"
printf 'a) five-hour HEALTHY (95%%) + weekly SPENT (0%%) - a real weekly park seen\n   through the hint alone:\n'
EXTRA=(FM_FAKE_QUOTA_PCT=95 "FM_FAKE_QUOTA_RESETS_AT=$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%M:%S+00:00')" FM_FAKE_QUOTA_WEEKLY_PCT=0 "FM_FAKE_QUOTA_WEEKLY_RESETS_AT=$(date -u -d '+3 days' '+%Y-%m-%dT%H:%M:%S+00:00')")
resume run >/dev/null
printf '   park record: %s\n' "$([ -e "$HOME_DIR/state/t1.limit-park" ] && echo 'OPENED - the worker keeps its declared wait' || echo 'MISSING')"
printf 'b) BOTH windows healthy - the same text quoted by a working crewmate:\n'
rm -f "$HOME_DIR/state/t1.limit-park"
EXTRA=(FM_FAKE_QUOTA_PCT=95 "FM_FAKE_QUOTA_RESETS_AT=$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%M:%S+00:00')" FM_FAKE_QUOTA_WEEKLY_PCT=80 "FM_FAKE_QUOTA_WEEKLY_RESETS_AT=$(date -u -d '+3 days' '+%Y-%m-%dT%H:%M:%S+00:00')")
resume run >/dev/null
printf '   park record: %s\n' "$([ -e "$HOME_DIR/state/t1.limit-park" ] && echo 'OPENED (wrong)' || echo 'refused - no false park, nothing written')"

say "10. Arming the sweep - two installs leave exactly one entry"
: > "$WORK/crontab.txt"
EXTRA=()
cmd "bin/fm-limit-resume.sh install --scheduler cron   (twice)"
resume install --scheduler cron
resume install --scheduler cron
printf '\nthe user crontab now holds:\n'; sed 's/^/  /' "$WORK/crontab.txt"
cmd "bin/fm-limit-resume.sh status"
resume status
cmd "bin/fm-limit-resume.sh uninstall"
resume uninstall
printf '\ncrontab after uninstall: %s\n' "$([ -s "$WORK/crontab.txt" ] && cat "$WORK/crontab.txt" || echo '(empty)')"

say "11. bin/fm-limit-resume.sh --help ends where the header ends (head-commit fix)"
cmd "bin/fm-limit-resume.sh --help | tail -12"
resume --help 2>&1 | tail -12
