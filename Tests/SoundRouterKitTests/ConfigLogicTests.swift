import XCTest
@testable import SoundRouterKit

final class ConfigValidatorTests: XCTestCase {
    private let validJSON = """
    {
      "schemaVersion": 1,
      "settings": { "cycleFrames": 256, "logLevel": "info" },
      "devices": [{
        "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
        "name": "Mix 1", "enabled": true, "sampleRate": 48000, "outputChannelCount": 2,
        "volume": 1, "muted": false,
        "sources": [
          { "id": "00000000-0000-0000-0000-000000000001", "kind": "passThru", "enabled": true,
            "volume": 1, "muted": false, "channelCount": 2, "displayName": "Pass-Thru" },
          { "id": "00000000-0000-0000-0000-000000000002", "kind": "application", "enabled": true,
            "volume": 0.5, "muted": false, "channelCount": 2, "displayName": "Music",
            "application": { "bundleID": "com.apple.Music", "muteWhenCapturing": true } },
          { "id": "00000000-0000-0000-0000-000000000003", "kind": "inputDevice", "enabled": true,
            "volume": 1, "muted": false, "channelCount": 1, "displayName": "Mic",
            "inputDevice": { "deviceUID": "BuiltInMic", "channels": [0] } }
        ],
        "routes": [
          { "sourceID": "00000000-0000-0000-0000-000000000001", "sourceChannel": 0, "outputChannel": 0, "gain": 1 },
          { "sourceID": "00000000-0000-0000-0000-000000000001", "sourceChannel": 1, "outputChannel": 1, "gain": 1 },
          { "sourceID": "00000000-0000-0000-0000-000000000003", "sourceChannel": 0, "outputChannel": 0, "gain": 0.7 },
          { "sourceID": "00000000-0000-0000-0000-000000000003", "sourceChannel": 0, "outputChannel": 1, "gain": 0.7 }
        ],
        "monitors": [
          { "id": "00000000-0000-0000-0000-0000000000AA", "deviceUID": "Speakers", "displayName": "",
            "enabled": true, "volume": 1, "muted": false,
            "routes": [ { "deviceChannel": 0, "monitorChannel": 0 }, { "deviceChannel": 1, "monitorChannel": 1 } ] }
        ]
      }]
    }
    """

    private func valid() throws -> RouterConfig {
        try ConfigMigration.load(Data(validJSON.utf8))
    }

    private func assertInvalid(_ mutate: (inout RouterConfig) -> Void, _ fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        var c = try valid()
        mutate(&c)
        XCTAssertThrowsError(try ConfigValidator.validate(c), file: file, line: line) { err in
            let text = (err as? ConfigError)?.description ?? "\(err)"
            XCTAssertTrue(text.contains(fragment), "\"\(text)\" should contain \"\(fragment)\"",
                          file: file, line: line)
        }
    }

    func testValidFixture() throws {
        let c = try valid()
        XCTAssertEqual(c.devices.count, 1)
        XCTAssertEqual(c.devices[0].sources.count, 3)
        XCTAssertNoThrow(try ConfigValidator.validate(c))
        XCTAssertNoThrow(try ConfigValidator.validate(RouterConfig()))
    }

    func testInvalidFixtures() throws {
        try assertInvalid({ $0.devices.append($0.devices[0]) }, "duplicate device id")
        try assertInvalid({ $0.devices[0].name = "  " }, "empty name")
        try assertInvalid({ $0.devices[0].outputChannelCount = 0 }, "out of range")
        try assertInvalid({ $0.devices[0].outputChannelCount = 65 }, "out of range")
        try assertInvalid({ $0.devices[0].sampleRate = 22_050 }, "sample rate")
        try assertInvalid({ $0.devices[0].sources.append(.passThru(channels: 2)) }, "more than one Pass-Thru")
        try assertInvalid({ $0.devices[0].sources[0].channelCount = 3 }, "Pass-Thru has")
        try assertInvalid({ $0.devices[0].sources[1].channelCount = 1 }, "2 channels")
        try assertInvalid({ $0.devices[0].sources[1].application = ApplicationSource() }, "no bundleID")
        try assertInvalid({ $0.devices[0].sources[2].inputDevice?.channels = [] }, "no channels")
        try assertInvalid({ $0.devices[0].sources[2].channelCount = 2 }, "channelCount != channels.count")
        try assertInvalid({ $0.devices[0].routes.append(Route(sourceID: UUID(), sourceChannel: 0, outputChannel: 0)) },
                          "unknown source")
        try assertInvalid({ $0.devices[0].routes[2].sourceChannel = 1 }, "source channel")
        try assertInvalid({ $0.devices[0].routes[0].outputChannel = 2 }, "output channel")
        try assertInvalid({ $0.devices[0].routes.append($0.devices[0].routes[0]) }, "duplicate route")
        try assertInvalid({ $0.devices[0].monitors[0].routes[0].deviceChannel = 5 }, "monitor route device channel")
        try assertInvalid({ $0.devices[0].monitors[0].routes[0].monitorChannel = -1 }, "negative")
        try assertInvalid({ $0.settings.cycleFrames = 32 }, "cycleFrames")
        try assertInvalid({ $0.settings.cycleFrames = 2048 }, "cycleFrames")
    }

    func testApplicationSourceByPidOrPathIsValid() throws {
        var c = try valid()
        c.devices[0].sources[1].application = ApplicationSource(pid: 42)
        XCTAssertNoThrow(try ConfigValidator.validate(c))
        c.devices[0].sources[1].application = ApplicationSource(executablePath: "/usr/bin/say")
        XCTAssertNoThrow(try ConfigValidator.validate(c))
    }
}

final class ConfigMigrationTests: XCTestCase {
    func testFutureVersionRejected() {
        let json = #"{ "schemaVersion": 99, "devices": [], "settings": { "cycleFrames": 256, "logLevel": "info" } }"#
        XCTAssertThrowsError(try ConfigMigration.load(Data(json.utf8))) { err in
            XCTAssertTrue("\(err)".contains("newer"))
        }
    }

    func testGarbageRejected() {
        XCTAssertThrowsError(try ConfigMigration.load(Data("not json".utf8)))
        XCTAssertThrowsError(try ConfigMigration.load(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try ConfigMigration.load(Data(#"{"devices": []}"#.utf8)))
        XCTAssertThrowsError(try ConfigMigration.load(Data(#"{"schemaVersion": 0}"#.utf8)))
        XCTAssertThrowsError(try ConfigMigration.load(Data(#"{"schemaVersion": 1, "devices": 3}"#.utf8)))
    }

    func testInvalidAfterDecodeRejected() {
        let json = """
        { "schemaVersion": 1, "devices": [], "settings": { "cycleFrames": 5, "logLevel": "info" } }
        """
        XCTAssertThrowsError(try ConfigMigration.load(Data(json.utf8)))
    }

    func testRoundTripThroughLoad() throws {
        let (c, _) = try ConfigReducer.apply(.createDevice(name: "A"), to: RouterConfig(),
                                             defaultSampleRate: 44_100)
        let loaded = try ConfigMigration.load(SRJSON.encode(c))
        XCTAssertEqual(loaded, c)
    }
}

final class ConfigReducerTests: XCTestCase {
    private func apply(_ cmd: ConfigCommand, _ c: RouterConfig, rate: Double = 48_000) throws
        -> (RouterConfig, UUID?) {
        try ConfigReducer.apply(cmd, to: c, defaultSampleRate: rate)
    }

    private func newDevice(rate: Double = 48_000) throws -> (RouterConfig, UUID) {
        let (c, id) = try apply(.createDevice(name: "Mix"), RouterConfig(), rate: rate)
        return (c, try XCTUnwrap(id))
    }

    private func app(_ bundle: String = "com.example.app") -> Source {
        .application(ApplicationSource(bundleID: bundle), displayName: bundle)
    }

    func testCreateDeviceDefaults() throws {
        let (c, id) = try newDevice(rate: 44_100)
        let d = try XCTUnwrap(c.devices.first)
        XCTAssertEqual(d.id, id)
        XCTAssertEqual(d.name, "Mix")
        XCTAssertEqual(d.outputChannelCount, 2)
        XCTAssertEqual(d.sampleRate, 44_100)
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.sources.count, 1)
        XCTAssertEqual(d.sources[0].kind, .passThru)
        XCTAssertEqual(d.sources[0].channelCount, 2)
        XCTAssertEqual(Set(d.routes), Set([
            Route(sourceID: d.sources[0].id, sourceChannel: 0, outputChannel: 0),
            Route(sourceID: d.sources[0].id, sourceChannel: 1, outputChannel: 1),
        ]))
        // Unsupported default output rate falls back to 48 kHz.
        let (c2, _) = try apply(.createDevice(name: "B"), RouterConfig(), rate: 12_345)
        XCTAssertEqual(c2.devices[0].sampleRate, 48_000)
    }

    func testCreateDeviceEmptyNameRejected() {
        XCTAssertThrowsError(try apply(.createDevice(name: ""), RouterConfig()))
    }

    func testAddSourceStereoAutoRoutes() throws {
        var (c, dev) = try newDevice()
        let src = app()
        let (c2, sid) = try apply(.addSource(deviceID: dev, source: src), c)
        XCTAssertEqual(sid, src.id)
        let routes = c2.devices[0].routes.filter { $0.sourceID == src.id }
        XCTAssertEqual(Set(routes), Set([
            Route(sourceID: src.id, sourceChannel: 0, outputChannel: 0),
            Route(sourceID: src.id, sourceChannel: 1, outputChannel: 1),
        ]))
        // Mono input source on a stereo device: no automatic routes.
        c = c2
        let mic = Source.inputDevice(InputDeviceSource(deviceUID: "mic", channels: [0]), displayName: "Mic")
        (c, _) = try apply(.addSource(deviceID: dev, source: mic), c)
        XCTAssertTrue(c.devices[0].routes.allSatisfy { $0.sourceID != mic.id })
        // Stereo source on a 4-channel device: no automatic routes.
        (c, _) = try apply(.setDeviceChannelCount(id: dev, count: 4), c)
        let other = app("com.example.other")
        (c, _) = try apply(.addSource(deviceID: dev, source: other), c)
        XCTAssertTrue(c.devices[0].routes.allSatisfy { $0.sourceID != other.id })
        dev = c.devices[0].id
        XCTAssertEqual(c.devices[0].sources.count, 4)
    }

    func testSecondPassThruRejected() throws {
        let (c, dev) = try newDevice()
        XCTAssertThrowsError(try apply(.addSource(deviceID: dev, source: .passThru(channels: 2)), c))
    }

    func testAddPassThruAfterRemovalGetsDeviceChannelsAndRoutes() throws {
        var (c, dev) = try newDevice()
        (c, _) = try apply(.setDeviceChannelCount(id: dev, count: 3), c)
        (c, _) = try apply(.removeSource(deviceID: dev, sourceID: c.devices[0].sources[0].id), c)
        XCTAssertTrue(c.devices[0].routes.isEmpty)
        let (c2, sid) = try apply(.addSource(deviceID: dev, source: .passThru(channels: 1)), c)
        let pt = try XCTUnwrap(c2.devices[0].sources.first { $0.id == sid })
        XCTAssertEqual(pt.channelCount, 3)
        XCTAssertEqual(c2.devices[0].routes.count, 3)
    }

    func testChannelCountBoundsAndResize() throws {
        var (c, dev) = try newDevice()
        XCTAssertThrowsError(try apply(.setDeviceChannelCount(id: dev, count: 0), c))
        XCTAssertThrowsError(try apply(.setDeviceChannelCount(id: dev, count: 65), c))
        XCTAssertNoThrow(try apply(.setDeviceChannelCount(id: dev, count: 64), c))
        XCTAssertNoThrow(try apply(.setDeviceChannelCount(id: dev, count: 1), c))

        let src = app()
        (c, _) = try apply(.addSource(deviceID: dev, source: src), c)
        let mon = Monitor(deviceUID: "spk", routes: [MonitorRoute(deviceChannel: 0, monitorChannel: 0),
                                                     MonitorRoute(deviceChannel: 1, monitorChannel: 1)])
        (c, _) = try apply(.addMonitor(deviceID: dev, monitor: mon), c)

        (c, _) = try apply(.setDeviceChannelCount(id: dev, count: 8), c)
        var d = c.devices[0]
        let pt = d.sources.first { $0.kind == .passThru }!
        XCTAssertEqual(pt.channelCount, 8)
        XCTAssertEqual(Set(d.routes.filter { $0.sourceID == pt.id }),
                       Set((0..<8).map { Route(sourceID: pt.id, sourceChannel: $0, outputChannel: $0) }))
        XCTAssertEqual(d.routes.filter { $0.sourceID == src.id }.count, 2)

        (c, _) = try apply(.setDeviceChannelCount(id: dev, count: 1), c)
        d = c.devices[0]
        XCTAssertEqual(d.outputChannelCount, 1)
        XCTAssertEqual(d.sources.first { $0.kind == .passThru }!.channelCount, 1)
        XCTAssertTrue(d.routes.allSatisfy { $0.outputChannel < 1 && ($0.sourceID != pt.id || $0.sourceChannel < 1) })
        XCTAssertEqual(d.routes.filter { $0.sourceID == pt.id }.count, 1)
        XCTAssertEqual(d.routes.filter { $0.sourceID == src.id }.count, 1)
        XCTAssertEqual(d.monitors[0].routes, [MonitorRoute(deviceChannel: 0, monitorChannel: 0)])
        XCTAssertNoThrow(try ConfigValidator.validate(c))
    }

    func testRemoveSourceRemovesRoutes() throws {
        var (c, dev) = try newDevice()
        let src = app()
        (c, _) = try apply(.addSource(deviceID: dev, source: src), c)
        XCTAssertEqual(c.devices[0].routes.count, 4)
        (c, _) = try apply(.removeSource(deviceID: dev, sourceID: src.id), c)
        XCTAssertEqual(c.devices[0].routes.count, 2)
        XCTAssertFalse(c.devices[0].sources.contains { $0.id == src.id })
        XCTAssertThrowsError(try apply(.removeSource(deviceID: dev, sourceID: src.id), c))
    }

    func testDuplicateDeviceRemapsIDs() throws {
        var (c, dev) = try newDevice()
        let src = app()
        (c, _) = try apply(.addSource(deviceID: dev, source: src), c)
        (c, _) = try apply(.addMonitor(deviceID: dev, monitor: Monitor(deviceUID: "spk")), c)
        let (c2, newID) = try apply(.duplicateDevice(id: dev), c)
        XCTAssertEqual(c2.devices.count, 2)
        let orig = c2.devices[0], copy = c2.devices[1]
        XCTAssertEqual(copy.id, newID)
        XCTAssertNotEqual(copy.id, orig.id)
        XCTAssertEqual(copy.name, "Mix copy")
        XCTAssertEqual(copy.sources.count, orig.sources.count)
        XCTAssertTrue(Set(copy.sources.map(\.id)).isDisjoint(with: Set(orig.sources.map(\.id))))
        XCTAssertEqual(copy.routes.count, orig.routes.count)
        let copyIDs = Set(copy.sources.map(\.id))
        XCTAssertTrue(copy.routes.allSatisfy { copyIDs.contains($0.sourceID) })
        XCTAssertNotEqual(copy.monitors[0].id, orig.monitors[0].id)
        for (a, b) in zip(orig.sources, copy.sources) {
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(orig.routes.filter { $0.sourceID == a.id }.map(\.outputChannel),
                           copy.routes.filter { $0.sourceID == b.id }.map(\.outputChannel))
        }
    }

    func testRoutesAndUnknownObjects() throws {
        var (c, dev) = try newDevice()
        let pt = c.devices[0].sources[0].id
        (c, _) = try apply(.addRoute(deviceID: dev, route: Route(sourceID: pt, sourceChannel: 0, outputChannel: 1, gain: 0.5)), c)
        XCTAssertEqual(c.devices[0].routes.count, 3)
        // Same key updates the gain instead of duplicating.
        (c, _) = try apply(.addRoute(deviceID: dev, route: Route(sourceID: pt, sourceChannel: 0, outputChannel: 1, gain: 0.25)), c)
        XCTAssertEqual(c.devices[0].routes.count, 3)
        XCTAssertEqual(c.devices[0].routes.last?.gain, 0.25)
        (c, _) = try apply(.removeRoute(deviceID: dev, route: Route(sourceID: pt, sourceChannel: 0, outputChannel: 1, gain: 9)), c)
        XCTAssertEqual(c.devices[0].routes.count, 2)
        XCTAssertThrowsError(try apply(.addRoute(deviceID: dev, route: Route(sourceID: pt, sourceChannel: 0, outputChannel: 5)), c))
        XCTAssertThrowsError(try apply(.renameDevice(id: UUID(), name: "x"), c))
        XCTAssertThrowsError(try apply(.deleteDevice(id: UUID()), c))
        XCTAssertThrowsError(try apply(.setDeviceSampleRate(id: dev, sampleRate: 1000), c))
        XCTAssertThrowsError(try apply(.updateSettings(EngineSettings(cycleFrames: 10)), c))
        (c, _) = try apply(.setDeviceVolume(id: dev, volume: 2, muted: true), c)
        XCTAssertEqual(c.devices[0].volume, 1)
        XCTAssertTrue(c.devices[0].muted)
        (c, _) = try apply(.deleteDevice(id: dev), c)
        XCTAssertTrue(c.devices.isEmpty)
    }

    func testJSONRoundTrip() throws {
        var (c, dev) = try newDevice()
        (c, _) = try apply(.addSource(deviceID: dev, source: app()), c)
        (c, _) = try apply(.addSource(deviceID: dev, source: .inputDevice(
            InputDeviceSource(deviceUID: "mic", channels: [0, 2]), displayName: "Mic")), c)
        (c, _) = try apply(.addMonitor(deviceID: dev, monitor: Monitor(
            deviceUID: "spk", routes: [MonitorRoute(deviceChannel: 1, monitorChannel: 0)])), c)
        (c, _) = try apply(.updateSettings(EngineSettings(cycleFrames: 512, logLevel: .debug)), c)
        let data = SRJSON.encode(c)
        let decoded = try SRJSON.decode(RouterConfig.self, data)
        XCTAssertEqual(decoded, c)
        // Commands round-trip too (XPC payloads).
        let cmd = ConfigCommand.addRoute(deviceID: dev, route: Route(sourceID: dev, sourceChannel: 1, outputChannel: 0, gain: 0.5))
        let back = try SRJSON.decode(ConfigCommand.self, SRJSON.encode(cmd))
        guard case .addRoute(let d, let r) = back else { return XCTFail("wrong case") }
        XCTAssertEqual(d, dev)
        XCTAssertEqual(r.gain, 0.5)
    }
}
