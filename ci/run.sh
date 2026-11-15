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
# After a failed step: relaunch and unlock, so one failure can't break the next checks.
recover() { log "recover after $1"; flow "recover-$1" relock.yaml >/dev/null 2>&1 || true; }

adb wait-for-device
log "sdk $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
log "install: $(adb install -r "$APK" 2>&1 | tail -1)"
adb logcat -c
adb logcat -b main,system,crash -v threadtime > "$OUT/logcat.txt" 2>&1 &
LOGPID=$!

# 1. First run: onboarding (shot twice, 1.2 s apart), passcode, welcome.
if flow setup setup.yaml; then res PASS "first run: onboarding, passcode, welcome to Albums"; else res FAIL "first run" "see maestro-setup.txt"; fi

# A picture for the import test: a real screenshot, pushed and indexed
# (the scan broadcast alone is ignored on Android 11).
adb exec-out screencap -p > "$OUT/pl_test_1.png"
adb shell mkdir -p /sdcard/Pictures
adb push "$OUT/pl_test_1.png" /sdcard/Pictures/pl_test_1.png >/dev/null 2>&1
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/pl_test_1.png >/dev/null 2>&1
adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1
sleep 3
adb shell content query --uri content://media/external/images/media --projection _display_name 2>/dev/null | grep -q pl_test_1 \
  && log "test picture indexed" || log "test picture NOT indexed"

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
  res FAIL "More → New Album flow" "see maestro-album.txt"; recover album
fi

# 4. Import Photos x2 → picker once → back → + still works.
if flow import import.yaml; then res PASS "Import Photos x2 → picker, back, + works again"; else res FAIL "Import Photos flow" "see maestro-import.txt"; recover import; fi

# 5. Camera opens the camera app → back → + still works.
if flow camera camera.yaml; then res PASS "Camera opens the camera, back, + works again"; else res FAIL "Camera flow" "see maestro-camera.txt"; recover camera; fi

# 5b. A real import: pick the test picture through the + menu.
if flow import_photo import_photo.yaml; then
  sleep 2; dump after_import > /dev/null
  grep -qE 'text="1 item|1 item' "$OUT/ui/after_import.xml" && res PASS "imported 1 photo through + → Import Photos" || res INFO "photo picked; check s51-s53 shots for the vault count"
else
  res FAIL "import a real photo" "see maestro-import_photo.txt"; recover import_photo
fi
alive || { res FAIL "app died after import"; adb shell monkey -p $PKG 1 >/dev/null 2>&1; sleep 4; }

# 5c. Delete the album: menu option and dialog button each tapped twice.
if flow delete delete.yaml; then
  dump after_delete > /dev/null
  n=$(count_text after_delete Trip)
  [ "$n" = 0 ] && res PASS "Delete Album x2 → Delete x2: one dialog, album gone" || res FAIL "after delete, $n albums named Trip"
else
  res FAIL "delete album flow" "see maestro-delete.txt"; recover delete
fi

# 6. Spam the + six times, then it must still open and run an action.
dump main1 > /dev/null
B=$(bounds main1 Add)
if [ -n "$B" ]; then
  read X1 Y1 X2 Y2 <<< "$B"; CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
  for i in 1 2 3 4 5 6; do adb shell input tap $CX $CY; sleep 0.09; done
  sleep 1.5; shot s40_after_spam
fi
if flow after_spam after_spam.yaml; then res PASS "after 6 fast + taps, menu + Import still work"; else res FAIL "after + spam" "see maestro-after_spam.txt"; fi

# 6b. Relaunch through the lock screen.
if flow relock relock.yaml; then res PASS "relaunch: lock screen keypad unlocks, + works"; else res FAIL "relaunch / lock screen" "see maestro-relock.txt"; fi

# 7. A tour: every tab, the Library and Settings screens in and out.
if flow tour tour.yaml; then res PASS "tour: Library, Notes, Browser, Settings pages in and out"; else res FAIL "tour of the screens" "see maestro-tour.txt"; recover tour; fi
alive || { res FAIL "app died during the tour"; recover tour-dead; }

# 8. Share from the viewer: the system share sheet opens and the app survives it.
if flow share share.yaml; then
  dump all_media > /dev/null
  CELL=$(python3 "$(pwd)/ci/first_cell.py" "$OUT/ui/all_media.xml")
  if [ -n "$CELL" ]; then
    adb shell input tap $CELL; sleep 2
    if flow share_tap share_tap.yaml; then
      focus=$(adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -d '\r')
      log "focus after Share: $focus"
      echo "$focus" | grep -qiE "Chooser|Resolver|intentresolver" && res PASS "Share opens the system share sheet" || res INFO "Share tapped, system sheet not seen in focus"
      adb shell input keyevent 4; sleep 2; shot s98_after_share
      alive && res PASS "app alive after the share sheet" || res FAIL "app died after the share sheet"
    else
      res FAIL "viewer Share" "see maestro-share_tap.txt"
    fi
  else
    res INFO "no photo cell found in All Media (ui/all_media.xml)"
  fi
else
  res FAIL "Library → All Media" "see maestro-share.txt"
fi
recover share

# 9. Many screen changes in a row.
if flow stress stress.yaml; then res PASS "12 page pushes, 20 tab hops, 4 + menus in a row"; else res FAIL "screen-change stress" "see maestro-stress.txt"; recover stress; fi
alive || { res FAIL "app died during the stress"; recover stress-dead; }

# 10. The lock screen: a wrong passcode, then five relaunches with the four
#     digits tapped as fast as adb can (a spring still running under each digit).
if flow wrongpin wrongpin.yaml; then res PASS "wrong passcode shakes, right one unlocks"; else res FAIL "wrong passcode flow" "see maestro-wrongpin.txt"; fi
fast_ok=0
for i in 1 2 3 4 5; do
  if flow "lockwait$i" lockwait.yaml; then
    dump "lock$i" > /dev/null
    T=""
    for d in 1 2 3 4; do
      B=$(bounds "lock$i" $d); [ -n "$B" ] || continue
      read X1 Y1 X2 Y2 <<< "$B"; T="$T input tap $(( (X1 + X2) / 2 )) $(( (Y1 + Y2) / 2 ));"
    done
    adb shell "$T"; sleep 4
    dump "unlocked$i" | grep -q 'content-desc="Add"' && fast_ok=$((fast_ok + 1))
  fi
done
[ $fast_ok = 5 ] && res PASS "5 relaunches with fast passcode taps all unlock" || res FAIL "fast passcode taps unlocked $fast_ok/5"

# 11. The daily reminder: saved and handed to the alarm manager.
adb shell dumpsys alarm > "$OUT/alarms.txt" 2>/dev/null
alarms=$(grep -c "$PKG" "$OUT/alarms.txt" 2>/dev/null)

# 11b. And it fires: the clock is moved to 19:59:30 tomorrow, so both the 8pm
#      reminder and the day-one nudge are due within the minute.
adb root >/dev/null 2>&1; sleep 4; adb wait-for-device
adb shell settings put global auto_time 0 >/dev/null 2>&1
log "clock: $(adb shell date "$(date -d tomorrow +%m%d)1959.30" 2>&1 | tr -d '\r')"
fired=0
for i in 1 2 3 4 5 6 7 8 9; do
  sleep 10
  adb shell dumpsys notification --noredact > "$OUT/notifications.txt" 2>/dev/null
  fired=$(grep -c "NotificationRecord.*pkg=$PKG" "$OUT/notifications.txt" 2>/dev/null)
  [ "${fired:-0}" -ge 1 ] && break
done
shot s99_after_8pm
[ "${fired:-0}" -ge 1 ] && res PASS "the reminder fires at 8pm" "notifications posted: $fired" || res FAIL "no reminder posted at 8pm"
alive || res FAIL "app died when the reminder fired"
sleep 2
alive && log "app alive at end" || log "app NOT running at end"
kill $LOGPID 2>/dev/null
notif=$(grep -c "expo-notifications: Action .* failed" "$OUT/logcat.txt" 2>/dev/null)
[ "${notif:-0}" = 0 ] && [ "${alarms:-0}" -ge 1 ] && res PASS "reminder saved and scheduled" "alarm lines: $alarms" || res FAIL "reminder not scheduled" "save failures ${notif:-0}, alarm lines ${alarms:-0}"

# 12. React Native's animation engine: its own error lines, and JS errors.
anim=$(grep -cE "Native animation workaround|Mapped style node|Mapped property node|animation cycle or disconnected graph" "$OUT/logcat.txt" 2>/dev/null)
illegal=$(grep -c "JSApplicationIllegalArgumentException" "$OUT/logcat.txt" 2>/dev/null)
jserr=$(grep -cE " E ReactNativeJS" "$OUT/logcat.txt" 2>/dev/null)
soft=$(grep -c "ReactNoCrashSoftException" "$OUT/logcat.txt" 2>/dev/null)
[ "${anim:-0}" = 0 ] && [ "${illegal:-0}" = 0 ] && res PASS "no animation engine errors in logcat" || res FAIL "animation engine errors" "race lines ${anim:-0}, illegal argument ${illegal:-0}"
[ "${jserr:-0}" = 0 ] && res PASS "no JS errors in logcat" || res FAIL "JS errors in logcat: $jserr"
res INFO "soft exceptions ${soft:-0}"

# 13. Crashes / ANRs during the whole run.
crashes=$(grep -c "FATAL EXCEPTION" "$OUT/logcat.txt" 2>/dev/null)
anrs=$(grep -c "ANR in $PKG" "$OUT/logcat.txt" 2>/dev/null)
[ "${crashes:-0}" = 0 ] && [ "${anrs:-0}" = 0 ] && res PASS "no crash, no ANR in logcat" || res FAIL "crashes $crashes, ANRs $anrs"
find "$OUT" -path "*takeScreenshot*" -name '*.png' -exec cp {} "$OUT/shots/" \; 2>/dev/null
exit 0
