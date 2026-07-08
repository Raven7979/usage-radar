import CryptoKit
import Foundation
import Security

/// QuotaRadar 自有的 Claude OAuth 授权。与 Claude Code 的登录态相互独立：
/// token 保存在 QuotaRadar 自己的 Application Support 目录并自动刷新，
/// 只读取、绝不修改 Claude Code 的钥匙串或凭据文件。
public enum ClaudeOAuth {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    // 只申请 profile：用量查询用不到推理权限，token 从根上无法用于第三方推理
    static let scope = "user:profile"
    static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public struct ExchangeError: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    struct StoredToken: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
    }

    static func tokenFileURL() -> URL {
        FileDiscovery.homeDirectory()
            .appendingPathComponent("Library/Application Support/QuotaRadar/claude-oauth.json")
    }

    public static func isConnected() -> Bool {
        loadStored() != nil
    }

    public static func disconnect() {
        try? FileManager.default.removeItem(at: tokenFileURL())
    }

    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    public static func authorizeURL(verifier: String) -> URL {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier)
        ]
        return components.url!
    }

    /// 授权页展示的代码形如 `<code>#<state>`。
    public static func exchange(code rawCode: String, verifier: String, timeout: TimeInterval = 15) throws {
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard let code = parts.first, !code.isEmpty else {
            throw ExchangeError(message: "授权码为空")
        }
        let state = parts.count > 1 ? String(parts[1]) : verifier

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": String(code),
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        guard let token = requestToken(body: body, timeout: timeout) else {
            throw ExchangeError(message: "兑换 token 失败，请重新授权")
        }
        try save(token)
    }

    /// 返回可用的 access token，临近过期时自动刷新并落盘。
    static func validAccessToken(timeout: TimeInterval) -> String? {
        guard var stored = loadStored() else { return nil }
        if stored.expiresAt - 60 > Date().timeIntervalSince1970 {
            return stored.accessToken
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": stored.refreshToken,
            "client_id": clientID
        ]
        guard let refreshed = requestToken(body: body, timeout: timeout) else { return nil }
        stored = refreshed
        try? save(stored)
        return stored.accessToken
    }

    private static func requestToken(body: [String: Any], timeout: TimeInterval) -> StoredToken? {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let data = HTTPSend.send(request, timeout: timeout),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }

        let refreshToken = (object["refresh_token"] as? String)
            ?? (body["refresh_token"] as? String)
            ?? ""
        let expiresIn = double(object["expires_in"]) ?? 3600
        return StoredToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().timeIntervalSince1970 + expiresIn
        )
    }

    static func loadStored() -> StoredToken? {
        guard let data = try? Data(contentsOf: tokenFileURL()),
              let token = try? JSONDecoder().decode(StoredToken.self, from: data),
              !token.accessToken.isEmpty else {
            return nil
        }
        return token
    }

    private static func save(_ token: StoredToken) throws {
        let url = tokenFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(token)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct ClaudeUsageAPIClient {
    private let usageAPIURL: URL
    private let timeout: TimeInterval

    public init(
        usageAPIURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        timeout: TimeInterval = 15
    ) {
        self.usageAPIURL = usageAPIURL
        self.timeout = timeout
    }

    public func fetch() -> ClaudeAPIUsage? {
        guard let data = fetchRawResponse() else { return nil }
        return Self.usage(from: data, fetchedAt: Date())
    }

    public func fetchRawResponse() -> Data? {
        guard let token = Self.resolveAccessToken(timeout: timeout) else { return nil }
        var request = URLRequest(url: usageAPIURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return HTTPSend.send(request, timeout: timeout)
    }

    /// 优先用 QuotaRadar 自己的授权，其次借用已登录的 Claude Code CLI 凭据（只读）。
    static func resolveAccessToken(timeout: TimeInterval) -> String? {
        if let own = ClaudeOAuth.validAccessToken(timeout: timeout) {
            return own
        }
        return claudeCodeCLIToken()
    }

    static func claudeCodeCLIToken() -> String? {
        if let blob = securityFindGenericPassword(service: "Claude Code-credentials"),
           let token = accessToken(fromCredentialsJSON: blob) {
            return token
        }
        let fileURL = FileDiscovery.homeDirectory().appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL),
           let token = accessToken(fromCredentialsJSON: data) {
            return token
        }
        return nil
    }

    static func accessToken(fromCredentialsJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        if let expiresAtMs = double(oauth["expiresAt"]),
           expiresAtMs / 1000 < Date().timeIntervalSince1970 {
            return nil
        }
        return token
    }

    private static func securityFindGenericPassword(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    static func usage(from data: Data, fetchedAt: Date) -> ClaudeAPIUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let container = (root["rate_limits"] as? [String: Any]) ?? root
        let fiveHour = window(container["five_hour"])
        let sevenDay = window(container["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeAPIUsage(fiveHour: fiveHour, sevenDay: sevenDay, fetchedAt: fetchedAt)
    }

    private static func window(_ value: Any?) -> ClaudeAPIWindow? {
        guard let object = value as? [String: Any],
              let used = double(object["utilization"])
                ?? double(object["used_percentage"])
                ?? double(object["used_percent"]) else {
            return nil
        }
        return ClaudeAPIWindow(usedPercentage: used, resetsAt: resetsAtDate(object["resets_at"]))
    }

    private static func resetsAtDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            return DateParsing.parse(string)
        }
        if let number = double(value) {
            let seconds = number > 1e12 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

public struct ClaudeAPIUsage {
    public let fiveHour: ClaudeAPIWindow?
    public let sevenDay: ClaudeAPIWindow?
    public let fetchedAt: Date
}

public struct ClaudeAPIWindow {
    public let usedPercentage: Double
    public let resetsAt: Date?
}

enum HTTPSend {
    static func send(_ request: URLRequest, timeout: TimeInterval) -> Data? {
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
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
