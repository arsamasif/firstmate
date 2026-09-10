#!/usr/bin/env bash
# Manual end-to-end demo: arm the usage-limit resume sweep on a host with no
# user systemd bus and an 8 KB WSL-style PATH, first with the BASE script
# (2cf6d0f) and then with the fixed script (3afced7). Fake crontab keeps
# cron's real 1000-byte line limit; fake systemctl has no user bus; fake
# loginctl reports lingering off. Nothing touches the real crontab or systemd.
set -u
WT=$1; BASE=$2
T=$(mktemp -d /tmp/fm-limit-resume-demo.XXXXXX)
mkdir -p "$T/home/state" "$T/home/config" "$T/home/data" "$T/fakebin" "$T/before-bin"
cp -r "$WT/bin/." "$T/before-bin/"
git -C "$WT" show "$BASE:bin/fm-limit-resume.sh" > "$T/before-bin/fm-limit-resume.sh"
chmod +x "$T/before-bin/fm-limit-resume.sh"
cat > "$T/fakebin/crontab" <<'SH'
#!/usr/bin/env bash
set -u
f=${FM_FAKE_CRONTAB_FILE:?}
case "${1:-}" in
  -l) [ -s "$f" ] || exit 1; cat "$f" ;;
  -r) : > "$f" ;;
  -)
    new=$(cat); n=0
    while IFS= read -r l; do
      n=$((n + 1))
      if [ "${#l}" -gt 1000 ]; then
        printf '"-":%s: command too long\nerrors in crontab file, can'"'"'t install.\n' "$n" >&2; exit 1
      fi
    done <<< "$new"
    printf '%s\n' "$new" > "$f" ;;
esac
SH
cat > "$T/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in *is-system-running*) echo 'Failed to connect to bus: No medium found' >&2; exit 1 ;; esac
exit 0
SH
cat > "$T/fakebin/loginctl" <<'SH'
#!/usr/bin/env bash
echo no
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/quota-axi"
chmod +x "$T"/fakebin/*
synthetic=''; i=0
while [ "${#synthetic}" -le 8192 ]; do i=$((i+1)); synthetic="$synthetic/mnt/c/Program Files/Vendor Number $i/Some Product/bin:"; done
BIGPATH="$T/fakebin:$synthetic$PATH"
run() { # <bin-dir> <args...>
  local b=$1; shift
  env PATH="$BIGPATH" FM_ROOT_OVERRIDE="$T/home" FM_HOME="$T/home" FM_FAKE_CRONTAB_FILE="$T/crontab.txt" \
    XDG_RUNTIME_DIR="$T/no-runtime" XDG_CONFIG_HOME="$T/xdg" "$b/fm-limit-resume.sh" "$@"
  echo "[exit $?]"
}
echo "== host PATH handed to install: ${#BIGPATH} bytes, no user bus (XDG_RUNTIME_DIR=$T/no-runtime absent), lingering off"
echo
echo "== BEFORE (base $BASE): bin/fm-limit-resume.sh install"
run "$T/before-bin" install
echo "-- crontab after BEFORE install:"; cat "$T/crontab.txt" 2>/dev/null || echo "(empty: nothing armed)"
echo
echo "== AFTER (fixed): bin/fm-limit-resume.sh install"
run "$WT/bin" install
echo "-- crontab after AFTER install:"; cat "$T/crontab.txt"
line=$(grep firstmate-limit-resume "$T/crontab.txt"); echo "-- entry length: $(printf '%s' "$line" | wc -c) bytes"
echo
echo "== AFTER: bin/fm-limit-resume.sh status"
run "$WT/bin" status
echo
echo "== AFTER: install again (idempotent re-install)"
run "$WT/bin" install
echo "-- tagged entries in crontab: $(grep -c firstmate-limit-resume "$T/crontab.txt")"
echo
echo "== AFTER: uninstall, then status"
run "$WT/bin" uninstall
echo "-- tagged entries in crontab: $(grep -c firstmate-limit-resume "$T/crontab.txt")"
run "$WT/bin" status
rm -rf "$T"
