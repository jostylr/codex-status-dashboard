import AppKit
import Foundation
import ServiceManagement
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
        case preparingTool
        case waiting
        case complete
    }

    private struct ThreadSlot {
        let sessionID: String
        var state: State
        var lastUpdated: Date
    }

    private var baseLightCount: Int
    private var slots = [ThreadSlot]()
    private var phase: CGFloat = 0
    private var timer: Timer?

    init(frame frameRect: NSRect, baseLightCount: Int) {
        self.baseLightCount = max(1, baseLightCount)
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Codex status: idle"
        startAnimation()
    }

    required init?(coder: NSCoder) {
        nil
    }

    var preferredWidth: CGFloat {
        let groupCount = max(slots.count, 1)
        let visibleLightCount = max(baseLightCount, groupCount)
        let diameter: CGFloat = 18
        let gap: CGFloat = 9
        let groupGap: CGFloat = 23
        let lightsWidth = CGFloat(visibleLightCount) * diameter
            + CGFloat(visibleLightCount - groupCount) * gap
            + CGFloat(groupCount - 1) * groupGap
        return max(236, lightsWidth + 32)
    }

    func setBaseLightCount(_ count: Int) {
        baseLightCount = max(1, count)
        needsDisplay = true
    }

    func apply(eventName: String, sessionID: String?) {
        let normalizedName = eventName.lowercased()
        let state: State?

        switch normalizedName {
        case "userpromptsubmit", "posttooluse":
            state = .working
        case "pretooluse":
            state = .preparingTool
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
        updateSlot(
            sessionID: id,
            state: state,
            clearCompletedFirst: normalizedName == "userpromptsubmit"
        )
        updateToolTip()
        needsDisplay = true
    }

    @discardableResult
    func clearCompletedSlots() -> Bool {
        let originalCount = slots.count
        slots.removeAll { $0.state == .complete }
        guard slots.count != originalCount else { return false }
        updateToolTip()
        needsDisplay = true
        return true
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
        let visibleLightCount = max(baseLightCount, states.count)
        let counts = lightCounts(total: visibleLightCount, for: states.count)
        let totalWidth =
            CGFloat(visibleLightCount) * diameter
            + CGFloat(visibleLightCount - states.count) * gap
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
        case .preparingTool: .systemRed
        case .waiting: .systemOrange
        case .complete: .systemGreen
        }
    }

    private func intensity(for index: Int, count: Int, state: State, groupIndex: Int) -> CGFloat {
        switch state {
        case .idle:
            return 0.1
        case .working, .preparingTool:
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

    private func lightCounts(total: Int, for groupCount: Int) -> [Int] {
        let base = total / groupCount
        let remainder = total % groupCount
        return (0..<groupCount).map { index in base + (index < remainder ? 1 : 0) }
    }

    private func updateSlot(sessionID: String, state: State, clearCompletedFirst: Bool) {
        let now = Date()
        if clearCompletedFirst {
            slots.removeAll { $0.state == .complete }
        }
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

        slots.append(slot)
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
        case .preparingTool: "preparing tool"
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
        phase += slots.contains(where: { $0.state == .working || $0.state == .preparingTool }) ? 0.18 : 0.1
        needsDisplay = true
    }
}

@MainActor
final class DashboardController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let baseLightCountKey = "base-light-count"
    private static let defaultBaseLightCount = 6
    private static let lightCountChoices = [4, 6, 8, 10, 12]
    private static let panelOriginXKey = "panel-origin-x"
    private static let panelOriginYKey = "panel-origin-y"

    private let panel = StatusPanel(
        contentRect: NSRect(x: 0, y: 0, width: 236, height: 44),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let lightStrip: LightStripView
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var dashboardMenuItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    override init() {
        lightStrip = LightStripView(
            frame: NSRect(x: 0, y: 0, width: 236, height: 44),
            baseLightCount: Self.baseLightCount
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePanel()
        configureStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveHookEvent(_:)),
            name: StatusNotification.name,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        resizePanelToContents()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
    }

    @objc private func receiveHookEvent(_ notification: Notification) {
        guard let values = notification.userInfo as? [String: String],
            let eventName = values[StatusNotification.eventNameKey]
        else { return }

        lightStrip.apply(eventName: eventName, sessionID: values[StatusNotification.sessionIDKey])
        resizePanelToContents()
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
        lightStrip.autoresizingMask = [.width, .height]
        panel.contentView = lightStrip
        positionPanel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Codex Status Dashboard")
        button.image?.isTemplate = true
        button.toolTip = "Codex Status Dashboard"

        let menu = NSMenu()
        menu.delegate = self

        let dashboardItem = NSMenuItem(title: "Hide Dashboard", action: #selector(toggleDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        dashboardMenuItem = dashboardItem

        let restorePositionItem = NSMenuItem(
            title: "Restore Default Position",
            action: #selector(restoreDefaultPosition),
            keyEquivalent: ""
        )
        restorePositionItem.target = self
        menu.addItem(restorePositionItem)

        let clearDoneItem = NSMenuItem(
            title: "Clear Done Lights",
            action: #selector(clearDoneLights),
            keyEquivalent: ""
        )
        clearDoneItem.target = self
        menu.addItem(clearDoneItem)

        let lightCountItem = NSMenuItem(title: "Base Lights", action: nil, keyEquivalent: "")
        let lightCountMenu = NSMenu(title: "Base Lights")
        for count in Self.lightCountChoices {
            let item = NSMenuItem(title: "\(count)", action: #selector(selectBaseLightCount(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            lightCountMenu.addItem(item)
        }
        lightCountItem.submenu = lightCountMenu
        menu.addItem(lightCountItem)

        menu.addItem(.separator())

        let installItem = NSMenuItem(title: "Install / Update Codex Hooks…", action: #selector(installHooks), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        self.loginItem = loginItem

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Codex Status Dashboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        dashboardMenuItem?.title = panel.isVisible ? "Hide Dashboard" : "Show Dashboard"
        for item in menu.items {
            guard let submenu = item.submenu, item.title == "Base Lights" else { continue }
            for choice in submenu.items {
                choice.state = choice.tag == Self.baseLightCount ? .on : .off
            }
        }
        loginItem?.isEnabled = isRunningAsAppBundle
        loginItem?.state = launchAtLoginEnabled ? .on : .off
        loginItem?.toolTip = isRunningAsAppBundle ? nil : "Available after the dashboard is installed as a .app bundle."
    }

    @objc private func toggleDashboard() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func restoreDefaultPosition() {
        clearSavedPanelOrigin()
        panel.setFrameOrigin(defaultPanelOrigin())
    }

    @objc private func clearDoneLights() {
        guard lightStrip.clearCompletedSlots() else { return }
        resizePanelToContents()
    }

    @objc private func selectBaseLightCount(_ sender: NSMenuItem) {
        Self.baseLightCount = sender.tag
        lightStrip.setBaseLightCount(sender.tag)
        resizePanelToContents()
    }

    @objc private func installHooks() {
        do {
            let helperURL = try CodexHookInstaller.helperExecutableURL()
            let alert = NSAlert()
            alert.messageText = "Install Codex Status hooks?"
            alert.informativeText = "This will merge six lifecycle hooks into \(CodexHookInstaller.configurationURL.path). Existing hooks and your notify setting will remain unchanged. Codex will still ask you to trust the new command hook."
            alert.addButton(withTitle: "Install Hooks")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let result = try CodexHookInstaller.install(helperURL: helperURL)
            let confirmation = NSAlert()
            confirmation.messageText = result.addedEvents.isEmpty ? "Codex hooks are already installed" : "Codex hooks installed"
            confirmation.informativeText = result.addedEvents.isEmpty
                ? "No changes were needed in \(result.configurationURL.path)."
                : "Added hooks for \(result.addedEvents.joined(separator: ", ")). Restart Codex Desktop, then approve the hook trust prompt when it appears."
            confirmation.runModal()
        } catch {
            showError(title: "Could not install Codex hooks", error: error)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard isRunningAsAppBundle else {
            showMessage(
                title: "Install the app first",
                message: "Launch at Login is available once Codex Status Dashboard is running from an installed .app bundle."
            )
            return
        }

        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError(title: "Could not update Launch at Login", error: error)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func panelDidMove(_ notification: Notification) {
        UserDefaults.standard.set(panel.frame.minX, forKey: Self.panelOriginXKey)
        UserDefaults.standard.set(panel.frame.minY, forKey: Self.panelOriginYKey)
    }

    private func resizePanelToContents() {
        panel.setContentSize(NSSize(width: lightStrip.preferredWidth, height: 44))
    }

    private var isRunningAsAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var launchAtLoginEnabled: Bool {
        isRunningAsAppBundle && SMAppService.mainApp.status == .enabled
    }

    private static var baseLightCount: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: baseLightCountKey)
            return value > 0 ? value : defaultBaseLightCount
        }
        set {
            UserDefaults.standard.set(newValue, forKey: baseLightCountKey)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showError(title: String, error: Error) {
        showMessage(title: title, message: error.localizedDescription)
    }

    private func positionPanel() {
        if let savedOrigin = savedPanelOrigin(), isVisibleOnAnyScreen(origin: savedOrigin) {
            panel.setFrameOrigin(savedOrigin)
            return
        }
        panel.setFrameOrigin(defaultPanelOrigin())
    }

    private func defaultPanelOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        // The light-strip border is inset by two points inside the panel. Align
        // the panel with the physical screen edge so that inset is also the
        // visible gap below and to the left of the border.
        let frame = screen.frame
        return NSPoint(x: frame.minX, y: frame.minY)
    }

    private func savedPanelOrigin() -> NSPoint? {
        guard
            UserDefaults.standard.object(forKey: Self.panelOriginXKey) != nil,
            UserDefaults.standard.object(forKey: Self.panelOriginYKey) != nil
        else { return nil }
        return NSPoint(
            x: UserDefaults.standard.double(forKey: Self.panelOriginXKey),
            y: UserDefaults.standard.double(forKey: Self.panelOriginYKey)
        )
    }

    private func clearSavedPanelOrigin() {
        UserDefaults.standard.removeObject(forKey: Self.panelOriginXKey)
        UserDefaults.standard.removeObject(forKey: Self.panelOriginYKey)
    }

    private func isVisibleOnAnyScreen(origin: NSPoint) -> Bool {
        let frame = NSRect(origin: origin, size: panel.frame.size)
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }
}

let app = NSApplication.shared
let controller = DashboardController()
app.delegate = controller
app.run()
