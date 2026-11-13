import Foundation

/// Why a GitHub Status fetch produced no incident list.
public enum StatusFetchError: Error, Equatable, Sendable {
    case hostNotAllowed
    case httpStatus(Int)
    case notJSON
    case tooLarge
    case timedOut
    case offline
    case transport(String)
    case decode(StatusDecodeError)

    public var message: String {
        switch self {
        case .hostNotAllowed: return "unexpected host"
        case .httpStatus(let code): return "HTTP \(code)"
        case .notJSON: return "unexpected response type"
        case .tooLarge: return "response too large"
        case .timedOut: return "timed out"
        case .offline: return "offline"
        case .transport(let detail): return detail
        case .decode: return "unreadable response"
        }
    }
}

/// Performs one unauthenticated GET and returns at most `maxBytes` of body.
public protocol StatusTransport: Sendable {
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// Reads GitHub's public Statuspage API (unauthenticated). Never uses gh or any GitHub token:
/// authenticated GitHub calls stay with the gh CLI.
public struct ServiceStatusClient: Sendable {
    public static let endpoint = URL(string: "https://www.githubstatus.com/api/v2/incidents/unresolved.json")!
    public static let allowedHosts: Set<String> = [ServiceStatusLink.host]
    public static let defaultMaxBytes = 512 * 1024
    public static let defaultTimeout: TimeInterval = 15

    public let endpoint: URL
    public let maxBytes: Int
    public let timeout: TimeInterval
    private let transport: StatusTransport

    public init(endpoint: URL = ServiceStatusClient.endpoint, transport: StatusTransport? = nil,
                maxBytes: Int = ServiceStatusClient.defaultMaxBytes,
                timeout: TimeInterval = ServiceStatusClient.defaultTimeout) {
        self.endpoint = endpoint
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.transport = transport ?? URLSessionStatusTransport(timeout: timeout)
    }

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, allowedHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        return true
    }

    public func fetch() async -> ServiceStatusOutcome {
        do {
            return .incidents(try await fetchIncidents())
        } catch let error as StatusFetchError {
            return .failure(error.message)
        } catch {
            return .failure(StatusFetchError.transport("request failed").message)
        }
    }

    public func fetchIncidents() async throws -> [ServiceIncident] {
        guard Self.isAllowed(endpoint) else { throw StatusFetchError.hostNotAllowed }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.get(request, maxBytes: maxBytes)
        } catch let error as StatusFetchError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        }
        // Redirects are refused by the transport; check the final URL anyway.
        guard Self.isAllowed(response.url ?? endpoint) else { throw StatusFetchError.hostNotAllowed }
        guard response.statusCode == 200 else { throw StatusFetchError.httpStatus(response.statusCode) }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard type == "application/json" else { throw StatusFetchError.notJSON }
        guard data.count <= maxBytes else { throw StatusFetchError.tooLarge }
        do {
            return try StatusPageDecoder.unresolvedIncidents(from: data)
        } catch let error as StatusDecodeError {
            throw StatusFetchError.decode(error)
        }
    }

    static func map(_ error: URLError) -> StatusFetchError {
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return .hostNotAllowed
        default: return .transport("network error \(error.code.rawValue)")
        }
    }
}

/// URLSession transport with no persistent state: ephemeral, no cookies, credentials or cache,
/// redirects refused, authentication challenges other than server trust cancelled, and the body
/// read incrementally so an oversized response is abandoned at `maxBytes`.
public final class URLSessionStatusTransport: NSObject, StatusTransport, URLSessionTaskDelegate, @unchecked Sendable {
    let configuration: URLSessionConfiguration

    /// - Parameter configure: test hook to adjust the hardened configuration (e.g. stub protocols).
    public init(timeout: TimeInterval, configure: ((URLSessionConfiguration) -> Void)? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        configure?(config)
        configuration = config
    }

    public func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        // A session per fetch: it holds its delegate strongly, and polls are minutes apart.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StatusFetchError.transport("not HTTP") }
        return (try await Self.collect(bytes, expectedLength: http.expectedContentLength, maxBytes: maxBytes), http)
    }

    /// Reads at most `maxBytes`, failing as soon as the declared or streamed length exceeds it.
    static func collect<S: AsyncSequence>(_ bytes: S, expectedLength: Int64, maxBytes: Int) async throws -> Data
    where S.Element == UInt8 {
        if expectedLength > Int64(maxBytes) { throw StatusFetchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maxBytes { throw StatusFetchError.tooLarge }
            data.append(byte)
        }
        return data
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
