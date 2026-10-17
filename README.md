# Android VM on Linux for ARM-only apps (TikTok case study)

Run a real Android app in a **GPU-accelerated Android VM** on an x86_64 Linux desktop — the
actual `com.zhiliaoapp.musically` app with its mobile-only features (posting, edits, filters,
DMs), not a web wrapper and not a container.

Measured on a Ryzen 7 5700X + RTX 3060 (NVIDIA 595) running Linux Mint 22.3:

| Metric | Result |
|---|---|
| Frame time (median / p90) | **16 ms / 20–23 ms** (60 fps) |
| Janky frames | **6–7%** (settled) |
| Video decoder errors | **0** |
| Audio | forwarded to host (HDMI) |
| Guest RAM headroom | 3.1 GB free of 6 GB |

## What it looks like

![TikTok running in the VM](assets/feed-final-config.png)

*The feed on the final configuration — 720x1280, host GPU, emulator's goldfish codec disabled.
Screencap taken from the guest, so this is the real output, not a mockup.*

## Why not Waydroid

Waydroid needs a Wayland session, and on NVIDIA it has no hardware video-decode path — 1080p
playback decodes in software. This approach uses KVM + a full Android system image with the
emulator's GPU translation, so the host GPU does the rendering.

## Quick start

```bash
# once
sudo apt install -y openjdk-17-jdk-headless unzip curl
mkdir -p ~/android-vm && cd ~/android-vm
curl -sSLo cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q cmdtools.zip -d sdk/
export ANDROID_HOME=~/android-vm/sdk
./sdk/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses
./sdk/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME \
    platform-tools emulator "system-images;android-35;google_apis_playstore;x86_64"

# then
cp scripts/*.sh scripts/ui.py ~/android-vm/ && chmod +x ~/android-vm/*.sh
~/android-vm/start-android.sh        # headless emulator, host GPU
~/android-vm/view-vm.sh              # window + sound via scrcpy
```

Install apps without a Google login using **Aurora Store** (anonymous Play client): sideload it
from F-Droid, grant `appops set com.aurora.store REQUEST_INSTALL_PACKAGES allow`, choose the
anonymous session, then search and install. Play serves the correct `arm64-v8a` splits, which the
image's native bridge translates.

## What the VM actually is

```
Android 15 (API 35) x86_64 google_apis_playstore  <- Google's own SDK image
    64-bit ARM app  ->  libndk_translation  ->  x86_64 host
    guest GLES      ->  gfxstream           ->  host GPU (NVIDIA via Vulkan)
    host side       ->  KVM (AMD-V), 6 vCPU, 6 GB guest RAM
    viewing/audio   ->  scrcpy 5 (video + audio forwarding)
```

## The traps, and the fix for each

### 1. Use Android 15 (API 35), never API 30
The `libndk_translation` build shipped in Android 11 images aborts heavy ARM apps at launch:

```
F ndk_translation: guest_call_arm64.cc:76: CHECK failed: <addr> == <addr>
F libc: Fatal signal 6 (SIGABRT) in tid ... (tp-io-17)
```

Same app, same setup, API 35 image: runs. Verify an image carries a translator before
downloading 2 GB (`grep -abo -m1 libndk_translation system.img`).

### 2. Run headless; the emulator's own window breaks the GPU path
The windowed GL path loses its display-surface context on the NVIDIA driver:

```
ERROR | DisplaySurfaceGlContextHelper context was preempted by others, current=(nil)
gles_v2_imp.cpp:glTexImage2D:3588 error null ctx
ERROR | bad color buffer handle 809
```

Result: corrupted/torn frames, and eventually SIGSEGV (exit 139). Headless measured **0** such
errors. View with scrcpy instead.

### 3. The emulator only initialises audio when it HAS a window
In headless mode the log shows `Could not init 'pa' audio driver` and the guest plays into
silence (it still reports active output tracks). `PULSE_SERVER`, restarting PipeWire and
`QEMU_AUDIO_DRV=pa` do not change it; `QEMU_AUDIO_DRV=alsa` is rejected (`Unknown audio driver`).
Since the window is what breaks the GPU path (#2), take the sound from **scrcpy 5**
(`--audio-source=playback`) and keep the emulator headless. Verify:
`pactl list sink-inputs | grep -A1 application.name` → `scrcpy`.

### 4. Disable the emulator's goldfish video codec
With the goldfish codec active, every clip logged:

```
Codec2Client: setOutputSurface -- failed to set consumer usage (6/BAD_INDEX)
CCodecBufferChannel: MediaCodec discarded an unknown buffer
```

~44–51 events per run, visible as on-screen glitches. Launch with `-feature -HardwareDecoder`
and the app falls back to its own bundled software decoder (`non hardware codecname matched` →
`ByteVC1_dec`): **decoder errors 0**, 0 null-ctx, 6.3% janky, p50 16 ms / p90 20 ms.

### 5. "The app closes after a while" is the low-memory killer, not a crash
```bash
adb shell dumpsys activity exit-info com.zhiliaoapp.musically
#   reason=3 (LOW_MEMORY)   -> lmkd killed it; the guest is starved
```
4 GB guest RAM is not enough for TikTok + Play Services (killed at 3.0 GB used). 6 GB measured
stable with 3.1 GB free. A genuine translator crash reads `reason=5 (APP CRASH(NATIVE))` with the
backtrace inside `libndk_translation.so (HandleHostSignal -> RunGuestSyscallImpl)`.

### 6. A 7 GB reading is not guest RAM
`qemu-system-x86_64` showed **7.7 GB RSS** on the host for a 6 GB guest — that is guest RAM plus
GPU buffers, page tables and zram. Check inside the guest instead (`/proc/meminfo`,
`dumpsys meminfo`); adding guest RAM does not fix rendering faults and pushes a tight host into
swap. Give the **host** swap if `swapon --show` is empty.

## Diagnostics cookbook

```bash
# is the app alive, and why did it die?
adb shell pidof com.zhiliaoapp.musically
adb shell dumpsys activity exit-info com.zhiliaoapp.musically

# is it smooth? (50th ~16 ms = 60 fps; >30 ms = visibly choppy)
adb shell dumpsys gfxinfo com.zhiliaoapp.musically | grep -E 'Total frames|Janky frames:|50th|90th'

# which decoder is in use?
adb logcat -d | grep -oE 'c2\.[a-z0-9._]+decoder' | sort | uniq -c

# glitch signature, per source
adb logcat -d | grep -cE 'discarded an unknown buffer|failed to set consumer usage|EGL_BAD_ATTRIBUTE'
grep -c 'error null ctx' <emulator stdout>

# audio chain
pactl list sink-inputs | grep -A1 application.name
adb shell dumpsys media.audio_flinger | grep Standby

# drive the guest without a screen: ui.py show | tap "<text>" | shot out.png
```

Note: `error null ctx` lines also appear during a normal shutdown, so they alone do not prove a
crash — `exit 139` is the crash signature, a manual `adb emu kill` exits without it.

## Tried, measured, rejected

- `-feature -GLDirectMem,-GLDMA,-YUVCache` — made it worse: immediate
  `reason=5 (APP CRASH(NATIVE))` inside the translator.
- `-feature -HardwareDecoder` **in windowed mode** — app hung on a black splash. In headless mode
  it is the best configuration measured (see trap 4).
- `-prop qemu.hwcodec.hevcdec=0` — no-op; those are `ro.boot.*` properties the emulator sets itself.
- `-prop debug.hwui.renderer=skiavk` — no-op; the emulator's `androidboot.debug.hwui.renderer=skiagl`
  wins. **Always read the property back in the guest before trusting an A/B result.**
- `-gpu swangle` (software GL) — stable but 52–73% janky, p50 32–38 ms.
- Windowed on Xvfb (for audio) — still SIGSEGV with the host GPU; ~26 fps with software GL.
- Emulator `-cores 8` — silently clamped to 6 (`WARNING | Emulator does not support more than 6 cores`).

## Repo layout

```
scripts/     start-android.sh, view-vm.sh, ui.py, tests/glitch-test.sh, tests/decode-test.sh
docs/        FINDINGS.md (raw evidence), TROUBLESHOOTING.md (symptom -> fix)
skill/       SKILL.md - the same method as an agent skill
```

## License

MIT. See `LICENSE`.
