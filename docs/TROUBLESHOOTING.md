# Troubleshooting — symptom → check → fix

## The app closes and returns to the Android home screen
**Check**
```bash
adb shell dumpsys activity exit-info com.zhiliaoapp.musically | grep reason
```
**Fix**
- `reason=3 (LOW_MEMORY)` — the guest is starved. Give it 6–8 GB
  (`VM_RAM=8192 ./start-android.sh`, or `hw.ramSize` in `config.ini`) and give the host swap.
  4 GB is measurably not enough.
- `reason=5 (APP CRASH(NATIVE))` with the backtrace inside `libndk_translation.so` — translator
  defect. Try a different system-image level; no host flag fixes it.

## The app never starts (dies within seconds)
**Check** `adb logcat -d | grep -E 'guest_call_arm64|CHECK failed'`
**Fix** You are on an Android 11 (API 30) image. Move to API 35 (`google_apis_playstore`, x86_64).

## Video is blocky / torn / smeared
**Check, one source at a time**
```bash
adb logcat -c            # clean window, then interact
grep -c 'error null ctx' <emulator stdout>        # host GL context loss
adb logcat -d | grep -cE 'discarded an unknown buffer|failed to set consumer usage|EGL_BAD_ATTRIBUTE'
adb logcat -d | grep -oE 'c2\.[a-z0-9._]+decoder' | sort | uniq -c
```
**Fix**
- `null ctx` / `bad color buffer handle` → run headless (`-no-window`) and view with scrcpy.
  Do not use the emulator's own window; do not go above 720p with `-gpu host`.
- `c2.goldfish.*.decoder` + discarded-buffer errors → launch with `-feature -HardwareDecoder`.
  The app falls back to its own software decoder and the errors go to zero.

## No sound
**Check**
```bash
pactl list sink-inputs | grep -A1 application.name     # expect: scrcpy
grep -c "Could not init .pa. audio driver" <emulator stdout>
adb shell dumpsys media.audio_flinger | grep Standby   # guest tracks can be active yet silent
```
**Fix** The emulator only initialises its audio backend when it has a window, and its window is what
breaks the GPU path. Keep the emulator headless and use scrcpy 5 with
`--audio-source=playback`. The apt scrcpy (1.25) has no audio support — use the static release.

## Loud burst of noise, then silence
Same cause as the glitches: the audio buffer floods/underruns when the video pipeline stalls.
Fix the video path first (see above).

## Emulator exits 139 / window vanishes
**Check** the last lines of the emulator's stdout: `context was preempted`, `error null ctx`, or
libunwind spam.
**Fix** headless + `-gpu host` at 720p. If you need a window, `-gpu swangle` is stable but roughly
half the framerate.

*Note:* `error null ctx` lines also appear during a clean shutdown and while rendering normally —
they are not proof of a crash. `exit 139` is; a deliberate `adb emu kill` exits without it.

## Everything feels slow / host load is high
**Check** `uptime`, then `adb shell dumpsys gfxinfo <pkg>`
**Fix** 50th percentile ≈16 ms is 60 fps; >30 ms is visibly choppy. Software rendering
(`-gpu swangle`) is the usual cause of a hot host (load ~9 vs ~2 with the GPU path).
Remember `-cores` is capped at 6.

## "It's using 7 GB of RAM"
That is `qemu-system-x86_64`'s **host** RSS — guest RAM plus GPU buffers, page tables and zram.
Check inside the guest:
```bash
adb shell cat /proc/meminfo | head -3
adb shell dumpsys meminfo | grep -E 'Total RAM|Free RAM|ZRAM'
```
More guest RAM does not fix rendering faults.

## I changed an emulator flag and nothing happened
Read the value back from the guest. Several flags are structured under `ro.boot.*` and are set by
the emulator itself, so `-prop` cannot override them:
```bash
adb shell getprop | grep -E 'hwcodec|hwui.renderer'
```
