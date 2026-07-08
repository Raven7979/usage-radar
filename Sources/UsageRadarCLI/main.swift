import Foundation
import QuotaRadarCore

func printSnapshot() throws {
    let snapshot = UsageSnapshotReader().read()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(snapshot)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func claudeLogin() {
    let verifier = ClaudeOAuth.makeVerifier()
    let url = ClaudeOAuth.authorizeURL(verifier: verifier)
    print("1. 在浏览器打开并授权：\n\n\(url.absoluteString)\n")
    print("2. 授权后把页面显示的授权码粘贴到这里，回车确认：")
    guard let code = readLine(), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("未输入授权码，已取消")
        exit(1)
    }
    do {
        try ClaudeOAuth.exchange(code: code, verifier: verifier)
        print("已连接 Claude 账号，token 保存在 ~/Library/Application Support/QuotaRadar/claude-oauth.json")
        if let usage = ClaudeUsageAPIClient().fetch() {
            let five = usage.fiveHour.map { String(format: "%.0f%%", $0.usedPercentage) } ?? "--"
            let seven = usage.sevenDay.map { String(format: "%.0f%%", $0.usedPercentage) } ?? "--"
            print("当前已用：5 小时 \(five) / 7 天 \(seven)")
        } else {
            print("token 已保存，但拉取 usage API 失败，可运行 usage-radar claude-usage-raw 排查")
        }
    } catch {
        print("连接失败：\(error.localizedDescription)")
        exit(1)
    }
}

func claudeUsageRaw() {
    guard let data = ClaudeUsageAPIClient().fetchRawResponse() else {
        print("拉取失败：无可用凭据或请求出错。先运行 usage-radar claude-login")
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

switch CommandLine.arguments.dropFirst().first {
case "claude-login":
    claudeLogin()
case "claude-usage-raw":
    claudeUsageRaw()
default:
    try printSnapshot()
}
