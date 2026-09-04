#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the Windows/MSYS session identity
# path in bin/fm-session-lock-lib.sh, on a real Git Bash/MSYS host.
# Proves against the REAL installed Claude Code that a Bash tool call inside a
# Claude session sees CLAUDE_PID, that `tasklist` names that pid a live claude
# image, and that bin/fm-lock.sh acquires an isolated home's session lock naming
# exactly that pid - while the same acquisition with CLAUDE_PID removed refuses
# the lock, which is the fail-closed control. The deterministic fake-tasklist
# cases in tests/fm-session-lock-ancestry.test.sh can only confirm the
# assumptions written into the fake (firstmate-coding-guidelines
# "Harness-dependent checks"): this guard is what refreshes the per-host
# evidence recorded in docs/verification/supervision.md after a Claude upgrade.
# The FM_HOME is isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Windows session-lock identity guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# The Windows path is host-shaped, not harness-shaped: it only ever runs where
# both platform variables are present, so any other host has nothing to check
# and says so rather than passing over it silently.
case "${OS:-}:${MSYSTEM:-}" in
  Windows_NT:?*) ;;
  *)
    echo "skip: the Windows session-lock identity guard needs a Git Bash/MSYS host (OS=Windows_NT with MSYSTEM set); this host reports OS=${OS:-unset} MSYSTEM=${MSYSTEM:-unset}"
    exit 0
    ;;
esac

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v tasklist >/dev/null 2>&1 || fail "tasklist not found on this Windows host"
CLAUDE_VERSION=$(claude --version)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-lock-windows-live.XXXXXX") || fail "cannot create lab directory"
HOME_DIR="$LAB/fmhome"
CONTROL_HOME="$LAB/control-home"
PROBE_OUT="$HOME_DIR/state/probe.out"
mkdir -p "$HOME_DIR/state" "$CONTROL_HOME/state"
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

# The probe Claude runs inside its own Bash tool: record CLAUDE_PID, acquire the
# isolated home's lock through the real fm-lock.sh, repeat the acquisition with
# CLAUDE_PID removed against a second isolated home, and capture what Windows
# itself reports for that pid. Everything is written to files so the verdict
# below reads observed state, never the model's prose.
cat > "$LAB/probe.sh" <<SH
#!/usr/bin/env bash
set -u
{
  printf 'claude_pid=%s\n' "\${CLAUDE_PID:-unset}"
  rc=0; FM_HOME='$HOME_DIR' bash '$ROOT/bin/fm-lock.sh' >'$HOME_DIR/state/lock.out' 2>&1 || rc=\$?
  printf 'lock_rc=%s\n' "\$rc"
  rc=0; env -u CLAUDE_PID FM_HOME='$CONTROL_HOME' bash '$ROOT/bin/fm-lock.sh' >'$CONTROL_HOME/state/lock.out' 2>&1 || rc=\$?
  printf 'control_rc=%s\n' "\$rc"
  printf 'tasklist=%s\n' "\$(tasklist //FI "PID eq \${CLAUDE_PID:-0}" //NH //FO CSV 2>/dev/null)"
} > '$PROBE_OUT'
SH

PROMPT="Run exactly \`bash $LAB/probe.sh\` with Bash as your only tool call, then reply with exactly PROBED and stop. Never use any other tool."

(
  cd "$ROOT" || exit 1
  CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low
) > "$LAB/claude.out" 2>&1 || fail "Claude $CLAUDE_VERSION live session failed: $(tail -20 "$LAB/claude.out")"

[ -s "$PROBE_OUT" ] || fail "Claude $CLAUDE_VERSION: the probe never ran, so nothing was checked: $(tail -20 "$LAB/claude.out")"
CLAUDE_PID_SEEN=$(sed -n 's/^claude_pid=//p' "$PROBE_OUT")
case "$CLAUDE_PID_SEEN" in
  ''|*[!0-9]*) fail "Claude $CLAUDE_VERSION did not export a numeric CLAUDE_PID into its Bash tool (saw '$CLAUDE_PID_SEEN')" ;;
esac
TASKLIST_LINE=$(sed -n 's/^tasklist=//p' "$PROBE_OUT" | tr -d '\r')
case "$TASKLIST_LINE" in
  '"'*claude*'"'*) ;;
  *) fail "Claude $CLAUDE_VERSION: tasklist does not name CLAUDE_PID $CLAUDE_PID_SEEN a live claude image ('$TASKLIST_LINE')" ;;
esac
[ "$(sed -n 's/^lock_rc=//p' "$PROBE_OUT")" = 0 ] \
  || fail "Claude $CLAUDE_VERSION: fm-lock.sh refused the lock inside a live session: $(cat "$HOME_DIR/state/lock.out")"
[ "$(tr -d '\r' < "$HOME_DIR/state/.lock")" = "$CLAUDE_PID_SEEN" ] \
  || fail "Claude $CLAUDE_VERSION: the acquired lock names '$(cat "$HOME_DIR/state/.lock")', expected CLAUDE_PID $CLAUDE_PID_SEEN"
grep -q "lock acquired: harness pid $CLAUDE_PID_SEEN" "$HOME_DIR/state/lock.out" \
  || fail "Claude $CLAUDE_VERSION: fm-lock.sh did not report acquiring pid $CLAUDE_PID_SEEN: $(cat "$HOME_DIR/state/lock.out")"

# Fail-closed control: with CLAUDE_PID removed there is no walkable ancestry and
# no other verified harness pid source on this host, so the lock is refused and
# nothing is written.
[ "$(sed -n 's/^control_rc=//p' "$PROBE_OUT")" != 0 ] \
  || fail "Claude $CLAUDE_VERSION: fm-lock.sh acquired a lock with CLAUDE_PID removed: $(cat "$CONTROL_HOME/state/lock.out")"
grep -q 'cannot locate harness process in ancestry' "$CONTROL_HOME/state/lock.out" \
  || fail "Claude $CLAUDE_VERSION: the CLAUDE_PID-less control failed for another reason: $(cat "$CONTROL_HOME/state/lock.out")"
[ ! -e "$CONTROL_HOME/state/.lock" ] || fail "Claude $CLAUDE_VERSION: the CLAUDE_PID-less control left a lock behind"

printf 'ok - Claude %s on Git Bash (%s) identified its session lock from CLAUDE_PID %s via tasklist and refused the lock without it\n' \
  "$CLAUDE_VERSION" "$MSYSTEM" "$CLAUDE_PID_SEEN"
