//
//  AetherRefreshView.swift
//  LiveContainerSwiftUI
//
//  Aether "Refresh" tab: signing status, VPN/WireGuard banner (owned by the
//  embedded SideStore), one-tap refresh handoff, and account facts read from
//  the real code signature + provisioning data. No simulated states.
//

import SwiftUI

struct AetherRefreshView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var certStatus: Int = -1 // -1 unknown, 0 valid, 1 expiring, 2 error
    @State private var certExpiry: Date?
    @State private var certTeamId: String?

    private var sideStorePresent: Bool { UserDefaults.sideStoreExist() }

    private var daysLeft: Int? {
        guard let certExpiry else { return nil }
        return max(0, Int(ceil(certExpiry.timeIntervalSinceNow / 86400)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                signingAccountCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(AetherPalette.background)
        .task {
            // zsign's checkCert aborts on a nil cert/password, so only validate when one is imported
            if LCUtils.certificateData() != nil {
                validateCertificate()
            } else {
                certStatus = 2
            }
        }
    }

    // MARK: Cards

    private var statusCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 30))
                .foregroundStyle(statusColor)
                .frame(width: 64, height: 64)
                .background(statusColor.opacity(0.12), in: Circle())

            VStack(spacing: 3) {
                Text(statusTitle)
                    .font(.title3).fontWeight(.black)
                    .foregroundStyle(AetherPalette.text)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(AetherPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if sideStorePresent {
                vpnBanner
            }

            Button {
                refreshAll()
            } label: {
                Label("REFRESH ALL APPS NOW", systemImage: "arrow.2.circlepath")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AetherPalette.uberBlack, in: Capsule())
            }
            .accessibilityHint("Opens the built-in SideStore to renew all app signatures")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(AetherPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AetherPalette.border, lineWidth: 1))
    }

    private var vpnBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.subheadline)
                .foregroundStyle(AetherPalette.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("WireGuard Local VPN")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(AetherPalette.text)
                Text("Managed by SideStore • keeps 7-day refresh alive")
                    .font(.caption2)
                    .foregroundStyle(AetherPalette.secondaryText)
            }
            Spacer()
            Button("Manage") {
                LCUtils.openSideStore(delegate: nil)
            }
            .font(.caption.bold())
            .buttonStyle(.borderless)
            .foregroundStyle(AetherPalette.accent)
        }
        .padding(12)
        .background(AetherPalette.groupHeader, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var signingAccountCard: some View {
        AetherCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Signing Account")
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(AetherPalette.text)
                    .padding(.bottom, 4)

                row("Team ID", value: certTeamId ?? LCSharedUtils.teamIdentifier() ?? "Unknown")
                row("Sideloaded by", value: storeName)
                row("Certificate", value: certSummary, tint: statusColor)
                if sideStorePresent {
                    row("Pairing file", value: pairingStatus, tint: pairingFound ? AetherPalette.success : AetherPalette.warning)
                }
            }
        }
    }

    private func row(_ label: String, value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(AetherPalette.secondaryText)
            Spacer()
            Text(value)
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(tint ?? AetherPalette.text)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(AetherPalette.border.opacity(0.5)).frame(height: 0.5)
        }
        .padding(.top, 4)
    }

    // MARK: Derived state

    private var statusTitle: String {
        switch certStatus {
        case 0:
            if let days = daysLeft, days <= 1 { return "Signature Expiring Soon" }
            return "All Apps Up To Date"
        case 1: return "Certificate Expiring"
        case 2: return "Certificate Problem"
        default: return "Checking Status…"
        }
    }

    private var statusSubtitle: String {
        if let days = daysLeft {
            return "Apps stay signed for \(days) more day\(days == 1 ? "" : "s") — refresh renews the 7-day window."
        }
        switch certStatus {
        case 2: return "Open Settings to diagnose the signing certificate."
        default: return "Free developer signatures renew every 7 days."
        }
    }

    private var statusColor: Color {
        switch certStatus {
        case 0: return daysLeft ?? 7 > 1 ? AetherPalette.success : AetherPalette.warning
        case 1: return AetherPalette.warning
        case 2: return AetherPalette.danger
        default: return AetherPalette.secondaryText
        }
    }

    private var certSummary: String {
        switch certStatus {
        case 0: return "Valid"
        case 1: return "Expiring soon"
        case 2: return "Invalid"
        default: return "Checking…"
        }
    }

    private var storeName: String {
        switch LCUtils.store() {
        case .SideStore: return "SideStore"
        case .AltStore: return "AltStore"
        case .ADP: return "Apple Developer Portal"
        default: return "Unknown"
        }
    }

    private var pairingFound: Bool {
        let fm = FileManager.default
        let candidates = [
            LCPath.docPath.appendingPathComponent("SideStore/pairing.mobiledevicepairing"),
            LCPath.lcGroupDocPath.appendingPathComponent("Documents/SideStore/pairing.mobiledevicepairing"),
        ]
        return candidates.contains { fm.fileExists(atPath: $0.path) }
    }

    private var pairingStatus: String {
        pairingFound ? "Active (pairing.mobiledevicepairing)" : "Not found — import in SideStore"
    }

    // MARK: Actions

    private func refreshAll() {
        guard sideStorePresent else {
            AetherToast.shared.show(
                title: "Refresh unavailable",
                message: "This build has no built-in SideStore. Reinstall using the LiveContainer+SideStore variant.",
                style: .warning
            )
            return
        }
        LCUtils.openSideStore(delegate: nil)
        AetherToast.shared.show(
            title: "Opened SideStore",
            message: "Pull-to-refresh inside SideStore renews all app signatures."
        )
    }

    private func validateCertificate() {
        LCUtils.validateCertificate { status, date, ou, _ in
            Task { @MainActor in
                if let ou {
                    certTeamId = ou
                }
                certStatus = Int(status)
                certExpiry = date
            }
        }
    }
}
