#!/usr/bin/env bash
# Open the visible window (and sound) for the headless Android VM.
#
# Why scrcpy instead of the emulator's own window:
#  * the emulator's windowed GL path loses its display-surface context on this
#    NVIDIA driver -> corrupted frames + SIGSEGV (exit 139);
#  * the emulator only initialises its own audio backend when it HAS a window,
#    so in headless mode it is silent.
# scrcpy 5 mirrors the guest and forwards the guest's audio to the host sink,
# which gives a smooth, stable AND audible setup.
set -euo pipefail

SCRCPY="$HOME/android-vm/scrcpy-linux-x86_64-v5.0.1/scrcpy"
export PATH="$HOME/android-vm/sdk/platform-tools:$PATH"

if ! adb devices | grep -q 'emulator-5554.*device$'; then
  echo "VM not running - start it first: ~/android-vm/start-android.sh"; exit 1
fi

[ -x "$SCRCPY" ] || { echo "scrcpy 5 not found at $SCRCPY"; exit 1; }

exec "$SCRCPY" \
  --window-title "TikTok VM" \
  --max-size 720 --video-bit-rate 8M \
  --audio-source=playback --audio-buffer=100 \
  --stay-awake "$@"
