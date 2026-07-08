import AppIntents
import SwiftUI
import WidgetKit

enum RadarProviderChoice: String, AppEnum {
    case codex
    case claude

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "服务")
    static var caseDisplayRepresentations: [RadarProviderChoice: DisplayRepresentation] = [
        .codex: "Codex",
        .claude: "Claude"
    ]

    var providerID: String {
        rawValue
    }
}

struct RadarWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Usage Radar 设置"
    static var description = IntentDescription("选择小组件显示 Codex 还是 Claude。")

    @Parameter(title: "服务", default: .codex)
    var provider: RadarProviderChoice
}

struct RefreshQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新额度"
    static var description = IntentDescription("重新读取本机 Codex / Claude 用量并刷新小组件。")

    func perform() async throws -> some IntentResult {
        let snapshot = UsageSnapshot(
            generatedAt: Date(),
            providers: [
                CodexUsageReader(maxFiles: 20).read(),
                ClaudeUsageReader(maxFiles: 0).read()
            ]
        )
        try SnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RadarEntry: TimelineEntry {
    let date: Date
    let providerChoice: RadarProviderChoice
    let provider: ProviderUsage?
    let providers: [ProviderUsage]
}

struct RadarTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RadarEntry {
        RadarEntry(date: .now, providerChoice: .codex, provider: .sampleCodex, providers: [.sampleCodex, .sampleClaude])
    }

    func snapshot(for configuration: RadarWidgetIntent, in context: Context) async -> RadarEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: RadarWidgetIntent, in context: Context) async -> Timeline<RadarEntry> {
        let entry = entry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: RadarWidgetIntent) -> RadarEntry {
        let snapshot = SnapshotStore.read()
        let providers = snapshot?.providers ?? [.sampleCodex, .sampleClaude]
        let provider = providers.first { $0.id == configuration.provider.providerID }
        return RadarEntry(date: .now, providerChoice: configuration.provider, provider: provider, providers: providers)
    }
}

struct QuotaRadarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RadarEntry

    private var provider: ProviderUsage {
        entry.provider ?? (entry.providerChoice == .codex ? .sampleCodex : .sampleClaude)
    }

    private var primaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 300 } ?? provider.windows.first
    }

    private var secondaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 10_080 } ?? provider.windows.dropFirst().first
    }

    private var accent: WidgetAccent {
        WidgetAccent(provider.accent)
    }

    var body: some View {
        if family == .systemLarge {
            WidgetStackedGlassView(providers: stackedProviders)
                .containerBackground(.clear, for: .widget)
        } else {
            singleProviderBody
                .containerBackground(.clear, for: .widget)
        }
    }

    private var stackedProviders: [ProviderUsage] {
        let codex = entry.providers.first { $0.id == "codex" } ?? .sampleCodex
        let claude = entry.providers.first { $0.id == "claude" } ?? .sampleClaude
        return [codex, claude]
    }

    private var singleProviderBody: some View {
        ZStack {
            LinearGradient(
                colors: [accent.backgroundStart, accent.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ProviderLogoMark(providerID: provider.id, opacity: 0.78)
                        .frame(width: 16, height: 16)
                    Text(provider.name)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(intent: RefreshQuotaIntent()) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                            Text("刷新")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 10) {
                    WidgetRing(primary: primaryWindow, secondary: secondaryWindow, accent: accent)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 6) {
                        WidgetMetric(label: "5h", window: primaryWindow, color: accent.primary)
                        WidgetMetric(label: "7d", window: secondaryWindow, color: accent.secondary)
                    }
                }

                Spacer(minLength: 0)

                Text(footerText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
            .padding(13)
        }
    }

    private var footerText: String {
        if provider.status == .ready {
            return "剩余额度"
        }
        if provider.id == "claude" {
            return "等待 Claude Code 百分比"
        }
        return "打开 App 刷新"
    }
}

struct WidgetStackedGlassView: View {
    let providers: [ProviderUsage]

    var body: some View {
        VStack(spacing: 18) {
            ForEach(providers) { provider in
                WidgetProviderGlassCard(provider: provider)
            }
        }
        .padding(11)
    }
}

struct WidgetProviderGlassCard: View {
    let provider: ProviderUsage

    private var primaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 300 } ?? provider.windows.first
    }

    private var secondaryWindow: UsageWindow? {
        provider.windows.first { $0.windowMinutes == 10_080 } ?? provider.windows.dropFirst().first
    }

    private var accent: WidgetAccent {
        WidgetAccent(provider.accent)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ProviderLogoMark(providerID: provider.id, opacity: 0.56)
                        .frame(width: 16, height: 16)
                    Text(provider.name)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Button(intent: RefreshQuotaIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .center, spacing: 10) {
                    WidgetRing(primary: primaryWindow, secondary: secondaryWindow, accent: accent)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 6) {
                        WidgetMetric(label: "5h", window: primaryWindow, color: .white.opacity(0.62))
                        WidgetMetric(label: "7d", window: secondaryWindow, color: .white.opacity(0.50))
                    }
                }

                Text(provider.status == .ready ? "剩余额度" : "打开 App 刷新")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            .padding(13)
        }
    }
}

struct WidgetRing: View {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let accent: WidgetAccent
    private let ringColor = Color.white.opacity(0.32)
    private let trackColor = Color.white.opacity(0.07)

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 12)
                .frame(width: 82, height: 82)
            RingArc(progress: remainingProgress(primary), color: ringColor, lineWidth: 12, diameter: 82)
                .rotationEffect(.degrees(130))

            Circle()
                .stroke(trackColor, lineWidth: 9)
                .frame(width: 56, height: 56)
            RingArc(progress: remainingProgress(secondary), color: ringColor, lineWidth: 9, diameter: 56)
                .rotationEffect(.degrees(200))

            VStack(spacing: 0) {
                Text(remainingText(primary))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .minimumScaleFactor(0.7)
                Text("剩余")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }
}

struct RingArc: View {
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

struct WidgetMetric: View {
    let label: String
    let window: UsageWindow?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(remainingText(window))
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

@main
struct QuotaRadarWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaRadarWidget()
    }
}

struct QuotaRadarWidget: Widget {
    let kind = "QuotaRadarWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RadarWidgetIntent.self, provider: RadarTimelineProvider()) { entry in
            QuotaRadarWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Radar")
        .description("查看 Codex 或 Claude 的剩余额度。")
        .supportedFamilies([.systemSmall, .systemLarge])
    }
}

struct WidgetAccent {
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

private func remainingProgress(_ window: UsageWindow?) -> Double? {
    guard let used = window?.usedPercent else { return nil }
    return max(0, min((100 - used) / 100, 1))
}

private func remainingText(_ window: UsageWindow?) -> String {
    guard let window else { return "--" }
    if let used = window.usedPercent {
        return "\(max(0, Int((100 - used).rounded())))%"
    }
    if let tokens = window.tokenCount {
        return compactWidgetNumber(tokens)
    }
    return "--"
}

func compactWidgetNumber(_ value: Int) -> String {
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
