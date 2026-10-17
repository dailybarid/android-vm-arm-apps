#!/usr/bin/env bash
# Does forcing software video decode remove the glitch signature?
# Baseline (already measured): goldfish decoder -> ~44-51 decoder-path errors/run.
set -uo pipefail
export ANDROID_HOME="$HOME/android-vm/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

adb emu kill >/dev/null 2>&1; sleep 6
LOG=/tmp/emu-swdecode.log; rm -f "$LOG"

( cd "$ANDROID_HOME/emulator" && \
  ./emulator -avd tiktok35 -gpu host -accel on -no-window \
    -cores 6 -memory 6144 -no-boot-anim -no-metrics \
    -feature -HardwareDecoder \
    -camera-back none -camera-front none -netdelay none -netspeed full >"$LOG" 2>&1 ) &

for i in $(seq 1 20); do sleep 6; adb devices | grep -q 'emulator-5554.*device$' && break; done
sleep 8
adb logcat -c
adb shell am start -n com.zhiliaoapp.musically/com.ss.android.ugc.aweme.splash.SplashActivity >/dev/null 2>&1
sleep 32
adb shell input tap 360 640; sleep 2
for i in $(seq 1 6); do adb shell input swipe 360 1000 360 300 220; sleep 4; done

echo "### headless + software decode (-HardwareDecoder)"
echo "null-ctx errors: $(grep -c 'error null ctx' "$LOG")"
echo "guest decoder-path errors: $(adb logcat -d 2>/dev/null | grep -cE 'discarded an unknown buffer|failed to set consumer usage|EGL_BAD_ATTRIBUTE')"
echo "decoders: $(adb logcat -d 2>/dev/null | grep -oE 'c2\.[a-z0-9._]+decoder' | sort | uniq -c | tr '\n' ' ')"
adb shell dumpsys gfxinfo com.zhiliaoapp.musically | grep -E 'Janky frames:|50th percentile' | sed 's/^/  /'
echo "  app pid: $(adb shell pidof com.zhiliaoapp.musically)"
adb exec-out screencap -p > $HOME/android-vm/decode-test.png
echo "  screenshot: $HOME/android-vm/decode-test.png ($(stat -c%s $HOME/android-vm/decode-test.png) bytes)"
echo "DONE"
