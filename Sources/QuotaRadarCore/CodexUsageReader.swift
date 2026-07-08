import Foundation

public struct CodexUsageReader {
    private let sessionsDirectory: URL
    private let maxFiles: Int
    private let now: () -> Date
    private let useUsageAPI: Bool
    private let authFileURL: URL
    private let usageAPIURL: URL
    private let usageAPITimeout: TimeInterval

    public init(
        sessionsDirectory: URL? = nil,
        maxFiles: Int = 50,
        now: @escaping () -> Date = Date.init,
        useUsageAPI: Bool = true,
        authFileURL: URL? = nil,
        usageAPIURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        usageAPITimeout: TimeInterval = 15
    ) {
        let home = FileDiscovery.homeDirectory()
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".codex/sessions")
        self.maxFiles = maxFiles
        self.now = now
        self.useUsageAPI = useUsageAPI
        self.authFileURL = authFileURL ?? home.appendingPathComponent(".codex/auth.json")
        self.usageAPIURL = usageAPIURL
        self.usageAPITimeout = usageAPITimeout
    }

    public func read() -> ProviderUsage {
        if useUsageAPI,
           let apiUsage = CodexUsageAPIClient(
                authFileURL: authFileURL,
                usageAPIURL: usageAPIURL,
                timeout: usageAPITimeout
           ).fetch() {
            return ProviderUsage(
                id: "codex",
                name: "Codex",
                accent: .blue,
                status: .ready,
                windows: apiUsage.windows,
                tokenSummary: nil,
                lastUpdatedAt: apiUsage.fetchedAt,
                note: "来自 Codex 官方 usage API"
            )
        }

        let files = FileDiscovery
            .sortedByModifiedDescending(FileDiscovery.jsonlFiles(under: sessionsDirectory))
            .filter { $0.lastPathComponent.hasPrefix("rollout-") }
            .prefix(maxFiles)
        let events = files.flatMap { Self.tokenEvents(in: $0) }
        let latestSessionEvent = Self.bestTokenEvent(from: events, now: now())

        if let latest = latestSessionEvent {
            return ProviderUsage(
                id: "codex",
                name: "Codex",
                accent: .blue,
                status: .ready,
                windows: Self.windows(from: latest.rateLimits),
                tokenSummary: latest.tokenSummary,
                lastUpdatedAt: latest.timestamp,
                note: "来自 Codex 本机会话 rate_limits"
            )
        }

        return ProviderUsage(
            id: "codex",
            name: "Codex",
            accent: .blue,
            status: .unavailable,
            windows: unavailableWindows(source: .unavailable, reason: "未找到 Codex token_count 事件"),
            tokenSummary: nil,
            lastUpdatedAt: nil,
            note: "只读扫描 \(sessionsDirectory.path)"
        )
    }

    private static func tokenEvents(in file: URL) -> [CodexTokenEvent] {
        var events: [CodexTokenEvent] = []
        for (object, _) in JSONLines.dictionaries(from: file) {
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let timestamp = (object["timestamp"] as? String).flatMap(DateParsing.parse)
            let tokenSummary = Self.tokenSummary(from: payload["info"] as? [String: Any])
            let event = CodexTokenEvent(
                timestamp: timestamp,
                rateLimits: rateLimits,
                tokenSummary: tokenSummary
            )

            events.append(event)
        }
        return events
    }

    private static func bestTokenEvent(from events: [CodexTokenEvent], now: Date) -> CodexTokenEvent? {
        let sorted = events.sorted { left, right in
            switch (left.timestamp, right.timestamp) {
            case let (left?, right?):
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }
        guard let latest = sorted.first else { return nil }

        if isAllZero(latest),
           let fallback = sorted.first(where: { !isAllZero($0) && hasFutureReset($0, now: now) }) {
            return fallback
        }

        return latest
    }

    private static func isAllZero(_ event: CodexTokenEvent) -> Bool {
        usedPercent(in: event, key: "primary") == 0 && usedPercent(in: event, key: "secondary") == 0
    }

    private static func hasFutureReset(_ event: CodexTokenEvent, now: Date) -> Bool {
        ["primary", "secondary"].contains { key in
            guard let raw = event.rateLimits[key] as? [String: Any],
                  let resetAt = int(raw["resets_at"]).map({ Date(timeIntervalSince1970: TimeInterval($0)) }) else {
                return false
            }
            return resetAt > now
        }
    }

    private static func usedPercent(in event: CodexTokenEvent, key: String) -> Double? {
        guard let raw = event.rateLimits[key] as? [String: Any] else { return nil }
        return double(raw["used_percent"])
    }

    private static func windows(from rateLimits: [String: Any]) -> [UsageWindow] {
        [("primary", "5 小时"), ("secondary", "7 天")].compactMap { key, label in
            guard let raw = rateLimits[key] as? [String: Any] else { return nil }
            let windowMinutes = int(raw["window_minutes"]) ?? (key == "primary" ? 300 : 10_080)
            let resetAt = int(raw["resets_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return UsageWindow(
                label: label,
                windowMinutes: windowMinutes,
                usedPercent: double(raw["used_percent"]),
                resetAt: resetAt,
                tokenCount: nil,
                source: .codexRateLimit,
                isEstimate: false,
                unavailableReason: nil
            )
        }
    }

    private static func tokenSummary(from info: [String: Any]?) -> TokenSummary? {
        guard let usage = info?["last_token_usage"] as? [String: Any] else {
            return nil
        }

        return TokenSummary(
            inputTokens: int(usage["input_tokens"]) ?? 0,
            cachedInputTokens: int(usage["cached_input_tokens"]) ?? 0,
            outputTokens: int(usage["output_tokens"]) ?? 0,
            reasoningOutputTokens: int(usage["reasoning_output_tokens"]) ?? 0,
            totalTokens: int(usage["total_tokens"]) ?? 0
        )
    }
}

private struct CodexTokenEvent {
    let timestamp: Date?
    let rateLimits: [String: Any]
    let tokenSummary: TokenSummary?
}

struct CodexUsageAPIClient {
    let authFileURL: URL
    let usageAPIURL: URL
    let timeout: TimeInterval

    func fetch() -> CodexUsageAPISnapshot? {
        guard let auth = try? Self.loadAuth(from: authFileURL) else { return nil }

        var request = URLRequest(url: usageAPIURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let data = Self.send(request, timeout: timeout),
              let windows = try? Self.windows(from: data),
              !windows.isEmpty else {
            return nil
        }

        return CodexUsageAPISnapshot(windows: windows, fetchedAt: Date())
    }

    private static func loadAuth(from url: URL) throws -> CodexAuth {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        let accessToken = file.tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { throw CodexUsageAPIError.missingAccessToken }
        let accountID = file.tokens.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexAuth(accessToken: accessToken, accountID: accountID?.isEmpty == false ? accountID : nil)
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }
            result = data
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
        }
        session.invalidateAndCancel()
        return result
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        let payload = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        return [
            window(from: payload.rateLimit?.primaryWindow, label: "5 小时", defaultMinutes: 300),
            window(from: payload.rateLimit?.secondaryWindow, label: "7 天", defaultMinutes: 10_080)
        ].compactMap { $0 }
    }

    private static func window(
        from source: CodexUsageAPIWindow?,
        label: String,
        defaultMinutes: Int
    ) -> UsageWindow? {
        guard let source, let usedPercent = source.usedPercent else { return nil }
        let windowMinutes = source.limitWindowSeconds.map { max(1, $0 / 60) } ?? defaultMinutes
        let resetAt = source.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return UsageWindow(
            label: label,
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetAt: resetAt,
            tokenCount: nil,
            source: .codexUsageAPI,
            isEstimate: false,
            unavailableReason: nil
        )
    }
}

struct CodexUsageAPISnapshot {
    let windows: [UsageWindow]
    let fetchedAt: Date
}

private struct CodexAuth {
    let accessToken: String
    let accountID: String?
}

private struct CodexAuthFile: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

private struct CodexUsageAPIResponse: Decodable {
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: CodexUsageAPIWindow?
        let secondaryWindow: CodexUsageAPIWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
}

private struct CodexUsageAPIWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private enum CodexUsageAPIError: Error {
    case missingAccessToken
}

func unavailableWindows(source: WindowSource, reason: String) -> [UsageWindow] {
    [
        UsageWindow(
            label: "5 小时",
            windowMinutes: 300,
            usedPercent: nil,
            resetAt: nil,
            tokenCount: nil,
            source: source,
            isEstimate: false,
            unavailableReason: reason
        ),
        UsageWindow(
            label: "7 天",
            windowMinutes: 10_080,
            usedPercent: nil,
            resetAt: nil,
            tokenCount: nil,
            source: source,
            isEstimate: false,
            unavailableReason: reason
        )
    ]
}

func int(_ value: Any?) -> Int? {
    if let cast = value as? Int { return cast }
    if let cast = value as? Int64 { return Int(cast) }
    if let cast = value as? Double { return Int(cast) }
    if let cast = value as? String { return Int(cast) }
    return nil
}

func double(_ value: Any?) -> Double? {
    if let cast = value as? Double { return cast }
    if let cast = value as? Int { return Double(cast) }
    if let cast = value as? String { return Double(cast) }
    return nil
}
