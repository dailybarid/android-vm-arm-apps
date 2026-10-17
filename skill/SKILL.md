---
name: android-vm-arm-apps
description: Run ARM-only Android apps in a GPU-accelerated Android VM.
---

# Android VM on x86_64 Linux for ARM-only apps

Goal: run an ARM-only app (e.g. TikTok `com.zhiliaoapp.musically`) in a real Android VM with the Android
Emulator (QEMU/KVM), GPU-accelerated, without Waydroid/Wayland.

## Hard-won rules

1. **Use Android 15 (API 35) `google_apis_playstore` x86_64, not API 30.** The `libndk_translation` build
   shipped in the Android 11 images aborts at launch on heavy ARM apps with
   `guest_call_arm64.cc:76: CHECK failed: <addr> == <addr>` (SIGABRT in a network thread). API 35's
   translator does not have that bug. Verify the image ships a translator before downloading 2 GB:
   `grep -abo -m1 libndk_translation system.img` (raw ext4 image only; newer images are sparse/partitioned,
   so absence of the string is not proof).
2. **`-gpu host` works only at <=720p on NVIDIA.** At 1080x1920 gfxstream's host-GL path dies with
   `DisplaySurfaceGlContextHelper context was preempted by others` / `glTexImage2D: error null ctx` and the
   emulator process exits. 720x1280 @ 320 dpi is stable and smooth.
3. **Software fallback is ~3x worse**: `-gpu swangle` gives ~50% janky frames and 50th pct ~53 ms vs
   `-gpu host` at 16 ms (60 fps). Only use it if host GL is broken.
4. **AVD config quirks**: `avdmanager create` writes `disk.dataPartition.path=<temp>` (data lost each boot),
   `PlayStore.enabled=no` even for Play images, and a relative `image.sysdir.1` that resolves wrongly when
   the SDK root is non-standard. Patch `~/.android/avd/<name>.avd/config.ini` before first boot:
   absolute `image.sysdir.1`, real `disk.dataPartition.path`, `userdata.useQcow2=yes`, `hw.ramSize=6144`,
   `hw.cpu.ncore=6`, `hw.gpu.mode=host`, `hw.keyboard=yes`. (4 GB is the trap: the guest lmkd kills the
   app under it - see the low-memory section below.)
5. **The emulator rejects `-no-audio-input`** on 37.x; and never `pkill -f "emulator -avd ..."` from a shell
   whose own command line contains that string (it kills itself). Use `adb emu kill` for a clean shutdown.
6. **Installing ARM apps without a Google login**: sideload **Aurora Store** from F-Droid
   (`https://f-droid.org/api/v1/packages/com.aurora.store` for the version, then
   `https://f-droid.org/repo/com.aurora.store_<verCode>.apk`), grant
   `appops set com.aurora.store REQUEST_INSTALL_PACKAGES allow`, choose **Anonymous** session, search, Install.
   Google Play serves the correct arm64 splits and installs them through PackageInstaller.
   APKPure/APKMirror direct downloads are Cloudflare-walled (403 from curl) - Aurora is the reliable path.

## Driving the VM without vision

`adb shell uiautomator dump /sdcard/ui.xml` + parse `text="..." bounds="[x1,y1][x2,y2]"`, then
`adb shell input tap <cx> <cy>` / `input swipe` / `input text`. Screenshots via
`adb exec-out screencap -p > out.png` and `vision_analyze` for the human-facing check.
A ready-made helper: `~/android-vm/ui.py` (`show`, `tap <text>`, `shot`, `key`).

## Do not diagnose a stop from the emulator log tail
The `...error null ctx` / `DisplaySurfaceGlContextHelper context was preempted` lines are emitted during
normal rendering AND during a clean shutdown, so their presence in the tail does not mean a crash. A
manual `adb emu kill` and a spontaneous death look similar there. Before blaming the host, ask (or
check) whether the user stopped it, and check the wrapper's exit status: a deliberate kill tends to show
`exit 0` / `completion_reason: exited`, while the driver failure shows `exit 139` (SIGSEGV).

## Run headless and mirror with scrcpy - it is both faster and more stable
The emulator's own window uses a display-surface GL context that gfxstream loses on some host drivers
(`DisplaySurfaceGlContextHelper context was preempted by others`, then thousands of
`gles_v2_imp.cpp ... error null ctx`). Consequences: corrupted/torn video frames, a loud audio pop then
silence, and eventually SIGSEGV of the whole emulator (exit 139).
Fix: `-no-window` on the emulator plus **scrcpy 5** for the visible window (static release from the
Genymobile GitHub releases; the apt package is 1.25 and has no audio forwarding). Measured on the
same box at 720p: headless+scrcpy 6-16% janky / 16 ms median / host load ~2, versus 18-37% janky
windowed, versus 52-73% janky / 32-38 ms with `-gpu swangle` software GL. Prefer headless+scrcpy;
keep the emulator's own window only for quick debugging.
The emulator silently clamps `-cores` to 6 - passing 8 changes nothing. A guest log full of
`c2.goldfish.hevc.decoder` plus `failed to set consumer usage` / `MediaCodec discarded an unknown
buffer` is the fingerprint of the glitching codec path (next section), not harmless noise - remove it
with `-feature -HardwareDecoder`. Confirm the outcome visually either way: log counts and screenshots
disagree often enough that the screenshot is the tiebreaker.

## Host-side flags that do NOT work (don't waste a restart on them)
- `-prop qemu.hwcodec.hevcdec=0` - no-op; those are `ro.boot.*` properties the emulator assigns itself.
- `-feature -GLDirectMem,-GLDMA,-YUVCache` - made it worse: immediate translator crash on launch.

## Video glitches: kill the emulator's goldfish codec, not the RAM
Symptom: blocky/torn frames while clips play. Diagnose per-source with a clean window:
```bash
adb logcat -c
# then interact, then:
adb logcat -d | grep -cE 'discarded an unknown buffer|failed to set consumer usage|EGL_BAD_ATTRIBUTE'
grep -c 'error null ctx' <emulator stdout>   # host-GL context loss
grep -oE 'c2\.[a-z0-9._]+decoder' <logcat> | sort | uniq -c
```
Two independent sources, only one of which is fixable from the host:
- **host GL context loss** (`error null ctx`, `bad color buffer handle`): single digits across a whole
  session in headless mode (measured: 7 since boot), versus dozens per video and eventual SIGSEGV when
  windowed. Headless+scrcpy reduces it to a non-issue rather than literally zero - do not claim zero.
- **goldfish codec path** (`c2.goldfish.hevc.decoder` + discarded-buffer/consumer-usage errors): present
  even headless, 44-51 events per run. Fix: launch with `-feature -HardwareDecoder`. The app then falls
  back to its own bundled software decoder (TikTok logs `non hardware codecname matched` then
  `ByteVC1_dec`), and the error signature goes to **0**; measured 7% janky, p50 16 ms, p90 23 ms at 720p.
  The flag is mode-dependent: windowed it hangs on a black splash with no decoder ever opened, so pair
  it with `-no-window` and leave it on by default in the launch script.

`-prop debug.hwui.renderer=skiavk` does **not** apply - the emulator's own
`androidboot.debug.hwui.renderer=skiagl` wins, and `getprop debug.hwui.renderer` still reports `skiagl`.
Always verify the guest property actually changed before drawing conclusions from an A/B run.

## Do not blame RAM for glitches (a 6 GB guest is not starved)
A 6 GB guest displayed as **7.7 GB RSS** in `qemu-system-x86_64` on the host - that is the VM's host
footprint (guest RAM + GPU buffers + page tables + zram), not guest usage. Check inside instead:
```bash
adb shell cat /proc/meminfo | head -3          # MemAvailable
adb shell dumpsys meminfo | grep -E 'Total RAM|Free RAM|ZRAM'
adb shell dumpsys meminfo <pkg> | grep 'TOTAL PSS'
adb shell dumpsys activity exit-info <pkg>    # any reason=3 LOW_MEMORY kills?
```
Measured here with TikTok running: 6.07 GB total, 2.85 GB free / 3.27 GB available, TikTok 1.15 GB PSS,
no LMK kills. Raising guest RAM does not affect glitches and pushes an already-tight host into swap.

## Translating app crashes: read reason=, then decide if it is even yours
The translator itself is the weak link for media-heavy arm64 apps:
`reason=5 (APP CRASH(NATIVE))` with the backtrace inside `/system/lib64/libndk_translation.so
(HandleHostSignal -> RunGuestSyscallImpl)`, plus logcat `NaviWarn: StackPtr is not 8-byte aligned`
(an ARM64 ABI violation by the translator). Nothing on the host fixes that class of failure - try a
different system-image level (translator builds differ a lot between SDK image revisions) or accept
restarts. Always check `dumpsys activity exit-info` before assuming the app or your config is at fault.

## "The app closes after a while" is usually the guest low-memory killer
`adb shell dumpsys activity exit-info <pkg>` shows the real reason. `reason=3 (LOW_MEMORY)` means lmkd
killed the app - not a crash. 4 GB guest RAM is not enough for TikTok + Play Services; give it 6-8 GB
(`hw.ramSize` in config.ini and `-memory` on the emulator command line; 6 GB verified stable).
Give the host swap too if `swapon --show` is empty: 15 GB RAM + a 4 GB VM with zero swap is an
OOM-waiting-to-happen. `Fatal signal` + tombstones point at the app; `exit-info` points at the system.

## Audio: the emulator only initialises its audio backend when it HAS a window
Measured: windowed -> a `qemu-system-x86_64` PulseAudio sink-input appears and sound works; headless
(`-no-window`) -> emulator log says `Could not init 'pa' audio driver`, no host stream ever, and the
guest still reports active output tracks, i.e. it plays into silence. `PULSE_SERVER` and
`QEMU_AUDIO_DRV=pa` do not change it, and `QEMU_AUDIO_DRV=alsa` is rejected (`Unknown audio driver
'alsa'`). Running windowed on a virtual display (Xvfb) does give audio, but with the host GPU it
still SIGSEGVs, and with the software renderer it drops to ~26 fps.

Resolution that keeps the smooth headless path: **scrcpy 5 audio forwarding**
(`--audio-source=playback`; install the static release from GitHub - the apt scrcpy 1.25 has no audio
support). Verify the host is receiving it:
```bash
pactl list sink-inputs | grep -A1 application.name   # expect: scrcpy, Corked: no
```
Playback capture needs the app to allow it, so a given app may still come through silent.

## Guest audio: verify the chain before blaming the VM
```bash
pactl list sink-inputs | grep -E 'application.name|Corked'   # qemu-system-x86_64, Corked: no
adb shell dumpsys media.audio_flinger | grep Standby         # output thread not in standby
paplay /tmp/tone.wav                                         # host-side proof the sink is audible
```
The emulator follows the host default sink, so "no sound" on a box whose only exposed sink is HDMI is
often the TV/monitor's own volume or input, not the VM. Watch out: `speaker-test -D pulse` fails with
`Playback open error: -2` under PipeWire; generate a WAV and use `paplay` instead.

## Measuring smoothness (do this, don't guess)

```bash
adb shell dumpsys gfxinfo <pkg> reset          # zero the counters
adb logcat -c                                  # zero the guest log
# ...now drive the exact interaction you want to measure...
adb shell dumpsys gfxinfo <pkg> | grep -E 'Total frames|Janky frames:|50th|90th|95th'
```
50th percentile ~16 ms = 60 fps; >30 ms = visibly choppy. `uptime` load tells you if the host is saturated.

Two rules, both learned by getting them wrong:
- **Zero the counters and let the app warm up before measuring.** Launch, dexopt and first-feed frames
  otherwise dominate: the *same* config reads 45-53% janky right after launch and 6-7% once warm. Never
  compare a just-launched run against a warm one - the difference you see is startup, not your change.
- **An A/B must differ in exactly one variable, and you must confirm it did.** Verify the knob took
  effect (`adb shell getprop <prop>`, or the emulator's own startup log) before trusting the result;
  otherwise it is two runs of the same config. State a void test as void rather than reporting it.

`scripts/vm-glitch-diagnostics.sh <package> [emulator-stdout-log]` runs the whole probe (app exit
reason, guest memory, decoder signature, host-GL loss, audio stream, warm frame stats) and prints a
verdict guide keyed to each failure mode above.

## Operating it day to day
- **Start**: `start-android.sh` (headless, host GPU, `-feature -HardwareDecoder`), then `view-vm.sh`
  for the window and sound (scrcpy 5 with `--audio-source=playback`).
- **A `.desktop` entry must NOT chain start + view with `;`.** `start-android.sh` ends in
  `exec ./emulator …`, which replaces the shell, so `start-android.sh; sleep 25; view-vm.sh` starts the
  VM headless and *never reaches the viewer* — the user sees a running emulator and no window, and
  running the two scripts by hand appears to be the only thing that works. Wrap it in a launcher that
  (1) starts the emulator detached (`setsid nohup ./start-android.sh >emu.log 2>&1 &`), (2) **polls
  readiness instead of sleeping** (`adb shell getprop sys.boot_completed` until `1`, with a timeout that
  prints the log path), (3) brings the app to the front, then (4) execs the viewer. Give that script a
  `--stop` (`adb emu kill` + close the viewer) and point two menu entries at it so the menu can both
  open and close the VM.
- **Poll, never `sleep N`, for readiness in anything user-facing.** A fixed sleep either wastes time on
  a warm start or races a cold first boot and opens a window onto a blank guest.
- **Stop**: `adb emu kill`. The persistent data partition is what holds the installed app and its
  login, so a SIGKILL of qemu is how you lose the user's session - do not `pkill` it.
- **The emulator can still exit on its own** (the gfxstream GL quirk above). Recovery is only
  re-running the two scripts: the AVD, the app and the logged-in session all persist. Never wipe or
  recreate the AVD to "fix" a dead emulator.
- When it dies, capture WHY before restarting, or the next one is another guess: a watcher that logs
  the moment the qemu pid disappears - host `free -h`, host OOM/GPU errors, the guest crash buffer,
  tombstones - converts the next occurrence into evidence. It also distinguishes a deliberate
  `adb emu kill` from a real fault (the log line is the same either way; the surrounding host state
  is not).
- Before blaming a tool for an unexplained exit, check whether the thing you just did touched it:
  state plainly which changes were live at that moment instead of asserting a cause you cannot prove.

## Sharing this method
When the user asks to publish it, do not dump the session — reuse the packaged write-up at
`~/android-vm-arm-apps/`: `README.md` (the method: what it gives you, the measured matrix, then the
traps with their exact error strings), `docs/FINDINGS.md` (raw evidence per claim), 
`docs/TROUBLESHOOTING.md` (symptom -> check -> fix), `scripts/` (the launch/view/ui scripts plus the
`tests/` A/B harnesses), `skill/SKILL.md`, MIT `LICENSE`. House rules for any such repo: state the
measured numbers **and the failed experiments** (a write-up that only lists what worked is the one
thing a reader cannot verify); de-hardcode personal absolute paths to `$HOME` or env overrides before
publishing; `.gitignore` `*.log`/`*.png` so crash logs and screenshots do not ship; credit the user
(`Khaled Mimoune, Hermes Agent`) under MIT, matching their other published skills. Two mechanics that
bite on the publish itself: a `*.png` ignore rule also swallows the screenshot you *want* in the README
(add `!assets/*.png`), and the commit identity should come from `gh api user`
(`<id>+<login>@users.noreply.github.com`) so no personal address is exposed. Then **verify from
GitHub's side rather than the push exit code**: `gh repo view --json visibility`, the remote tree via
`gh api repos/<owner>/<repo>/git/trees/HEAD?recursive=1`, and a fetch of the raw README/screenshot URL.

## Layout used here

`~/android-vm/`: `sdk/`, `start-android.sh` (headless emulator, host GPU, `-feature -HardwareDecoder`;
`VM_RAM` / `GPU_MODE` / `AVD_NAME` / `CORES` env overrides), `view-vm.sh` (scrcpy 5 + audio),
`launch-vm.sh` (the menu entry: detached emulator + boot poll + app to front + viewer; `--stop` shuts down),
`ui.py` (adb UI driver), `crashwatch.sh` (exit watcher), `glitch-test.sh` and `decode-test.sh`
(A/B harnesses that feed the measured matrix), `README.md` (mode matrix + gotchas),
`scrcpy-linux-x86_64-v5.0.1/`. AVD `tiktok35`; menu entries
`~/.local/share/applications/android-vm-tiktok.desktop` (launch-vm.sh) and `android-vm-stop.desktop`
(launch-vm.sh --stop).
