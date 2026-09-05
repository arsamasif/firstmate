#!/usr/bin/env bash
# fm-limit-park-lib.sh - the ONE owner of the usage-limit PARK record: what it
# means for a Claude worker or the primary to be parked on the account's
# five-hour usage window, how that park is recorded durably, how its reset time
# is reconciled between the rendered banner and quota-axi, and how the outage
# is recorded so supervision describes it truthfully.
#
# Why this exists (incident 2026-09-04, task fm-usage-limit-resume): every
# Claude worker and the primary share ONE account window, so they park within
# the same minute. The workers' panes showed the banner below, the primary's
# Stop-hook rewake needed a model turn the limit refused, and nothing re-armed
# anything for 7.9 hours until the captain typed. Firstmate must treat that
# park as a declared external wait (paused-class, never a wedge), resume every
# parked worker after the reset with no model tokens, and never describe the
# gap as a lapsed watcher.
#
# Banner shape: bin/fm-composer-lib.sh's fm_composer_claude_usage_limit is the
# only owner of the rendered shape. This file consumes its verdict and owns
# everything that needs a clock, a time zone, or a file.
#
# Corroboration rule: the banner is only a SCREEN SIGNAL. A healthy worker that
# reads this feature's own source, or greps for the hint text, renders those
# words too, and a park verdict there would misreport a working crewmate as
# paused and later steer it for nothing. So fm_limit_park_observe refuses to
# OPEN a record when quota-axi is readable and the window the banner NAMES
# still has more than FM_LIMIT_PARK_CORROBORATE_MAX_PCT remaining (five_hour
# against quota-axi's five_hour row, weekly against its seven_day row, because
# the two windows exhaust independently). An unreadable quota-axi, or output
# carrying no row for that window, still ADMITS the park: a false park costs
# one spurious steer, while the missed park of 2026-09-04 cost 7.9 idle hours.
# The refusal is a clean no-op on disk - no marker, no episode, no negative
# cache, no mutation of an existing record - so the next sweep, once quota-axi
# has caught up with a real park, opens it normally. Refusing to OPEN is the
# only gate: an already-open record keeps the refresh, re-reconcile, and clear
# behaviour below unchanged.
#
# Record: state/<id>.limit-park - written by fm_limit_park_observe (the
# watcher's per-poll capture and bin/fm-limit-resume.sh's tokenless sweep both
# call it) and removed by the same function once the banner is gone, or by
# teardown. One `key=value` line per field, private (mode 0600):
#   v1
#   episode=<epoch>          identity of this park episode: the reconciled reset
#                            epoch when one is known, else the first observation
#   observed_at=<epoch>      first sighting of this episode
#   last_seen=<epoch>        most recent sighting (refreshed on every observe)
#   window=<five_hour|weekly> which account window the banner names; the
#                            five-hour window is the only one the resume owner
#                            resumes, a weekly park is a declared wait with no
#                            automatic resume and note= says so
#   banner=<text>            the matched headline or hint line, plain text
#   banner_reset=<text>      the raw reset phrase parsed from the headline
#   banner_resets_at=<epoch|> that phrase as an epoch, empty when unparsable
#   quota_pct=<int|>         quota-axi five_hour percentRemaining at first sight
#   quota_resets_at=<epoch|> quota-axi five_hour resetsAt at first sight
#   resets_at=<epoch|>       the reconciled reset: the LATER of banner and quota
#   reset_source=<banner|quota|agree|none>
#   rechecked_at=<epoch|>    last time a refresh re-read quota-axi (see below)
#   note=<text>              set when the two sources disagreed, naming both,
#                            or when the park is on the weekly window
# Cross-check rule: when the banner and quota-axi disagree, the later time wins,
# because resuming early merely re-parks the worker on the same limit while
# resuming late only delays it; the disagreement is logged in note= and by the
# resume owner. A missing quota-axi row keeps the banner's time; a missing or
# unparsable banner time keeps quota-axi's; neither leaves resets_at empty and
# reset_source=none, which the resume owner treats as "recheck quota-axi live".
# A weekly park never consults the five_hour row: its reset is the banner's
# when that parses, else empty, and the resume owner leaves it alone.
# Re-reconcile rule: a refresh (same banner, same reset phrase) whose
# reconciled five-hour reset has already PASSED re-reads quota-axi, at most
# once per FM_LIMIT_PARK_RECHECK_SECS, because the banner Claude keeps
# rendering after a refused resume is the one case the first reconciliation
# cannot see: the window did not really move when the banner said it would.
# When the live window still reads exhausted (percentRemaining below
# FM_LIMIT_RESUME_MIN_PCT, or unreadable) and its five_hour resetsAt is later
# than the record's reset AND still ahead of the clock, the record takes it
# and the EPISODE advances to it, so the one-steer-per-episode receipt no
# longer matches and a second steer goes out once the live reset has passed
# and the window reads healthy. A live window that already reads healthy
# keeps the record as it is even when its resetsAt has moved, because that
# time names the NEXT window and waiting on it would be the incident again;
# so does a live reset that has not moved or already lies in the past.
#
# Resumed marker: state/<id>.limit-park.resumed - written ONLY by
# bin/fm-limit-resume.sh after it sends the one resume steer for an episode:
#   episode=<epoch> resets_at=<epoch|> sent_at=<epoch>
# A later observe that re-creates a record for the SAME reset (the banner did
# not clear, or the worker re-parked before the window really moved) reuses the
# episode identity, so the marker keeps a second run from ringing again.
#
# Outage record: state/.limit-park-outage - written by the resume owner when it
# sees the primary parked, or any worker parked while the watcher beacon is
# stale; read by bin/fm-guard.sh so a stale beacon inside the park window is
# described as "parked on the usage limit from X to Y", not as a lapsed
# watcher. Cleared by the guard once a healthy watcher is seen again, and
# ignored once `until` plus FM_LIMIT_OUTAGE_GRACE_SECS has passed, so a genuine
# lapse after the reset alarms exactly as before:
#   from=<epoch> until=<epoch|> observed_at=<epoch> source=<primary|crew:<id>>
#
# Primary pane record: state/.primary-pane - written by locked session start
# through bin/fm-limit-resume.sh record-primary using the ONE supervisor-pane
# resolution owner (bin/fm-supervisor-target-lib.sh, the same discovery
# bin/fm-afk-launch.sh relies on), because a scheduler-run sweep inherits no
# TMUX_PANE or HERDR_* environment of its own:
#   <backend>\t<target>\t<harness>\t<lock-pid>
# Absent when the primary was started outside a reachable pane; the resume
# owner then falls back to a durable wake plus a plain-language bootstrap line.
#
# Sourcing: set -u safe. Every function takes the state dir explicitly.

_FM_LIMIT_PARK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_LIMIT_PARK_LIB_DIR="."

case $- in *u*) _fm_limit_park_nounset=on ;; *) _fm_limit_park_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_LIMIT_PARK_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_limit_park_nounset" = on ] || set +u
unset _fm_limit_park_nounset
# shellcheck source=bin/fm-composer-lib.sh
# shellcheck disable=SC1091
. "$_FM_LIMIT_PARK_LIB_DIR/fm-composer-lib.sh"

FM_LIMIT_PARK_VERSION=v1
# Seconds a bounded quota-axi read may take before the sweep proceeds without it.
FM_LIMIT_QUOTA_TIMEOUT_SECS=${FM_LIMIT_QUOTA_TIMEOUT_SECS:-15}
# Past `until` by this much, an outage record no longer softens the watcher alarm.
FM_LIMIT_OUTAGE_GRACE_SECS=${FM_LIMIT_OUTAGE_GRACE_SECS:-3600}
# Floor between two quota-axi re-reads for one record whose reset has passed.
FM_LIMIT_PARK_RECHECK_SECS=${FM_LIMIT_PARK_RECHECK_SECS:-300}
# quota-axi five_hour percentRemaining at or above which the window reads
# healthy: the resume owner's steer floor and the re-reconcile rule's one
# definition of "still exhausted".
FM_LIMIT_RESUME_MIN_PCT=${FM_LIMIT_RESUME_MIN_PCT:-40}
case "$FM_LIMIT_RESUME_MIN_PCT" in ''|*[!0-9]*) FM_LIMIT_RESUME_MIN_PCT=40 ;; esac
# percentRemaining at or below which a rendered banner is corroborated, so a
# park record may be OPENED: a genuine park sits at or near zero remaining.
FM_LIMIT_PARK_CORROBORATE_MAX_PCT=${FM_LIMIT_PARK_CORROBORATE_MAX_PCT:-5}
case "$FM_LIMIT_PARK_CORROBORATE_MAX_PCT" in ''|*[!0-9]*) FM_LIMIT_PARK_CORROBORATE_MAX_PCT=5 ;; esac
# Test seam for the data-only quota source. Production never sets it.
FM_LIMIT_QUOTA_BIN=${FM_LIMIT_QUOTA_BIN:-quota-axi}

fm_limit_park_record_path() {  # <state> <id>
  printf '%s/%s.limit-park' "$1" "$2"
}

fm_limit_park_resumed_path() {  # <state> <id>
  printf '%s/%s.limit-park.resumed' "$1" "$2"
}

fm_limit_park_outage_path() {  # <state>
  printf '%s/.limit-park-outage' "$1"
}

fm_limit_park_primary_path() {  # <state>
  printf '%s/.primary-pane' "$1"
}

fm_limit_park_now() { date +%s; }

# fm_limit_park_fmt_epoch <epoch> -> "HH:MM TZ on YYYY-MM-DD" in the local zone,
# or the bare epoch when no date implementation can render it.
fm_limit_park_fmt_epoch() {  # <epoch>
  local epoch=$1 out
  case "$epoch" in ''|*[!0-9]*) printf '%s' "${epoch:-unknown}"; return 0 ;; esac
  if out=$(date -d "@$epoch" '+%H:%M %Z on %Y-%m-%d' 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
  elif out=$(date -r "$epoch" '+%H:%M %Z on %Y-%m-%d' 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
  else
    printf 'epoch %s' "$epoch"
  fi
}

# _fm_limit_park_date_in_zone <zone|> <date args...>: GNU date in the named
# zone, or in the ambient zone when none is named. An EMPTY TZ would mean UTC,
# which is why the zone is not exported blindly.
_fm_limit_park_date_in_zone() {  # <zone|> <date args...>
  local zone=$1
  shift
  if [ -n "$zone" ]; then
    TZ=$zone date "$@"
  else
    date "$@"
  fi
}

# fm_limit_park_parse_reset <raw-phrase> <observed-epoch> <result-var>
# Turn "9pm (America/New_York)", "3:30am", or "21:00" into the next such wall
# clock at or after <observed-epoch>, in the named zone (local zone when the
# phrase carries none). GNU date first, python3 zoneinfo second; 1 and an empty
# result when neither can parse it, so a caller never guesses.
fm_limit_park_parse_reset() {  # <raw-phrase> <observed-epoch> <result-var>
  local __fmpr_raw=${1-} __fmpr_observed=${2-} __fmpr_var=${3-} __fmpr_zone='' __fmpr_clock __fmpr_day __fmpr_epoch=''
  [ -n "$__fmpr_var" ] || return 2
  printf -v "$__fmpr_var" '%s' ''
  [ -n "$__fmpr_raw" ] || return 1
  case "$__fmpr_observed" in ''|*[!0-9]*) __fmpr_observed=$(fm_limit_park_now) ;; esac
  case "$__fmpr_raw" in
    *'('*')'*)
      __fmpr_zone=${__fmpr_raw#*(}
      __fmpr_zone=${__fmpr_zone%%)*}
      __fmpr_clock=${__fmpr_raw%%(*}
      ;;
    *) __fmpr_clock=$__fmpr_raw ;;
  esac
  __fmpr_clock=$(printf '%s' "$__fmpr_clock" | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr 'APM' 'apm')
  case "$__fmpr_clock" in
    [0-9]|[0-9][0-9]|[0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]|\
    [0-9]am|[0-9]pm|[0-9][0-9]am|[0-9][0-9]pm|\
    [0-9]:[0-9][0-9]am|[0-9]:[0-9][0-9]pm|[0-9][0-9]:[0-9][0-9]am|[0-9][0-9]:[0-9][0-9]pm) ;;
    *) return 1 ;;
  esac
  case "$__fmpr_zone" in ''|*[!A-Za-z0-9_/+-]*) __fmpr_zone='' ;; esac
  # Try the observed day and the next one; the first at or after observation wins.
  if __fmpr_day=$(_fm_limit_park_date_in_zone "$__fmpr_zone" -d "@$__fmpr_observed" '+%Y-%m-%d' 2>/dev/null) && [ -n "$__fmpr_day" ]; then
    __fmpr_epoch=$(_fm_limit_park_date_in_zone "$__fmpr_zone" -d "$__fmpr_day $__fmpr_clock" '+%s' 2>/dev/null) || __fmpr_epoch=''
    if [ -n "$__fmpr_epoch" ] && [ "$__fmpr_epoch" -lt "$__fmpr_observed" ]; then
      __fmpr_epoch=$(_fm_limit_park_date_in_zone "$__fmpr_zone" -d "$__fmpr_day $__fmpr_clock + 1 day" '+%s' 2>/dev/null) || __fmpr_epoch=''
    fi
  fi
  if [ -z "$__fmpr_epoch" ] && command -v python3 >/dev/null 2>&1; then
    __fmpr_epoch=$(python3 - "$__fmpr_clock" "$__fmpr_zone" "$__fmpr_observed" <<'PY' 2>/dev/null
import re, sys, datetime
clock, zone, observed = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.match(r'^(\d{1,2})(?::(\d{2}))?(am|pm)?$', clock)
if not m:
    sys.exit(1)
h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3)
if ap == 'pm' and h < 12:
    h += 12
if ap == 'am' and h == 12:
    h = 0
try:
    from zoneinfo import ZoneInfo
    tz = ZoneInfo(zone) if zone else None
except Exception:
    tz = None
now = datetime.datetime.fromtimestamp(observed, tz) if tz else datetime.datetime.fromtimestamp(observed).astimezone()
cand = now.replace(hour=h, minute=mi, second=0, microsecond=0)
if cand < now:
    cand += datetime.timedelta(days=1)
print(int(cand.timestamp()))
PY
) || __fmpr_epoch=''
  fi
  case "$__fmpr_epoch" in ''|*[!0-9]*) printf -v "$__fmpr_var" '%s' ''; return 1 ;; esac
  printf -v "$__fmpr_var" '%s' "$__fmpr_epoch"
}

# fm_limit_park_iso_to_epoch <iso8601> <result-var>: quota-axi's resetsAt.
fm_limit_park_iso_to_epoch() {  # <iso> <result-var>
  local __fmie_iso=${1-} __fmie_var=${2-} __fmie_epoch=''
  [ -n "$__fmie_var" ] || return 2
  printf -v "$__fmie_var" '%s' ''
  [ -n "$__fmie_iso" ] || return 1
  # GNU date does not read fractional seconds; drop them (they never matter here).
  __fmie_iso=$(printf '%s' "$__fmie_iso" | LC_ALL=C sed -E 's/(:[0-9]{2})\.[0-9]+/\1/')
  __fmie_epoch=$(date -d "$__fmie_iso" '+%s' 2>/dev/null) || __fmie_epoch=''
  if [ -z "$__fmie_epoch" ] && command -v python3 >/dev/null 2>&1; then
    __fmie_epoch=$(python3 -c 'import sys,datetime; s=sys.argv[1].replace("Z","+00:00"); print(int(datetime.datetime.fromisoformat(s).timestamp()))' "$__fmie_iso" 2>/dev/null) || __fmie_epoch=''
  fi
  case "$__fmie_epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf -v "$__fmie_var" '%s' "$__fmie_epoch"
}

# fm_limit_park_quota_window [<window>]: read one account window from quota-axi's
# data-only TOON (row `claude,<row-id>,<label>,<percentRemaining>,"<resetsAt>",...`).
# <window> is the name the banner carries: `five_hour` (the default, quota-axi's
# five_hour row) or `weekly` (its seven_day row).
# Sets FM_LIMIT_QUOTA_PCT (whole percent) and FM_LIMIT_QUOTA_RESETS_AT (epoch);
# 1 with both empty when the tool is absent, times out, or prints no such row.
FM_LIMIT_QUOTA_PCT=
FM_LIMIT_QUOTA_RESETS_AT=
fm_limit_park_quota_window() {  # [<window>]
  local window=${1:-five_hour} rowid out row pct iso epoch
  case "$window" in
    weekly) rowid=seven_day ;;
    *) rowid=five_hour ;;
  esac
  FM_LIMIT_QUOTA_PCT=
  FM_LIMIT_QUOTA_RESETS_AT=
  command -v "$FM_LIMIT_QUOTA_BIN" >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$FM_LIMIT_QUOTA_TIMEOUT_SECS" "$FM_LIMIT_QUOTA_BIN" --full 2>/dev/null) || return 1
  row=$(printf '%s\n' "$out" | LC_ALL=C grep -E "^[[:space:]]*claude,$rowid," | head -1)
  [ -n "$row" ] || return 1
  pct=$(printf '%s' "$row" | awk -F, '{print $4}')
  iso=$(printf '%s' "$row" | awk -F, '{print $5}' | tr -d '"')
  pct=${pct%.*}
  case "$pct" in ''|*[!0-9]*) pct='' ;; esac
  epoch=''
  fm_limit_park_iso_to_epoch "$iso" epoch || epoch=''
  FM_LIMIT_QUOTA_PCT=$pct
  FM_LIMIT_QUOTA_RESETS_AT=$epoch
  [ -n "$pct" ] || [ -n "$epoch" ]
}

# --- record read/write ------------------------------------------------------

FM_LIMIT_PARK_EPISODE=
FM_LIMIT_PARK_OBSERVED_AT=
FM_LIMIT_PARK_LAST_SEEN=
FM_LIMIT_PARK_WINDOW=
FM_LIMIT_PARK_BANNER=
FM_LIMIT_PARK_BANNER_RESET=
FM_LIMIT_PARK_BANNER_RESETS_AT=
FM_LIMIT_PARK_QUOTA_PCT=
FM_LIMIT_PARK_QUOTA_RESETS_AT=
FM_LIMIT_PARK_RESETS_AT=
FM_LIMIT_PARK_RESET_SOURCE=
FM_LIMIT_PARK_RECHECKED_AT=
FM_LIMIT_PARK_NOTE=

_fm_limit_park_reset_vars() {
  FM_LIMIT_PARK_EPISODE=
  FM_LIMIT_PARK_OBSERVED_AT=
  FM_LIMIT_PARK_LAST_SEEN=
  FM_LIMIT_PARK_WINDOW=
  FM_LIMIT_PARK_BANNER=
  FM_LIMIT_PARK_BANNER_RESET=
  FM_LIMIT_PARK_BANNER_RESETS_AT=
  FM_LIMIT_PARK_QUOTA_PCT=
  FM_LIMIT_PARK_QUOTA_RESETS_AT=
  FM_LIMIT_PARK_RESETS_AT=
  FM_LIMIT_PARK_RESET_SOURCE=
  FM_LIMIT_PARK_RECHECKED_AT=
  FM_LIMIT_PARK_NOTE=
}

fm_limit_park_active() {  # <state> <id>
  [ -f "$(fm_limit_park_record_path "$1" "$2")" ]
}

# fm_limit_park_read <state> <id>: load the record into FM_LIMIT_PARK_*; 1 when absent or malformed.
fm_limit_park_read() {  # <state> <id>
  local path line key value first=1
  path=$(fm_limit_park_record_path "$1" "$2")
  _fm_limit_park_reset_vars
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$FM_LIMIT_PARK_VERSION" ] || { _fm_limit_park_reset_vars; return 1; }
      continue
    fi
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    case "$key" in
      episode) FM_LIMIT_PARK_EPISODE=$value ;;
      observed_at) FM_LIMIT_PARK_OBSERVED_AT=$value ;;
      last_seen) FM_LIMIT_PARK_LAST_SEEN=$value ;;
      window) FM_LIMIT_PARK_WINDOW=$value ;;
      banner) FM_LIMIT_PARK_BANNER=$value ;;
      banner_reset) FM_LIMIT_PARK_BANNER_RESET=$value ;;
      banner_resets_at) FM_LIMIT_PARK_BANNER_RESETS_AT=$value ;;
      quota_pct) FM_LIMIT_PARK_QUOTA_PCT=$value ;;
      quota_resets_at) FM_LIMIT_PARK_QUOTA_RESETS_AT=$value ;;
      resets_at) FM_LIMIT_PARK_RESETS_AT=$value ;;
      reset_source) FM_LIMIT_PARK_RESET_SOURCE=$value ;;
      rechecked_at) FM_LIMIT_PARK_RECHECKED_AT=$value ;;
      note) FM_LIMIT_PARK_NOTE=$value ;;
    esac
  done < "$path"
  [ -n "$FM_LIMIT_PARK_WINDOW" ] || FM_LIMIT_PARK_WINDOW=five_hour
  [ -n "$FM_LIMIT_PARK_EPISODE" ] && [ -n "$FM_LIMIT_PARK_OBSERVED_AT" ]
}

_fm_limit_park_write() {  # <state> <id>  (from FM_LIMIT_PARK_*)
  local path tmp
  path=$(fm_limit_park_record_path "$1" "$2")
  tmp=$(mktemp "$path.tmp.XXXXXX") || return 1
  {
    printf '%s\n' "$FM_LIMIT_PARK_VERSION"
    printf 'episode=%s\n' "$FM_LIMIT_PARK_EPISODE"
    printf 'observed_at=%s\n' "$FM_LIMIT_PARK_OBSERVED_AT"
    printf 'last_seen=%s\n' "$FM_LIMIT_PARK_LAST_SEEN"
    printf 'window=%s\n' "${FM_LIMIT_PARK_WINDOW:-five_hour}"
    printf 'banner=%s\n' "$(printf '%s' "$FM_LIMIT_PARK_BANNER" | LC_ALL=C tr '\n\r' '  ')"
    printf 'banner_reset=%s\n' "$FM_LIMIT_PARK_BANNER_RESET"
    printf 'banner_resets_at=%s\n' "$FM_LIMIT_PARK_BANNER_RESETS_AT"
    printf 'quota_pct=%s\n' "$FM_LIMIT_PARK_QUOTA_PCT"
    printf 'quota_resets_at=%s\n' "$FM_LIMIT_PARK_QUOTA_RESETS_AT"
    printf 'resets_at=%s\n' "$FM_LIMIT_PARK_RESETS_AT"
    printf 'reset_source=%s\n' "$FM_LIMIT_PARK_RESET_SOURCE"
    printf 'rechecked_at=%s\n' "$FM_LIMIT_PARK_RECHECKED_AT"
    printf 'note=%s\n' "$(printf '%s' "$FM_LIMIT_PARK_NOTE" | LC_ALL=C tr '\n\r' '  ')"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_limit_park_clear() {  # <state> <id>
  rm -f "$(fm_limit_park_record_path "$1" "$2")"
}

# _fm_limit_park_reconcile <banner-epoch|> <quota-epoch|>: sets
# FM_LIMIT_PARK_RESETS_AT, FM_LIMIT_PARK_RESET_SOURCE, FM_LIMIT_PARK_NOTE.
# Later wins; agreement within two minutes is "agree".
_fm_limit_park_reconcile() {  # <banner-epoch|> <quota-epoch|>
  local b=${1-} q=${2-} diff
  FM_LIMIT_PARK_NOTE=
  if [ -n "$b" ] && [ -n "$q" ]; then
    diff=$((b - q))
    [ "$diff" -ge 0 ] || diff=$((-diff))
    if [ "$diff" -le 120 ]; then
      FM_LIMIT_PARK_RESETS_AT=$b
      FM_LIMIT_PARK_RESET_SOURCE=agree
    elif [ "$b" -gt "$q" ]; then
      FM_LIMIT_PARK_RESETS_AT=$b
      FM_LIMIT_PARK_RESET_SOURCE=banner
      FM_LIMIT_PARK_NOTE="banner reset $(fm_limit_park_fmt_epoch "$b") is later than quota-axi five_hour resetsAt $(fm_limit_park_fmt_epoch "$q"); trusting the later banner time"
    else
      FM_LIMIT_PARK_RESETS_AT=$q
      FM_LIMIT_PARK_RESET_SOURCE=quota
      FM_LIMIT_PARK_NOTE="quota-axi five_hour resetsAt $(fm_limit_park_fmt_epoch "$q") is later than the banner reset $(fm_limit_park_fmt_epoch "$b"); trusting the later quota-axi time"
    fi
  elif [ -n "$b" ]; then
    FM_LIMIT_PARK_RESETS_AT=$b
    FM_LIMIT_PARK_RESET_SOURCE=banner
  elif [ -n "$q" ]; then
    FM_LIMIT_PARK_RESETS_AT=$q
    FM_LIMIT_PARK_RESET_SOURCE=quota
  else
    FM_LIMIT_PARK_RESETS_AT=
    FM_LIMIT_PARK_RESET_SOURCE=none
  fi
}

# _fm_limit_park_recheck <now>: the re-reconcile rule above, on the record
# loaded in FM_LIMIT_PARK_*. 0 when the episode advanced (caller writes).
_fm_limit_park_recheck() {  # <now>
  local now=$1 prev=$FM_LIMIT_PARK_RESETS_AT
  [ "${FM_LIMIT_PARK_WINDOW:-five_hour}" = five_hour ] || return 1
  case "$prev" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$prev" ] || return 1
  case "$FM_LIMIT_PARK_RECHECKED_AT" in
    ''|*[!0-9]*) ;;
    *) [ $((now - FM_LIMIT_PARK_RECHECKED_AT)) -ge "$FM_LIMIT_PARK_RECHECK_SECS" ] || return 1 ;;
  esac
  FM_LIMIT_PARK_RECHECKED_AT=$now
  fm_limit_park_quota_window || return 1
  FM_LIMIT_PARK_QUOTA_PCT=$FM_LIMIT_QUOTA_PCT
  FM_LIMIT_PARK_QUOTA_RESETS_AT=$FM_LIMIT_QUOTA_RESETS_AT
  case "$FM_LIMIT_QUOTA_PCT" in
    ''|*[!0-9]*) ;;
    *) [ "$FM_LIMIT_QUOTA_PCT" -lt "$FM_LIMIT_RESUME_MIN_PCT" ] || return 1 ;;
  esac
  case "$FM_LIMIT_QUOTA_RESETS_AT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FM_LIMIT_QUOTA_RESETS_AT" -gt "$prev" ] && [ "$FM_LIMIT_QUOTA_RESETS_AT" -gt "$now" ] || return 1
  FM_LIMIT_PARK_RESETS_AT=$FM_LIMIT_QUOTA_RESETS_AT
  FM_LIMIT_PARK_RESET_SOURCE=quota
  FM_LIMIT_PARK_EPISODE=$FM_LIMIT_QUOTA_RESETS_AT
  FM_LIMIT_PARK_NOTE="reset $(fm_limit_park_fmt_epoch "$prev") passed while the banner stayed and the window still reads ${FM_LIMIT_QUOTA_PCT:-?}%; quota-axi five_hour now resets $(fm_limit_park_fmt_epoch "$FM_LIMIT_QUOTA_RESETS_AT"); trusting the later live time as a new episode"
  return 0
}

# fm_limit_park_observe <state> <id> <screen-text>
# Classify one bounded capture. 0 = parked (record created or refreshed),
# 1 = not parked (any record for <id> removed). A new episode consults
# quota-axi once, for the corroboration gate and the cross-check together; a
# refresh only does so under the re-reconcile rule above.
fm_limit_park_observe() {  # <state> <id> <screen>
  local state=$1 id=$2 screen=${3-} now reset='' banner='' window='' banner_epoch='' quota_epoch='' quota_pct='' quota_read=0
  local prev_episode prev_observed prev_reset
  now=$(fm_limit_park_now)
  if ! fm_composer_claude_usage_limit "$screen" reset banner window; then
    fm_limit_park_clear "$state" "$id"
    return 1
  fi
  if [ ! -e "$(fm_limit_park_record_path "$state" "$id")" ] && fm_limit_park_quota_window "$window"; then
    if [ "$window" != weekly ]; then
      quota_read=1
      quota_pct=$FM_LIMIT_QUOTA_PCT
      quota_epoch=$FM_LIMIT_QUOTA_RESETS_AT
    fi
    case "$FM_LIMIT_QUOTA_PCT" in
      ''|*[!0-9]*) ;;
      *) [ "$FM_LIMIT_QUOTA_PCT" -le "$FM_LIMIT_PARK_CORROBORATE_MAX_PCT" ] || return 1 ;;
    esac
  fi
  if fm_limit_park_read "$state" "$id" && [ "$FM_LIMIT_PARK_BANNER_RESET" = "$reset" ] \
    && [ "$FM_LIMIT_PARK_WINDOW" = "$window" ]; then
    FM_LIMIT_PARK_LAST_SEEN=$now
    FM_LIMIT_PARK_BANNER=$banner
    _fm_limit_park_recheck "$now" || true
    _fm_limit_park_write "$state" "$id"
    return 0
  fi
  prev_episode=$FM_LIMIT_PARK_EPISODE
  prev_observed=$FM_LIMIT_PARK_OBSERVED_AT
  prev_reset=$FM_LIMIT_PARK_RESETS_AT
  _fm_limit_park_reset_vars
  fm_limit_park_parse_reset "$reset" "$now" banner_epoch || banner_epoch=''
  if [ "$window" = weekly ]; then
    _fm_limit_park_reconcile "$banner_epoch" ''
    FM_LIMIT_PARK_NOTE="weekly limit, not the five-hour window; a declared wait with no automatic resume (bin/fm-limit-resume.sh owns the five-hour window only)"
  else
    if [ "$quota_read" = 0 ] && fm_limit_park_quota_window; then
      quota_pct=$FM_LIMIT_QUOTA_PCT
      quota_epoch=$FM_LIMIT_QUOTA_RESETS_AT
    fi
    _fm_limit_park_reconcile "$banner_epoch" "$quota_epoch"
  fi
  FM_LIMIT_PARK_OBSERVED_AT=$now
  FM_LIMIT_PARK_LAST_SEEN=$now
  FM_LIMIT_PARK_WINDOW=$window
  FM_LIMIT_PARK_BANNER=$banner
  FM_LIMIT_PARK_BANNER_RESET=$reset
  FM_LIMIT_PARK_BANNER_RESETS_AT=$banner_epoch
  FM_LIMIT_PARK_QUOTA_PCT=$quota_pct
  FM_LIMIT_PARK_QUOTA_RESETS_AT=$quota_epoch
  # Episode identity: the reconciled reset when known. A record replaced while
  # its reset did not move (the banner re-rendered with a slightly different
  # phrase) keeps the prior episode so the resumed marker still matches.
  if [ -n "$FM_LIMIT_PARK_RESETS_AT" ]; then
    FM_LIMIT_PARK_EPISODE=$FM_LIMIT_PARK_RESETS_AT
  else
    FM_LIMIT_PARK_EPISODE=$now
  fi
  if [ -n "$prev_episode" ] && [ -n "$prev_reset" ] && [ "$prev_reset" = "$FM_LIMIT_PARK_RESETS_AT" ]; then
    FM_LIMIT_PARK_EPISODE=$prev_episode
    FM_LIMIT_PARK_OBSERVED_AT=$prev_observed
  fi
  _fm_limit_park_write "$state" "$id"
}

# fm_limit_park_reset_due <state> <id>: 0 once the reconciled reset has passed.
# A record with no reset time is never due on its own; the resume owner rechecks
# quota-axi live for it.
fm_limit_park_reset_due() {  # <state> <id>
  fm_limit_park_read "$1" "$2" || return 1
  case "$FM_LIMIT_PARK_RESETS_AT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(fm_limit_park_now)" -ge "$FM_LIMIT_PARK_RESETS_AT" ]
}

# fm_limit_park_describe <state> <id> -> one plain line for a wake reason or a
# crew-state detail, or empty when no record exists.
fm_limit_park_describe() {  # <state> <id>
  fm_limit_park_read "$1" "$2" || return 1
  if [ "$FM_LIMIT_PARK_WINDOW" = weekly ]; then
    printf 'parked on the Claude weekly usage limit%s; not resumed automatically (the resume sweep owns the five-hour window only)' \
      "${FM_LIMIT_PARK_RESETS_AT:+ until $(fm_limit_park_fmt_epoch "$FM_LIMIT_PARK_RESETS_AT")}"
  elif [ -n "$FM_LIMIT_PARK_RESETS_AT" ]; then
    printf 'parked on the Claude usage limit until %s, resumes automatically after the reset' \
      "$(fm_limit_park_fmt_epoch "$FM_LIMIT_PARK_RESETS_AT")"
  else
    printf 'parked on the Claude usage limit (reset time unknown; quota-axi is rechecked before the automatic resume)'
  fi
}

# --- resumed marker ----------------------------------------------------------

# shellcheck disable=SC2034 # Read by bin/fm-limit-resume.sh and its tests.
FM_LIMIT_RESUMED_EPISODE=
# shellcheck disable=SC2034
FM_LIMIT_RESUMED_RESETS_AT=
# shellcheck disable=SC2034
FM_LIMIT_RESUMED_SENT_AT=
# shellcheck disable=SC2034 # Sets the FM_LIMIT_RESUMED_* result variables for callers.
fm_limit_park_resumed_read() {  # <state> <id>
  local path line
  FM_LIMIT_RESUMED_EPISODE=
  FM_LIMIT_RESUMED_RESETS_AT=
  FM_LIMIT_RESUMED_SENT_AT=
  path=$(fm_limit_park_resumed_path "$1" "$2")
  [ -f "$path" ] || return 1
  IFS= read -r line < "$path" || return 1
  FM_LIMIT_RESUMED_EPISODE=$(printf '%s' "$line" | sed -n 's/.*episode=\([0-9]*\).*/\1/p')
  FM_LIMIT_RESUMED_RESETS_AT=$(printf '%s' "$line" | sed -n 's/.*resets_at=\([0-9]*\).*/\1/p')
  FM_LIMIT_RESUMED_SENT_AT=$(printf '%s' "$line" | sed -n 's/.*sent_at=\([0-9]*\).*/\1/p')
  [ -n "$FM_LIMIT_RESUMED_EPISODE" ]
}

fm_limit_park_resumed_write() {  # <state> <id> <episode> <resets_at|>
  local path tmp
  path=$(fm_limit_park_resumed_path "$1" "$2")
  tmp=$(mktemp "$path.tmp.XXXXXX") || return 1
  printf 'episode=%s resets_at=%s sent_at=%s\n' "$3" "${4-}" "$(fm_limit_park_now)" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_limit_park_resumed_clear() {  # <state> <id>
  rm -f "$(fm_limit_park_resumed_path "$1" "$2")"
}

# fm_limit_park_already_resumed <state> <id>: 0 when the current record's
# episode already received its one resume steer.
fm_limit_park_already_resumed() {  # <state> <id>
  fm_limit_park_read "$1" "$2" || return 1
  fm_limit_park_resumed_read "$1" "$2" || return 1
  [ "$FM_LIMIT_RESUMED_EPISODE" = "$FM_LIMIT_PARK_EPISODE" ]
}

# The one resume instruction every parked worker receives.
fm_limit_park_resume_text() {
  # shellcheck disable=SC2016 # The backticks are literal Markdown for the worker.
  printf '%s' 'The Claude usage window has reset (automatic resume, no captain present). If a no-mistakes run exists for your branch, read `no-mistakes axi status` FIRST and drive from its current gate or outcome; never restart the run or start a second one while it owns the branch. If no run exists, continue your brief from where you stopped. Append your normal status line when you reach the next gate or outcome.'
}

# --- outage record -----------------------------------------------------------

FM_LIMIT_OUTAGE_FROM=
FM_LIMIT_OUTAGE_UNTIL=
FM_LIMIT_OUTAGE_OBSERVED_AT=
# shellcheck disable=SC2034 # Read by the resume owner's status output.
FM_LIMIT_OUTAGE_SOURCE=
# shellcheck disable=SC2034 # Sets the FM_LIMIT_OUTAGE_* result variables for callers.
fm_limit_park_outage_read() {  # <state>
  local path line
  FM_LIMIT_OUTAGE_FROM=
  FM_LIMIT_OUTAGE_UNTIL=
  FM_LIMIT_OUTAGE_OBSERVED_AT=
  FM_LIMIT_OUTAGE_SOURCE=
  path=$(fm_limit_park_outage_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r line < "$path" || return 1
  FM_LIMIT_OUTAGE_FROM=$(printf '%s' "$line" | sed -n 's/.*from=\([0-9]*\).*/\1/p')
  FM_LIMIT_OUTAGE_UNTIL=$(printf '%s' "$line" | sed -n 's/.*until=\([0-9]*\).*/\1/p')
  FM_LIMIT_OUTAGE_OBSERVED_AT=$(printf '%s' "$line" | sed -n 's/.*observed_at=\([0-9]*\).*/\1/p')
  FM_LIMIT_OUTAGE_SOURCE=$(printf '%s' "$line" | sed -n 's/.*source=\([^ ]*\).*/\1/p')
  [ -n "$FM_LIMIT_OUTAGE_FROM" ]
}

# fm_limit_park_outage_write <state> <from> <until|> <source>
# Create-or-extend: an existing record keeps its earlier `from` and takes the
# later `until`, so one long park is one outage, not a fresh one per sweep.
fm_limit_park_outage_write() {  # <state> <from> <until|> <source>
  local state=$1 from=$2 until=${3-} source=$4 path tmp
  path=$(fm_limit_park_outage_path "$state")
  if fm_limit_park_outage_read "$state"; then
    [ -n "$FM_LIMIT_OUTAGE_FROM" ] && [ "$FM_LIMIT_OUTAGE_FROM" -lt "$from" ] && from=$FM_LIMIT_OUTAGE_FROM
    if [ -n "$FM_LIMIT_OUTAGE_UNTIL" ] && { [ -z "$until" ] || [ "$FM_LIMIT_OUTAGE_UNTIL" -gt "$until" ]; }; then
      until=$FM_LIMIT_OUTAGE_UNTIL
    fi
  fi
  tmp=$(mktemp "$path.tmp.XXXXXX") || return 1
  printf 'from=%s until=%s observed_at=%s source=%s\n' "$from" "$until" "$(fm_limit_park_now)" "$source" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_limit_park_outage_clear() {  # <state>
  rm -f "$(fm_limit_park_outage_path "$1")"
}

# fm_limit_park_outage_current <state>: 0 while a recorded park explains a stale
# beacon right now - the record exists and `until` plus the grace has not passed
# (a record with no `until` stays current for one grace from its observation).
fm_limit_park_outage_current() {  # <state>
  local now horizon
  fm_limit_park_outage_read "$1" || return 1
  now=$(fm_limit_park_now)
  if [ -n "$FM_LIMIT_OUTAGE_UNTIL" ]; then
    horizon=$((FM_LIMIT_OUTAGE_UNTIL + FM_LIMIT_OUTAGE_GRACE_SECS))
  else
    horizon=$((${FM_LIMIT_OUTAGE_OBSERVED_AT:-$FM_LIMIT_OUTAGE_FROM} + FM_LIMIT_OUTAGE_GRACE_SECS))
  fi
  [ "$now" -le "$horizon" ]
}

# fm_limit_park_outage_describe <state> -> "parked on the Claude usage limit from X to Y"
fm_limit_park_outage_describe() {  # <state>
  fm_limit_park_outage_read "$1" || return 1
  if [ -n "$FM_LIMIT_OUTAGE_UNTIL" ]; then
    printf 'parked on the Claude usage limit from %s to %s' \
      "$(fm_limit_park_fmt_epoch "$FM_LIMIT_OUTAGE_FROM")" "$(fm_limit_park_fmt_epoch "$FM_LIMIT_OUTAGE_UNTIL")"
  else
    printf 'parked on the Claude usage limit since %s (reset time unknown)' \
      "$(fm_limit_park_fmt_epoch "$FM_LIMIT_OUTAGE_FROM")"
  fi
}

# --- primary pane record -----------------------------------------------------

FM_LIMIT_PRIMARY_BACKEND=
FM_LIMIT_PRIMARY_TARGET=
# shellcheck disable=SC2034 # Read by bin/fm-limit-resume.sh.
FM_LIMIT_PRIMARY_HARNESS=
# shellcheck disable=SC2034
FM_LIMIT_PRIMARY_LOCK_PID=
# shellcheck disable=SC2034 # Sets the FM_LIMIT_PRIMARY_* result variables for callers.
fm_limit_park_primary_read() {  # <state>
  local path
  FM_LIMIT_PRIMARY_BACKEND=
  FM_LIMIT_PRIMARY_TARGET=
  FM_LIMIT_PRIMARY_HARNESS=
  FM_LIMIT_PRIMARY_LOCK_PID=
  path=$(fm_limit_park_primary_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS=$'\t' read -r FM_LIMIT_PRIMARY_BACKEND FM_LIMIT_PRIMARY_TARGET FM_LIMIT_PRIMARY_HARNESS FM_LIMIT_PRIMARY_LOCK_PID < "$path" || return 1
  [ -n "$FM_LIMIT_PRIMARY_BACKEND" ] && [ -n "$FM_LIMIT_PRIMARY_TARGET" ]
}

fm_limit_park_primary_write() {  # <state> <backend> <target> <harness> <lock-pid>
  local path tmp
  path=$(fm_limit_park_primary_path "$1")
  tmp=$(mktemp "$path.tmp.XXXXXX") || return 1
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_limit_park_primary_clear() {  # <state>
  rm -f "$(fm_limit_park_primary_path "$1")"
}
