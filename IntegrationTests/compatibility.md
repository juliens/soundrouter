# Compatibility checklist (manual)

For each client: select a SoundRouter device as **input** (microphone) — and as **output** when the
device has pass-thru — then verify: device listed with its name, audio flows, no crackles over 10 min,
sample-rate changes handled, device deletion handled without client crash.
Note app version, macOS version and result (OK / KO + details).

## Video conferencing
- [ ] Zoom — microphone = virtual device; also "original sound" mode
- [ ] Microsoft Teams (new client)
- [ ] Google Meet in Chrome and Safari
- [ ] FaceTime
- [ ] Slack huddles / Discord

## DAW / audio
- [ ] Logic Pro — record 8+ channels from a multichannel device; pass-thru from Logic output
- [ ] Ableton Live — device as input at 48 and 96 kHz
- [ ] Reaper — 64-channel device
- [ ] Audacity
- [ ] Audio MIDI Setup — formats shown, aggregate device containing a SoundRouter device

## Screen recording / streaming
- [ ] OBS Studio — macOS audio input capture with the device
- [ ] QuickTime Player — new audio recording / screen recording with the device as microphone
- [ ] macOS screenshot tool (Cmd-Shift-5) — microphone option
- [ ] Loopback / other virtual drivers installed side by side (no conflict)

## Browsers (as captured application sources and as consumers)
- [ ] Safari, Chrome, Firefox, Arc — captured as application (multi-process helpers)
- [ ] Web page `getUserMedia` selecting the virtual device

## Other
- [ ] Music / Spotify captured as application sources, mute-while-capturing respected
- [ ] System sounds and default output switching do not disturb the virtual devices
- [ ] Bluetooth headphones as monitor (latency, 44.1/48 kHz changes)
