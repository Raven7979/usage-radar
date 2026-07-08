import Foundation

public struct UsageSnapshot: Codable, Equatable {
    public let generatedAt: Date
    public let providers: [ProviderUsage]

    public init(generatedAt: Date, providers: [ProviderUsage]) {
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct ProviderUsage: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let accent: Accent
    public let status: ProviderStatus
    public let windows: [UsageWindow]
    public let tokenSummary: TokenSummary?
    public let lastUpdatedAt: Date?
    public let note: String?

    public init(
        id: String,
        name: String,
        accent: Accent,
        status: ProviderStatus,
        windows: [UsageWindow],
        tokenSummary: TokenSummary?,
        lastUpdatedAt: Date?,
        note: String?
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.status = status
        self.windows = windows
        self.tokenSummary = tokenSummary
        self.lastUpdatedAt = lastUpdatedAt
        self.note = note
    }
}

public extension ProviderUsage {
    static let sampleCodex = ProviderUsage(
        id: "codex",
        name: "Codex",
        accent: .blue,
        status: .ready,
        windows: [
            UsageWindow(label: "5 小时", windowMinutes: 300, usedPercent: 35, resetAt: nil, tokenCount: nil, source: .codexRateLimit, isEstimate: false, unavailableReason: nil),
            UsageWindow(label: "7 天", windowMinutes: 10_080, usedPercent: 64, resetAt: nil, tokenCount: nil, source: .codexRateLimit, isEstimate: false, unavailableReason: nil)
        ],
        tokenSummary: nil,
        lastUpdatedAt: .now,
        note: nil
    )

    static let sampleClaude = ProviderUsage(
        id: "claude",
        name: "Claude",
        accent: .teal,
        status: .partial,
        windows: [
            UsageWindow(label: "5 小时", windowMinutes: 300, usedPercent: nil, resetAt: nil, tokenCount: 6_800_000, source: .claudeLocalUsage, isEstimate: false, unavailableReason: nil),
            UsageWindow(label: "7 天", windowMinutes: 10_080, usedPercent: nil, resetAt: nil, tokenCount: 1_950_000_000, source: .claudeLocalUsage, isEstimate: false, unavailableReason: nil)
        ],
        tokenSummary: nil,
        lastUpdatedAt: .now,
        note: nil
    )
}

public enum ProviderStatus: String, Codable, Equatable {
    case ready
    case partial
    case unavailable
}

public enum Accent: String, Codable, Equatable {
    case blue
    case teal
    case purple
    case orange
}

public struct UsageWindow: Codable, Equatable, Identifiable {
    public var id: String { "\(label)-\(windowMinutes)" }

    public let label: String
    public let windowMinutes: Int
    public let usedPercent: Double?
    public let resetAt: Date?
    public let tokenCount: Int?
    public let source: WindowSource
    public let isEstimate: Bool
    public let unavailableReason: String?

    public init(
        label: String,
        windowMinutes: Int,
        usedPercent: Double?,
        resetAt: Date?,
        tokenCount: Int?,
        source: WindowSource,
        isEstimate: Bool,
        unavailableReason: String?
    ) {
        self.label = label
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.tokenCount = tokenCount
        self.source = source
        self.isEstimate = isEstimate
        self.unavailableReason = unavailableReason
    }
}

public enum WindowSource: String, Codable, Equatable {
    case codexUsageAPI
    case codexRateLimit
    case claudeUsageAPI
    case claudeRateLimit
    case claudeLocalUsage
    case unavailable
}

public struct TokenSummary: Codable, Equatable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public func adding(_ other: TokenSummary) -> TokenSummary {
        TokenSummary(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens + other.cacheCreationInputTokens,
            cacheReadInputTokens: cacheReadInputTokens + other.cacheReadInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }
}
