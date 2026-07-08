import XCTest
@testable import QuotaRadarCore

final class UsageReadersTests: XCTestCase {
    func testCodexReaderExtractsRateLimitWindows() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent(".codex/sessions/2026/07/07", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try copyFixture("codex-sample", extension: "jsonl", to: sessions.appendingPathComponent("rollout-test.jsonl"))

        let usage = CodexUsageReader(
            sessionsDirectory: root.appendingPathComponent(".codex/sessions"),
            useUsageAPI: false
        ).read()

        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5 小时")
        XCTAssertEqual(usage.windows[0].usedPercent, 60.0)
        XCTAssertEqual(usage.windows[1].label, "7 天")
        XCTAssertEqual(usage.windows[1].usedPercent, 25.0)
        XCTAssertEqual(usage.tokenSummary?.totalTokens, 60)
    }

    func testCodexReaderSkipsTransientAllZeroRateLimitsWhenPriorWindowIsActive() throws {
        let root = try temporaryDirectory()
        let sessions = root.appendingPathComponent(".codex/sessions/2026/07/07", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try copyFixture("codex-zero-after-nonzero", extension: "jsonl", to: sessions.appendingPathComponent("rollout-test.jsonl"))

        let usage = CodexUsageReader(
            sessionsDirectory: root.appendingPathComponent(".codex/sessions"),
            now: { DateParsing.parse("2026-07-07T10:06:00.000Z")! },
            useUsageAPI: false
        ).read()

        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.windows[0].usedPercent, 20.0)
        XCTAssertEqual(usage.windows[1].usedPercent, 22.0)
        XCTAssertEqual(usage.tokenSummary?.totalTokens, 60)
    }

    func testCodexUsageAPIClientParsesOfficialUsagePayload() throws {
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 33,
              "limit_window_seconds": 18000,
              "reset_at": 1783482206
            },
            "secondary_window": {
              "used_percent": 24,
              "limit_window_seconds": 604800,
              "reset_at": 1783477469
            }
          }
        }
        """.data(using: .utf8)!

        let windows = try CodexUsageAPIClient.windows(from: payload)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5 小时")
        XCTAssertEqual(windows[0].usedPercent, 33)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[0].source, .codexUsageAPI)
        XCTAssertEqual(windows[1].label, "7 天")
        XCTAssertEqual(windows[1].usedPercent, 24)
        XCTAssertEqual(windows[1].windowMinutes, 10_080)
        XCTAssertEqual(windows[1].source, .codexUsageAPI)
    }

    func testClaudeReaderBuildsFiveHourBlocksAndSevenDayTokens() throws {
        let root = try temporaryDirectory()
        let project = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try copyFixture("claude-sample", extension: "jsonl", to: project.appendingPathComponent("session.jsonl"))

        let now = DateParsing.parse("2026-07-07T10:30:00.000Z")!
        let usage = ClaudeUsageReader(
            projectsDirectory: root.appendingPathComponent(".claude/projects"),
            rateLimitCacheURL: root.appendingPathComponent("missing-rate-limits.json"),
            useUsageAPI: false,
            now: { now }
        ).read()

        XCTAssertEqual(usage.status, .partial)
        XCTAssertEqual(usage.windows[0].label, "5 小时")
        XCTAssertNil(usage.windows[0].usedPercent)
        XCTAssertEqual(usage.windows[0].tokenCount, 1_000)
        XCTAssertEqual(usage.windows[1].label, "7 天")
        XCTAssertEqual(usage.windows[1].tokenCount, 1_110)
        XCTAssertEqual(usage.tokenSummary?.totalTokens, 1_110)
    }

    func testClaudeReaderUsesStatusLineRateLimitsWhenAvailable() throws {
        let root = try temporaryDirectory()
        let project = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try copyFixture("claude-sample", extension: "jsonl", to: project.appendingPathComponent("session.jsonl"))
        try copyFixture("claude-rate-limits", extension: "json", to: root.appendingPathComponent("claude-rate-limits.json"))

        let now = DateParsing.parse("2026-07-07T10:30:00.000Z")!
        let usage = ClaudeUsageReader(
            projectsDirectory: root.appendingPathComponent(".claude/projects"),
            rateLimitCacheURL: root.appendingPathComponent("claude-rate-limits.json"),
            useUsageAPI: false,
            now: { now }
        ).read()

        XCTAssertEqual(usage.status, .ready)
        XCTAssertEqual(usage.windows[0].usedPercent, 40)
        XCTAssertEqual(usage.windows[0].source, .claudeRateLimit)
        XCTAssertEqual(usage.windows[1].usedPercent, 12.5)
        XCTAssertEqual(usage.windows[1].source, .claudeRateLimit)
        XCTAssertEqual(usage.tokenSummary?.totalTokens, 1_110)
    }

    func testClaudeReaderKeepsStaleCachePercentUntilWindowResets() throws {
        let root = try temporaryDirectory()
        let project = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try copyFixture("claude-sample", extension: "jsonl", to: project.appendingPathComponent("session.jsonl"))
        try copyFixture("claude-rate-limits", extension: "json", to: root.appendingPathComponent("claude-rate-limits.json"))

        // 缓存生成于 11:00，30 分钟后已超过 10 分钟新鲜期，但两个窗口的 resets_at 都在未来
        let now = DateParsing.parse("2026-07-07T11:30:00.000Z")!
        let usage = ClaudeUsageReader(
            projectsDirectory: root.appendingPathComponent(".claude/projects"),
            rateLimitCacheURL: root.appendingPathComponent("claude-rate-limits.json"),
            maxRateLimitCacheAge: 10 * 60,
            useUsageAPI: false,
            now: { now }
        ).read()

        XCTAssertEqual(usage.status, .partial)
        XCTAssertEqual(usage.windows[0].usedPercent, 40)
        XCTAssertEqual(usage.windows[0].source, .claudeRateLimit)
        XCTAssertEqual(usage.windows[1].usedPercent, 12.5)
        XCTAssertTrue(usage.note?.contains("缓存数据") == true)
    }

    func testClaudeReaderKeepsStaleCacheEvenWithoutScanningLocalMessages() throws {
        let root = try temporaryDirectory()
        try copyFixture("claude-rate-limits", extension: "json", to: root.appendingPathComponent("claude-rate-limits.json"))

        let now = DateParsing.parse("2026-07-07T11:30:00.000Z")!
        let usage = ClaudeUsageReader(
            projectsDirectory: root.appendingPathComponent(".claude/projects"),
            rateLimitCacheURL: root.appendingPathComponent("claude-rate-limits.json"),
            maxFiles: 0,
            maxRateLimitCacheAge: 10 * 60,
            useUsageAPI: false,
            now: { now }
        ).read()

        XCTAssertEqual(usage.status, .partial)
        XCTAssertEqual(usage.windows[0].usedPercent, 40)
        XCTAssertEqual(usage.windows[1].usedPercent, 12.5)
    }

    func testClaudeUsableWindowStaleRules() {
        let now = DateParsing.parse("2026-07-07T12:00:00.000Z")!
        let futureReset = ClaudeRateWindow(usedPercentage: 40, resetsAt: now.addingTimeInterval(3600))
        let pastReset = ClaudeRateWindow(usedPercentage: 40, resetsAt: now.addingTimeInterval(-60))
        let manual = ClaudeRateWindow(usedPercentage: 40, resetsAt: nil)

        // 新鲜缓存原样返回
        XCTAssertNotNil(ClaudeUsageReader.usableWindow(pastReset, fresh: true, generatedAt: now, windowDuration: 300 * 60, now: now))
        // 过期缓存：未到重置时间则保留，已过重置时间则丢弃
        XCTAssertNotNil(ClaudeUsageReader.usableWindow(futureReset, fresh: false, generatedAt: nil, windowDuration: 300 * 60, now: now))
        XCTAssertNil(ClaudeUsageReader.usableWindow(pastReset, fresh: false, generatedAt: nil, windowDuration: 300 * 60, now: now))
        // 无 resets_at 的缓存：一个窗口周期内保留，超过后丢弃
        let recent = now.addingTimeInterval(-4 * 60 * 60)
        let old = now.addingTimeInterval(-6 * 60 * 60)
        XCTAssertNotNil(ClaudeUsageReader.usableWindow(manual, fresh: false, generatedAt: recent, windowDuration: 5 * 60 * 60, now: now))
        XCTAssertNil(ClaudeUsageReader.usableWindow(manual, fresh: false, generatedAt: old, windowDuration: 5 * 60 * 60, now: now))
    }

    func testClaudeUsageAPIClientParsesUtilizationPayload() throws {
        let payload = """
        {
          "five_hour": {"utilization": 41.5, "resets_at": "2026-07-08T10:00:00Z"},
          "seven_day": {"utilization": 26, "resets_at": 1783900000},
          "seven_day_opus": {"utilization": 3}
        }
        """.data(using: .utf8)!

        let usage = try XCTUnwrap(ClaudeUsageAPIClient.usage(from: payload, fetchedAt: .now))

        XCTAssertEqual(usage.fiveHour?.usedPercentage, 41.5)
        XCTAssertEqual(usage.fiveHour?.resetsAt, DateParsing.parse("2026-07-08T10:00:00Z"))
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 26)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_783_900_000))
    }

    func testClaudeUsageAPIClientParsesUsedPercentagePayload() throws {
        let payload = """
        {"rate_limits": {"five_hour": {"used_percentage": 12}}}
        """.data(using: .utf8)!

        let usage = try XCTUnwrap(ClaudeUsageAPIClient.usage(from: payload, fetchedAt: .now))

        XCTAssertEqual(usage.fiveHour?.usedPercentage, 12)
        XCTAssertNil(usage.sevenDay)
    }

    func testClaudeCredentialsJSONTokenParsing() {
        let valid = """
        {"claudeAiOauth": {"accessToken": "sk-test", "expiresAt": \(Int(Date().timeIntervalSince1970 * 1000) + 3_600_000)}}
        """.data(using: .utf8)!
        XCTAssertEqual(ClaudeUsageAPIClient.accessToken(fromCredentialsJSON: valid), "sk-test")

        let expired = """
        {"claudeAiOauth": {"accessToken": "sk-test", "expiresAt": 1000}}
        """.data(using: .utf8)!
        XCTAssertNil(ClaudeUsageAPIClient.accessToken(fromCredentialsJSON: expired))
    }

    private func copyFixture(_ name: String, extension fileExtension: String, to destination: URL) throws {
        let source = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaRadarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
