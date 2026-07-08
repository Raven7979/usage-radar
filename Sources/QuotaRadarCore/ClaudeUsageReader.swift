import Foundation

public struct ClaudeUsageReader {
    private let projectsDirectory: URL
    private let rateLimitCacheURL: URL
    private let maxFiles: Int
    private let maxRateLimitCacheAge: TimeInterval
    private let useUsageAPI: Bool
    private let now: () -> Date

    public init(
        projectsDirectory: URL? = nil,
        rateLimitCacheURL: URL? = nil,
        maxFiles: Int = 400,
        maxRateLimitCacheAge: TimeInterval = 10 * 60,
        useUsageAPI: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.projectsDirectory = projectsDirectory ?? FileDiscovery.homeDirectory().appendingPathComponent(".claude/projects")
        self.rateLimitCacheURL = rateLimitCacheURL ?? FileDiscovery.homeDirectory()
            .appendingPathComponent("Library/Application Support/QuotaRadar/claude-rate-limits.json")
        self.maxFiles = maxFiles
        self.maxRateLimitCacheAge = maxRateLimitCacheAge
        self.useUsageAPI = useUsageAPI
        self.now = now
    }

    public func read() -> ProviderUsage {
        let currentDate = now()
        let apiUsage = useUsageAPI ? ClaudeUsageAPIClient().fetch() : nil
        let rawCachedLimits = loadRateLimitCache()
        let entries = loadEntries()

        guard apiUsage != nil || !entries.isEmpty || rawCachedLimits != nil else {
            return ProviderUsage(
                id: "claude",
                name: "Claude",
                accent: .teal,
                status: .unavailable,
                windows: unavailableWindows(source: .unavailable, reason: "未同步：请在设置中连接 Claude 账号"),
                tokenSummary: nil,
                lastUpdatedAt: nil,
                note: "未连接 Claude 账号，也未发现本地 Claude 数据"
            )
        }

        let block = Self.currentOrLatestBlock(from: entries, now: currentDate)
        let weeklyStart = currentDate.addingTimeInterval(-7 * 24 * 60 * 60)
        let weeklyEntries = entries.filter { $0.timestamp >= weeklyStart && $0.timestamp <= currentDate }
        let weeklySummary = weeklyEntries.map(\.tokens).reduce(TokenSummary(), { $0.adding($1) })

        if let apiUsage {
            let fiveHourWindow = UsageWindow(
                label: "5 小时",
                windowMinutes: 300,
                usedPercent: apiUsage.fiveHour?.usedPercentage,
                resetAt: apiUsage.fiveHour?.resetsAt ?? block?.end,
                tokenCount: block?.tokens.totalTokens,
                source: .claudeUsageAPI,
                isEstimate: false,
                unavailableReason: apiUsage.fiveHour == nil ? "官方 usage API 未返回 5 小时窗口" : nil
            )
            let sevenDayWindow = UsageWindow(
                label: "7 天",
                windowMinutes: 10_080,
                usedPercent: apiUsage.sevenDay?.usedPercentage,
                resetAt: apiUsage.sevenDay?.resetsAt,
                tokenCount: weeklySummary.totalTokens > 0 ? weeklySummary.totalTokens : nil,
                source: .claudeUsageAPI,
                isEstimate: false,
                unavailableReason: apiUsage.sevenDay == nil ? "官方 usage API 未返回 7 天窗口" : nil
            )
            return ProviderUsage(
                id: "claude",
                name: "Claude",
                accent: .teal,
                status: .ready,
                windows: [fiveHourWindow, sevenDayWindow],
                tokenSummary: entries.isEmpty ? nil : weeklySummary,
                lastUpdatedAt: [entries.last?.timestamp, apiUsage.fetchedAt].compactMap { $0 }.max(),
                note: "来自 Claude 官方 usage API"
            )
        }

        let cacheIsFresh = Self.isFresh(rawCachedLimits?.generatedAt, at: currentDate, maxAge: maxRateLimitCacheAge)
        let fiveHourLimit = Self.usableWindow(
            rawCachedLimits?.fiveHour,
            fresh: cacheIsFresh,
            generatedAt: rawCachedLimits?.generatedAt,
            windowDuration: 5 * 60 * 60,
            now: currentDate
        )
        let sevenDayLimit = Self.usableWindow(
            rawCachedLimits?.sevenDay,
            fresh: cacheIsFresh,
            generatedAt: rawCachedLimits?.generatedAt,
            windowDuration: 7 * 24 * 60 * 60,
            now: currentDate
        )

        let missingReason: String
        if let generatedAt = rawCachedLimits?.generatedAt, !cacheIsFresh {
            missingReason = "缓存已过重置时间（上次同步 \(Self.displayDate(generatedAt))），等待新数据"
        } else {
            missingReason = "未同步：连接 Claude 账号后自动获取官方百分比"
        }

        let fiveHourWindow = UsageWindow(
            label: "5 小时",
            windowMinutes: 300,
            usedPercent: fiveHourLimit?.usedPercentage,
            resetAt: fiveHourLimit?.resetsAt ?? block?.end,
            tokenCount: block?.tokens.totalTokens,
            source: fiveHourLimit == nil ? .claudeLocalUsage : .claudeRateLimit,
            isEstimate: false,
            unavailableReason: fiveHourLimit == nil ? missingReason : nil
        )
        let sevenDayWindow = UsageWindow(
            label: "7 天",
            windowMinutes: 10_080,
            usedPercent: sevenDayLimit?.usedPercentage,
            resetAt: sevenDayLimit?.resetsAt,
            tokenCount: weeklySummary.totalTokens > 0 ? weeklySummary.totalTokens : nil,
            source: sevenDayLimit == nil ? .claudeLocalUsage : .claudeRateLimit,
            isEstimate: false,
            unavailableReason: sevenDayLimit == nil ? missingReason : nil
        )

        let hasOfficialPercent = fiveHourWindow.usedPercent != nil || sevenDayWindow.usedPercent != nil
        let hasLocalTokens = (fiveHourWindow.tokenCount ?? 0) > 0 || weeklySummary.totalTokens > 0
        let status: ProviderStatus
        if hasOfficialPercent {
            status = cacheIsFresh ? .ready : .partial
        } else {
            status = hasLocalTokens ? .partial : .unavailable
        }

        let note: String
        if hasOfficialPercent, cacheIsFresh {
            note = "来自 Claude Code statusLine rate_limits 缓存"
        } else if hasOfficialPercent, let generatedAt = rawCachedLimits?.generatedAt {
            note = "缓存数据（截至 \(Self.displayDate(generatedAt))）；连接 Claude 账号后可自动同步"
        } else {
            note = "等待同步：在设置中连接 Claude 账号，即可显示官方百分比"
        }

        return ProviderUsage(
            id: "claude",
            name: "Claude",
            accent: .teal,
            status: status,
            windows: [fiveHourWindow, sevenDayWindow],
            tokenSummary: entries.isEmpty ? nil : weeklySummary,
            lastUpdatedAt: [entries.last?.timestamp, rawCachedLimits?.generatedAt].compactMap { $0 }.max(),
            note: note
        )
    }

    /// 缓存新鲜时直接使用；过期后只要窗口还未到重置时间就继续显示旧值，
    /// 缺少重置时间的最多沿用一个窗口周期。
    static func usableWindow(
        _ window: ClaudeRateWindow?,
        fresh: Bool,
        generatedAt: Date?,
        windowDuration: TimeInterval,
        now: Date
    ) -> ClaudeRateWindow? {
        guard let window else { return nil }
        if fresh { return window }
        if let resetsAt = window.resetsAt {
            return resetsAt > now ? window : nil
        }
        guard let generatedAt else { return nil }
        return now.timeIntervalSince(generatedAt) <= windowDuration ? window : nil
    }

    private static func isFresh(_ generatedAt: Date?, at currentDate: Date, maxAge: TimeInterval) -> Bool {
        guard let generatedAt else { return false }
        return currentDate.timeIntervalSince(generatedAt) <= maxAge
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func loadRateLimitCache() -> ClaudeRateLimitCache? {
        guard let data = try? Data(contentsOf: rateLimitCacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return ClaudeRateLimitCache(
            generatedAt: (object["generated_at"] as? String).flatMap(DateParsing.parse),
            fiveHour: Self.rateWindow(from: object["five_hour"] as? [String: Any]),
            sevenDay: Self.rateWindow(from: object["seven_day"] as? [String: Any])
        )
    }

    private static func rateWindow(from object: [String: Any]?) -> ClaudeRateWindow? {
        guard let object,
              let usedPercentage = double(object["used_percentage"]) else {
            return nil
        }

        let resetsAt = int(object["resets_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return ClaudeRateWindow(usedPercentage: usedPercentage, resetsAt: resetsAt)
    }

    private func loadEntries() -> [ClaudeEntry] {
        let files = FileDiscovery
            .sortedByModifiedDescending(
                FileDiscovery.jsonlFiles(
                    under: projectsDirectory,
                    skippingDirectoryNames: ["subagents"]
                )
            )
            .prefix(maxFiles)

        var entries: [ClaudeEntry] = []
        for file in files {
            for (object, _) in JSONLines.dictionaries(from: file) {
                guard let timestampString = object["timestamp"] as? String,
                      let timestamp = DateParsing.parse(timestampString),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                entries.append(
                    ClaudeEntry(
                        timestamp: timestamp,
                        model: message["model"] as? String,
                        tokens: Self.tokenSummary(from: usage)
                    )
                )
            }
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private static func tokenSummary(from usage: [String: Any]) -> TokenSummary {
        let input = int(usage["input_tokens"]) ?? 0
        let output = int(usage["output_tokens"]) ?? 0
        let creation = int(usage["cache_creation_input_tokens"]) ?? 0
        let read = int(usage["cache_read_input_tokens"]) ?? 0
        return TokenSummary(
            inputTokens: input,
            cacheCreationInputTokens: creation,
            cacheReadInputTokens: read,
            outputTokens: output,
            totalTokens: input + output + creation + read
        )
    }

    static func currentOrLatestBlock(from entries: [ClaudeEntry], now: Date) -> ClaudeBlock? {
        let blocks = billingBlocks(from: entries)
        if let active = blocks.last(where: { $0.start <= now && now < $0.end }) {
            return active
        }
        return blocks.last
    }

    static func billingBlocks(from entries: [ClaudeEntry]) -> [ClaudeBlock] {
        var blocks: [ClaudeBlock] = []
        var current: ClaudeBlock?
        let calendar = Calendar(identifier: .gregorian)

        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            if current == nil || entry.timestamp >= current!.end {
                if let current {
                    blocks.append(current)
                }
                let start = DateParsing.floorToHour(entry.timestamp, calendar: calendar)
                current = ClaudeBlock(start: start, end: start.addingTimeInterval(5 * 60 * 60), entries: [])
            }
            current?.entries.append(entry)
        }

        if let current {
            blocks.append(current)
        }
        return blocks
    }
}

struct ClaudeEntry: Equatable {
    let timestamp: Date
    let model: String?
    let tokens: TokenSummary
}

struct ClaudeBlock: Equatable {
    let start: Date
    let end: Date
    var entries: [ClaudeEntry]

    var tokens: TokenSummary {
        entries.map(\.tokens).reduce(TokenSummary(), { $0.adding($1) })
    }
}

struct ClaudeRateLimitCache: Equatable {
    let generatedAt: Date?
    let fiveHour: ClaudeRateWindow?
    let sevenDay: ClaudeRateWindow?
}

struct ClaudeRateWindow: Equatable {
    let usedPercentage: Double
    let resetsAt: Date?
}
