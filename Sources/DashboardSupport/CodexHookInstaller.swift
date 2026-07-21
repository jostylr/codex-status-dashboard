import Foundation

public struct CodexHookInstaller {
    public struct InstallResult {
        public let configurationURL: URL
        public let addedEvents: [String]
        public let updatedEvents: [String]
        public let backupURL: URL?

        public var changed: Bool {
            !addedEvents.isEmpty || !updatedEvents.isEmpty
        }
    }

    public enum InstallationError: LocalizedError {
        case helperNotFound(URL)
        case invalidExistingConfiguration(URL)
        case invalidHooksSection(URL)
        case invalidEventSection(String, URL)
        case invalidHookGroup(String, URL)

        public var errorDescription: String? {
            switch self {
            case .helperNotFound(let url):
                "The bundled hook helper was not found at \(url.path). Build the app and helper before installing hooks."
            case .invalidExistingConfiguration(let url):
                "The existing hooks file at \(url.path) is not a JSON object, so it was left unchanged."
            case .invalidHooksSection(let url):
                "The hooks section in \(url.path) is not a JSON object, so it was left unchanged."
            case .invalidEventSection(let event, let url):
                "The \(event) section in \(url.path) is not an array, so the hooks file was left unchanged."
            case .invalidHookGroup(let event, let url):
                "A \(event) hook group in \(url.path) has an invalid hooks value, so the hooks file was left unchanged."
            }
        }
    }

    public static let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
    ]

    public static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    public static func helperExecutableURL() throws -> URL {
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

    public static func install(
        helperURL: URL,
        configurationURL: URL = Self.configurationURL,
        fileManager: FileManager = .default
    ) throws -> InstallResult {
        let existed = fileManager.fileExists(atPath: configurationURL.path)
        let originalPermissions = try? fileManager.attributesOfItem(atPath: configurationURL.path)[.posixPermissions]
        var root = try readConfiguration(at: configurationURL, fileManager: fileManager)
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
        var updatedEvents = [String]()

        // Validate and prepare every event before writing or backing anything
        // up. A malformed event therefore leaves the original file untouched.
        for eventName in eventNames {
            let groups: [Any]
            if let existingGroups = updatedHooks[eventName] {
                guard let parsedGroups = existingGroups as? [Any] else {
                    throw InstallationError.invalidEventSection(eventName, configurationURL)
                }
                groups = parsedGroups
            } else {
                groups = []
            }

            let update = try updatingDashboardHooks(
                in: groups,
                eventName: eventName,
                command: command,
                configurationURL: configurationURL
            )
            updatedHooks[eventName] = update.groups
            if update.added {
                addedEvents.append(eventName)
            } else if update.updated {
                updatedEvents.append(eventName)
            }
        }

        guard !addedEvents.isEmpty || !updatedEvents.isEmpty else {
            return InstallResult(
                configurationURL: configurationURL,
                addedEvents: [],
                updatedEvents: [],
                backupURL: nil
            )
        }

        root["hooks"] = updatedHooks
        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let backupURL: URL?
        if existed {
            let destination = uniqueBackupURL(for: configurationURL, fileManager: fileManager)
            try fileManager.copyItem(at: configurationURL, to: destination)
            backupURL = destination
        } else {
            backupURL = nil
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        do {
            try data.write(to: configurationURL, options: .atomic)
            if let originalPermissions {
                try fileManager.setAttributes(
                    [.posixPermissions: originalPermissions],
                    ofItemAtPath: configurationURL.path
                )
            }
        } catch {
            throw error
        }

        return InstallResult(
            configurationURL: configurationURL,
            addedEvents: addedEvents,
            updatedEvents: updatedEvents,
            backupURL: backupURL
        )
    }

    private static func readConfiguration(
        at url: URL,
        fileManager: FileManager
    ) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallationError.invalidExistingConfiguration(url)
        }
        return root
    }

    private static func updatingDashboardHooks(
        in groups: [Any],
        eventName: String,
        command: String,
        configurationURL: URL
    ) throws -> (groups: [Any], added: Bool, updated: Bool) {
        var output = groups
        var found = false
        var updated = false

        for groupIndex in output.indices {
            guard var group = output[groupIndex] as? [String: Any],
                  let hooksValue = group["hooks"]
            else { continue }
            guard var commandHooks = hooksValue as? [Any] else {
                throw InstallationError.invalidHookGroup(eventName, configurationURL)
            }

            for hookIndex in commandHooks.indices {
                guard var hook = commandHooks[hookIndex] as? [String: Any],
                      hook["type"] as? String == "command",
                      let existingCommand = hook["command"] as? String,
                      isDashboardCommand(existingCommand)
                else { continue }

                found = true
                if existingCommand != command {
                    hook["command"] = command
                    commandHooks[hookIndex] = hook
                    updated = true
                }
            }

            group["hooks"] = commandHooks
            output[groupIndex] = group
        }

        if !found {
            output.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 2,
                ]],
            ])
        }
        return (output, !found, updated)
    }

    private static func isDashboardCommand(_ command: String) -> Bool {
        command.contains("/codex-status-hook")
            || command.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-status-hook"
    }

    private static func uniqueBackupURL(
        for configurationURL: URL,
        fileManager: FileManager
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let safeTimestamp = formatter.string(from: Date()).replacing(":", with: "-")
        let baseName = "\(configurationURL.lastPathComponent).backup-\(safeTimestamp)"
        var candidate = configurationURL.deletingLastPathComponent().appendingPathComponent(baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = configurationURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\''"))'"
    }
}
