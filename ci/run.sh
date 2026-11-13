#!/usr/bin/env bash
# Runs inside the emulator job. Never exits non-zero itself: summary.txt has a
# PASS / FAIL line per check, the rest of OUT is detail (sealed before upload).
set -u
APK=$1; OUT=$2
PKG=com.photoslocked.app
FLOWS="$(pwd)/ci/flows"
mkdir -p "$OUT/shots" "$OUT/ui"
: > "$OUT/summary.txt"
log() { echo "$(date +%T) $*" | tee -a "$OUT/steps.txt"; }
res() { echo "$1 $2${3:+  ($3)}" | tee -a "$OUT/summary.txt"; }
shot() { adb exec-out screencap -p > "$OUT/shots/$1.png" 2>/dev/null; }
dump() { # name -> prints the UI hierarchy (also kept)
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  adb shell cat /sdcard/ui.xml > "$OUT/ui/$1.xml" 2>/dev/null
  cat "$OUT/ui/$1.xml"
}
# bounds of the first node whose content-desc or text is exactly $2, from dump $1
bounds() {
  python3 - "$OUT/ui/$1.xml" "$2" <<'PY'
import re, sys
x = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
for n in re.findall(r'<node [^>]*>', x):
    if f'content-desc="{sys.argv[2]}"' in n or f'text="{sys.argv[2]}"' in n:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        print(*b.groups()); break
PY
}
count_text() { grep -o "text=\"$2\"" "$OUT/ui/$1.xml" 2>/dev/null | wc -l; }
flow() { # name file -> 0 on pass
  (cd "$OUT/shots" && maestro test --debug-output "$OUT/maestro-$1" "$FLOWS/$2") > "$OUT/maestro-$1.txt" 2>&1
  local rc=$?
  log "maestro $1 exit $rc"
  return $rc
}
alive() { adb shell pidof $PKG >/dev/null 2>&1; }

adb wait-for-device
log "sdk $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
log "install: $(adb install -r "$APK" 2>&1 | tail -1)"
adb logcat -c
adb logcat -b main,system,crash -v threadtime > "$OUT/logcat.txt" 2>&1 &
LOGPID=$!

# 1. First run: onboarding (shot twice, 1.2 s apart), passcode, welcome.
if flow setup setup.yaml; then res PASS "first run: onboarding, passcode, welcome to Albums"; else res FAIL "first run" "see maestro-setup.txt"; fi

# 2. The + button's top half (it used to stand outside the tab bar's bounds,
#    where Android dropped the touch). Three taps on its top edge.
dump main0 > /dev/null
B=$(bounds main0 Add)
if [ -n "$B" ]; then
  read X1 Y1 X2 Y2 <<< "$B"; CX=$(( (X1 + X2) / 2 )); TY=$(( Y1 + (Y2 - Y1) / 6 ))
  ok=0
  for i in 1 2 3; do
    adb shell input tap $CX $TY; sleep 1.2
    dump "dial_top_$i" | grep -q 'Import Photos' && ok=$((ok + 1))
    [ $i = 1 ] && shot s06_dial_from_top_half
    adb shell input keyevent 4; sleep 1
  done
  [ $ok = 3 ] && res PASS "+ top half opens the menu 3/3" "tap at $CX,$TY of [$X1,$Y1][$X2,$Y2]" || res FAIL "+ top half opens the menu $ok/3" "tap at $CX,$TY"
  # Response time: one shot 300 ms after a tap on the centre.
  adb shell input tap $CX $(( (Y1 + Y2) / 2 )); sleep 0.3; shot s07_dial_300ms; sleep 1; adb shell input keyevent 4; sleep 1
else
  res FAIL "+ button not found on Albums" "see ui/main0.xml"
fi

# 3. More → New Album → Create tapped twice: one album.
if flow album album.yaml; then
  dump albums1 > /dev/null
  n=$(count_text albums1 Trip)
  [ "$n" = 1 ] && res PASS "More → New Album → Create x2 makes 1 album" || res FAIL "Create x2 made $n albums named Trip"
else
  res FAIL "More → New Album flow" "see maestro-album.txt"
fi

# 4. Import Photos x2 → picker once → back → + still works.
if flow import import.yaml; then res PASS "Import Photos x2 → picker, back, + works again"; else res FAIL "Import Photos flow" "see maestro-import.txt"; fi

# 5. Camera → deny → our dialog → Not Now x2 → + still works.
if flow camera camera.yaml; then res PASS "Camera denied → our dialog → Not Now x2 → + works again"; else res FAIL "Camera / dialog flow" "see maestro-camera.txt"; fi

# 5b. A real import: put a picture on the device, pick it through the + menu.
adb shell screencap -p /sdcard/Pictures/pl_test_1.png
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/pl_test_1.png >/dev/null 2>&1
sleep 2
if flow import_photo import_photo.yaml; then
  sleep 2; dump after_import > /dev/null
  grep -qE 'text="1 item|1 item' "$OUT/ui/after_import.xml" && res PASS "imported 1 photo through + → Import Photos" || res INFO "photo picked; check s51-s53 shots for the vault count"
else
  res FAIL "import a real photo" "see maestro-import_photo.txt"
fi
alive || { res FAIL "app died after import"; adb shell monkey -p $PKG 1 >/dev/null 2>&1; sleep 4; }

# 6. Spam the + six times, then it must still open and run an action.
dump main1 > /dev/null
B=$(bounds main1 Add)
if [ -n "$B" ]; then
  read X1 Y1 X2 Y2 <<< "$B"; CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  for i in 1 2 3 4 5 6; do adb shell input tap $CX $CY; sleep 0.09; done
  sleep 1.5; shot s40_after_spam
fi
if flow after_spam after_spam.yaml; then res PASS "after 6 fast + taps, menu + Import still work"; else res FAIL "after + spam" "see maestro-after_spam.txt"; fi

# 7. Crashes / ANRs during the whole run.
sleep 2
alive && log "app alive at end" || log "app NOT running at end"
kill $LOGPID 2>/dev/null
crashes=$(grep -c "FATAL EXCEPTION" "$OUT/logcat.txt" 2>/dev/null)
anrs=$(grep -c "ANR in $PKG" "$OUT/logcat.txt" 2>/dev/null)
[ "${crashes:-0}" = 0 ] && [ "${anrs:-0}" = 0 ] && res PASS "no crash, no ANR in logcat" || res FAIL "crashes $crashes, ANRs $anrs"
find "$HOME/.maestro/tests" -name '*.png' -exec cp {} "$OUT/shots/" \; 2>/dev/null
exit 0
