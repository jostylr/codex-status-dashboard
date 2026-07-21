import DashboardSupport
import Foundation
import Testing

@Test func updatesMovedHelperAndPreservesUnrelatedHooks() throws {
    let fixture = try HookFixture(json: """
        {
          "custom": {"keep": true},
          "hooks": {
            "UserPromptSubmit": [
              {"matcher": "existing", "hooks": [
                {"type": "command", "command": "'/old/location/codex-status-hook'", "timeout": 9},
                {"type": "command", "command": "user-command"}
              ]}
            ]
          }
        }
        """)
    defer { fixture.remove() }

    let originalData = try Data(contentsOf: fixture.configurationURL)
    let helperURL = URL(fileURLWithPath: "/Applications/Codex Status Dashboard.app/Contents/Helpers/codex-status-hook")
    let result = try CodexHookInstaller.install(
        helperURL: helperURL,
        configurationURL: fixture.configurationURL
    )

    #expect(result.addedEvents.count == 5)
    #expect(result.updatedEvents == ["UserPromptSubmit"])
    let backupURL = try #require(result.backupURL)
    #expect(try Data(contentsOf: backupURL) == originalData)

    let root = try fixture.readRoot()
    #expect((root["custom"] as? [String: Bool])?["keep"] == true)
    let promptGroups = try #require((root["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [Any])
    let firstGroup = try #require(promptGroups.first as? [String: Any])
    #expect(firstGroup["matcher"] as? String == "existing")
    let hooks = try #require(firstGroup["hooks"] as? [[String: Any]])
    #expect(hooks[0]["command"] as? String == "'/Applications/Codex Status Dashboard.app/Contents/Helpers/codex-status-hook'")
    #expect(hooks[0]["timeout"] as? Int == 9)
    #expect(hooks[1]["command"] as? String == "user-command")
}

@Test func repeatedInstallDoesNotRewriteOrCreateAnotherBackup() throws {
    let fixture = try HookFixture(json: "{}")
    defer { fixture.remove() }
    let helperURL = URL(fileURLWithPath: "/Applications/Dashboard.app/Contents/Helpers/codex-status-hook")

    let first = try CodexHookInstaller.install(
        helperURL: helperURL,
        configurationURL: fixture.configurationURL
    )
    #expect(first.backupURL != nil)
    let installedData = try Data(contentsOf: fixture.configurationURL)

    let second = try CodexHookInstaller.install(
        helperURL: helperURL,
        configurationURL: fixture.configurationURL
    )
    #expect(!second.changed)
    #expect(second.backupURL == nil)
    #expect(try Data(contentsOf: fixture.configurationURL) == installedData)
}

@Test func malformedEventLeavesConfigurationUntouched() throws {
    let fixture = try HookFixture(json: """
        {"hooks": {"Stop": {"unexpected": true}}}
        """)
    defer { fixture.remove() }
    let originalData = try Data(contentsOf: fixture.configurationURL)

    #expect(throws: CodexHookInstaller.InstallationError.self) {
        try CodexHookInstaller.install(
            helperURL: URL(fileURLWithPath: "/Applications/Dashboard.app/Contents/Helpers/codex-status-hook"),
            configurationURL: fixture.configurationURL
        )
    }
    #expect(try Data(contentsOf: fixture.configurationURL) == originalData)
    #expect(try fixture.backupURLs().isEmpty)
}

private struct HookFixture {
    let directoryURL: URL
    let configurationURL: URL

    init(json: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-hook-installer-tests-\(UUID().uuidString)")
        configurationURL = directoryURL.appendingPathComponent("hooks.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: configurationURL)
    }

    func readRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: configurationURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func backupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("hooks.json.backup-") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
