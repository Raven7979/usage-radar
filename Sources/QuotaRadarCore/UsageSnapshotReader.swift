import Foundation

public struct UsageSnapshotReader {
    private let codexReader: CodexUsageReader
    private let claudeReader: ClaudeUsageReader
    private let now: () -> Date

    public init(
        codexReader: CodexUsageReader = CodexUsageReader(),
        claudeReader: ClaudeUsageReader = ClaudeUsageReader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.now = now
    }

    public func read() -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now(),
            providers: [
                codexReader.read(),
                claudeReader.read()
            ]
        )
    }
}

