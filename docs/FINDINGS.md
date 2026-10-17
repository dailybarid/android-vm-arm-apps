# Findings — raw evidence

Every claim in the README traces to one of these observations. Hardware: Ryzen 7 5700X,
RTX 3060 (driver 595.99), Linux Mint 22.3, kernel 7.0.0-38, emulator 37.2.12, AVD
`tiktok35` = Android 15 / API 35 `google_apis_playstore` x86_64, 6 vCPU, 6 GB RAM, 720x1280 @ 320 dpi.

## 1. API 30 image: translator abort at launch

Android 11 (`android-30`) image, same app and AVD tuning:

```
10-17 21:27:10.129  5455  5525 F ndk_translation: vendor/unbundled_google/libs/ndk_translation/runtime/guest_call_arm64.cc:76: CHECK failed: 132358778305648 == 132358778306512
10-17 21:27:10.222  5455  5525 F libc: Fatal signal 6 (SIGABRT) in tid 5525 (tp-io-17), pid 5455 (aoapp.musically)
```

Reproduced on 3 consecutive launches — deterministic, not a race. The API 35 image runs the same
app. The translator version differs between SDK image revisions; API 30's build has this bug.

## 2. Windowed GPU path loses its GL context

Emulator started **with** its own window, `-gpu host`, 720p:

```
ERROR | DisplaySurfaceGlContextHelper context was preempted by others, current=(nil), needed=0x3
gles_v2_imp.cpp:glTexImage2D:3588 error null ctx
gles_v2_imp.cpp:glTexParameteri:3663 error null ctx
gles_v2_imp.cpp:glGetTexImage:3699 error null ctx
ERROR | bad color buffer handle 809
```

Two emulator runs died with **exit 139** (SIGSEGV). At 1080x1920 the death was immediate and
repeatable, hence 720x1280.

Same AVD, **headless** (`-no-window`), identical interaction:

```
null-ctx errors: 0
bad color buffers: 0
```

## 3. Audio requires the window the GPU path cannot tolerate

| Launch | Host PulseAudio stream | Emulator log |
|---|---|---|
| windowed | `qemu-system-x86_64`, Corked: no | audio works |
| headless | none, ever | `Could not init 'pa' audio driver` |

Things that did **not** fix headless audio: exporting `PULSE_SERVER=unix:/run/user/1000/pulse/native`
(verified present in the emulator's environment via `/proc/<pid>/environ`), restarting
`pipewire-pulse`, and `QEMU_AUDIO_DRV=pa`. `QEMU_AUDIO_DRV=alsa` →

```
Unknown audio driver `alsa'
Run with -audio-help to list available drivers
```

Windowed on Xvfb (`DISPLAY=:99`) did produce a stream (`sink-input #1860`) but then the emulator
exited 139 with `-gpu host`; with `-gpu swangle` it survived at 52% janky / p50 38 ms.

Works: headless emulator + **scrcpy 5** `--audio-source=playback` →
`pactl list sink-inputs` shows `application.name = "scrcpy"`, Corked: no.

## 4. Goldfish codec = the remaining glitch source

Headless + host GPU, goldfish codec enabled, 6 swipe-throughs of the feed:

```
decoder-path errors: 44            (discarded an unknown buffer / failed to set consumer usage / EGL_BAD_ATTRIBUTE)
decoders: 85 c2.goldfish.hevc.decoder, 75 c2.android.vorbis.decoder, ...
Janky frames: 50 (14.16%)  50th pct: 16ms  90th pct: 44ms
```

`-feature -HardwareDecoder`, same interaction, clean `logcat -c` window:

```
decoder-path errors: 0
decoders: (none - app uses its own)   logcat: "non hardware codecname matched" -> ByteVC1_dec (48 lines)
Janky frames: 26 (6.31%)  50th: 16ms  90th: 20ms  95th: 31ms
guest pid alive
```

Screenshot of the feed after this change: clean, no blockiness/tearing (vision-checked).

## 5. Low-memory kill vs crash

```
ApplicationExitInfo #0:
  timestamp=2026-10-17 21:53:58 pid=1502 reason=3 (LOW_MEMORY) subreason=0 status=0
  importance=100 pss=0.00 rss=0.00 state=empty
```

Guest at the time: `MemTotal 4,013,956K`, Used RAM 3.0 GB, Free RAM 1.5 GB, lmkd OOM threshold
322 MB. After raising to 6 GB: `MemTotal 6,072,184K`, MemAvailable 3.27 GB, TikTok
`TOTAL PSS 1147934` (1.15 GB), and no further `LOW_MEMORY` records.

Contrast, a translator failure:

```
reason=5 (APP CRASH(NATIVE)) subreason=0 status=6
F libc: Fatal signal 6 (SIGABRT) in tid 4313 (VOutle2-V0)
  #01 pc /system/lib64/libndk_translation.so (ndk_translation::RunGuestSyscallImpl+3461)
  #04 pc /system/lib64/libndk_translation.so (berberis::HandleHostSignal+764)
W NaviWarn: StackPtr is not 8-byte aligned.
```

## 6. Memory footprint confusion

```
host:  qemu-system-x86_64 RSS = 7.7 GB          (for a 6 GB guest)
guest: MemTotal 6.07 GB, MemAvailable 3.27 GB
```

The host figure includes GPU buffers, page tables and zram — it is not guest usage and is not a
reason to raise guest RAM.

## 7. No-op flags (each verified by reading the value back)

```
$ ./emulator ... -prop qemu.hwcodec.hevcdec=0
$ adb shell getprop | grep hwcodec
[ro.boot.qemu.hwcodec.hevcdec]: [2]        <- unchanged; the emulator sets ro.boot.* itself

$ ./emulator ... -prop debug.hwui.renderer=skiavk
$ adb shell getprop debug.hwui.renderer
skiagl                                     <- unchanged; androidboot.debug.hwui.renderer wins
```

The second one invalidated an A/B test that had already been "run" — read properties back before
trusting results.

## 8. Other measured facts

- `-cores 8` → `WARNING | Emulator does not support more than 6 cores. Number of cores set to 6`.
- `-gpu swangle` headless: 73% janky, p50 32 ms, p90 81 ms, host load 9.8.
- `-gpu host` headless + scrcpy: 7–16% janky, p50 16 ms, p90 20–23 ms, host load 1.7–2.4.
- Sideloading: `d.apkpure.com` direct downloads return HTTP 403 (Cloudflare) to curl; the F-Droid
  APK for Aurora Store downloads cleanly and Play supplies the arm64 splits.
- `speaker-test -D pulse` fails under PipeWire (`Playback open error: -2`); generate a WAV and use
  `paplay` for a host-side audio check.
