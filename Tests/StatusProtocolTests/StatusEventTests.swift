import Foundation
import Testing
@testable import StatusProtocol

@Test func parsesRelevantHookFields() throws {
    let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"session-1","turn_id":"turn-1","cwd":"/tmp/project","stop_reason":"interrupted","prompt":"do not forward me"}"#

    let event = try #require(StatusEvent(hookData: Data(json.utf8)))

    #expect(event.eventName == "UserPromptSubmit")
    #expect(event.sessionID == "session-1")
    #expect(event.turnID == "turn-1")
    #expect(event.workingDirectory == "/tmp/project")
    #expect(event.stopReason == "interrupted")
    #expect(event.notificationUserInfo["prompt"] == nil)
}

@Test func ignoresMalformedOrIncompleteEvents() {
    #expect(StatusEvent(hookData: Data("not json".utf8)) == nil)
    #expect(StatusEvent(hookData: Data(#"{"session_id":"session-1"}"#.utf8)) == nil)
}

@Test func acceptsCodexNotifyArgument() throws {
    let event = try #require(StatusEvent(commandLineEventName: "turn-ended"))
    #expect(event.eventName == "turn-ended")
    #expect(event.sessionID == nil)
}
