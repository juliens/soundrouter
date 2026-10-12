# Integration tests

Run on a real Mac (macOS 14.2+) with SoundRouter installed (`make pkg` + install, or
`make app && make install-driver` and launch the app once). They are not part of `make test`.

| Spec test | Script | Automated |
| --- | --- | --- |
| Driver: device visible, formats | `driver_visible.sh` | yes |
| Driver: pass-thru bit-exact (J1) | `passthru_bitexact.sh [DEVICE] [RATES...]` | yes |
| Application capture (J2) | `app_capture.sh [DEVICE]` + manual steps below | partly |
| Endurance: drift, dropouts (J3) | `endurance.sh [HOURS] [INTERVAL]` | monitoring only; setup manual |
| Robustness | [`robustness.md`](robustness.md) | checklist |
| Compatibility | [`compatibility.md`](compatibility.md) | checklist |

## Tools

`IntegrationTests/run_tool.sh <tool> [args]` compiles a tool from `Tools/` (with
`Tools/CoreAudioUtil.swift`) into `build/it/` and runs it.

- `list_devices` – lists Core Audio devices; `--devices-json PATH` or `--uid UID --channels N --rate R`
  asserts a SoundRouter device is published correctly.
- `passthru_bitexact` – one HAL IOProc plays a deterministic 24-bit-quantized signal to the
  device output and records its input; finds the loopback offset by exact search and requires
  every sample to match.
- `tone_gen OUT.wav [--kind signal|sine] [--rate] [--seconds] [--freq]` – known test signal.
- `capture_check --reference F.wav [--device] [--seconds] [--min-corr]` – records the device
  input and reports the peak normalized cross-correlation with the reference.
- `srctl` (`make srctl`, output `build/srctl`) – XPC client of the engine:
  `hello | status | config | devices | underruns | create-device NAME [--rate R] [--channels N] |
  delete-device DEV | add-app DEV BUNDLEID (--pid PID | --path EXE) [--no-mute] |
  add-input DEV UID CH,CH | meters DEV [--count N]`.
  The engine only accepts callers with the same Team ID: `SIGN_IDENTITY=... make srctl`.

## Pass-thru setup

In the app: create a device (2 ch, 48 kHz) that contains only the pass-thru source, routed 1:1,
gain 1, device volume 100 %, no monitor. Then `IntegrationTests/passthru_bitexact.sh "<name>" 48000 44100 96000`.

## app_capture — manual

1. `IntegrationTests/run_tool.sh tone_gen /tmp/signal.wav --seconds 30`
2. In the app, create device "Capture" (48 kHz, 2 ch) and add the application source
   *afplay* (or play the file in QuickTime Player / a browser and add that app).
3. `afplay /tmp/signal.wav &` — the first time, accept the Audio Capture prompt for SoundRouter Engine.
4. `IntegrationTests/run_tool.sh capture_check --device Capture --reference /tmp/signal.wav` → PASS (≥ 0.9).
5. With "mute the application while capturing" on, the tone must not be heard on the speakers but
   must still be captured (repeat step 4); with it off, it is heard and captured.
6. Quit the player: the source shows "waiting"; relaunch: capture resumes without action.

## Endurance setup (8 h)

Device at 48 kHz with: a USB microphone at 44.1 kHz (input source) + an application source
(e.g. `afplay` looping a long file, or a browser playing a stream) + optionally the pass-thru
with a recorder (QuickTime) recording the device. Then `IntegrationTests/endurance.sh 8 60`.
Pass: underrun counters unchanged, engine always reachable, the recording has no audible dropout.
