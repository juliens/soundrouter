# Robustness checklist

Run with `srctl status` / the app open and a recorder recording the device when relevant.
Record result, macOS version, hardware and date for each line.

## Engine / agent
- [ ] `kill -9` the engine: launchd restarts it (KeepAlive) within ~5 s; devices stay visible (silence meanwhile); capture resumes; config unchanged.
- [ ] Engine crash loop (e.g. corrupt config.json): engine starts with `config.json.bak` or an empty config and reports the error; no crash loop.
- [ ] Agent disabled in System Settings > General > Login Items: the app detects it and guides the user; re-enabling restores operation.
- [ ] Logout / login: agent starts, devices republished, sources reattached.
- [ ] Sleep / wake (lid close 10 min): capture and monitors resume, no stuck underrun counter growth.
- [ ] Engine upgrade while running (install newer pkg): new engine running after install, config migrated.

## coreaudiod / driver
- [ ] `sudo killall coreaudiod`: devices reappear; engine re-attaches shm; clients (recorder) recover or report device loss cleanly.
- [ ] Engine stopped: devices remain visible and deliver silence (no client error).
- [ ] devices.json missing / unreadable / invalid JSON: driver publishes nothing or keeps previous list, never crashes coreaudiod.
- [ ] Create / delete / rename devices 50 times in a row (srctl loop): no restart of coreaudiod needed, no leaked devices.
- [ ] Change sample rate of a device while a client records from it: client follows or stops cleanly.
- [ ] 64-channel device at 192 kHz: visible, pass-thru bit-exact, CPU acceptable.

## Sources / monitors
- [ ] Captured app quits and relaunches: source "waiting" then active again automatically.
- [ ] Captured app launched twice (multiple processes, helpers e.g. browsers): all audio captured.
- [ ] USB input unplugged during capture: source "disconnected", config kept; replug: resumes.
- [ ] Monitor output device unplugged / default output changed: monitor "disconnected", no effect on the virtual device.
- [ ] Input source at 44.1 kHz into 48 kHz device for 1 h: no drift accumulation (latency stable).
- [ ] Audio Capture permission revoked in System Settings: source "permissionDenied", clear message, no crash.
- [ ] Microphone permission denied: input sources "permissionDenied", app sources unaffected.
- [ ] Feedback loop (device A input -> device B -> A): rejected by validation or bounded, no runaway level.

## Install / uninstall
- [ ] Fresh Mac, macOS 14.2 and latest: pkg install, first run, permissions, devices visible (J6 exit criterion).
- [ ] Reinstall over existing install: idempotent, config kept.
- [ ] `uninstall.sh`: driver, agent, support dirs removed; coreaudiod restarted; no SoundRouter device left.
- [ ] `uninstall.sh --keep-config` then reinstall: previous devices restored.
