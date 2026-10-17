#!/usr/bin/env bash
# Start the Android 15 (x86_64) VM used for TikTok.
#
# Default: HEADLESS emulator + host GPU, viewed with scrcpy (view-vm.sh).
#   This is the fastest AND most stable combination measured on this box:
#   11-13% janky frames, 60 fps median. The emulator's own window uses a
#   display-surface GL context that gfxstream loses on NVIDIA 595 -> corrupted
#   frames and occasional SIGSEGV; headless + scrcpy avoids it entirely.
#
# Usage:  ./start-android.sh            # headless (view with ./view-vm.sh)
#         ./start-android.sh -windowed  # use the emulator's own window
#         GPU_MODE=swangle ./start-android.sh   # software renderer fallback (~30 fps)
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-vm/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_AVD_HOME="$HOME/.android/avd"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# The emulator's PulseAudio backend is flaky: it can fail with
# "Could not init `pa' audio driver / Failed to initialize PA context",
# leaving the guest playing into a dead output (silence, no host stream).
# Naming the socket explicitly makes it connect reliably.
export PULSE_SERVER="${PULSE_SERVER:-unix:${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native}"
# QEMU audio backend. The emulator's own default can fail to initialise
# ("Could not init `pa' audio driver") and then the guest plays into silence.
# Override with QEMU_AUDIO_DRV=alsa to bypass PulseAudio, or =pa to force it.
export QEMU_AUDIO_DRV="${QEMU_AUDIO_DRV:-pa}"

AVD="${AVD_NAME:-tiktok35}"
GPU="${GPU_MODE:-host}"                 # host = NVIDIA accel; swangle = software
CORES="${CORES:-6}"                     # emulator caps at 6 (>6 is silently clamped)
NO_WINDOW="-no-window"
[ "${1:-}" = "-windowed" ] && NO_WINDOW=""

if adb devices | grep -q emulator-5554; then
  echo "emulator already running (view with ./view-vm.sh)"; exit 0
fi

cd "$ANDROID_HOME/emulator"
exec ./emulator -avd "$AVD" \
  -gpu "$GPU" -accel on $NO_WINDOW \
  -cores "$CORES" -memory "${VM_RAM:-6144}" \
  -no-boot-anim -no-metrics \
  -feature -HardwareDecoder \
  -camera-back none -camera-front none \
  -netdelay none -netspeed full
