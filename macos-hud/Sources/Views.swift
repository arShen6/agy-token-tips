import SwiftUI
import AppKit

enum IslandPlacement: String {
    case bottomRight  // Default: Sleek obsidian micro-island at bottom-right (draggable anywhere)
    case topNotch     // Optional: Hardware-fused top MacBook notch island
}

enum NotchState: Equatable {
    case collapsed   // Ultra-minimal: 2 crisp metrics only (Context % · tok/s)
    case expanded    // Full zero-scroll 652pt obsidian command center + official quota
}

struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let hasPhysicalNotch: Bool
    let notchWidth: CGFloat    // e.g. 185pt on 14" MBP, 0 on non-notch display
    let notchHeight: CGFloat   // e.g. 32pt on 14" MBP, 28pt on non-notch display

    static let fallback = NotchGeometry(
        screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 949),
        hasPhysicalNotch: true,
        notchWidth: 185,
        notchHeight: 32
    )

    static func detect(preferNotch: Bool = false) -> NotchGeometry {
        let screens = NSScreen.screens
        let target: NSScreen?
        if preferNotch {
            target = screens.first(where: { $0.safeAreaInsets.top >= 20 }) ?? NSScreen.main ?? screens.first
        } else {
            target = NSScreen.main ?? screens.first(where: { $0.safeAreaInsets.top >= 20 }) ?? screens.first
        }
        guard let screen = target else { return .fallback }

        let safeTop = screen.safeAreaInsets.top
        if safeTop >= 20,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let gap = max(140, rightArea.minX - leftArea.maxX)
            return NotchGeometry(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasPhysicalNotch: true,
                notchWidth: gap,
                notchHeight: safeTop
            )
        } else {
            let barHeight = max(26, min(32, screen.frame.maxY - screen.visibleFrame.maxY))
            return NotchGeometry(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasPhysicalNotch: false,
                notchWidth: 0,
                notchHeight: barHeight > 16 ? barHeight : 28
            )
        }
    }

    var earWidth: CGFloat { hasPhysicalNotch ? 66 : 74 }
    var topFlareCollapsed: CGFloat { 8 }
    var topFlareExpanded: CGFloat { 14 }

    var notchCollapsedWidth: CGFloat {
        if hasPhysicalNotch {
            return notchWidth + earWidth * 2 + topFlareCollapsed * 2
        } else {
            return 168 + topFlareCollapsed * 2
        }
    }

    var floatingCollapsedWidth: CGFloat { 146 }
    var floatingCollapsedHeight: CGFloat { 32 }
    var expandedWidth: CGFloat { 652 }
}

/// Authentic Apple Dynamic Notch silhouette with smooth outward concave top shoulders
/// and continuous rounded bottom corners.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topCornerRadius, rect.height / 2, rect.width / 6)
        let br = min(bottomCornerRadius, rect.height - tr, rect.width / 2 - tr)
        var p = Path()

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var snapshot: HUDSnapshot = .initial
    @Published var quotaSnapshot: QuotaSnapshot? = nil
    @Published var quotaState: QuotaFetchState = .idle
    @Published var notchState: NotchState = .collapsed
    @Published var geometry: NotchGeometry = NotchGeometry.detect()

    @Published var placement: IslandPlacement {
        didSet {
            UserDefaults.standard.set(placement.rawValue, forKey: "tl.placement")
            onPlacementChanged?()
        }
    }
    @Published var isChinese: Bool {
        didSet { UserDefaults.standard.set(isChinese, forKey: "tl.zh") }
    }
    @Published var hoverDirectExpand: Bool {
        didSet { UserDefaults.standard.set(hoverDirectExpand, forKey: "tl.hoverDirectExpandV2") }
    }
    @Published var isHoveringCollapsed = false
    @Published var onlyWhenAgyActive: Bool {
        didSet { UserDefaults.standard.set(onlyWhenAgyActive, forKey: "tl.onlyAgyV2"); onVisibilityPrefChanged?() }
    }
    @Published var showNotchIsland: Bool = true {
        didSet { onVisibilityPrefChanged?() }
    }
    @Published var pinnedConversationId: String? = nil {
        didSet { refreshNow() }
    }
    @Published var showSessionPicker = false
    /// When floating in lower half of screen, hover tray blooms ABOVE the micro-pill.
    @Published var floatingExpandsUpward = true

    var onPlacementChanged: (() -> Void)?
    var onVisibilityPrefChanged: (() -> Void)?
    var onSnapshotUpdated: (() -> Void)?
    var onLayoutNeeded: (() -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onQuit: (() -> Void)?

    nonisolated private let store = AntigravityDataStore()
    nonisolated private let quotaService = QuotaService()
    private let ioQueue = DispatchQueue(label: "io.tokenlens.reader", qos: .utility)
    private var timer: Timer?
    private var quotaTimer: Timer?
    private var isFetching = false
    private var lastModelFamily: QuotaModelFamily = .unknown

    init() {
        let savedPlace = UserDefaults.standard.string(forKey: "tl.placement") ?? IslandPlacement.bottomRight.rawValue
        self.placement = IslandPlacement(rawValue: savedPlace) ?? .bottomRight

        if UserDefaults.standard.object(forKey: "tl.zh") != nil {
            self.isChinese = UserDefaults.standard.bool(forKey: "tl.zh")
        } else {
            self.isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? true
        }
        if UserDefaults.standard.object(forKey: "tl.hoverDirectExpandV2") != nil {
            self.hoverDirectExpand = UserDefaults.standard.bool(forKey: "tl.hoverDirectExpandV2")
        } else {
            self.hoverDirectExpand = true
        }
        if UserDefaults.standard.object(forKey: "tl.onlyAgyV2") != nil {
            self.onlyWhenAgyActive = UserDefaults.standard.bool(forKey: "tl.onlyAgyV2")
        } else {
            self.onlyWhenAgyActive = true
        }
        if let cached = quotaService.loadCachedSnapshot() {
            self.quotaSnapshot = cached
            self.quotaState = .ready
        }
    }

    var activeModelFamily: QuotaModelFamily {
        QuotaModelFamily.infer(from: snapshot.metrics.model)
    }

    var activeQuotaGroup: QuotaGroup? {
        quotaSnapshot?.group(for: activeModelFamily)
    }

    func startPolling() {
        refreshNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshQuota(force: false, maxAge: 180)
        }

        quotaTimer?.invalidate()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.showNotchIsland || self.notchState == .expanded else { return }
                self.refreshQuota(force: false, maxAge: 290)
            }
        }
    }

    func refreshNow() {
        guard !isFetching else { return }
        isFetching = true
        let pin = pinnedConversationId
        let dataStore = self.store
        ioQueue.async { [weak self] in
            let next = dataStore.fetchSnapshot(pinnedId: pin)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let layoutChanged = self.snapshot.conversationId != next.conversationId
                    || self.snapshot.subagents.count != next.subagents.count
                    || self.snapshot.metrics.hasData != next.metrics.hasData
                self.snapshot = next
                self.isFetching = false
                self.onSnapshotUpdated?()

                let nextFamily = QuotaModelFamily.infer(from: next.metrics.model)
                if nextFamily != .unknown && nextFamily != self.lastModelFamily {
                    self.lastModelFamily = nextFamily
                    self.refreshQuota(force: false, maxAge: 60)
                }

                if layoutChanged && self.notchState == .expanded {
                    self.onLayoutNeeded?()
                }
            }
        }
    }

    func refreshQuota(force: Bool, maxAge: TimeInterval = 90) {
        let current = self.quotaSnapshot
        quotaService.fetchIfAllowed(
            force: force,
            currentSnapshot: current,
            maxAge: maxAge,
            onStateChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.quotaState = state
                }
            },
            onResult: { [weak self] snap, state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let snap {
                        self.quotaSnapshot = snap
                    }
                    self.quotaState = state
                    if self.notchState == .expanded {
                        self.onLayoutNeeded?()
                    }
                }
            }
        )
    }
}

// MARK: - Formatting & Semantic Colors

func fmtCompact(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1e3) }
    return "\(n)"
}

func fmtInt(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func fmtRate(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

func fmtRateShort(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    return v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

func fmtSec(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    return String(format: "%.1fs", v)
}

func fmtSecDetail(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    return v >= 10 ? String(format: "%.1fs", v) : String(format: "%.2fs", v)
}

func fmtRelTime(_ ms: Double, zh: Bool) -> String {
    guard ms > 0 else { return "" }
    let delta = max(0, Date().timeIntervalSince1970 - ms / 1000.0)
    if delta < 60 { return zh ? "刚刚" : "now" }
    if delta < 3600 { return zh ? "\(Int(delta / 60))分前" : "\(Int(delta / 60))m" }
    if delta < 86400 { return zh ? "\(Int(delta / 3600))小时前" : "\(Int(delta / 3600))h" }
    return zh ? "\(Int(delta / 86400))天前" : "\(Int(delta / 86400))d"
}

func fmtQuotaAge(_ date: Date, at now: Date, zh: Bool) -> String {
    let delta = max(0, now.timeIntervalSince(date))
    if delta < 30 { return zh ? "刚刚更新" : "just now" }
    if delta < 60 { return zh ? "\(Int(delta))秒前" : "\(Int(delta))s ago" }
    if delta < 3600 { return zh ? "\(Int(delta / 60))分钟前" : "\(Int(delta / 60))m ago" }
    return zh ? "\(Int(delta / 3600))小时前" : "\(Int(delta / 3600))h ago"
}

func fmtQuotaPercent(_ fraction: Double?) -> String {
    guard let fraction, fraction.isFinite else { return "—" }
    let pct = min(100.0, max(0.0, fraction * 100.0))
    if pct > 0 && pct < 10.0 {
        return String(format: "%.1f%%", pct)
    }
    return "\(Int(pct.rounded()))%"
}

func fmtCountdownDetail(_ reset: Date?, isWeekly: Bool, at now: Date, zh: Bool) -> String {
    guard let reset else { return "—" }
    let secs = Int(reset.timeIntervalSince(now))
    if secs <= 0 { return zh ? "待确认" : "reset" }
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    let rem = secs % 60
    if isWeekly || days > 0 {
        if days > 0 { return zh ? "\(days)天\(hours)时" : "\(days)d \(hours)h" }
        return zh ? "\(hours)时\(mins)分" : "\(hours)h \(mins)m"
    }
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, mins, rem)
    }
    return String(format: "%02d:%02d", mins, rem)
}

func colorFromHex(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255.0,
        green: Double((hex >> 8) & 0xFF) / 255.0,
        blue: Double(hex & 0xFF) / 255.0
    )
}

func levelColor(_ level: ContextLevel) -> Color {
    switch level {
    case .normal: return Color(red: 0.22, green: 0.74, blue: 0.97)
    case .warning: return Color(red: 0.96, green: 0.62, blue: 0.14)
    case .critical: return Color(red: 0.97, green: 0.44, blue: 0.44)
    }
}

func quotaColor(fraction: Double?) -> Color {
    guard let f = fraction else { return Color.white.opacity(0.45) }
    if f <= 0.10 { return Color(red: 0.97, green: 0.44, blue: 0.44) }
    if f <= 0.20 { return Color(red: 0.96, green: 0.62, blue: 0.14) }
    return Color(red: 0.20, green: 0.83, blue: 0.60)
}

func shortModel(_ name: String) -> String {
    name
        .replacingOccurrences(of: "Gemini ", with: "G")
        .replacingOccurrences(of: "Claude ", with: "C ")
        .replacingOccurrences(of: " (XHigh)", with: " XH")
        .replacingOccurrences(of: " (High)", with: " H")
        .replacingOccurrences(of: " (Medium)", with: " M")
        .replacingOccurrences(of: " (Low)", with: " L")
}

// MARK: - Subtle Breathing Pulse

struct BreathingDot: View {
    let active: Bool
    var size: CGFloat = 5.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color(red: 0.22, green: 0.74, blue: 0.97))
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.85), radius: 3)
            .opacity(reduceMotion ? 1.0 : (pulse ? 0.30 : 1.0))
            .onAppear {
                guard active && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: active) { _, next in
                if next && !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    pulse = false
                }
            }
    }
}

// MARK: - Root Obsidian Island View (Supports BOTH Bottom-Right Floating Island & Top Notch!)

struct DynamicNotchRootView: View {
    @ObservedObject var vm: HUDViewModel

    private var zh: Bool { vm.isChinese }
    private var geo: NotchGeometry { vm.geometry }
    private var isNotchMode: Bool { vm.placement == .topNotch }

    private var currentWidth: CGFloat {
        switch vm.notchState {
        case .collapsed:
            return isNotchMode ? geo.notchCollapsedWidth : geo.floatingCollapsedWidth
        case .expanded:
            return geo.expandedWidth
        }
    }

    private var topFlare: CGFloat {
        guard isNotchMode else { return 0 }
        return vm.notchState == .collapsed ? geo.topFlareCollapsed : geo.topFlareExpanded
    }

    private var bottomRadius: CGFloat {
        switch vm.notchState {
        case .collapsed: return isNotchMode ? 11 : 16
        case .expanded: return 18
        }
    }

    private var syncBadgeText: String {
        switch vm.snapshot.syncSource {
        case "window": return zh ? "窗口同步" : "Synced"
        case "pinned": return zh ? "已锁定" : "Pinned"
        default: return zh ? "自动跟随" : "Auto"
        }
    }

    var body: some View {
        Group {
            if isNotchMode {
                topNotchContainer
            } else {
                floatingObsidianContainer
            }
        }
        .preferredColorScheme(.dark)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: Mode 1 (Default) — Bottom-Right Sleek Obsidian Island

    private var floatingObsidianContainer: some View {
        let radius: CGFloat = bottomRadius
        let cardShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hoverLit = (vm.notchState == .collapsed && vm.isHoveringCollapsed)

        return VStack(spacing: 0) {
            if vm.notchState == .collapsed {
                floatingMicroPillContent
                    .frame(height: geo.floatingCollapsedHeight)
            } else {
                floatingExpandedHeader
                expandedCommandCenter(horizontalInset: 14)
            }
        }
        .frame(width: currentWidth, alignment: .center)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.065, green: 0.072, blue: 0.092),
                    Color(red: 0.032, green: 0.036, blue: 0.048)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(cardShape)
        )
        .overlay(
            cardShape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(hoverLit ? 0.32 : (vm.notchState == .collapsed ? 0.16 : 0.18)),
                        Color.white.opacity(hoverLit ? 0.16 : 0.07)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
        .animation(.easeOut(duration: 0.13), value: hoverLit)
    }

    /// Ultra-clean 146×32pt Obsidian Micro-Island: ONLY Ring + Context % · Dot · Speed t/s
    private var floatingMicroPillContent: some View {
        let s = vm.snapshot
        let m = s.metrics
        let pct = min(1.0, max(0.0, (m.ctxPercent ?? 0) / 100.0))
        let ctxColor = levelColor(m.ctxLevel)
        let pctInt = m.ctxPercent != nil ? Int(m.ctxPercent!.rounded()) : nil

        return HStack(spacing: 8) {
            HStack(spacing: 5.5) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 2.0)
                        .frame(width: 14, height: 14)
                    Circle()
                        .trim(from: 0, to: max(pct, m.hasData ? 0.04 : 0))
                        .stroke(ctxColor, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 14, height: 14)
                        .shadow(color: s.isRunning ? ctxColor.opacity(0.9) : .clear, radius: 3)
                }
                Text(pctInt != nil ? "\(pctInt!)%" : "—")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(m.ctxLevel == .critical ? Color(red: 0.97, green: 0.44, blue: 0.44) : Color.white.opacity(0.94))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            if s.isRunning {
                BreathingDot(active: true, size: 4.5)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 3.5, height: 3.5)
            }

            if m.hasData {
                HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                    Text(fmtRateShort(m.speed))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .monospacedDigit()
                    Text("t/s")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.46))
                }
                .lineLimit(1)
                .fixedSize()
            } else {
                Text(zh ? "空闲" : "Idle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
    }

    private var floatingExpandedHeader: some View {
        let s = vm.snapshot
        let m = s.metrics
        return HStack(spacing: 7) {
            if s.isRunning {
                BreathingDot(active: true, size: 6.5)
            } else {
                Circle()
                    .fill(Color(red: 0.20, green: 0.83, blue: 0.60))
                    .frame(width: 6.5, height: 6.5)
            }
            Text("Token Lens")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
            Text(syncBadgeText)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.10))
                .foregroundStyle(s.syncSource == "window" ? Color(red: 0.20, green: 0.83, blue: 0.60) : Color(red: 0.22, green: 0.74, blue: 0.97))
                .clipShape(Capsule())
            if m.hasData {
                Text(m.model)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            obsidianMiniButton(zh ? "切顶刘海" : "Notch") {
                vm.placement = .topNotch
            }
            obsidianMiniButton(zh ? "EN" : "中文") {
                vm.isChinese.toggle()
            }
            obsidianMiniButton("↻") {
                vm.refreshNow()
                vm.refreshQuota(force: true)
            }
            obsidianMiniButton("✕") {
                vm.onRequestCollapse?()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 7)
    }

    // MARK: Mode 2 (Optional) — Hardware-Fused Top MacBook Notch Island

    private var topNotchContainer: some View {
        let shape = NotchShape(topCornerRadius: topFlare, bottomCornerRadius: bottomRadius)
        let hoverLit = (vm.notchState == .collapsed && vm.isHoveringCollapsed)

        return VStack(spacing: 0) {
            topNotchStrip
                .frame(height: geo.notchHeight)

            if vm.notchState == .expanded {
                expandedCommandCenter(horizontalInset: topFlare + 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: currentWidth, alignment: .top)
        .background(
            LinearGradient(
                colors: vm.notchState == .collapsed
                    ? [Color.black, Color.black]
                    : [Color.black, Color(red: 0.04, green: 0.045, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(shape)
        )
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(vm.notchState == .collapsed ? (hoverLit ? 0.14 : 0.0) : 0.06),
                        Color.white.opacity(vm.notchState == .collapsed ? (hoverLit ? 0.22 : 0.0) : 0.13)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: (vm.notchState == .collapsed && !hoverLit) ? 0 : 0.75
            )
        )
        .animation(.easeOut(duration: 0.13), value: hoverLit)
    }

    private var topNotchStrip: some View {
        let s = vm.snapshot
        let m = s.metrics
        let pct = min(1.0, max(0.0, (m.ctxPercent ?? 0) / 100.0))
        let ctxColor = levelColor(m.ctxLevel)
        let pctInt = m.ctxPercent != nil ? Int(m.ctxPercent!.rounded()) : nil

        return HStack(spacing: 0) {
            if vm.notchState == .expanded {
                HStack(spacing: 7) {
                    if s.isRunning {
                        BreathingDot(active: true, size: 6.5)
                    } else {
                        Circle()
                            .fill(Color(red: 0.20, green: 0.83, blue: 0.60))
                            .frame(width: 6.5, height: 6.5)
                    }
                    Text("Token Lens")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                    Text(syncBadgeText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.10))
                        .foregroundStyle(s.syncSource == "window" ? Color(red: 0.20, green: 0.83, blue: 0.60) : Color(red: 0.22, green: 0.74, blue: 0.97))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                }
                .padding(.leading, topFlare + 14)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity)

                if geo.hasPhysicalNotch {
                    Color.clear.frame(width: geo.notchWidth)
                }

                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    obsidianMiniButton(zh ? "切 AGY 右下" : "AGY Corner") {
                        vm.placement = .bottomRight
                    }
                    obsidianMiniButton(zh ? "EN" : "中文") {
                        vm.isChinese.toggle()
                    }
                    obsidianMiniButton("↻") {
                        vm.refreshNow()
                        vm.refreshQuota(force: true)
                    }
                    obsidianMiniButton("✕") {
                        vm.onRequestCollapse?()
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, topFlare + 14)
                .frame(maxWidth: .infinity)

            } else if geo.hasPhysicalNotch {
                HStack(spacing: 5.5) {
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.16), lineWidth: 2.0)
                            .frame(width: 14, height: 14)
                        Circle()
                            .trim(from: 0, to: max(pct, m.hasData ? 0.04 : 0))
                            .stroke(ctxColor, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 14, height: 14)
                            .shadow(color: s.isRunning ? ctxColor.opacity(0.9) : .clear, radius: 3)
                    }
                    Text(pctInt != nil ? "\(pctInt!)%" : "—")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(m.ctxLevel == .critical ? Color(red: 0.97, green: 0.44, blue: 0.44) : Color.white.opacity(0.92))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.leading, topFlare + 6)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity)

                Color.clear.frame(width: geo.notchWidth)

                HStack(spacing: 4.5) {
                    if m.hasData {
                        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                            Text(fmtRateShort(m.speed))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.90))
                                .monospacedDigit()
                            Text("t/s")
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        .lineLimit(1)
                        .fixedSize()
                    } else {
                        Text(zh ? "空闲" : "Idle")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if s.isRunning {
                        BreathingDot(active: true, size: 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, topFlare + 6)
                .frame(maxWidth: .infinity)

            } else {
                floatingMicroPillContent
                    .padding(.horizontal, topFlare)
            }
        }
    }

    // MARK: Shared Full Zero-Scroll Obsidian Command Center

    private func expandedCommandCenter(horizontalInset: CGFloat) -> some View {
        let s = vm.snapshot
        let m = s.metrics

        return TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date

            VStack(alignment: .leading, spacing: 9) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)

                // 1. Inline Session Switcher
                HStack(spacing: 8) {
                    Button {
                        vm.showSessionPicker.toggle()
                        vm.onLayoutNeeded?()
                    } label: {
                        HStack(spacing: 6) {
                            Text(s.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.94))
                                .lineLimit(1)
                            if !s.workspaceLabel.isEmpty {
                                Text(s.workspaceLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.white.opacity(0.09))
                                    .foregroundStyle(Color.white.opacity(0.70))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text(vm.showSessionPicker ? "▲" : "▼")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if vm.pinnedConversationId != nil {
                        obsidianAccentButton(zh ? "恢复同步" : "Auto Sync") {
                            vm.pinnedConversationId = nil
                            vm.showSessionPicker = false
                            vm.onLayoutNeeded?()
                        }
                    } else {
                        obsidianSubtleButton(zh ? "锁定会话" : "Pin") {
                            vm.pinnedConversationId = s.conversationId
                        }
                    }
                }

                if vm.showSessionPicker {
                    VStack(alignment: .leading, spacing: 2) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(s.recentConversations.prefix(10)) { c in
                                    let isSelected = c.id == s.conversationId
                                    Button {
                                        vm.pinnedConversationId = c.id
                                        vm.showSessionPicker = false
                                        vm.onLayoutNeeded?()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(c.isRunning ? Color(red: 0.22, green: 0.74, blue: 0.97) : (isSelected ? Color(red: 0.20, green: 0.83, blue: 0.60) : Color.white.opacity(0.25)))
                                                .frame(width: 6, height: 6)
                                            Text(c.title)
                                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                                .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.80))
                                                .lineLimit(1)
                                            if !c.workspaceLabel.isEmpty {
                                                Text("[\(c.workspaceLabel)]")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Color.white.opacity(0.45))
                                            }
                                            if c.childCount > 0 {
                                                Text("+\(c.childCount)")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Color(red: 0.22, green: 0.74, blue: 0.97))
                                            }
                                            Spacer()
                                            Text(fmtRelTime(c.activityMs, zh: zh))
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color.white.opacity(0.42))
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.16) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                // 2. Official Quota + Optional Swarm Tree
                if s.subagents.isEmpty {
                    quotaSectionCard(now: now, sideBySideGroups: true)
                } else {
                    HStack(alignment: .top, spacing: 9) {
                        quotaSectionCard(now: now, sideBySideGroups: false)
                            .frame(maxWidth: .infinity)
                        swarmTreeCard(s: s, m: m)
                            .frame(width: 248)
                    }
                }

                // 3. Session Metrics
                if !m.hasData {
                    Text(zh ? "当前会话暂无模型调用记录，发送一条消息后自动展示实时数据。" : "No generation records in this conversation yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    HStack(spacing: 8) {
                        kpiCard(
                            title: zh ? "输出速度" : "Throughput",
                            value: "\(fmtRate(m.speed)) tok/s",
                            sub: m.isStreamMode
                                ? (zh ? "流式 · 含等 \(fmtRate(m.endToEndSpeed))" : "Stream · E2E \(fmtRate(m.endToEndSpeed))")
                                : (zh ? "含等待端到端" : "End-to-end")
                        )
                        kpiCard(
                            title: m.isStreamMode ? (zh ? "首字等待" : "TTFT") : (zh ? "缓冲等待" : "Hold"),
                            value: fmtSecDetail(m.waitSeconds),
                            sub: zh ? "出 \(fmtSecDetail(m.streamSeconds)) · 总 \(fmtSecDetail(m.totalSeconds))" : "Out \(fmtSecDetail(m.streamSeconds)) · Tot \(fmtSecDetail(m.totalSeconds))"
                        )
                        kpiCard(
                            title: zh ? "本次输出" : "Latest Out",
                            value: fmtCompact(m.latestOutput),
                            sub: zh ? "思 \(fmtCompact(m.latestThinking)) · 答 \(fmtCompact(m.latestResponse))" : "T \(fmtCompact(m.latestThinking)) · R \(fmtCompact(m.latestResponse))"
                        )
                        kpiCard(
                            title: zh ? "缓存命中" : "Cache Hit",
                            value: m.cachePercent != nil ? String(format: "%.1f%%", m.cachePercent!) : "—",
                            sub: zh ? "命中 \(fmtCompact(m.totalCached))" : "Hit \(fmtCompact(m.totalCached))"
                        )
                    }

                    unifiedContextCard(m: m)
                    recentCallsCard(m: m)
                }

                // 4. Footer
                HStack(spacing: 12) {
                    Toggle(zh ? "悬停直展详情" : "Hover to Expand", isOn: $vm.hoverDirectExpand)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.68))
                    Toggle(zh ? "仅 AGY 前台显示" : "Only over AGY", isOn: $vm.onlyWhenAgyActive)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.68))
                    Spacer()
                    Text(zh ? "点外部或按 Esc 自动收起 · 右键微岛可退出" : "Click outside or Esc to close · Right-click HUD to quit")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.36))
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, 13)
        }
    }

    // MARK: Obsidian Sub-Cards

    private func quotaSectionCard(now: Date, sideBySideGroups: Bool) -> some View {
        let snap = vm.quotaSnapshot
        let activeFam = vm.activeModelFamily
        let ageSec = snap.map { max(0, now.timeIntervalSince($0.fetchedAt)) } ?? 0
        let isStale = snap != nil && ageSec > 600

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(zh ? "官方模型额度（剩余）" : "Official Quota (Remaining)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                if vm.quotaState == .loading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                    Text(zh ? "查询中…" : "Checking…")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.48))
                } else if let snap {
                    Text(fmtQuotaAge(snap.fetchedAt, at: now, zh: zh))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isStale ? Color(red: 0.96, green: 0.62, blue: 0.14) : Color.white.opacity(0.45))
                }

                Spacer()

                if case .failed = vm.quotaState, snap != nil {
                    Text(zh ? "刷新失败" : "Failed")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
                } else if vm.quotaState == .timeout, snap != nil {
                    Text(zh ? "超时" : "Timeout")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
                }

                obsidianSubtleButton(zh ? "刷新额度" : "Refresh", disabled: vm.quotaState == .loading) {
                    vm.refreshQuota(force: true)
                }
            }

            if let snap, !snap.groups.isEmpty {
                if sideBySideGroups && snap.groups.count >= 2 {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(snap.groups.prefix(2)) { g in
                            quotaGroupBox(group: g, isActive: g.family == activeFam && activeFam != .unknown, now: now)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snap.groups.prefix(2)) { g in
                            quotaGroupBox(group: g, isActive: g.family == activeFam && activeFam != .unknown, now: now)
                        }
                    }
                }
            } else {
                quotaEmptyStateView
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func quotaGroupBox(group: QuotaGroup, isActive: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(group.displayName(zh: zh))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isActive ? 0.95 : 0.78))
                    .lineLimit(1)
                if isActive {
                    Text(zh ? "当前" : "Active")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0.5)
                        .background(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.20))
                        .foregroundStyle(Color(red: 0.22, green: 0.74, blue: 0.97))
                        .clipShape(Capsule())
                }
                Spacer()
            }

            if let b7 = group.weeklyBucket {
                quotaBucketRow(label: zh ? "7天" : "7d", bucket: b7, isWeekly: true, barHeight: isActive ? 5.5 : 4.5, now: now)
            }
            if let b5 = group.fiveHourBucket {
                quotaBucketRow(label: "5h", bucket: b5, isWeekly: false, barHeight: isActive ? 5.5 : 4.5, now: now)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(isActive ? Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.09) : Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .stroke(isActive ? Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.38) : Color.white.opacity(0.07), lineWidth: isActive ? 0.9 : 0.6)
        )
    }

    private func quotaBucketRow(label: String, bucket: QuotaBucket, isWeekly: Bool, barHeight: CGFloat, now: Date) -> some View {
        let frac = bucket.effectiveFraction(at: now)
        let tint = quotaColor(fraction: frac)
        let pending = bucket.isAwaitingResetConfirm(at: now)

        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.50))
                .frame(width: 22, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.11))
                    if let frac {
                        Capsule()
                            .fill(pending ? tint.opacity(0.45) : tint)
                            .frame(width: max(4, geo.size.width * frac))
                    }
                }
            }
            .frame(height: barHeight)

            Text(fmtQuotaPercent(frac))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle((frac ?? 1) <= 0.20 ? tint : Color.white.opacity(0.92))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            Text(fmtCountdownDetail(bucket.resetDate, isWeekly: isWeekly, at: now, zh: zh))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.46))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var quotaEmptyStateView: some View {
        HStack(spacing: 8) {
            switch vm.quotaState {
            case .loading:
                ProgressView().controlSize(.small)
                Text(zh ? "正在查询官方 agy /usage 实时额度（首次约 8 秒，零 Token）…" : "Querying official agy /usage (~8s, zero tokens)…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
            case .cliMissing:
                Text(zh ? "未找到 agy CLI（需安装 ~/.local/bin/agy 并登录）" : "agy CLI not found (~/.local/bin/agy required)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
            case .notSignedIn:
                Text(zh ? "agy CLI 未登录，请在终端运行 `agy` 登录后点刷新。" : "Run `agy` in Terminal to sign in, then refresh.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
            case .timeout:
                Text(zh ? "额度查询超时，请检查网络后重试。" : "Quota query timed out.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
            case .failed(let msg):
                Text(zh ? "额度查询失败（\(msg)），点击刷新重试。" : "Quota check failed (\(msg)).")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
            default:
                Text(zh ? "点击右侧「刷新额度」获取最新 5h / 7d 剩余额度。" : "Click Refresh to fetch 5h / 7d official quota.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func unifiedContextCard(m: ConversationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(zh ? "上下文窗口（已用）" : "Context Window (Used)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                if let anatomy = m.anatomy {
                    Text(zh ? "系统开销 ~\(fmtCompact(anatomy.systemOverheadTokens)) (\(String(format: "%.0f%%", anatomy.systemOverheadPercent)))" : "Sys ~\(fmtCompact(anatomy.systemOverheadTokens)) (\(String(format: "%.0f%%", anatomy.systemOverheadPercent)))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.46))
                }
                Spacer()
                Text("\(fmtInt(m.ctxUsed)) / \(m.ctxLimit != nil ? fmtInt(m.ctxLimit!) : "—")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .monospacedDigit()
                if let p = m.ctxPercent {
                    Text(String(format: "%.1f%%", p))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1)
                        .background(levelColor(m.ctxLevel).opacity(0.18))
                        .foregroundStyle(levelColor(m.ctxLevel))
                        .clipShape(Capsule())
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                let totalPct = min(1.0, max(0.0, (m.ctxPercent ?? 0) / 100.0))
                let usedWidth = max(4, geo.size.width * totalPct)

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))

                    if let anatomy = m.anatomy, m.ctxLevel == .normal {
                        HStack(spacing: 1) {
                            ForEach(anatomy.items.filter { $0.percentOfInput >= 0.8 }) { item in
                                Rectangle()
                                    .fill(colorFromHex(item.hexColor))
                                    .frame(width: max(2, usedWidth * item.percentOfInput / 100.0))
                            }
                        }
                        .frame(width: usedWidth, alignment: .leading)
                        .clipShape(Capsule())
                    } else {
                        Capsule()
                            .fill(levelColor(m.ctxLevel))
                            .frame(width: usedWidth)
                    }

                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * 0.75)
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * 0.90)
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                if let anatomy = m.anatomy {
                    ForEach(anatomy.items.prefix(5)) { item in
                        HStack(spacing: 3.5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colorFromHex(item.hexColor))
                                .frame(width: 6.5, height: 6.5)
                            Text("\(zh ? item.labelZh : item.labelEn) \(fmtCompact(item.estTokens))")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
                if let callsLeft = m.runwayCallsLeft, callsLeft <= 15 {
                    Text(callsLeft == 0
                        ? (zh ? "已超 90%，建议 /compact" : ">90% · /compact")
                        : (zh ? "预计还可 ≈\(callsLeft) 次" : "~\(callsLeft) calls left"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(callsLeft == 0 ? Color(red: 0.97, green: 0.44, blue: 0.44) : Color(red: 0.96, green: 0.62, blue: 0.14))
                        .monospacedDigit()
                }
            }

            if let drop = m.cacheDrops.last, drop.callNumber >= max(1, m.totalCalls - 2) {
                let msg = drop.isModelSwitch
                    ? (zh ? "缓存提示：第 #\(drop.callNumber) 次命中 \(drop.prevRate)% → \(drop.currRate)%（切换模型：\(shortModel(drop.fromModel)) → \(shortModel(drop.toModel))）" : "Cache drop at #\(drop.callNumber): \(drop.prevRate)% → \(drop.currRate)% (model switch)")
                    : (zh ? "缓存提示：第 #\(drop.callNumber) 次命中 \(drop.prevRate)% → \(drop.currRate)%（提示词/规则变更）" : "Cache drop at #\(drop.callNumber): \(drop.prevRate)% → \(drop.currRate)% (prompt change)")
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.14))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func swarmTreeCard(s: HUDSnapshot, m: ConversationMetrics) -> some View {
        let grand = max(1, s.combinedTotalTokens)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(zh ? "子代理 / Swarm" : "Subagents")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text(zh ? "合并 \(fmtCompact(s.combinedTotalTokens))" : "Sum \(fmtCompact(s.combinedTotalTokens))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .monospacedDigit()
            }
            subRow(name: zh ? "主会话" : "Root", model: m.model, calls: m.totalCalls, tokens: m.totalTokens, grand: grand, isChild: false)
            ForEach(s.subagents.prefix(4)) { sub in
                subRow(name: "↳ \(sub.name)", model: sub.model, calls: sub.calls, tokens: sub.totalTokens, grand: grand, isChild: true)
            }
            if s.subagents.count > 4 {
                Text(zh ? "另有 +\(s.subagents.count - 4) 个子代理…" : "+\(s.subagents.count - 4) more…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .padding(.leading, 8)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func recentCallsCard(m: ConversationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(zh ? "会话累计（\(m.totalCalls) 次调用）" : "Session Totals (\(m.totalCalls) calls)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Text(zh ? "新入 \(fmtCompact(m.totalInput)) · 缓存 \(fmtCompact(m.totalCached)) · 输出 \(fmtCompact(m.totalOutput))（思 \(fmtCompact(m.totalThinking))）· 总 \(fmtCompact(m.totalTokens))" : "In \(fmtCompact(m.totalInput)) · Cache \(fmtCompact(m.totalCached)) · Out \(fmtCompact(m.totalOutput)) · Total \(fmtCompact(m.totalTokens))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .monospacedDigit()
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            ForEach(m.recentCalls.prefix(5)) { r in
                HStack(spacing: 8) {
                    Text("#\(r.callNumber)")
                        .frame(width: 28, alignment: .leading)
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text(shortModel(r.model))
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(1)
                        .frame(width: 132, alignment: .leading)
                    Text("\(fmtCompact(r.input + r.cached)) (\(r.cachePercent != nil ? "\(Int(r.cachePercent!.rounded()))%" : "—"))")
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("↑\(fmtCompact(r.output)) (\(fmtCompact(r.thinking))/\(fmtCompact(r.response)))")
                        .foregroundStyle(Color.white.opacity(0.76))
                        .frame(width: 134, alignment: .trailing)
                    Text(fmtSecDetail(r.waitSeconds))
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(Color.white.opacity(0.50))
                    Text("\(fmtRate(r.speed)) tok/s")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.white.opacity(0.94))
                        .frame(width: 72, alignment: .trailing)
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func kpiCard(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
                .monospacedDigit()
            Text(sub)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func subRow(name: String, model: String, calls: Int, tokens: Int, grand: Int, isChild: Bool) -> some View {
        let pct = max(1, Int((100.0 * Double(tokens) / Double(grand)).rounded()))
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                Text("\(shortModel(model)) · \(calls)\(zh ? "次" : "x")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            Text("\(fmtCompact(tokens)) (\(pct)%)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .monospacedDigit()
        }
        .padding(.leading, isChild ? 8 : 0)
    }

    private func obsidianMiniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func obsidianSubtleButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(disabled ? 0.35 : 0.86))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func obsidianAccentButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(red: 0.22, green: 0.74, blue: 0.97))
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
