import AppKit
import Foundation
import StatusProtocol

@MainActor
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class LightStripView: NSView {
    private enum State: Equatable {
        case idle
        case working
        case waiting
        case complete
    }

    private struct ThreadSlot {
        let sessionID: String
        var state: State
        var lastUpdated: Date
    }

    private let lightCount = 6
    private let maximumThreadSlots = 6
    private var slots = [ThreadSlot]()
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Codex status: idle"
        startAnimation()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(eventName: String, sessionID: String?) {
        let normalizedName = eventName.lowercased()
        let state: State?

        switch normalizedName {
        case "userpromptsubmit", "pretooluse", "posttooluse":
            state = .working
        case "permissionrequest":
            state = .waiting
        case "stop", "turn-ended":
            state = .complete
        case "sessionstart":
            // A session is visible only after it has activity. This avoids an
            // unopened thread consuming lights from a working thread.
            if let sessionID, let index = slots.firstIndex(where: { $0.sessionID == sessionID }) {
                slots[index].state = .idle
                slots[index].lastUpdated = Date()
            }
            updateToolTip()
            needsDisplay = true
            return
        default:
            toolTip = "Codex event: \(eventName)"
            return
        }

        let id = sessionID ?? "legacy-notify"
        guard let state else { return }
        updateSlot(sessionID: id, state: state)
        updateToolTip()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        let background = NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(calibratedWhite: 0.055, alpha: 0.92).setFill()
        background.fill()

        let diameter: CGFloat = 18
        let gap: CGFloat = 9
        let groupGap: CGFloat = 23
        let states = slots.isEmpty ? [.idle] : slots.map(\.state)
        let counts = lightCounts(for: states.count)
        let totalWidth =
            CGFloat(lightCount) * diameter
            + CGFloat(lightCount - states.count) * gap
            + CGFloat(states.count - 1) * groupGap
        var originX = (self.bounds.width - totalWidth) / 2
        let originY = (self.bounds.height - diameter) / 2

        for (groupIndex, state) in states.enumerated() {
            for localIndex in 0..<counts[groupIndex] {
                let rect = NSRect(x: originX, y: originY, width: diameter, height: diameter)
                drawLight(
                    in: rect,
                    index: localIndex,
                    count: counts[groupIndex],
                    state: state,
                    groupIndex: groupIndex
                )
                originX += diameter + gap
            }
            originX += groupGap - gap
        }
    }

    private func drawLight(in rect: NSRect, index: Int, count: Int, state: State, groupIndex: Int) {
        let intensity = intensity(for: index, count: count, state: state, groupIndex: groupIndex)
        let color = color(for: state)
        let path = NSBezierPath(ovalIn: rect)
        let context = NSGraphicsContext.current?.cgContext

        context?.saveGState()
        context?.setShadow(
            offset: .zero,
            blur: 8 + 10 * intensity,
            color: color.withAlphaComponent(0.75 * intensity).cgColor
        )
        color.withAlphaComponent(0.16 + 0.84 * intensity).setFill()
        path.fill()
        context?.restoreGState()

        NSColor.white.withAlphaComponent(0.12 * intensity).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 5)).fill()
    }

    private func color(for state: State) -> NSColor {
        switch state {
        case .idle: .systemGray
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .complete: .systemGreen
        }
    }

    private func intensity(for index: Int, count: Int, state: State, groupIndex: Int) -> CGFloat {
        switch state {
        case .idle:
            return 0.1
        case .working:
            guard count > 1 else {
                return 0.65 + 0.35 * ((sin(phase) + 1) / 2)
            }
            let end = CGFloat(count - 1)
            let journey = (phase + CGFloat(groupIndex) * 1.7).truncatingRemainder(
                dividingBy: end * 2)
            let scanner = journey <= end ? journey : (end * 2 - journey)
            return max(0.12, 1 - abs(CGFloat(index) - scanner) * 0.48)
        case .waiting:
            return 0.32 + 0.68 * ((sin(phase + CGFloat(groupIndex) * 0.6) + 1) / 2)
        case .complete:
            return 1
        }
    }

    private func lightCounts(for groupCount: Int) -> [Int] {
        let base = lightCount / groupCount
        let remainder = lightCount % groupCount
        return (0..<groupCount).map { index in base + (index < remainder ? 1 : 0) }
    }

    private func updateSlot(sessionID: String, state: State) {
        let now = Date()
        if let index = slots.firstIndex(where: { $0.sessionID == sessionID }) {
            slots[index].state = state
            slots[index].lastUpdated = now
            return
        }

        let slot = ThreadSlot(sessionID: sessionID, state: state, lastUpdated: now)
        // Completion stays visible until another thread becomes active. At that
        // point we discard every completed segment and rebalance the whole strip
        // among the currently active threads.
        slots.removeAll { $0.state == .complete }

        if slots.count < maximumThreadSlots {
            slots.append(slot)
            return
        }
    }

    private func updateToolTip() {
        guard !slots.isEmpty else {
            toolTip = "Codex status: idle"
            return
        }
        toolTip = slots.enumerated().map { index, slot in
            "Thread \(index + 1): \(description(for: slot.state))"
        }.joined(separator: " • ")
    }

    private func description(for state: State) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .waiting: "needs approval"
        case .complete: "complete"
        }
    }

    private func startAnimation() {
        let timer = Timer(
            timeInterval: 1 / 30, target: self, selector: #selector(tick), userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        phase += slots.contains(where: { $0.state == .working }) ? 0.18 : 0.1
        needsDisplay = true
    }
}

@MainActor
final class DashboardController: NSObject, NSApplicationDelegate {
    private let panel = StatusPanel(
        contentRect: NSRect(x: 0, y: 0, width: 236, height: 44),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let lightStrip = LightStripView(frame: NSRect(x: 0, y: 0, width: 236, height: 44))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePanel()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveHookEvent(_:)),
            name: StatusNotification.name,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func receiveHookEvent(_ notification: Notification) {
        guard let values = notification.userInfo as? [String: String],
            let eventName = values[StatusNotification.eventNameKey]
        else { return }

        lightStrip.apply(eventName: eventName, sessionID: values[StatusNotification.sessionIDKey])
    }

    private func configurePanel() {
        panel.title = "Codex Status"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = lightStrip
        positionPanel()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        // The light-strip border is inset by two points inside the panel. Align
        // the panel with the physical screen edge so that inset is also the
        // visible gap below and to the left of the border.
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.minX + 7, y: frame.minY + 7))
    }
}

let app = NSApplication.shared
let controller = DashboardController()
app.delegate = controller
app.run()
