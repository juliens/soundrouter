# SoundRouter HAL driver (`SoundRouter.driver`)

This is an AudioServerPlugIn loaded by `coreaudiod`, written in C11 and following the architecture of Apple's NullAudio sample.
It publishes one AudioDevice for each entry in `/Library/Application Support/SoundRouter/devices.json`.
It doesn't mix anything: it only exposes the per-device shm rings defined in `Sources/SRCore/include/sr_shm.h`, which is the contract. This code includes that header and never copies it.

| File | Role |
| --- | --- |
| `src/sr_driver.c` | Plug-in, device, stream and control objects, properties, IO, reload and maintenance |
| `src/sr_devices.[ch]` | Pure code: `devices.json` parser (hand-written, locale-independent) and device-list diff |
| `src/sr_ring.[ch]` | Pure code, real-time safe: ring index math and (de)interleaving between the HAL buffers and the planar shm planes |
| `tests/test_main.c` | Unit tests for the pure parts (`make test`) |
| `tests/harness.c` | In-process integration test of the whole driver: fake host, real shm segment, temp `devices.json` (`make harness`) |
| `Info.plist` | Bundle id `io.soundrouter.driver`, factory `5A3E9D12-…` = `SR_Create`, type `443ABAB8-…` |

## Build

```sh
cd Driver
make            # ../build/SoundRouter.driver, universal arm64+x86_64, ad-hoc signed
make test       # parser / diff / ring unit tests (UBSan; ASAN=1 adds ASan)
make harness    # full driver in-process (~15 s)
make clean
SIGN_IDENTITY="Developer ID Application: …" make   # hardened runtime + timestamp
```

## Install / uninstall (admin)

```sh
sudo cp -R build/SoundRouter.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall -9 coreaudiod
sudo rm -rf /Library/Audio/Plug-Ins/HAL/SoundRouter.driver && sudo killall -9 coreaudiod
```

To see the logs:

```sh
log stream --info --predicate 'subsystem == "io.soundrouter.driver"'
```

## Behaviour

- **Devices**
  - The driver loads the device list at `Initialize`, then reloads it on `notify_post("io.soundrouter.devices-changed")`.
  - As a fallback, it also polls the file's inode, mtime and size every 2 s.
  - A missing file means no devices. An unreadable or unparsable file keeps the current list.
  - Invalid entries are skipped. A UID must contain only hex digits and dashes, with at least 24 hex digits.
- **Reconfiguration**
  - A new or deleted `id` adds or removes the device and notifies `kAudioPlugInPropertyDeviceList`.
  - A new `name` triggers `PropertiesChanged(kAudioObjectPropertyName)`.
  - A new `channels` or `sampleRate` triggers `RequestDeviceConfigurationChange`, which is applied in `PerformDeviceConfigurationChange`.
  - Toggling `passThru` removes the device and re-adds it under a new AudioObjectID with the same UID.
- **Objects per device**
  - The input stream (N channels) is always present. The output stream exists only when `passThru` is true.
  - Volume and mute controls sit on the main element: input scope always, output scope too when `passThru` is true. Both sets mirror the single device volume.
  - Rates: 44.1, 48, 88.2, 96, 176.4 and 192 kHz.
  - Transport type is virtual. `IsHidden` is 0 and the clock domain is `'SRtr'`.
  - `CanBeDefaultDevice` is always true for input. For output it is true only when `passThru` is true.
- **Format**
  - The format is Float32. The HAL-facing physical format is interleaved, as in Apple's NullAudio sample, which is the proven path for plug-in IO buffers.
  - The ring code converts to and from the planar shm planes. `-DSR_NONINTERLEAVED=1` switches to `kAudioFormatFlagIsNonInterleaved`, but that path is untested with coreaudiod.
- **Clock**
  - `ZeroTimeStampPeriod` is `SR_RING_FRAMES`.
  - If the segment is mapped and compatible (magic, version, channels and rate all match), timestamps derive from `anchorHostTime`, so the engine and the driver share one zero-drift timeline.
  - Otherwise the driver uses a private anchor and serves silence.
  - If a segment appears or is recreated while IO runs (engine started late or restarted), the driver switches anchors and increments the timestamp seed.
- **IO**
  - `ReadInput` copies from the mix planes at `mInputTime.mSampleTime`. Missing, too-old or unmapped frames become silence.
  - When the engine heartbeat is less than 100 ms old, every silent frame increments `underrunCount`.
  - `WriteMix` writes the pass-thru planes and publishes `passThruWriteFrame` as a monotonic max.
  - IO calls never return errors.
  - The IO path takes no lock and makes no allocation, log or syscall (`mach_absolute_time` only). It reads an immutable `SRIOState` through an atomic pointer.
  - Replaced states and mappings are freed only when the device has no IO client. Removed devices are freed 5 s after their IO has stopped.
- **Controls**
  - When the engine heartbeat is fresh, values come from shm `volumeBits` and `muted`. A 250 ms poll calls `PropertiesChanged` when they change.
  - Host changes write `hostVolumeBits` and `hostMuted` and bump `hostControlSeq`. The host value is reported until the engine mirrors it, or for at most 2 s.
- **Sample rate set by a client**
  - Only supported rates are accepted.
  - The driver writes `requestedSampleRateBits` and calls `RequestDeviceConfigurationChange`.
  - Until the engine recreates the segment at the new rate, the device serves silence.
- **Shm**
  - The driver opens the segment on reload, at `StartIO`, and every 1 s. It detects engine restarts by a changed anchor.
  - If `O_RDWR` is refused (`EACCES`), the driver maps the segment read-only: input works, but pass-thru and host controls do not. The engine creates the segment 0666 (macOS does not apply the umask to `shm_open`; `fchmod` is not supported on shm).
  - `st_size` is checked with `>=` because the size is rounded up to the page size.

## J1 test (driver only, no engine)

There is no hard-coded device by default. The J1 device appears only when `devices.json` is missing and either:

- the flag file `/Library/Application Support/SoundRouter/j1-test` exists, or
- `SOUNDROUTER_DRIVER_J1=1` is set in coreaudiod's environment.

In that case the driver exposes "SoundRouter J1 Loopback": UID `53524A31-0000-4000-8000-000000000001`, 2 channels, 48 kHz, pass-thru. Its output is looped back to its input in driver memory, and it applies no gain, so the result is bit-exact.

```sh
sudo mkdir -p "/Library/Application Support/SoundRouter"
sudo mv "/Library/Application Support/SoundRouter/devices.json" /tmp/ 2>/dev/null
sudo touch "/Library/Application Support/SoundRouter/j1-test"   # picked up within 2 s
# play a 48 kHz file into "SoundRouter J1 Loopback", record from it in another app, compare samples
sudo rm "/Library/Application Support/SoundRouter/j1-test"
```

## Fallback if the coreaudiod sandbox blocks the driver

Validated on macOS 26: the sandbox allows reading `devices.json`, the Darwin notification and `shm_open` on the engine's segment (pass-thru is bit-exact). Should a future macOS block it, the driver keeps its devices visible and serves silence; look for "cannot open … (sandbox?)" in the log.

The planned fallback is a Mach service published by the engine. The driver would declare it in `Info.plist` under the key below, which is currently empty and not shipped:

```xml
<key>AudioServerPlugIn_MachServices</key>
<array>
    <!-- <string>io.soundrouter.engine.driver</string> -->
</array>
```

The driver would then receive the device list and a shm or memory-entry handle over that Mach connection instead of opening the paths itself.
