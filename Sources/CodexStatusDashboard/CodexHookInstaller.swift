import Foundation

struct CodexHookInstaller {
    struct InstallResult {
        let configurationURL: URL
        let addedEvents: [String]
    }

    enum InstallationError: LocalizedError {
        case helperNotFound(URL)
        case invalidExistingConfiguration(URL)
        case invalidHooksSection(URL)

        var errorDescription: String? {
            switch self {
            case .helperNotFound(let url):
                "The bundled hook helper was not found at \(url.path). Build the app and helper before installing hooks."
            case .invalidExistingConfiguration(let url):
                "The existing hooks file at \(url.path) is not a JSON object, so it was left unchanged."
            case .invalidHooksSection(let url):
                "The hooks section in \(url.path) is not a JSON object, so it was left unchanged."
            }
        }
    }

    static let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
    ]

    static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    static func helperExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let appBundle = Bundle.main.bundleURL
        let bundledHelper = appBundle.appendingPathComponent("Contents/Helpers/codex-status-hook")
        if fileManager.isExecutableFile(atPath: bundledHelper.path) {
            return bundledHelper
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let siblingHelper = executableURL.deletingLastPathComponent().appendingPathComponent("codex-status-hook")
        if fileManager.isExecutableFile(atPath: siblingHelper.path) {
            return siblingHelper
        }

        throw InstallationError.helperNotFound(siblingHelper)
    }

    static func install(helperURL: URL) throws -> InstallResult {
        let fileManager = FileManager.default
        let configurationURL = configurationURL
        var root = try readConfiguration(at: configurationURL)
        let hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let parsedHooks = existingHooks as? [String: Any] else {
                throw InstallationError.invalidHooksSection(configurationURL)
            }
            hooks = parsedHooks
        } else {
            hooks = [:]
        }
        var updatedHooks = hooks
        let command = shellQuoted(helperURL.path)
        var addedEvents = [String]()

        for eventName in eventNames {
            var groups = updatedHooks[eventName] as? [Any] ?? []
            if !containsDashboardHook(in: groups) {
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": 2,
                    ]],
                ])
                updatedHooks[eventName] = groups
                addedEvents.append(eventName)
            }
        }

        root["hooks"] = updatedHooks
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configurationURL, options: .atomic)
        return InstallResult(configurationURL: configurationURL, addedEvents: addedEvents)
    }

    private static func readConfiguration(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallationError.invalidExistingConfiguration(url)
        }
        return root
    }

    private static func containsDashboardHook(in value: Any) -> Bool {
        if let string = value as? String {
            return string.contains("codex-status-hook")
        }
        if let values = value as? [Any] {
            return values.contains(where: containsDashboardHook)
        }
        if let values = value as? [String: Any] {
            return values.values.contains(where: containsDashboardHook)
        }
        return false
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\''"))'"
    }
}
