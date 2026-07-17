import AppKit
import Foundation
import StatusProtocol

@MainActor
final class DashboardController: NSObject, NSApplicationDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 280),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    private let eventLabel = NSTextField(labelWithString: "Waiting for a Codex status event…")
    private let detailLabel = NSTextField(labelWithString: "Run the bundled codex-status-hook from Codex's notify configuration.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureWindow()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveHookEvent(_:)),
            name: StatusNotification.name,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func receiveHookEvent(_ notification: Notification) {
        guard let values = notification.userInfo as? [String: String],
              let eventName = values[StatusNotification.eventNameKey]
        else { return }

        eventLabel.stringValue = "Received \(eventName)"
        eventLabel.textColor = color(for: eventName)

        let fields = [
            values[StatusNotification.sessionIDKey].map { "session: \($0)" },
            values[StatusNotification.turnIDKey].map { "turn: \($0)" },
            values[StatusNotification.workingDirectoryKey].map { "cwd: \($0)" },
            values[StatusNotification.receivedAtKey],
        ].compactMap { $0 }
        detailLabel.stringValue = fields.joined(separator: "\n")
    }

    private func configureWindow() {
        window.title = "Codex Status Monitor"
        window.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)

        eventLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        eventLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(eventLabel)
        stack.addArrangedSubview(detailLabel)
        window.contentView = stack
    }

    private func color(for eventName: String) -> NSColor {
        switch eventName.lowercased() {
        case "userpromptsubmit", "pretooluse", "posttooluse": .systemBlue
        case "permissionrequest": .systemOrange
        case "stop", "turn-ended": .systemGreen
        default: .labelColor
        }
    }
}

let app = NSApplication.shared
let controller = DashboardController()
app.delegate = controller
app.run()
