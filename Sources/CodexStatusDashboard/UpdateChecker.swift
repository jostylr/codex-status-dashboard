import Foundation

enum UpdateChecker {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/jostylr/codex-status-dashboard/releases/latest")!

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    struct Result {
        let release: Release
        let isNewer: Bool
    }

    enum Error: LocalizedError {
        case noPublishedRelease
        case unexpectedResponse
        case invalidReleaseVersion(String)

        var errorDescription: String? {
            switch self {
            case .noPublishedRelease:
                "There is no published release to compare yet."
            case .unexpectedResponse:
                "GitHub returned an unexpected response while checking for updates."
            case .invalidReleaseVersion(let version):
                "The latest release tag (\(version)) is not a version number."
            }
        }
    }

    static func check(currentVersion: String) async throws -> Result {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexStatusDashboard", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw Error.unexpectedResponse
        }
        if response.statusCode == 404 {
            throw Error.noPublishedRelease
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Error.unexpectedResponse
        }

        let release = try JSONDecoder().decode(Release.self, from: data)
        guard versionComponents(release.tagName) != nil else {
            throw Error.invalidReleaseVersion(release.tagName)
        }
        return Result(
            release: release,
            isNewer: isVersion(release.tagName, newerThan: currentVersion)
        )
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateComponents = versionComponents(candidate) ?? []
        let currentComponents = versionComponents(current) ?? []
        let componentCount = max(candidateComponents.count, currentComponents.count)

        for index in 0..<componentCount {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst()) : trimmed
        let components = withoutPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : nil
    }
}
