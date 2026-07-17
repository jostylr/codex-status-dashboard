import Foundation

public enum StatusNotification {
    public static let name = Notification.Name("com.codex-monitor.hook-event")
    public static let eventNameKey = "event_name"
    public static let sessionIDKey = "session_id"
    public static let turnIDKey = "turn_id"
    public static let workingDirectoryKey = "cwd"
    public static let receivedAtKey = "received_at"
}

/// The small, safe subset of a Codex hook payload needed by the first UI.
/// Unknown fields deliberately remain in the original hook process and are not
/// broadcast to another process.
public struct StatusEvent: Equatable, Sendable {
    public let eventName: String
    public let sessionID: String?
    public let turnID: String?
    public let workingDirectory: String?

    public init(
        eventName: String,
        sessionID: String? = nil,
        turnID: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.eventName = eventName
        self.sessionID = sessionID
        self.turnID = turnID
        self.workingDirectory = workingDirectory
    }

    public init?(hookData: Data) {
        guard
            let payload = try? JSONSerialization.jsonObject(with: hookData) as? [String: Any],
            let eventName = payload["hook_event_name"] as? String,
            !eventName.isEmpty
        else {
            return nil
        }

        self.init(
            eventName: eventName,
            sessionID: payload["session_id"] as? String,
            turnID: payload["turn_id"] as? String,
            workingDirectory: payload["cwd"] as? String
        )
    }

    public init?(commandLineEventName: String?) {
        guard let commandLineEventName, !commandLineEventName.isEmpty else {
            return nil
        }
        self.init(eventName: commandLineEventName)
    }

    public var notificationUserInfo: [String: String] {
        var values = [StatusNotification.eventNameKey: eventName]
        if let sessionID { values[StatusNotification.sessionIDKey] = sessionID }
        if let turnID { values[StatusNotification.turnIDKey] = turnID }
        if let workingDirectory { values[StatusNotification.workingDirectoryKey] = workingDirectory }
        values[StatusNotification.receivedAtKey] = ISO8601DateFormatter().string(from: Date())
        return values
    }
}
