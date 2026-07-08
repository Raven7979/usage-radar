import AppKit
import SwiftUI
import WidgetKit

@main
struct QuotaRadarMacApp: App {
    @StateObject private var model = QuotaRadarAppModel()
    private let desktopWidget = DesktopWidgetController.shared
    private let menuBarStatus = MenuBarStatusController.shared

    var body: some Scene {
        WindowGroup("Usage Radar") {
            SettingsView(model: model, desktopWidget: desktopWidget)
                .frame(width: 430, height: 360)
                .onAppear {
                    menuBarStatus.bind(model: model, desktopWidget: desktopWidget)
                    desktopWidget.bind(model)
                    model.refresh()
                    if model.isDesktopWidgetVisible {
                        desktopWidget.show()
                    }
                }
        }
    }
}

@MainActor
final class QuotaRadarAppModel: ObservableObject {
    @Published private(set) var statusText = "准备刷新"
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published var claudeAuthCodeText = ""
    @Published private(set) var claudeAuthPendingVerifier: String?
    @Published private(set) var isClaudeConnected = ClaudeOAuth.isConnected()
    @Published var selectedProviderID: String {
        didSet {
            UserDefaults.standard.set(selectedProviderID, forKey: "selectedProviderID")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var menuBarProviderChoice: String {
        didSet {
            UserDefaults.standard.set(menuBarProviderChoice, forKey: "menuBarProviderChoice")
            MenuBarStatusController.shared.update(snapshot: snapshot)
        }
    }
    @Published var isDesktopWidgetVisible: Bool {
        didSet {
            UserDefaults.standard.set(isDesktopWidgetVisible, forKey: "desktopWidgetVisible")
        }
    }

    private var autoRefreshTimer: Timer?

    init() {
        selectedProviderID = UserDefaults.standard.string(forKey: "selectedProviderID") ?? "codex"
        menuBarProviderChoice = UserDefaults.standard.string(forKey: "menuBarProviderChoice") ?? "both"
        isDesktopWidgetVisible = UserDefaults.standard.object(forKey: "desktopWidgetVisible") as? Bool ?? true
        snapshot = SnapshotStore.read()
        statusText = snapshot == nil ? "点击刷新以读取本机用量" : "已加载缓存，点击刷新可更新"
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: false)
            }
        }
    }

    /// force = true（手动/首次）总是拉取；自动刷新只拉取检测到正在运行的服务。
    func refresh(force: Bool = true) {
        guard !isRefreshing else { return }
        let previousCodex = snapshot?.providers.first { $0.id == "codex" }
        let previousClaude = snapshot?.providers.first { $0.id == "claude" }
        isRefreshing = true
        if force {
            statusText = "正在读取 Codex / Claude 用量..."
        }

        Task.detached(priority: .userInitiated) {
            let fetchCodex = force || previousCodex == nil || ProviderProcessDetector.isCodexRunning()
            let fetchClaude = force || previousClaude == nil || ProviderProcessDetector.isClaudeRunning()

            guard fetchCodex || fetchClaude else {
                await MainActor.run {
                    self.isRefreshing = false
                    self.statusText = "Codex / Claude 均未运行，已暂停自动刷新"
                }
                return
            }

            let codex = fetchCodex ? CodexUsageReader(maxFiles: 20).read() : previousCodex!
            let claude = fetchClaude ? ClaudeUsageReader(maxFiles: 40).read() : previousClaude!
            let snapshot = UsageSnapshot(generatedAt: Date(), providers: [codex, claude])
            do {
                try SnapshotStore.write(snapshot)
                await MainActor.run {
                    self.snapshot = snapshot
                    self.statusText = "已刷新，小组件会自动读取最新缓存"
                    self.isRefreshing = false
                    MenuBarStatusController.shared.update(snapshot: snapshot)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                await MainActor.run {
                    self.statusText = "写入缓存失败：\(error.localizedDescription)"
                    self.isRefreshing = false
                }
            }
        }
    }

    var isClaudeAuthPending: Bool {
        claudeAuthPendingVerifier != nil
    }

    func startClaudeLogin() {
        let verifier = ClaudeOAuth.makeVerifier()
        claudeAuthPendingVerifier = verifier
        claudeAuthCodeText = ""
        NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(verifier: verifier))
        statusText = "已打开浏览器授权页；登录并授权后，把页面上的授权码粘贴到下方"
    }

    func completeClaudeLogin() {
        guard let verifier = claudeAuthPendingVerifier else { return }
        let code = claudeAuthCodeText
        statusText = "正在验证授权码..."

        Task.detached(priority: .userInitiated) {
            do {
                try ClaudeOAuth.exchange(code: code, verifier: verifier)
                await MainActor.run {
                    self.claudeAuthPendingVerifier = nil
                    self.claudeAuthCodeText = ""
                    self.isClaudeConnected = true
                    self.selectedProviderID = "claude"
                    self.statusText = "Claude 账号已连接，正在刷新..."
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.statusText = "连接失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func disconnectClaude() {
        ClaudeOAuth.disconnect()
        claudeAuthPendingVerifier = nil
        isClaudeConnected = false
        statusText = "已断开 Claude 账号，刷新后回退到本地缓存"
    }

    var selectedProvider: ProviderUsage {
        snapshot?.providers.first { $0.id == selectedProviderID }
            ?? (selectedProviderID == "claude" ? .sampleClaude : .sampleCodex)
    }
}

enum ProviderProcessDetector {
    static func isCodexRunning() -> Bool {
        isGUIAppRunning(bundlePrefix: "com.openai.codex") || commandLineProcessExists("codex")
    }

    static func isClaudeRunning() -> Bool {
        isGUIAppRunning(bundlePrefix: "com.anthropic") || commandLineProcessExists("claude")
    }

    private static func isGUIAppRunning(bundlePrefix: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier?.lowercased().hasPrefix(bundlePrefix) == true
        }
    }

    private static func commandLineProcessExists(_ pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-qif", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

struct SettingsView: View {
    @ObservedObject var model: QuotaRadarAppModel
    let desktopWidget: DesktopWidgetController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Usage Radar")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Label(model.isRefreshing ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }

            Picker("显示", selection: $model.selectedProviderID) {
                Text("Codex").tag("codex")
                Text("Claude").tag("claude")
            }
            .pickerStyle(.segmented)

            Picker("菜单栏", selection: $model.menuBarProviderChoice) {
                Text("Codex + Claude").tag("both")
                Text("仅 Codex").tag("codex")
                Text("仅 Claude").tag("claude")
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                if model.isClaudeConnected {
                    Label("Claude 账号已连接", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("断开") {
                        model.disconnectClaude()
                    }
                } else if model.isClaudeAuthPending {
                    TextField("粘贴浏览器里的授权码", text: $model.claudeAuthCodeText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.completeClaudeLogin()
                    } label: {
                        Label("完成连接", systemImage: "checkmark")
                    }
                    .disabled(model.claudeAuthCodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button {
                        model.startClaudeLogin()
                    } label: {
                        Label("连接 Claude 账号", systemImage: "person.crop.circle.badge.plus")
                    }
                    Text("自动同步官方剩余百分比")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.isDesktopWidgetVisible.toggle()
                    if model.isDesktopWidgetVisible {
                        desktopWidget.show()
                    } else {
                        desktopWidget.hide()
                    }
                } label: {
                    Label(model.isDesktopWidgetVisible ? "隐藏桌面小窗" : "显示桌面小窗", systemImage: model.isDesktopWidgetVisible ? "eye.slash" : "eye")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusText)
                    .font(.system(size: 13, weight: .semibold))
                if let snapshot = model.snapshot {
                    ForEach(snapshot.providers) { provider in
                        Text(summaryLine(provider))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(22)
    }

    private func summaryLine(_ provider: ProviderUsage) -> String {
        let values = provider.windows.map { window in
            if let used = window.usedPercent {
                return "\(window.label): 剩余 \(max(0, Int((100 - used).rounded())))%"
            }
            if let tokens = window.tokenCount {
                return "\(window.label): \(compactAppNumber(tokens))"
            }
            return "\(window.label): --"
        }
        .joined(separator: " / ")
        return "\(provider.name)  \(values)"
    }
}

struct MenuBarQuotaView: View {
    @ObservedObject var model: QuotaRadarAppModel
    let desktopWidget: DesktopWidgetController

    private var providers: [ProviderUsage] {
        let snapshotProviders = model.snapshot?.providers ?? []
        let codex = snapshotProviders.first { $0.id == "codex" } ?? .sampleCodex
        let claude = snapshotProviders.first { $0.id == "claude" } ?? .sampleClaude
        return [codex, claude]
    }

    var body: some View {
        ForEach(providers) { provider in
            Section(provider.name) {
                ForEach(provider.windows) { window in
                    Text(menuWindowLine(window))
                }
            }
        }

        Divider()

        Button {
            model.refresh()
        } label: {
            Label(model.isRefreshing ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)

        Button {
            model.isDesktopWidgetVisible.toggle()
            if model.isDesktopWidgetVisible {
                desktopWidget.show()
            } else {
                desktopWidget.hide()
            }
        } label: {
            Label(model.isDesktopWidgetVisible ? "隐藏桌面小窗" : "显示桌面小窗", systemImage: model.isDesktopWidgetVisible ? "eye.slash" : "eye")
        }
    }
}

@MainActor
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private weak var model: QuotaRadarAppModel?
    private weak var desktopWidget: DesktopWidgetController?
    private var countdownTimer: Timer?

    private override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let shared = MenuBarStatusController.shared
                shared.update(snapshot: shared.model?.snapshot)
            }
        }
    }

    func bind(model: QuotaRadarAppModel, desktopWidget: DesktopWidgetController) {
        self.model = model
        self.desktopWidget = desktopWidget
        update(snapshot: model.snapshot)
    }

    func update(snapshot: UsageSnapshot?) {
        let choice = MenuBarProviderChoice(rawValue: model?.menuBarProviderChoice ?? "") ?? .both
        let image = makeMenuBarStatusImage(snapshot: snapshot, choice: choice)
        statusItem.length = image.size.width + 6
        statusItem.button?.image = image
        statusItem.button?.toolTip = menuBarCompactLabel(snapshot: snapshot, choice: choice)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        for provider in menuProviders() {
            let header = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for window in provider.windows {
                let item = NSMenuItem(title: menuWindowLine(window), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: model?.isRefreshing == true ? "刷新中" : "刷新",
            action: #selector(refreshUsage),
            keyEquivalent: "r"
        )
        refresh.target = self
        refresh.isEnabled = model?.isRefreshing != true
        menu.addItem(refresh)

        let toggleTitle = model?.isDesktopWidgetVisible == true ? "隐藏桌面小窗" : "显示桌面小窗"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleDesktopWidget), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "打开设置", action: #selector(showSettingsWindow), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func menuProviders() -> [ProviderUsage] {
        let choice = MenuBarProviderChoice(rawValue: model?.menuBarProviderChoice ?? "") ?? .both
        let snapshotProviders = model?.snapshot?.providers ?? []
        let codex = snapshotProviders.first { $0.id == "codex" } ?? .sampleCodex
        let claude = snapshotProviders.first { $0.id == "claude" } ?? .sampleClaude
        switch choice {
        case .codex: return [codex]
        case .claude: return [claude]
        case .both: return [codex, claude]
        }
    }

    @objc private func refreshUsage() {
        model?.refresh()
    }

    @objc private func toggleDesktopWidget() {
        guard let model else { return }
        model.isDesktopWidgetVisible.toggle()
        let shouldShow = model.isDesktopWidgetVisible
        Task { @MainActor [weak self] in
            guard let desktopWidget = self?.desktopWidget else { return }
            if shouldShow {
                desktopWidget.show()
            } else {
                desktopWidget.hide()
            }
        }
    }

    @objc private func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.title == "Usage Radar" }
        window?.makeKeyAndOrderFront(nil)
    }
}

enum MenuBarProviderChoice: String {
    case both
    case codex
    case claude

    var providerIDs: [String] {
        switch self {
        case .both: return ["codex", "claude"]
        case .codex: return ["codex"]
        case .claude: return ["claude"]
        }
    }
}

private func makeMenuBarStatusImage(snapshot: UsageSnapshot?, choice: MenuBarProviderChoice) -> NSImage {
    let providers = snapshot?.providers ?? [.sampleCodex, .sampleClaude]
    let segments: [(providerID: String, text: NSString)] = choice.providerIDs.map { id in
        let provider = providers.first { $0.id == id }
        let pair = menuBarRemainingPair(provider)
        var text = "\(pair.primary)/\(pair.secondary)"
        let fiveHour = provider?.windows.first { $0.windowMinutes == 300 } ?? provider?.windows.first
        if let countdown = resetCountdownText(fiveHour?.resetAt, now: Date()) {
            text += " · \(countdown.replacingOccurrences(of: " ", with: ""))"
        }
        return (id, NSString(string: text))
    }

    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.94)
    ]

    let iconSize: CGFloat = 13
    let height: CGFloat = 18
    let iconTextGap: CGFloat = 4
    let providerGap: CGFloat = 9
    let textSizes = segments.map { $0.text.size(withAttributes: attributes) }
    let width = ceil(
        textSizes.reduce(0) { $0 + iconSize + iconTextGap + $1.width }
            + providerGap * CGFloat(max(0, segments.count - 1))
    )

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true

    let color = NSColor.white.withAlphaComponent(0.94)
    var x: CGFloat = 0
    let iconY = (height - iconSize) / 2
    for (index, segment) in segments.enumerated() {
        let iconRect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
        if segment.providerID == "claude" {
            drawClaudeMenuIcon(in: iconRect, color: color)
        } else {
            drawCodexMenuIcon(in: iconRect, color: color)
        }
        x += iconSize + iconTextGap
        segment.text.draw(at: NSPoint(x: x, y: (height - textSizes[index].height) / 2 + 0.5), withAttributes: attributes)
        x += textSizes[index].width + providerGap
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
}

private func drawCodexMenuIcon(in rect: NSRect, color: NSColor) {
    color.setFill()
    let circles: [(CGFloat, CGFloat, CGFloat)] = [
        (0.27, 0.54, 0.47),
        (0.42, 0.73, 0.49),
        (0.64, 0.68, 0.44),
        (0.74, 0.45, 0.47),
        (0.53, 0.27, 0.48),
        (0.29, 0.34, 0.43)
    ]

    for circle in circles {
        let diameter = rect.width * circle.2
        let x = rect.minX + rect.width * circle.0 - diameter / 2
        let y = rect.minY + rect.height * circle.1 - diameter / 2
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
    }

    NSBezierPath(ovalIn: NSRect(
        x: rect.minX + rect.width * 0.24,
        y: rect.minY + rect.height * 0.30,
        width: rect.width * 0.56,
        height: rect.height * 0.45
    )).fill()
}

private func drawClaudeMenuIcon(in rect: NSRect, color: NSColor) {
    color.setFill()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let length = rect.height * 0.50
    let width = rect.width * 0.13

    for index in 0..<11 {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: CGFloat(index) * 360 / 11)
        transform.concat()

        let ray = NSRect(
            x: -width / 2,
            y: rect.height * 0.11,
            width: width,
            height: length
        )
        NSBezierPath(roundedRect: ray, xRadius: width / 2, yRadius: width / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSBezierPath(ovalIn: NSRect(
        x: center.x - rect.width * 0.17,
        y: center.y - rect.height * 0.17,
        width: rect.width * 0.34,
        height: rect.height * 0.34
    )).fill()
}

@MainActor
final class DesktopWidgetController: ObservableObject {
    static let shared = DesktopWidgetController()

    private var window: NSPanel?
    private weak var model: QuotaRadarAppModel?

    func bind(_ model: QuotaRadarAppModel) {
        self.model = model
        if window == nil {
            createWindow(model: model)
        }
    }

    func show() {
        guard let model else { return }
        if window == nil {
            createWindow(model: model)
        }
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func createWindow(model: QuotaRadarAppModel) {
        let size = NSSize(width: 190, height: 382)
        let origin = loadOrigin() ?? defaultOrigin(size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Usage Radar Desktop Widget"
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: DesktopQuotaWidgetView(model: model))
        panel.delegate = DesktopWidgetWindowDelegate.shared

        DesktopWidgetWindowDelegate.shared.onMove = { [weak panel] in
            guard let origin = panel?.frame.origin else { return }
            UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: "desktopWidgetOrigin")
        }

        window = panel
    }

    private func defaultOrigin(size: NSSize = NSSize(width: 190, height: 382)) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: 252, y: screenFrame.maxY - size.height - 24)
    }

    private func loadOrigin() -> NSPoint? {
        guard let value = UserDefaults.standard.dictionary(forKey: "desktopWidgetOrigin"),
              let x = value["x"] as? CGFloat,
              let y = value["y"] as? CGFloat else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }
}

final class DesktopWidgetWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = DesktopWidgetWindowDelegate()
    var onMove: (() -> Void)?

    func windowDidMove(_ notification: Notification) {
        onMove?()
    }
}

struct DesktopQuotaWidgetView: View {
    @ObservedObject var model: QuotaRadarAppModel

    private var providers: [ProviderUsage] {
        let snapshotProviders = model.snapshot?.providers ?? []
        let codex = snapshotProviders.first { $0.id == "codex" } ?? .sampleCodex
        let claude = snapshotProviders.first { $0.id == "claude" } ?? .sampleClaude
        return [codex, claude]
    }

    var body: some View {
        VStack(spacing: 18) {
            ForEach(providers) { provider in
                AppProviderGlassCard(provider: provider) {
                    model.refresh()
                }
                .frame(width: 172, height: 172)
            }
        }
        .padding(9)
        .frame(width: 190, height: 382)
    }
}

struct AppProviderGlassCard: View {
    let provider: ProviderUsage
    let onRefresh: () -> Void

    private var primaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 300 } ?? provider.windows.first
    }

    private var secondaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 10_080 } ?? provider.windows.dropFirst().first
    }

    private var accent: AppAccent {
        AppAccent(provider.accent)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.08))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    LinearGradient(
                        colors: [
                            accent.primary.opacity(0.18),
                            accent.secondary.opacity(0.10),
                            .white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ProviderLogoMark(providerID: provider.id, opacity: 0.56)
                        .frame(width: 16, height: 16)
                    Text(provider.name)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .center, spacing: 10) {
                    AppRing(primary: primaryWindow, secondary: secondaryWindow, accent: accent)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 6) {
                        AppMetric(label: "5h", window: primaryWindow, color: .white.opacity(0.62))
                        AppMetric(label: "7d", window: secondaryWindow, color: .white.opacity(0.50))
                    }
                }

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(footerText(at: context.date))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }
            .padding(13)
        }
    }

    private func footerText(at date: Date) -> String {
        if let countdown = resetCountdownText(primaryWindow?.resetAt, now: date) {
            return "5h | \(countdown) 后重置"
        }
        if provider.status == .ready, primaryWindow?.resetAt != nil {
            return "已到 5h 重置点，点刷新"
        }
        return provider.status == .ready ? "剩余额度" : "打开 App 刷新"
    }
}

struct AppRing: View {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let accent: AppAccent
    private let ringColor = Color.white.opacity(0.32)
    private let trackColor = Color.white.opacity(0.07)

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 12)
                .frame(width: 82, height: 82)
            AppRingArc(progress: appRemainingProgress(primary), color: ringColor, lineWidth: 12, diameter: 82)
                .rotationEffect(.degrees(130))

            Circle()
                .stroke(trackColor, lineWidth: 9)
                .frame(width: 56, height: 56)
            AppRingArc(progress: appRemainingProgress(secondary), color: ringColor, lineWidth: 9, diameter: 56)
                .rotationEffect(.degrees(200))

            VStack(spacing: 0) {
                Text(appRemainingText(primary))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .minimumScaleFactor(0.70)
                Text("剩余")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }
}

struct AppRingArc: View {
    let progress: Double?
    let color: Color
    let lineWidth: CGFloat
    let diameter: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0, to: CGFloat(progress ?? 0.08))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .opacity(progress == nil ? 0.24 : 1)
            .shadow(color: color.opacity(0.18), radius: 4)
    }
}

struct AppMetric: View {
    let label: String
    let window: UsageWindow?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(appRemainingText(window))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
    }
}

struct ProviderLogoMark: View {
    let providerID: String
    let opacity: Double

    var body: some View {
        Group {
            if providerID == "claude" {
                ClaudeBurstLogo()
            } else {
                CodexCloudLogo()
            }
        }
        .foregroundStyle(.white.opacity(opacity))
    }
}

struct MenuBarStatusLabel: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        let providers = snapshot?.providers ?? [.sampleCodex, .sampleClaude]
        let codex = menuBarRemainingPair(providers.first { $0.id == "codex" })
        let claude = menuBarRemainingPair(providers.first { $0.id == "claude" })

        HStack(spacing: 4) {
            ProviderLogoMark(providerID: "codex", opacity: 0.92)
                .frame(width: 12, height: 12)
            Text("\(codex.primary)/\(codex.secondary)")

            ProviderLogoMark(providerID: "claude", opacity: 0.92)
                .frame(width: 12, height: 12)
                .padding(.leading, 2)
            Text("\(claude.primary)/\(claude.secondary)")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.92))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(menuBarCompactLabel(snapshot: snapshot, choice: .both))
    }
}

struct ClaudeBurstLogo: View {
    private let rays: [(angle: Double, length: CGFloat, width: CGFloat)] = [
        (-92, 0.58, 0.14),
        (-55, 0.54, 0.15),
        (-20, 0.52, 0.14),
        (15, 0.50, 0.13),
        (52, 0.54, 0.14),
        (88, 0.56, 0.14),
        (125, 0.52, 0.13),
        (162, 0.54, 0.14),
        (202, 0.50, 0.13),
        (238, 0.54, 0.14),
        (275, 0.56, 0.13)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(Array(rays.enumerated()), id: \.offset) { _, ray in
                    Capsule()
                        .frame(width: size * ray.width, height: size * ray.length)
                        .offset(y: -size * 0.24)
                        .rotationEffect(.degrees(ray.angle))
                }
                Circle()
                    .frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct CodexCloudLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .frame(width: size * 0.47, height: size * 0.47)
                    .offset(x: -size * 0.23, y: -size * 0.06)
                Circle()
                    .frame(width: size * 0.50, height: size * 0.50)
                    .offset(x: -size * 0.05, y: -size * 0.23)
                Circle()
                    .frame(width: size * 0.45, height: size * 0.45)
                    .offset(x: size * 0.20, y: -size * 0.16)
                Circle()
                    .frame(width: size * 0.46, height: size * 0.46)
                    .offset(x: size * 0.25, y: size * 0.09)
                Circle()
                    .frame(width: size * 0.49, height: size * 0.49)
                    .offset(x: size * 0.04, y: size * 0.24)
                Circle()
                    .frame(width: size * 0.45, height: size * 0.45)
                    .offset(x: -size * 0.22, y: size * 0.16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct AppAccent {
    let primary: Color
    let secondary: Color
    let backgroundStart: Color
    let backgroundEnd: Color

    init(_ accent: Accent) {
        switch accent {
        case .blue:
            primary = Color(red: 0.34, green: 0.65, blue: 1.0)
            secondary = Color(red: 0.68, green: 0.46, blue: 0.98)
            backgroundStart = Color(red: 0.07, green: 0.09, blue: 0.16)
            backgroundEnd = Color(red: 0.07, green: 0.12, blue: 0.23)
        case .teal:
            primary = Color(red: 0.17, green: 0.78, blue: 0.66)
            secondary = Color(red: 1.0, green: 0.47, blue: 0.18)
            backgroundStart = Color(red: 0.05, green: 0.13, blue: 0.12)
            backgroundEnd = Color(red: 0.08, green: 0.19, blue: 0.16)
        case .purple:
            primary = Color(red: 0.65, green: 0.48, blue: 1.0)
            secondary = Color(red: 0.33, green: 0.71, blue: 1.0)
            backgroundStart = Color(red: 0.13, green: 0.08, blue: 0.19)
            backgroundEnd = Color(red: 0.08, green: 0.10, blue: 0.17)
        case .orange:
            primary = Color(red: 1.0, green: 0.55, blue: 0.22)
            secondary = Color(red: 0.25, green: 0.79, blue: 0.67)
            backgroundStart = Color(red: 0.18, green: 0.11, blue: 0.07)
            backgroundEnd = Color(red: 0.08, green: 0.11, blue: 0.10)
        }
    }
}

private func appRemainingProgress(_ window: UsageWindow?) -> Double? {
    guard let used = window?.usedPercent else { return nil }
    return max(0, min((100 - used) / 100, 1))
}

private func appRemainingText(_ window: UsageWindow?) -> String {
    guard let window else { return "--" }
    if let used = window.usedPercent {
        return "\(max(0, Int((100 - used).rounded())))%"
    }
    if let tokens = window.tokenCount {
        return compactAppNumber(tokens)
    }
    return "--"
}

private func menuBarCompactLabel(snapshot: UsageSnapshot?, choice: MenuBarProviderChoice) -> String {
    let providers = snapshot?.providers ?? [.sampleCodex, .sampleClaude]
    let parts = choice.providerIDs.map { id in
        let name = id == "claude" ? "Cl" : "C"
        let pair = menuBarRemainingPair(providers.first { $0.id == id })
        return "\(name) \(pair.primary)/\(pair.secondary)"
    }
    return parts.joined(separator: " · ")
}

private func menuBarRemainingPair(_ provider: ProviderUsage?) -> (primary: String, secondary: String) {
    guard let provider else { return ("--", "--") }
    let primary = provider.windows.first { $0.windowMinutes == 300 } ?? provider.windows.first
    let secondary = provider.windows.first { $0.windowMinutes == 10_080 } ?? provider.windows.dropFirst().first
    return (appRemainingText(primary), appRemainingText(secondary))
}

private func menuWindowLine(_ window: UsageWindow) -> String {
    var line = "\(window.label)  剩余 \(appRemainingText(window))"
    if window.windowMinutes == 300, let countdown = resetCountdownText(window.resetAt, now: Date()) {
        line += " · \(countdown) 后重置"
    }
    return line
}

private func resetCountdownText(_ resetAt: Date?, now: Date) -> String? {
    guard let resetAt else { return nil }
    let remaining = resetAt.timeIntervalSince(now)
    guard remaining > 0 else { return nil }
    let totalMinutes = Int((remaining / 60).rounded(.up))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

private func compactAppNumber(_ value: Int) -> String {
    let number = Double(value)
    if number >= 1_000_000_000 {
        return String(format: "%.1fB", number / 1_000_000_000)
    }
    if number >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if number >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return "\(value)"
}
