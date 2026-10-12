import AppKit
import SoundRouterKit
import SwiftUI

// MARK: - Model

/// A connectable point in the editor.
enum PortID: Hashable {
    case source(UUID, Int)         // source id, source channel
    case outputIn(Int)             // device output channel (left side, fed by sources)
    case outputOut(Int)            // device output channel (right side, feeds monitors)
    case monitor(UUID, Int)        // monitor id, monitor channel
}

/// A drawn cable (a Route or a MonitorRoute).
enum CableID: Hashable {
    case route(sourceID: UUID, sourceChannel: Int, outputChannel: Int)
    case monitor(monitorID: UUID, deviceChannel: Int, monitorChannel: Int)
}

struct PortDrag: Equatable {
    var from: PortID
    var location: CGPoint
}

let routingSpace = "routing"

struct PortFramesKey: PreferenceKey {
    static var defaultValue: [PortID: CGRect] { [:] }
    static func reduce(value: inout [PortID: CGRect], nextValue: () -> [PortID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Interaction state shared by the ports, cables and the editor.
@Observable
@MainActor
final class RoutingModel {
    var frames: [PortID: CGRect] = [:]
    var drag: PortDrag?
    var selectedCable: CableID?
    /// First port of a click-then-click connection.
    var pendingPort: PortID?
    @ObservationIgnored var connect: ((PortID, PortID) -> Void)?
    @ObservationIgnored var requestFocus: (() -> Void)?

    func port(at point: CGPoint) -> PortID? {
        frames.first { $0.value.insetBy(dx: -6, dy: -6).contains(point) }?.key
    }

    var dropTarget: PortID? {
        guard let drag, let target = port(at: drag.location), target != drag.from,
              Self.compatible(drag.from, target) else { return nil }
        return target
    }

    func endDrag(at point: CGPoint) {
        defer { drag = nil }
        guard let from = drag?.from, let to = port(at: point), to != from else { return }
        connect?(from, to)
    }

    /// Click on a port: first click arms it, a click on a compatible port connects them.
    func click(_ id: PortID) {
        selectedCable = nil
        if let from = pendingPort, from != id, Self.compatible(from, id) {
            pendingPort = nil
            connect?(from, id)
        } else {
            pendingPort = pendingPort == id ? nil : id
        }
    }

    static func compatible(_ a: PortID, _ b: PortID) -> Bool {
        switch (a, b) {
        case (.source, .outputIn), (.outputIn, .source), (.outputOut, .monitor), (.monitor, .outputOut): return true
        default: return false
        }
    }
}

// MARK: - Editor

/// Three-column routing editor: Sources → Output channels → Monitors, with cables (F9, F11).
struct RoutingEditor: View {
    let device: VirtualDevice
    @Environment(EngineClient.self) private var client
    @Environment(SourceCatalog.self) private var catalog
    @State private var model = RoutingModel()
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { viewport in
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 110) {
                SourcesColumn(device: device, routing: routing)
                    .frame(width: 340)
                OutputsColumn(device: device, routing: routing)
                    .frame(width: 180)
                MonitorsColumn(device: device, routing: routing)
                    .frame(width: 250)
            }
            .padding(20)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedCable = nil; model.pendingPort = nil }
            }
            .coordinateSpace(name: routingSpace)
            .overlay { CablesLayer(device: device, routing: routing, names: names) }
            .onPreferenceChange(PortFramesKey.self) { frames in
                MainActor.assumeIsolated { model.frames = frames }
            }
            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
        }
        }
        .environment(model)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard model.selectedCable != nil else { return .ignored }
            deleteSelectedCable()
            return .handled
        }
        .onDeleteCommand { deleteSelectedCable() }
        .onExitCommand { model.selectedCable = nil; model.pendingPort = nil }
        .onAppear {
            model.connect = { a, b in routing.connect(a, b) }
            model.requestFocus = { focused = true }
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: device) { _, _ in
            model.connect = { a, b in routing.connect(a, b) }
        }
    }

    private var routing: RoutingActions { RoutingActions(device: device, client: client, catalog: catalog) }
    private var names: PortNames { PortNames(device: device) }

    /// SwiftUI key handlers need keyboard focus, which macOS only grants to custom views when
    /// "Keyboard navigation" is enabled. A local monitor makes Backspace / Delete / Escape work
    /// on a selected cable regardless, unless a text field is being edited.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window?.firstResponder is NSText { return event }
            switch event.keyCode {
            case 51, 117: // Backspace, forward Delete
                guard model.selectedCable != nil else { return event }
                deleteSelectedCable()
                return nil
            case 53: // Escape
                guard model.selectedCable != nil || model.pendingPort != nil else { return event }
                model.selectedCable = nil
                model.pendingPort = nil
                return nil
            default:
                return event
            }
        }
    }

    private func deleteSelectedCable() {
        guard let cable = model.selectedCable else { return }
        routing.remove(cable)
        model.selectedCable = nil
    }
}

/// Route / monitor-route editing commands, shared by drag, context menus and accessibility.
@MainActor
struct RoutingActions {
    let device: VirtualDevice
    let client: EngineClient
    let catalog: SourceCatalog

    func connect(_ a: PortID, _ b: PortID) {
        switch (a, b) {
        case let (.source(s, c), .outputIn(o)), let (.outputIn(o), .source(s, c)):
            addRoute(source: s, channel: c, output: o)
        case let (.outputOut(o), .monitor(m, c)), let (.monitor(m, c), .outputOut(o)):
            addMonitorRoute(monitor: m, deviceChannel: o, monitorChannel: c)
        default:
            break
        }
    }

    func isRouted(source: UUID, channel: Int, output: Int) -> Bool {
        device.routes.contains { $0.sourceID == source && $0.sourceChannel == channel && $0.outputChannel == output }
    }

    func addRoute(source: UUID, channel: Int, output: Int) {
        guard !isRouted(source: source, channel: channel, output: output) else { return }
        client.send(.addRoute(deviceID: device.id,
                              route: Route(sourceID: source, sourceChannel: channel, outputChannel: output)))
    }

    func removeRoute(source: UUID, channel: Int, output: Int) {
        client.send(.removeRoute(deviceID: device.id,
                                 route: Route(sourceID: source, sourceChannel: channel, outputChannel: output)))
    }

    func toggleRoute(source: UUID, channel: Int, output: Int) {
        if isRouted(source: source, channel: channel, output: output) {
            removeRoute(source: source, channel: channel, output: output)
        } else {
            addRoute(source: source, channel: channel, output: output)
        }
    }

    func isMonitorRouted(monitor: UUID, deviceChannel: Int, monitorChannel: Int) -> Bool {
        device.monitors.first { $0.id == monitor }?.routes
            .contains(MonitorRoute(deviceChannel: deviceChannel, monitorChannel: monitorChannel)) ?? false
    }

    func addMonitorRoute(monitor: UUID, deviceChannel: Int, monitorChannel: Int) {
        guard var m = device.monitors.first(where: { $0.id == monitor }) else { return }
        let r = MonitorRoute(deviceChannel: deviceChannel, monitorChannel: monitorChannel)
        guard !m.routes.contains(r) else { return }
        m.routes.append(r)
        client.send(.updateMonitor(deviceID: device.id, monitor: m))
    }

    func removeMonitorRoute(monitor: UUID, deviceChannel: Int, monitorChannel: Int) {
        guard var m = device.monitors.first(where: { $0.id == monitor }) else { return }
        m.routes.removeAll { $0.deviceChannel == deviceChannel && $0.monitorChannel == monitorChannel }
        client.send(.updateMonitor(deviceID: device.id, monitor: m))
    }

    func toggleMonitorRoute(monitor: UUID, deviceChannel: Int, monitorChannel: Int) {
        if isMonitorRouted(monitor: monitor, deviceChannel: deviceChannel, monitorChannel: monitorChannel) {
            removeMonitorRoute(monitor: monitor, deviceChannel: deviceChannel, monitorChannel: monitorChannel)
        } else {
            addMonitorRoute(monitor: monitor, deviceChannel: deviceChannel, monitorChannel: monitorChannel)
        }
    }

    func remove(_ cable: CableID) {
        switch cable {
        case let .route(s, c, o): removeRoute(source: s, channel: c, output: o)
        case let .monitor(m, d, c): removeMonitorRoute(monitor: m, deviceChannel: d, monitorChannel: c)
        }
    }

    /// Number of channels of a monitor's physical output device.
    func monitorChannelCount(_ monitor: Monitor) -> Int {
        if let dev = catalog.device(uid: monitor.deviceUID), dev.outputChannels > 0 {
            return min(dev.outputChannels, maxOutputChannels)
        }
        return max(2, (monitor.routes.map(\.monitorChannel).max() ?? -1) + 1)
    }
}

/// Human-readable names for ports and cables (VoiceOver labels, menus).
struct PortNames {
    let device: VirtualDevice

    func sourceName(_ id: UUID) -> String {
        guard let s = device.sources.first(where: { $0.id == id }) else { return "Source" }
        return SourceNaming.name(s)
    }

    func monitorName(_ id: UUID) -> String {
        device.monitors.first { $0.id == id }.map { $0.displayName.isEmpty ? $0.deviceUID : $0.displayName } ?? "Monitor"
    }

    func cableLabel(_ cable: CableID) -> String {
        switch cable {
        case let .route(s, c, o): return "Cable \(sourceName(s)) \(c + 1) to Output \(o + 1)"
        case let .monitor(m, d, c): return "Cable Output \(d + 1) to \(monitorName(m)) \(c + 1)"
        }
    }
}

enum SourceNaming {
    static func name(_ s: Source) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        switch s.kind {
        case .passThru: return "Pass-Thru"
        case .application: return s.application?.bundleID ?? s.application?.executablePath ?? "Application"
        case .inputDevice: return s.inputDevice?.deviceUID ?? "Input"
        }
    }

    static func channelLabel(_ s: Source, _ channel: Int) -> String {
        switch s.kind {
        case .application where s.channelCount == 2: return channel == 0 ? "L" : "R"
        case .inputDevice:
            if let ch = s.inputDevice?.channels, channel < ch.count { return "In \(ch[channel] + 1)" }
            return "\(channel + 1)"
        default: return "\(channel + 1)"
        }
    }
}

// MARK: - Ports

struct PortView: View {
    let id: PortID
    let label: String
    var connected: Bool
    var tint: Color = .accentColor
    @Environment(RoutingModel.self) private var model

    var body: some View {
        let isTarget = model.dropTarget == id
        let isSource = model.drag?.from == id || model.pendingPort == id
        Circle()
            .fill(connected ? tint : Color.primary.opacity(0.12))
            .overlay(Circle().strokeBorder(isTarget ? Color.accentColor : Color.primary.opacity(0.45),
                                           lineWidth: isTarget ? 2.5 : 1))
            .frame(width: isTarget || isSource ? 14 : 12, height: isTarget || isSource ? 14 : 12)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: PortFramesKey.self,
                                           value: [id: g.frame(in: .named(routingSpace))])
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(routingSpace))
                    .onChanged { v in
                        model.pendingPort = nil
                        model.drag = PortDrag(from: id, location: v.location)
                    }
                    .onEnded { v in model.endDrag(at: v.location) }
            )
            .onTapGesture { model.click(id) }
            .help("Drag to another port, or click here then on another port, to connect")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(connected ? "connected" : "not connected")
            .accessibilityHint("Use the context menu to connect or disconnect")
    }
}

// MARK: - Cables

struct CableShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = max(40, abs(to.x - from.x) / 2)
        p.move(to: from)
        p.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y), control2: CGPoint(x: to.x - dx, y: to.y))
        return p
    }
}

/// Wide invisible hit area along the middle of a cable (ends excluded so ports stay clickable).
struct CableHitShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        CableShape(from: from, to: to).path(in: rect)
            .trimmedPath(from: 0.08, to: 0.92)
            .strokedPath(StrokeStyle(lineWidth: 10, lineCap: .round))
    }
}

struct CablesLayer: View {
    let device: VirtualDevice
    let routing: RoutingActions
    let names: PortNames
    @Environment(RoutingModel.self) private var model

    private struct Cable: Identifiable {
        var id: CableID
        var from: CGPoint
        var to: CGPoint
        var color: Color
        var dimmed: Bool
    }

    private var cables: [Cable] {
        func center(_ p: PortID) -> CGPoint? { model.frames[p].map { CGPoint(x: $0.midX, y: $0.midY) } }
        var out: [Cable] = []
        for r in device.routes {
            guard let a = center(.source(r.sourceID, r.sourceChannel)), let b = center(.outputIn(r.outputChannel))
            else { continue }
            let src = device.sources.first { $0.id == r.sourceID }
            out.append(Cable(id: .route(sourceID: r.sourceID, sourceChannel: r.sourceChannel, outputChannel: r.outputChannel),
                             from: a, to: b, color: CableColor.color(for: r.sourceID),
                             dimmed: !(src?.enabled ?? false) || (src?.muted ?? false)))
        }
        for m in device.monitors {
            for r in m.routes {
                guard let a = center(.outputOut(r.deviceChannel)), let b = center(.monitor(m.id, r.monitorChannel))
                else { continue }
                out.append(Cable(id: .monitor(monitorID: m.id, deviceChannel: r.deviceChannel, monitorChannel: r.monitorChannel),
                                 from: a, to: b, color: .secondary, dimmed: !m.enabled || m.muted))
            }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cables) { cable in
                let selected = model.selectedCable == cable.id
                ZStack {
                    if selected {
                        CableShape(from: cable.from, to: cable.to)
                            .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    }
                    CableShape(from: cable.from, to: cable.to)
                        .stroke(cable.color.opacity(cable.dimmed ? 0.35 : 0.9),
                                style: StrokeStyle(lineWidth: selected ? 3 : 2, lineCap: .round))
                }
                .contentShape(CableHitShape(from: cable.from, to: cable.to))
                .onTapGesture {
                    model.pendingPort = nil
                    model.selectedCable = cable.id
                    model.requestFocus?()
                }
                .contextMenu {
                    Button("Delete Cable") { routing.remove(cable.id) }
                }
                .accessibilityElement()
                .accessibilityLabel(names.cableLabel(cable.id))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.selectedCable = cable.id }
                .accessibilityAction(named: "Delete") { routing.remove(cable.id) }
            }
            if let drag = model.drag, let f = model.frames[drag.from] {
                let start = CGPoint(x: f.midX, y: f.midY)
                let end = model.dropTarget.flatMap { model.frames[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) } ?? drag.location
                let reversed = end.x < start.x
                CableShape(from: reversed ? end : start, to: reversed ? start : end)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Output channels column

struct OutputsColumn: View {
    let device: VirtualDevice
    let routing: RoutingActions
    @Environment(EngineClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outputs").font(.headline)
                Text("\(device.outputChannelCount)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    client.send(.setDeviceChannelCount(id: device.id, count: device.outputChannelCount - 1))
                } label: { Image(systemName: "minus") }
                    .disabled(device.outputChannelCount <= 1)
                    .accessibilityLabel("Remove output channel")
                Button {
                    client.send(.setDeviceChannelCount(id: device.id, count: device.outputChannelCount + 1))
                } label: { Image(systemName: "plus") }
                    .disabled(device.outputChannelCount >= maxOutputChannels)
                    .accessibilityLabel("Add output channel")
            }
            .buttonStyle(.borderless)
            .frame(height: 22)

            VStack(spacing: 2) {
                ForEach(0..<device.outputChannelCount, id: \.self) { ch in
                    OutputRow(device: device, channel: ch, routing: routing)
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }
}

struct OutputRow: View {
    let device: VirtualDevice
    let channel: Int
    let routing: RoutingActions

    var body: some View {
        let fed = device.routes.contains { $0.outputChannel == channel }
        let monitored = device.monitors.contains { $0.routes.contains { $0.deviceChannel == channel } }
        HStack(spacing: 6) {
            PortView(id: .outputIn(channel), label: "Output \(channel + 1)", connected: fed)
                .contextMenu { inputMenu }
            Text("Output \(channel + 1)")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)
            OutputMeter(channel: channel)
            PortView(id: .outputOut(channel), label: "Output \(channel + 1) to monitors", connected: monitored,
                     tint: .secondary)
                .contextMenu { monitorMenu }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var inputMenu: some View {
        Menu("Connect from…") {
            ForEach(device.sources) { src in
                Menu(SourceNaming.name(src)) {
                    ForEach(0..<src.channelCount, id: \.self) { c in
                        Toggle("Channel \(SourceNaming.channelLabel(src, c))",
                               isOn: Binding(get: { routing.isRouted(source: src.id, channel: c, output: channel) },
                                             set: { _ in routing.toggleRoute(source: src.id, channel: c, output: channel) }))
                    }
                }
            }
        }
        let routes = device.routes.filter { $0.outputChannel == channel }
        if !routes.isEmpty {
            Menu("Disconnect from…") {
                ForEach(routes, id: \.self) { r in
                    Button("\(PortNames(device: device).sourceName(r.sourceID)) \(r.sourceChannel + 1)") {
                        routing.removeRoute(source: r.sourceID, channel: r.sourceChannel, output: channel)
                    }
                }
            }
        }
    }

    @ViewBuilder private var monitorMenu: some View {
        if device.monitors.isEmpty {
            Text("No monitors")
        }
        ForEach(device.monitors) { m in
            Menu("Monitor to \(PortNames(device: device).monitorName(m.id))") {
                ForEach(0..<routing.monitorChannelCount(m), id: \.self) { c in
                    Toggle("Channel \(c + 1)",
                           isOn: Binding(get: { routing.isMonitorRouted(monitor: m.id, deviceChannel: channel, monitorChannel: c) },
                                         set: { _ in routing.toggleMonitorRoute(monitor: m.id, deviceChannel: channel, monitorChannel: c) }))
                }
            }
        }
    }
}

struct OutputMeter: View {
    let channel: Int
    @Environment(EngineClient.self) private var client

    var body: some View {
        let levels = client.meters.outputs
        MeterBar(level: channel < levels.count ? levels[channel] : MeterLevel(), thickness: 5)
            .frame(maxWidth: .infinity)
    }
}
