import AppKit
import Darwin
import Foundation
import SRCore
import SoundRouterKit

// SoundRouterEngine — background LaunchAgent (packaged as an LSUIElement app bundle).
//
// Threads:
//   main           NSApplication run loop (workspace sleep/wake notifications, signals, TCC UI)
//   control queue  serial DispatchQueue: config, XPC handlers, Core Audio listeners, 10 Hz poll
//   mix threads    one RT pthread per enabled device (MixCore.swift)
//   Core Audio IO  tap IOProcs, AUHAL input/output callbacks (RT, SPSC rings only)
//
// Flags:
//   --selftest     load/save config in $SOUNDROUTER_CONFIG_DIR (or a temp dir), exercise the
//                  config path, devices.json and one pass-thru device's shm + mix thread, exit.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

let controller = EngineController()
controller.start()
let xpc = XPCService(controller: controller)
xpc.resume()

// SIGTERM / SIGINT: stop mixers cleanly, keep shm segments (devices keep serving silence).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Log.info("Signal \(sig) received; shutting down")
        controller.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

let app = NSApplication.shared
// In the LSUIElement bundle the policy is already .accessory; a bare binary (dev) must not
// show a Dock icon either. .accessory (not .prohibited) keeps system permission prompts working.
app.setActivationPolicy(.accessory)
Log.info("SoundRouterEngine \(EngineController.engineVersion) started (pid \(getpid()))")
app.run()
