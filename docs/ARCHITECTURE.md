# SoundRouter — architecture & build contracts

Spec: virtual audio router for macOS 14.2+ (process taps). Three components:

| Component | Location | Language | Product |
| --- | --- | --- | --- |
| HAL driver (AudioServerPlugIn) | `Driver/` | C11 only | `build/SoundRouter.driver` (universal) |
| Engine (LaunchAgent) | `Sources/SoundRouterEngine` + RT core `Sources/SRCore` | Swift + C | `SoundRouterEngine.app` (nested login item) |
| Control app | `Sources/SoundRouter` | SwiftUI (+AppKit canvas) | `build/SoundRouter.app` |
| Shared Swift | `Sources/SoundRouterKit` | Swift | model, XPC contract, pure config logic |

## Contracts (source of truth — do not change without updating every component)

- `Sources/SRCore/include/sr_shm.h` — shm layout, clock model, devices.json format, names.
  The driver includes it with `-I../Sources/SRCore/include`.
- `Sources/SRCore/include/sr_core.h` — RT core API (ring, drift resampler, mixer, meters, plan slot, shm helpers).
- `Sources/SoundRouterKit/Model.swift` — config model (`RouterConfig`, `VirtualDevice`, …).
- `Sources/SoundRouterKit/IPC.swift` — `EngineXPCProtocol`, `ConfigCommand`, `EngineStatus`, `MeterSnapshot`, paths.
- `Sources/SoundRouterKit/ConfigLogic.swift` — `ConfigValidator`, `ConfigMigration`, `ConfigReducer`.

## Identifiers

| Thing | Value |
| --- | --- |
| App bundle id | `io.soundrouter.app` |
| Engine bundle id | `io.soundrouter.engine` |
| LaunchAgent label / plist | `io.soundrouter.engine` / `io.soundrouter.engine.plist` |
| XPC Mach service | `io.soundrouter.engine.xpc` |
| Driver bundle id | `io.soundrouter.driver` |
| Driver plug-in factory UUID | `5A3E9D12-7B6C-4F0E-9A51-3C2D8E7F1B40` |
| Driver plug-in type (kAudioServerPlugInTypeUUID) | `443ABAB8-E7B3-491A-B985-BEB9187030DB` |
| Darwin notification | `io.soundrouter.devices-changed` |
| User config | `~/Library/Application Support/SoundRouter/config.json` (+ `.bak`) |
| Driver device list | `/Library/Application Support/SoundRouter/devices.json` |
| Shm per device | `/sr.<24 hex of uuid>` (see `sr_shm_name`) |

## App bundle layout (produced by `Scripts/build.sh`)

```
build/SoundRouter.app/Contents/
  Info.plist                                 (io.soundrouter.app)
  MacOS/SoundRouter
  Library/LoginItems/SoundRouterEngine.app/  (io.soundrouter.engine, LSUIElement,
                                              NSAudioCaptureUsageDescription, NSMicrophoneUsageDescription)
  Library/LaunchAgents/io.soundrouter.engine.plist
      Label=io.soundrouter.engine, BundleProgram=Contents/Library/LoginItems/SoundRouterEngine.app/Contents/MacOS/SoundRouterEngine,
      MachServices={io.soundrouter.engine.xpc=true}, RunAtLoad, KeepAlive, AssociatedBundleIdentifiers=[io.soundrouter.app]
  Resources/SoundRouter.driver               (copied to /Library/Audio/Plug-Ins/HAL by the installer)
  Resources/install-driver.sh, uninstall.sh
```

The app registers the agent with `SMAppService.agent(plistName: "io.soundrouter.engine.plist")`.
The driver is installed by `install-driver.sh` run with admin rights (from the app's first-run
assistant via an authorization prompt, or by the `.pkg` postinstall). It also creates
`/Library/Application Support/SoundRouter` owned by the console user (so the engine can write
`devices.json`) and restarts coreaudiod.

## Audio flow

```
 app taps ─┐ (SPSC ring + drift resampler per source)
 AUHAL in ─┼─► engine mix thread (RT, clocked by device clock in shm) ─► shm mixBuffer ─► driver ReadInput ─► client apps (input)
 passThru ─┘            │                                                                                       
   ▲                    └─► per-monitor SPSC ring ─► AUHAL out (drift resampler) ─► speakers
 driver WriteMix ◄── client apps writing to the device (output, only if pass-thru source)
```

## Open question (spec): coreaudiod sandbox

Whether coreaudiod may `shm_open` a user-created segment and read
`/Library/Application Support/SoundRouter/devices.json` must be validated on real hardware.
Fallback: a Mach service declared under `AudioServerPlugIn_MachServices` in the driver
Info.plist. The driver treats every failure as "silence, device still visible".
