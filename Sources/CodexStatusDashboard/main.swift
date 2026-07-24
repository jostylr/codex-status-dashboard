import AppKit
import DashboardSupport
import Foundation
import ServiceManagement
import StatusProtocol

@MainActor
private final class StatusPanel: NSPanel {
    var primaryClickHandler: (() -> Void)?
    private var mouseDownScreenLocation: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownScreenLocation = NSEvent.mouseLocation
        case .leftMouseUp:
            let mouseUpScreenLocation = NSEvent.mouseLocation
            let mouseDownScreenLocation = mouseDownScreenLocation
            self.mouseDownScreenLocation = nil
            super.sendEvent(event)
            guard let mouseDownScreenLocation else { return }
            let distance = hypot(
                mouseUpScreenLocation.x - mouseDownScreenLocation.x,
                mouseUpScreenLocation.y - mouseDownScreenLocation.y
            )
            if distance < 4 {
                primaryClickHandler?()
            }
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class LightStripView: NSView {
    private enum State: Equatable {
        case idle
        case working
        case preparingTool
        case waiting
        case complete
        case failed
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
    private var lightScale: CGFloat = 1

    var contextMenuProvider: (() -> NSMenu?)?
    var primaryClickHandler: (() -> Void)?

    init(frame frameRect: NSRect, baseLightCount: Int) {
        self.baseLightCount = max(1, baseLightCount)
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Codex status: idle"
    }

    required init?(coder: NSCoder) {
        nil
    }

    var preferredWidth: CGFloat {
        let groupCount = max(slots.count, 1)
        let visibleLightCount = max(baseLightCount, groupCount)
        let diameter = 18 * lightScale
        let gap = 9 * lightScale
        let groupGap = 23 * lightScale
        let lightsWidth =
            CGFloat(visibleLightCount) * diameter
            + CGFloat(visibleLightCount - groupCount) * gap
            + CGFloat(groupCount - 1) * groupGap
        return max(236 * lightScale, lightsWidth + 32 * lightScale)
    }

    var preferredHeight: CGFloat {
        44 * lightScale
    }

    var currentLightScale: CGFloat {
        lightScale
    }

    func setBaseLightCount(_ count: Int) {
        baseLightCount = max(1, count)
        needsDisplay = true
    }

    func setLightScale(_ scale: CGFloat) {
        let clampedScale = min(max(scale, 0.55), 2.0)
        guard abs(lightScale - clampedScale) > 0.001 else { return }
        lightScale = clampedScale
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    func apply(eventName: String, sessionID: String?, stopReason: String?) {
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
            if isInterruption(stopReason) {
                clear(sessionID: sessionID)
                toolTip = "Codex task interrupted"
                updateAnimation()
                needsDisplay = true
                return
            }
            state = isProblematicStop(stopReason) ? .failed : .complete
        case "sessionstart":
            // A session is visible only after it has activity. This avoids an
            // unopened thread consuming lights from a working thread.
            if let sessionID, let index = slots.firstIndex(where: { $0.sessionID == sessionID }) {
                slots[index].state = .idle
                slots[index].lastUpdated = Date()
            }
            updateToolTip()
            updateAnimation()
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
        updateAnimation()
        needsDisplay = true
    }

    @discardableResult
    func clearCompletedSlots() -> Bool {
        let originalCount = slots.count
        slots.removeAll { $0.state == .complete }
        guard slots.count != originalCount else { return false }
        updateToolTip()
        updateAnimation()
        needsDisplay = true
        return true
    }

    func clearAllSlots() {
        slots.removeAll()
        updateToolTip()
        updateAnimation()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 2 * lightScale, dy: 2 * lightScale)
        let background = NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(calibratedWhite: 0.055, alpha: 0.92).setFill()
        background.fill()

        let diameter = 18 * lightScale
        let gap = 9 * lightScale
        let groupGap = 23 * lightScale
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
            blur: (8 + 10 * intensity) * lightScale,
            color: color.withAlphaComponent(0.75 * intensity).cgColor
        )
        color.withAlphaComponent(0.16 + 0.84 * intensity).setFill()
        path.fill()
        context?.restoreGState()

        NSColor.white.withAlphaComponent(0.12 * intensity).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 4 * lightScale, dy: 5 * lightScale)).fill()
    }

    private func color(for state: State) -> NSColor {
        switch state {
        case .idle: .systemGray
        case .working: .systemBlue
        case .preparingTool: .systemRed
        case .waiting: .systemOrange
        case .complete: .systemGreen
        case .failed: NSColor(calibratedRed: 0.48, green: 0.04, blue: 0.05, alpha: 1)
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
        case .failed:
            return 0.72
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
            slots.removeAll { $0.state == .complete || $0.state == .failed }
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
        slots.removeAll { $0.state == .complete || $0.state == .failed }

        slots.append(slot)
    }

    private func clear(sessionID: String?) {
        if let sessionID {
            slots.removeAll { $0.sessionID == sessionID }
        } else {
            slots.removeAll()
        }
        updateToolTip()
    }

    private func isInterruption(_ stopReason: String?) -> Bool {
        guard let stopReason else { return false }
        let reason = stopReason.lowercased()
        return reason.contains("interrupt") || reason.contains("abort") || reason.contains("cancel")
    }

    private func isProblematicStop(_ stopReason: String?) -> Bool {
        guard let stopReason else { return false }
        let reason = stopReason.lowercased()
        return reason.contains("error")
            || reason.contains("fail")
            || reason.contains("timeout")
            || reason.contains("limit")
            || reason.contains("budget")
            || reason.contains("quota")
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
        case .failed: "failed"
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: 1 / 30, target: self, selector: #selector(tick), userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        phase = 0
    }

    private func updateAnimation() {
        let needsAnimation = slots.contains {
            $0.state == .working || $0.state == .preparingTool || $0.state == .waiting
        }
        if needsAnimation {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    @objc private func tick() {
        phase +=
            slots.contains(where: { $0.state == .working || $0.state == .preparingTool })
            ? 0.18 : 0.1
        needsDisplay = true
    }
}

@MainActor
final class DashboardController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct DisplayLayout {
        let horizontalFraction: CGFloat
        let verticalFraction: CGFloat
        let lightScale: CGFloat

        init(horizontalFraction: CGFloat, verticalFraction: CGFloat, lightScale: CGFloat) {
            self.horizontalFraction = horizontalFraction
            self.verticalFraction = verticalFraction
            self.lightScale = lightScale
        }

        init?(propertyList: [String: Any]) {
            guard
                let horizontal = propertyList["horizontalFraction"] as? Double,
                let vertical = propertyList["verticalFraction"] as? Double,
                let scale = propertyList["lightScale"] as? Double
            else { return nil }
            horizontalFraction = min(max(CGFloat(horizontal), 0), 1)
            verticalFraction = min(max(CGFloat(vertical), 0), 1)
            lightScale = min(max(CGFloat(scale), 0.55), 2.0)
        }

        var propertyList: [String: Double] {
            [
                "horizontalFraction": Double(horizontalFraction),
                "verticalFraction": Double(verticalFraction),
                "lightScale": Double(lightScale),
            ]
        }
    }

    private struct LightScalePreset {
        let title: String
        let scale: CGFloat
    }

    private static let baseLightCountKey = "base-light-count"
    private static let defaultBaseLightCount = 6
    private static let lightCountChoices = [4, 6, 8, 10, 12]
    private static let panelOriginXKey = "panel-origin-x"
    private static let panelOriginYKey = "panel-origin-y"
    private static let displayLayoutsKey = "display-layouts"
    private static let lastDisplayIdentifierKey = "last-display-identifier"
    private static let lightScalePresets = [
        LightScalePreset(title: "Compact (70%)", scale: 0.7),
        LightScalePreset(title: "Standard (100%)", scale: 1),
        LightScalePreset(title: "Large (130%)", scale: 1.3),
    ]
    private static let legacyBundleIdentifier = "com.codex-monitor.dashboard"
    private static let legacyDefaultsMigrationKey = "migrated-defaults-from-com.codex-monitor.dashboard"

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
        Self.migrateLegacyDefaultsIfNeeded()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveHookEvent(_:)),
            name: StatusNotification.name,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        restoreLayoutForAvailableScreens()
        saveCurrentLayout()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func receiveHookEvent(_ notification: Notification) {
        guard let values = notification.userInfo as? [String: String],
            let eventName = values[StatusNotification.eventNameKey]
        else { return }

        lightStrip.apply(
            eventName: eventName,
            sessionID: values[StatusNotification.sessionIDKey],
            stopReason: values[StatusNotification.stopReasonKey]
        )
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
        lightStrip.contextMenuProvider = { [weak self] in
            self?.makeDashboardContextMenu()
        }
        panel.primaryClickHandler = { [weak self] in
            self?.activateCodex()
        }
        panel.contentView = lightStrip
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "circle.grid.3x3.fill",
            accessibilityDescription: "Codex Status Dashboard")
        button.image?.isTemplate = true
        button.toolTip = "Codex Status Dashboard"

        let menu = NSMenu()
        menu.delegate = self

        let dashboardItem = NSMenuItem(
            title: "Hide Dashboard", action: #selector(toggleDashboard), keyEquivalent: "")
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

        let clearAllItem = NSMenuItem(
            title: "Clear All Lights",
            action: #selector(clearAllLights),
            keyEquivalent: ""
        )
        clearAllItem.target = self
        menu.addItem(clearAllItem)

        let lightCountItem = NSMenuItem(title: "Base Lights", action: nil, keyEquivalent: "")
        let lightCountMenu = NSMenu(title: "Base Lights")
        for count in Self.lightCountChoices {
            let item = NSMenuItem(
                title: "\(count)", action: #selector(selectBaseLightCount(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            lightCountMenu.addItem(item)
        }
        lightCountItem.submenu = lightCountMenu
        menu.addItem(lightCountItem)

        let lightScaleItem = NSMenuItem(title: "Light Size", action: nil, keyEquivalent: "")
        lightScaleItem.submenu = makeLightScaleMenu()
        menu.addItem(lightScaleItem)

        menu.addItem(.separator())

        let installItem = NSMenuItem(
            title: "Install / Update Codex Hooks…", action: #selector(installHooks),
            keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        self.loginItem = loginItem

        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let aboutItem = NSMenuItem(
            title: "About & Status…", action: #selector(showAboutAndStatus), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit Codex Status Dashboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        dashboardMenuItem?.title = panel.isVisible ? "Hide Dashboard" : "Show Dashboard"
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            if item.title == "Base Lights" {
                for choice in submenu.items {
                    choice.state = choice.tag == Self.baseLightCount ? .on : .off
                }
            } else if item.title == "Light Size" {
                updateLightScaleMenu(submenu)
            }
        }
        loginItem?.isEnabled = isRunningAsAppBundle
        loginItem?.state = launchAtLoginEnabled ? .on : .off
        loginItem?.toolTip =
            isRunningAsAppBundle
            ? nil : "Available after the dashboard is installed as a .app bundle."
    }

    @objc private func toggleDashboard() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func restoreDefaultPosition() {
        guard let screen = screenContainingPanel() ?? NSScreen.main else { return }
        panel.setFrameOrigin(defaultPanelOrigin(on: screen))
        saveCurrentLayout(on: screen)
    }

    @objc private func clearDoneLights() {
        guard lightStrip.clearCompletedSlots() else { return }
        resizePanelToContents()
    }

    @objc private func clearAllLights() {
        lightStrip.clearAllSlots()
        resizePanelToContents()
    }

    @objc private func showAboutAndStatus() {
        let alert = NSAlert()
        alert.messageText = "Codex Status Dashboard"
        alert.informativeText =
            "Monitors Codex processing. Be sure to install the hooks.\\nBlue swooshing: Codex thinking.\nRed swooshing: Codex using a tool.\nOrange pulsing: Codex needs approval.\nGreen solid: Codex done.\nDark Red solid: Failed.\n\nSome interrupts do not yield notifications. Use Clear-All-Lights to clear. Clearing happens automatically for solid lights when Codex receives any new prompt.\n\nVersion: \(applicationVersion)\nHooks file: \(CodexHookInstaller.configurationURL.path)\nBase lights: \(Self.baseLightCount)\n\nDeveloper: James Taylor"
        alert.addButton(withTitle: "Git Home")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "https://github.com/jostylr/codex-status-dashboard") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func checkForUpdates() {
        statusItem.button?.toolTip = "Checking for Codex Status Dashboard updates…"
        Task {
            defer { statusItem.button?.toolTip = "Codex Status Dashboard" }
            do {
                let result = try await UpdateChecker.check(currentVersion: applicationVersion)
                if result.isNewer {
                    showAvailableUpdate(result.release)
                } else {
                    showMessage(
                        title: "You're up to date",
                        message: "Codex Status Dashboard \(applicationVersion) is current. Latest release: \(result.release.tagName)."
                    )
                }
            } catch {
                showError(title: "Could not check for updates", error: error)
            }
        }
    }

    private func showAvailableUpdate(_ release: UpdateChecker.Release) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText =
            "Codex Status Dashboard \(release.tagName) is available. The download page will open in your browser; quit the dashboard before replacing the copy in Applications."
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(release.htmlURL)
    }

    @objc private func selectBaseLightCount(_ sender: NSMenuItem) {
        Self.baseLightCount = sender.tag
        lightStrip.setBaseLightCount(sender.tag)
        resizePanelToContents()
        saveCurrentLayout()
    }

    @objc private func selectLightScale(_ sender: NSMenuItem) {
        guard
            let value = sender.representedObject as? NSNumber,
            let screen = screenContainingPanel() ?? NSScreen.main
        else { return }

        applyLightScale(CGFloat(value.doubleValue), on: screen)
    }

    @objc private func adjustLightScale(_ sender: NSMenuItem) {
        guard let screen = screenContainingPanel() ?? NSScreen.main else { return }
        applyLightScale(lightStrip.currentLightScale + CGFloat(sender.tag) * 0.1, on: screen)
    }

    @objc private func saveDashboardLook() {
        saveCurrentLayout()
    }

    @objc private func restoreDashboardLook() {
        guard let screen = screenContainingPanel() ?? NSScreen.main else { return }
        restoreLayout(on: screen)
    }

    @objc private func resetDashboardLook() {
        guard let screen = screenContainingPanel() ?? NSScreen.main else { return }
        removeLayout(for: screen)
        lightStrip.setLightScale(defaultLightScale(for: screen))
        setPanelContentSize()
        panel.setFrameOrigin(defaultPanelOrigin(on: screen))
        saveCurrentLayout(on: screen)
    }

    @objc private func activateCodex() {
        let workspace = NSWorkspace.shared
        if let codex = workspace.runningApplications.first(where: { application in
            application.bundleIdentifier?.localizedCaseInsensitiveContains("codex") == true
                || application.localizedName?.localizedCaseInsensitiveCompare("Codex") == .orderedSame
        }) {
            codex.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let applicationURL = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: applicationURL.path) {
            workspace.open(applicationURL)
            return
        }

        showMessage(
            title: "Codex was not found",
            message: "Start the Codex desktop app, then click the dashboard to bring it forward. The dashboard cannot yet select a specific task."
        )
    }

    @objc private func installHooks() {
        do {
            let helperURL = try CodexHookInstaller.helperExecutableURL()
            let alert = NSAlert()
            alert.messageText = "Install Codex Status hooks?"
            alert.informativeText =
                "This will merge six lifecycle hooks into \(CodexHookInstaller.configurationURL.path). Existing hooks and your notify setting will remain unchanged. Codex will still ask you to trust the new command hook."
            alert.addButton(withTitle: "Install Hooks")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let result = try CodexHookInstaller.install(helperURL: helperURL)
            let confirmation = NSAlert()
            confirmation.messageText =
                !result.changed
                ? "Codex hooks are already installed" : "Codex hooks installed"
            if !result.changed {
                confirmation.informativeText =
                    "No changes were needed in \(result.configurationURL.path)."
            } else {
                var changes = [String]()
                if !result.addedEvents.isEmpty {
                    changes.append("Added: \(result.addedEvents.joined(separator: ", "))")
                }
                if !result.updatedEvents.isEmpty {
                    changes.append("Updated paths: \(result.updatedEvents.joined(separator: ", "))")
                }
                if let backupURL = result.backupURL {
                    changes.append("Backup: \(backupURL.path)")
                }
                changes.append(
                    "Restart Codex Desktop, then approve the hook trust prompt if it appears."
                )
                confirmation.informativeText = changes.joined(separator: "\n")
            }
            confirmation.runModal()
        } catch {
            showError(title: "Could not install Codex hooks", error: error)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard isRunningAsAppBundle else {
            showMessage(
                title: "Install the app first",
                message:
                    "Launch at Login is available once Codex Status Dashboard is running from an installed .app bundle."
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
        saveCurrentLayout()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard let screen = screenContainingPanel() else {
            restoreLayoutForAvailableScreens()
            return
        }
        restoreLayout(on: screen)
    }

    private func makeDashboardContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Codex Status Dashboard")

        let openCodexItem = NSMenuItem(
            title: "Bring Codex Forward", action: #selector(activateCodex), keyEquivalent: "")
        openCodexItem.target = self
        menu.addItem(openCodexItem)
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "Light Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = makeLightScaleMenu()
        menu.addItem(sizeItem)

        let saveItem = NSMenuItem(
            title: "Save This Display’s Look", action: #selector(saveDashboardLook), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        let restoreItem = NSMenuItem(
            title: "Restore This Display’s Look", action: #selector(restoreDashboardLook), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = (screenContainingPanel()).flatMap(layout(for:)) != nil
        menu.addItem(restoreItem)

        let resetItem = NSMenuItem(
            title: "Reset This Display’s Look", action: #selector(resetDashboardLook), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        return menu
    }

    private func makeLightScaleMenu() -> NSMenu {
        let menu = NSMenu(title: "Light Size")
        let smallerItem = NSMenuItem(
            title: "Smaller", action: #selector(adjustLightScale(_:)), keyEquivalent: "")
        smallerItem.target = self
        smallerItem.tag = -1
        menu.addItem(smallerItem)

        let largerItem = NSMenuItem(
            title: "Larger", action: #selector(adjustLightScale(_:)), keyEquivalent: "")
        largerItem.target = self
        largerItem.tag = 1
        menu.addItem(largerItem)
        menu.addItem(.separator())

        for preset in Self.lightScalePresets {
            let item = NSMenuItem(
                title: preset.title, action: #selector(selectLightScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(preset.scale))
            item.state = abs(lightStrip.currentLightScale - preset.scale) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func applyLightScale(_ scale: CGFloat, on screen: NSScreen) {
        lightStrip.setLightScale(scale)
        resizePanelToContents(on: screen)
        saveCurrentLayout(on: screen)
    }

    private func updateLightScaleMenu(_ menu: NSMenu) {
        for item in menu.items {
            guard let value = item.representedObject as? NSNumber else { continue }
            item.state = abs(lightStrip.currentLightScale - CGFloat(value.doubleValue)) < 0.01
                ? .on : .off
        }
    }

    private func resizePanelToContents(on screen: NSScreen? = nil) {
        let targetScreen = screen ?? screenContainingPanel()
        let relativeOrigin = targetScreen.map { normalizedOrigin(on: $0) }
        setPanelContentSize()
        if let targetScreen, let relativeOrigin {
            panel.setFrameOrigin(panelOrigin(from: relativeOrigin, on: targetScreen))
        }
    }

    private func setPanelContentSize() {
        panel.setContentSize(
            NSSize(width: lightStrip.preferredWidth, height: lightStrip.preferredHeight)
        )
    }

    private var isRunningAsAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var launchAtLoginEnabled: Bool {
        isRunningAsAppBundle && SMAppService.mainApp.status == .enabled
    }

    private var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
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

    private static func migrateLegacyDefaultsIfNeeded() {
        let currentDefaults = UserDefaults.standard
        guard !currentDefaults.bool(forKey: legacyDefaultsMigrationKey) else { return }

        if let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) {
            for key in [baseLightCountKey, panelOriginXKey, panelOriginYKey] {
                if currentDefaults.object(forKey: key) == nil,
                   let legacyValue = legacyDefaults.object(forKey: key)
                {
                    currentDefaults.set(legacyValue, forKey: key)
                }
            }
        }
        currentDefaults.set(true, forKey: legacyDefaultsMigrationKey)
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

    private func restoreLayoutForAvailableScreens() {
        guard let screen = preferredScreenForRestore() else {
            setPanelContentSize()
            panel.setFrameOrigin(.zero)
            return
        }
        restoreLayout(on: screen)
    }

    private func restoreLayout(on screen: NSScreen) {
        if let layout = layout(for: screen) {
            lightStrip.setLightScale(layout.lightScale)
            setPanelContentSize()
            panel.setFrameOrigin(panelOrigin(from: layout, on: screen))
            return
        }

        lightStrip.setLightScale(defaultLightScale(for: screen))
        setPanelContentSize()
        if let savedOrigin = savedPanelOrigin(), isVisibleOn(screen: screen, origin: savedOrigin) {
            panel.setFrameOrigin(savedOrigin)
        } else {
            panel.setFrameOrigin(defaultPanelOrigin(on: screen))
        }
    }

    private func preferredScreenForRestore() -> NSScreen? {
        if let lastIdentifier = UserDefaults.standard.string(forKey: Self.lastDisplayIdentifierKey),
           let lastScreen = NSScreen.screens.first(where: {
               displayIdentifier(for: $0) == lastIdentifier
           })
        {
            return lastScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func defaultPanelOrigin(on screen: NSScreen) -> NSPoint {
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

    private func screenContainingPanel() -> NSScreen? {
        let panelFrame = panel.frame
        guard let screen = NSScreen.screens.max(by: { left, right in
            intersectionArea(panelFrame, left.frame) < intersectionArea(panelFrame, right.frame)
        }) else { return nil }
        return intersectionArea(panelFrame, screen.frame) > 0 ? screen : nil
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func normalizedOrigin(on screen: NSScreen) -> DisplayLayout {
        let frame = screen.frame
        let horizontalRange = max(frame.width - panel.frame.width, 1)
        let verticalRange = max(frame.height - panel.frame.height, 1)
        return DisplayLayout(
            horizontalFraction: min(max((panel.frame.minX - frame.minX) / horizontalRange, 0), 1),
            verticalFraction: min(max((panel.frame.minY - frame.minY) / verticalRange, 0), 1),
            lightScale: lightStrip.currentLightScale
        )
    }

    private func panelOrigin(from layout: DisplayLayout, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let horizontalRange = max(frame.width - panel.frame.width, 0)
        let verticalRange = max(frame.height - panel.frame.height, 0)
        return NSPoint(
            x: frame.minX + horizontalRange * layout.horizontalFraction,
            y: frame.minY + verticalRange * layout.verticalFraction
        )
    }

    private func saveCurrentLayout(on screen: NSScreen? = nil) {
        guard let screen = screen ?? screenContainingPanel() else { return }
        let identifier = displayIdentifier(for: screen)
        var layouts = UserDefaults.standard.dictionary(forKey: Self.displayLayoutsKey) ?? [:]
        layouts[identifier] = normalizedOrigin(on: screen).propertyList
        UserDefaults.standard.set(layouts, forKey: Self.displayLayoutsKey)
        UserDefaults.standard.set(identifier, forKey: Self.lastDisplayIdentifierKey)
    }

    private func layout(for screen: NSScreen) -> DisplayLayout? {
        guard
            let layouts = UserDefaults.standard.dictionary(forKey: Self.displayLayoutsKey),
            let propertyList = layouts[displayIdentifier(for: screen)] as? [String: Any]
        else { return nil }
        return DisplayLayout(propertyList: propertyList)
    }

    private func removeLayout(for screen: NSScreen) {
        var layouts = UserDefaults.standard.dictionary(forKey: Self.displayLayoutsKey) ?? [:]
        layouts.removeValue(forKey: displayIdentifier(for: screen))
        UserDefaults.standard.set(layouts, forKey: Self.displayLayoutsKey)
    }

    private func defaultLightScale(for screen: NSScreen) -> CGFloat {
        // Built-in displays tend to be much narrower in points than external
        // monitors. Once the user chooses a preset, that display's saved scale
        // takes precedence over this first-run fallback.
        screen.frame.width <= 1_600 ? 0.7 : 1
    }

    private func displayIdentifier(for screen: NSScreen) -> String {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber {
            return "display-\(screenNumber.stringValue)"
        }
        return "display-\(screen.localizedName)"
    }

    private func isVisibleOn(screen: NSScreen, origin: NSPoint) -> Bool {
        let frame = NSRect(origin: origin, size: panel.frame.size)
        return screen.frame.intersects(frame)
    }
}

let app = NSApplication.shared
let controller = DashboardController()
app.delegate = controller
app.run()
