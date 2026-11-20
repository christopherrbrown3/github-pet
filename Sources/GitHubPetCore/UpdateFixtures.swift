import Foundation

/// Offline stand-ins for the GitHub Releases endpoint, for tests and the QA scenario runner.
/// The fixture installed build is `0.1.0-beta.3` (build 200).
public enum UpdateFixture: String, CaseIterable, Sendable {
    case noUpdate = "no-update"
    case betaAvailable = "beta-available"
    case stableAvailable = "stable-available"
    case draftsOnly = "drafts-only"
    case offline
    case forbidden403 = "forbidden-403"
    case rateLimited403 = "rate-limited-403"
    case rateLimited429 = "rate-limited-429"
    case malformed
    case untrustedMetadata = "untrusted-metadata"
    case serverError500 = "server-error-500"

    public static let installedBuild = InstalledBuild(
        shortVersion: "0.1.0", buildNumber: "200", releaseVersion: SemanticVersion("0.1.0-beta.3"), revision: nil)
    /// Fixed so QA records are reproducible: 2026-11-21T00:00:00Z.
    public static let resetEpoch = 1_795_219_200

    public var transport: StatusTransport { UpdateFixtureTransport(fixture: self) }

    private static func release(_ tag: String, prerelease: Bool, draft: Bool = false, notes: String,
                                url: String? = nil, published: String = "2026-11-20T10:00:00Z") -> String {
        let page = url ?? "https://github.com/christopherrbrown3/github-pet/releases/tag/\(tag)"
        return #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"\#(page)","published_at":"\#(published)","body":"\#(notes)","target_commitish":"main"}"#
    }

    var body: String {
        let beta3 = Self.release("v0.1.0-beta.3", prerelease: true, notes: "## What's new\\n\\n- Little Chris mascot.", published: "2026-11-19T16:23:28Z")
        switch self {
        case .noUpdate: return "[\(beta3)]"
        case .betaAvailable:
            return "[\(Self.release("v0.1.0-beta.4", prerelease: true, notes: "## What's new\\n\\n- **Fixture:** a newer beta.\\n- Another change.")),\(beta3)]"
        case .stableAvailable:
            return "[\(Self.release("v0.1.0", prerelease: false, notes: "## What's new\\n\\n- **Fixture:** the first stable release.")),\(Self.release("v0.1.0-beta.4", prerelease: true, notes: "Beta four.")),\(beta3)]"
        case .draftsOnly:
            return "[\(Self.release("v9.9.9", prerelease: false, draft: true, notes: "Draft, must be ignored.")),\(beta3)]"
        case .untrustedMetadata:
            return "[\(Self.release("v0.2.0", prerelease: false, notes: "Bad link.", url: "https://evil.example/releases/tag/v0.2.0")),\(Self.release("not-a-version", prerelease: false, notes: "Bad tag."))]"
        case .malformed: return #"{"message": "this is not a release list""#
        case .offline, .forbidden403, .rateLimited403, .rateLimited429, .serverError500: return "{}"
        }
    }
}

struct UpdateFixtureTransport: StatusTransport {
    let fixture: UpdateFixture

    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? UpdateChecker.endpoint
        func reply(_ code: Int, _ headers: [String: String] = [:], body: String = "{}") -> (Data, HTTPURLResponse) {
            var all = ["Content-Type": "application/json; charset=utf-8"]
            all.merge(headers) { $1 }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: all)!)
        }
        let reset = String(UpdateFixture.resetEpoch)
        switch fixture {
        case .offline: throw URLError(.notConnectedToInternet)
        case .forbidden403: return reply(403, ["x-ratelimit-remaining": "42"])
        case .rateLimited403: return reply(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": reset])
        case .rateLimited429: return reply(429, ["Retry-After": "3600", "x-ratelimit-reset": reset])
        case .serverError500: return reply(500)
        default: return reply(200, body: fixture.body)
        }
    }
}
