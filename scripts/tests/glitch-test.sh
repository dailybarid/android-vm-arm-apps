#!/usr/bin/env bash
# A/B test: which guest renderer path survives the glitchy host GL translator.
# Runs the same interaction on two renderers and counts the error signatures
# from the emulator's own stdout. Nothing is changed permanently.
set -uo pipefail
export ANDROID_HOME="$HOME/android-vm/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

run_case () {
  local renderer="$1" log="/tmp/emu-glitch-$1.log"
  adb emu kill >/dev/null 2>&1; sleep 6
  rm -f "$log"
  ( cd "$ANDROID_HOME/emulator" && \
    ./emulator -avd tiktok35 -gpu host -accel on -no-window \
      -cores 6 -memory 6144 -no-boot-anim -no-metrics \
      -prop "debug.hwui.renderer=$renderer" \
      -camera-back none -camera-front none -netdelay none -netspeed full >"$log" 2>&1 ) &
  for i in $(seq 1 20); do sleep 6; adb devices | grep -q 'emulator-5554.*device$' && break; done
  sleep 8
  local actual; actual=$(adb shell getprop debug.hwui.renderer | tr -d '\r')
  adb shell am start -n com.zhiliaoapp.musically/com.ss.android.ugc.aweme.splash.SplashActivity >/dev/null 2>&1
  sleep 30
  adb shell input tap 360 640; sleep 2
  for i in $(seq 1 6); do adb shell input swipe 360 1000 360 300 220; sleep 4; done
  echo "### renderer=$renderer (property in guest: '$actual')"
  echo "null-ctx errors: $(grep -c 'error null ctx' "$log")"
  echo "bad color buffers: $(grep -c 'bad color buffer' "$log")"
  echo "guest decoder-path errors: $(adb logcat -d 2>/dev/null | grep -cE 'discarded an unknown buffer|failed to set consumer usage|EGL_BAD_ATTRIBUTE')"
  echo "decoders: $(adb logcat -d 2>/dev/null | grep -oE 'c2\.[a-z0-9._]+decoder' | sort | uniq -c | tr '\n' ' ')"
  adb shell dumpsys gfxinfo com.zhiliaoapp.musically | grep -E 'Janky frames:|50th percentile' | sed 's/^/  /'
  adb shell pidof com.zhiliaoapp.musically | sed 's/^/  app pid: /'
  echo
}

run_case skiagl
run_case skiavk
echo "DONE"
