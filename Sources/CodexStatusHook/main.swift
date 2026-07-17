import AppKit
import Foundation
import StatusProtocol

// Current Codex `notify` configuration invokes this executable with an event
// name argument (for example, `turn-ended`). A future lifecycle hook can pass
// structured JSON on stdin when no argument is supplied.
// Prefer the argument so the helper never waits on an inherited stdin from a
// notification process.
let event = StatusEvent(commandLineEventName: CommandLine.arguments.dropFirst().first)
    ?? StatusEvent(hookData: FileHandle.standardInput.readDataToEndOfFile())

if let event {
    DistributedNotificationCenter.default().postNotificationName(
        StatusNotification.name,
        object: nil,
        userInfo: event.notificationUserInfo,
        deliverImmediately: true
    )
}
// An unexpected payload intentionally exits successfully: a status integration
// should never make Codex's own lifecycle action fail.
