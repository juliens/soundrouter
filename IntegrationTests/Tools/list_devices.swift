// Lists Core Audio devices and optionally asserts SoundRouter devices are published correctly.
//
//   list_devices                                   list every device
//   list_devices --uid UID [--channels N] [--rate R] [--rates 44100,48000,...]
//   list_devices --devices-json "/Library/Application Support/SoundRouter/devices.json"
//       asserts every device listed by the engine is visible with its channel count and rate.
// Exit 0 = all assertions passed.

import CoreAudio
import Foundation

@main
struct ListDevices {
    static func describe(_ d: AudioObjectID) -> String {
        let rates = CA.availableRates(d).map { r in
            r.lowerBound == r.upperBound ? "\(Int(r.lowerBound))" : "\(Int(r.lowerBound))-\(Int(r.upperBound))"
        }.joined(separator: ",")
        return "\(d)\t\(CA.uid(d) ?? "?")\t\(CA.name(d) ?? "?")\tin=\(CA.channelCount(d, kAudioObjectPropertyScopeInput))"
            + "\tout=\(CA.channelCount(d, kAudioObjectPropertyScopeOutput))\trate=\(Int(CA.nominalRate(d)))\trates=[\(rates)]"
    }

    static func supports(_ d: AudioObjectID, _ rate: Double) -> Bool {
        CA.availableRates(d).contains { $0.contains(rate) }
    }

    /// Returns a list of failures for one expected device.
    static func check(uid: String, channels: Int?, rate: Double?, rates: [Double], passThru: Bool?) -> [String] {
        guard let d = CA.device(uid: uid) else { return ["device \(uid) not visible in Core Audio"] }
        print("found: " + describe(d))
        var errs: [String] = []
        let inCh = CA.channelCount(d, kAudioObjectPropertyScopeInput)
        let outCh = CA.channelCount(d, kAudioObjectPropertyScopeOutput)
        if let channels {
            if inCh != channels { errs.append("\(uid): input channels \(inCh) != \(channels)") }
            if passThru == true, outCh != channels { errs.append("\(uid): output channels \(outCh) != \(channels) (pass-thru)") }
        }
        if let rate {
            if CA.nominalRate(d) != rate { errs.append("\(uid): nominal rate \(CA.nominalRate(d)) != \(rate)") }
            if !supports(d, rate) { errs.append("\(uid): rate \(rate) not in available rates") }
        }
        for r in rates where !supports(d, r) { errs.append("\(uid): rate \(r) not available") }
        return errs
    }

    static func main() {
        let args = Args()
        let rates = (args.string("rates") ?? "").split(separator: ",").compactMap { Double($0) }

        if let path = args.string("devices-json") {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = obj["devices"] as? [[String: Any]] else { fail("cannot read \(path)") }
            if devices.isEmpty { print("WARN: \(path) lists no device (create one in the app first)") }
            var errs: [String] = []
            for dev in devices {
                guard let id = dev["id"] as? String else { errs.append("entry without id"); continue }
                errs += check(uid: id, channels: dev["channels"] as? Int, rate: dev["sampleRate"] as? Double,
                              rates: rates, passThru: dev["passThru"] as? Bool)
            }
            if !errs.isEmpty { fail(errs.joined(separator: "\n")) }
            print("PASS: \(devices.count) device(s) visible")
            return
        }

        if let uid = args.string("uid") {
            let errs = check(uid: uid, channels: args.string("channels").flatMap(Int.init),
                             rate: args.string("rate").flatMap(Double.init), rates: rates, passThru: args.has("passthru"))
            if !errs.isEmpty { fail(errs.joined(separator: "\n")) }
            print("PASS")
            return
        }

        for d in CA.allDevices() { print(describe(d)) }
    }
}
