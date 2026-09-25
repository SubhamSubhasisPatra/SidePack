//
//  AetherKit.swift
//  LiveContainerSwiftUI
//
//  Design system + shared chrome for the Aether re-skin.
//  Colors use iOS system tokens so they map 1:1 to the Aether design
//  (bg #F2F2F7, card #FFFFFF, accent #007AFF, green/amber/red) and adapt
//  to dark mode + accessibility automatically.
//

import SwiftUI

// MARK: - Palette

enum AetherPalette {
    static let background = Color(UIColor.systemGroupedBackground) // #F2F2F7 (light)
    static let surface = Color(UIColor.systemBackground)           // cards #FFFFFF
    static let groupHeader = Color(UIColor.secondarySystemBackground)
    static let text = Color(UIColor.label)
    static let secondaryText = Color(UIColor.secondaryLabel)       // #8E8E93
    static let border = Color(UIColor.separator)                   // #E5E5EA
    static let pillFill = Color(UIColor.secondarySystemFill)       // #E9E9EB pill-switch track
    static let accent = Color(UIColor.systemBlue)                  // #007AFF
    static let success = Color(UIColor.systemGreen)                // #34C759
    static let warning = Color(UIColor.systemOrange)               // #FF9500
    static let danger = Color(UIColor.systemRed)                    // #FF3B30
    static let uberBlack = Color.black                              // black pill buttons
    static let glass = Material.ultraThin
}

// MARK: - Tab model (one Aether tab per LCTabIdentifier case)

struct AetherTabItem: Hashable {
    let id: LCTabIdentifier
    let title: String
    let icon: String
}

extension AetherTabItem {
    static var all: [AetherTabItem] {
        [
            .init(id: .apps, title: "Apps", icon: "cubes.fill"),
            .init(id: .sources, title: "Discover", icon: "globe"),
            .init(id: .tweaks, title: "Refresh", icon: "arrow.2.circlepath"), // Phase 3 swaps content
            .init(id: .settings, title: "Settings", icon: "gearshape.fill"),
        ]
    }
}

// MARK: - Toasts (glass, auto-dismiss, top overlay)

enum ToastStyle { case success, warning, error, info }

final class AetherToast: ObservableObject {
    static let shared = AetherToast()

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let style: ToastStyle
    }

    @Published var items: [Item] = []
    private var timers: [UUID: Timer] = [:]

    func show(title: String, message: String = "", style: ToastStyle = .info) {
        let item = Item(title: title, message: message, style: style)
        items.append(item)
        timers[item.id] = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { _ in
            self.dismiss(item)
        }
    }

    func dismiss(_ item: Item) {
        timers[item.id]?.invalidate()
        timers[item.id] = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            items.removeAll { $0.id == item.id }
        }
    }
}

private struct AetherToastView: View {
    @ObservedObject var host = AetherToast.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(host.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: item.style))
                        .frame(width: 18)
                        .foregroundStyle(color(for: item.style))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(color(for: item.style))
                        if !item.message.isEmpty {
                            Text(item.message)
                                .font(.caption2)
                                .foregroundStyle(AetherPalette.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(stroke(for: item.style), lineWidth: 1))
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    private func icon(for style: ToastStyle) -> String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .warning:  "exclamationmark.octagon.fill"
        case .error:    "xmark.octagon.fill"
        case .info:     "info.circle.fill"
        }
    }
    private func color(for style: ToastStyle) -> Color {
        switch style {
        case .success: AetherPalette.success
        case .warning:  AetherPalette.warning
        case .error:    AetherPalette.danger
        case .info:     AetherPalette.accent
        }
    }
    private func stroke(for style: ToastStyle) -> Color {
        switch style {
        case .success: AetherPalette.success.opacity(0.4)
        case .warning:  AetherPalette.warning.opacity(0.4)
        case .error:    AetherPalette.danger.opacity(0.4)
        case .info:     AetherPalette.accent.opacity(0.4)
        }
    }
}

extension View {
    @ViewBuilder
    func aetherToast() -> some View {
        overlay(AetherToastView(), alignment: .top)
    }
}

// MARK: - Liquid Glass (iOS 26+) with frosted fallback
//
// Scope decision: Liquid Glass is applied to the floating bottom tab bar
// ONLY. Cards, banners, header and toasts keep the solid design so every
// tab looks the same.

extension View {
    /// Places a Liquid Glass shape behind this view (as the background), so
    /// nested glass elements (the active-tab pill) can merge with it inside
    /// a glass container. Frosted-card fallback below iOS 26.
    @ViewBuilder
    func aetherGlassBackground<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.background {
                Color.clear.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(AetherPalette.surface, in: shape)
                .overlay(shape.stroke(AetherPalette.border.opacity(0.6), lineWidth: 1))
        }
    }
}

/// Merges sibling glass shapes on iOS 26+; passthrough below.
struct AetherGlassContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - VPN status (best-effort, honest)

/// Detects an active VPN tunnel without NetworkExtension entitlements:
/// a utun interface that currently carries an IP address. System-internal
/// utuns are addressless, so this stays false until a real tunnel
/// (e.g. SideStore's WireGuard) connects.
enum AetherVPNStatus {
    static func isTunnelLikelyActive() -> Bool {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return false }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let iface = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            if iface.hasPrefix("utun"), let addr = current.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                    return true
                }
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }
}

// MARK: - Header

struct AetherHeader: View {
    let title: String

    @State private var tunnelActive = false

    private var sideStorePresent: Bool { UserDefaults.sideStoreExist() }

    private var status: AetherVPNIndicator {
        if !sideStorePresent { return .unavailable }
        return tunnelActive ? .active : .offline
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AETHER")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(AetherPalette.secondaryText)
                    .textCase(.uppercase)
                Text(title)
                    .font(.title2).fontWeight(.black)
                    .foregroundStyle(AetherPalette.text)
            }
            Spacer()
            vpnPill
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear(perform: refreshTunnel)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshTunnel()
        }
    }

    private func refreshTunnel() {
        tunnelActive = AetherVPNStatus.isTunnelLikelyActive()
    }

    private enum AetherVPNIndicator {
        case active, offline, unavailable

        var dot: Color {
            switch self {
            case .active: AetherPalette.success
            case .offline: AetherPalette.danger
            case .unavailable: AetherPalette.secondaryText
            }
        }

        var label: String {
            switch self {
            case .active: "VPN Active"
            case .offline: "VPN Offline"
            case .unavailable: "VPN N/A"
            }
        }
    }

    @ViewBuilder
    private var vpnPill: some View {
        Button {
            switch status {
            case .offline:
                // SideStore owns the WireGuard tunnel; its VPN toggle lives there.
                LCUtils.openSideStore(delegate: nil)
            case .unavailable:
                AetherToast.shared.show(
                    title: "No VPN in this build",
                    message: "The +SideStore variant carries the WireGuard tunnel.",
                    style: .info
                )
            case .active:
                break
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(status.dot)
                    .frame(width: 7, height: 7)
                Text(status.label)
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(status == .unavailable ? AetherPalette.secondaryText : AetherPalette.text)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(AetherPalette.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AetherPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(status == .active)
    }
}

// MARK: - Bottom navigation bar

struct AetherBottomBar: View {
    @Binding var selection: LCTabIdentifier

    var body: some View {
        let visible = DataManager.shared.model.multiLCStatus == 2
            ? AetherTabItem.all.filter { $0.id != .sources && $0.id != .tweaks }
            : AetherTabItem.all
        AetherGlassContainer {
            HStack(spacing: 2) {
                ForEach(visible, id: \.id) { tab in
                    tabButton(tab)
                }
            }
            .padding(6)
        }
        .aetherGlassBackground(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func tabButton(_ tab: AetherTabItem) -> some View {
        Button {
            selection = tab.id
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon).font(.callout)
                Text(tab.title).font(.caption2).fontWeight(.bold)
            }
            .foregroundStyle(tab.id == selection ? AetherPalette.accent : AetherPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .modifier(AetherTabHighlight(selected: tab.id == selection))
        }
        .buttonStyle(.plain)
    }
}

/// Active tab gets its own interactive glass capsule on iOS 26 (it merges
/// into the bar glass inside AetherGlassContainer); a tinted pill below.
struct AetherTabHighlight: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if selected {
                content
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content
            }
        } else {
            content
                .background(selected ? AetherPalette.pillFill : .clear, in: Capsule())
        }
    }
}

// convenience to read the current tab title
extension LCTabIdentifier {
    var aetherTitle: String {
        switch self {
        case .apps: "Apps"
        case .sources: "Discover"
        case .tweaks: "Refresh"
        case .settings: "Settings"
        }
    }
}
