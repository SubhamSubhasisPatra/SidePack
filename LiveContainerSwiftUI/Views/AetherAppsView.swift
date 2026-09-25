//
//  AetherAppsView.swift
//  LiveContainerSwiftUI
//
//  Aether "Apps" tab: Container / Standard pill switch, guest app cards with
//  one-tap launch, long-press actions (launch / standalone handoff / data
//  containers / remove), dual-mode IPA import sheet, live install progress.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Small helpers

struct PendingIpa: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var size: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}

struct AppModelBox: Identifiable {
    let id = UUID()
    let app: LCAppModel
}

// MARK: - Main view

struct AetherAppsView: View, LCAppModelDelegate {
    enum Mode: Hashable { case container, standard }

    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var sharedAppSortManager: LCAppSortManager
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var installer = LCAppInstaller()
    @State private var mode: Mode = .container

    // import flow
    @State private var choosingIPA = false
    @State private var pendingIpa: PendingIpa?
    @State private var installOptions: [AppReplaceOption] = []
    @StateObject private var installReplaceAlert = AlertHelper<AppReplaceOption>()

    // JIT flow (ported from LCAppListView)
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    @State private var webViewOpened = false
    @State private var webViewURL = URL(string: "about:blank")!

    // other prompts
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    @StateObject private var removeAppAlert = YesNoHelper()
    @StateObject private var removeDataAlert = YesNoHelper()
    @State private var appPendingRemoval: LCAppModel?

    // per-app sheets
    @State private var appSettingsBox: AppModelBox?

    private var apps: [LCAppModel] { sharedAppSortManager.sortedApps }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                modeSwitch
                modeBanner

                if installer.isInstalling || installer.isDownloading {
                    installProgressBar
                }

                Group {
                    if mode == .container {
                        containerSection
                    } else {
                        standardSection
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(AetherPalette.background)
        .onAppear(perform: assignDelegates)
        .betterFileImporter(
            isPresented: $choosingIPA,
            types: [UTType(filenameExtension: "ipa")!, UTType(filenameExtension: "tipa")!],
            multiple: false,
            callback: { urls in
                if let url = urls.first {
                    pendingIpa = PendingIpa(url: url)
                }
            },
            onDismiss: {}
        )
        .sheet(item: $pendingIpa) { pending in
            AetherInstallSheet(pending: pending) { choice in
                pendingIpa = nil
                handleInstallChoice(pending.url, choice)
            }
        }
        .sheet(item: $appSettingsBox) { box in
            NavigationView {
                LCAppSettingsView(model: box.app)
            }
        }
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            aetherJITModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installer.installFromPlist(urlStr: urlStr, onConflict: conflictHandler)
            })
        }
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $removeAppAlert.show) {
            Button(role: .destructive) {
                removeAppAlert.close(result: true)
            } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeAppAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(appPendingRemoval?.displayName ?? "?"))
        }
        .alert("lc.appBanner.deleteDataTitle".loc, isPresented: $removeDataAlert.show) {
            Button(role: .destructive) {
                removeDataAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeDataAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.deleteDataMsg %@".localizeWithFormat(appPendingRemoval?.displayName ?? "?"))
        }
        .onChange(of: installer.installError) { err in
            if let err {
                AetherToast.shared.show(title: "Install failed", message: err, style: .error)
                installer.installError = nil
            }
        }
    }

    // MARK: Sections

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton(.container, icon: "shippingbox.fill", label: "Containers")
            modeButton(.standard, icon: "iphone", label: "Standard")
        }
        .padding(4)
        .background(AetherPalette.pillFill, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func modeButton(_ m: Mode, icon: String, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { mode = m }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.subheadline).fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(mode == m ? AetherPalette.text : AetherPalette.secondaryText)
            .background(
                mode == m ? AnyShapeStyle(AetherPalette.surface) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .shadow(color: mode == m ? .black.opacity(0.08) : .clear, radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var modeBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .container ? "LiveContainer Mode Active" : "Standard Sideload Mode Active")
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(AetherPalette.text)
                Text(mode == .container
                     ? "Runs instantly inside the sandbox without using Apple's 3-app sideload slots."
                     : "Sideloaded directly to the iOS Home Screen using local signing profiles.")
                    .font(.caption)
                    .foregroundStyle(AetherPalette.secondaryText)
            }
            Spacer()
            Button {
                choosingIPA = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(AetherPalette.uberBlack, in: Circle())
            }
            .accessibilityLabel("Import IPA")
        }
        .padding(14)
        .background(AetherPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AetherPalette.border, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private var installProgressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(installer.isDownloading ? "Downloading…" : "Signing with your certificate…")
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(AetherPalette.secondaryText)
            ProgressView(value: installer.isDownloading ? installer.downloadProgress : installer.installProgress)
                .tint(AetherPalette.accent)
        }
        .padding(12)
        .background(AetherPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var containerSection: some View {
        if apps.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 10) {
                ForEach(apps, id: \.self) { app in
                    AetherAppRow(app: app, colorScheme: colorScheme) {
                        launch(app: app)
                    }
                    .contextMenu {
                        Button {
                            launch(app: app)
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                        }
                        if UserDefaults.sideStoreExist() {
                            Button {
                                installStandalone(app: app)
                            } label: {
                                Label("Install Standalone…", systemImage: "arrow.up.forward.app")
                            }
                        }
                        Button {
                            appSettingsBox = AppModelBox(app: app)
                        } label: {
                            Label("Data Containers…", systemImage: "externaldrive.fill")
                        }
                        Button(role: .destructive) {
                            beginRemoval(of: app)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var standardSection: some View {
        VStack(spacing: 10) {
            if UserDefaults.sideStoreExist() {
                // The embedded SideStore owns standalone installs + 7-day refresh.
                AetherCard {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(
                                LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SideStore")
                                .font(.subheadline).fontWeight(.bold)
                                .foregroundStyle(AetherPalette.text)
                            Text("Standalone installer & 7-day refresher")
                                .font(.caption)
                                .foregroundStyle(AetherPalette.secondaryText)
                        }
                        Spacer()
                        Button {
                            LCUtils.openSideStore(delegate: self)
                            AetherToast.shared.show(title: "Opening SideStore", message: "Manage standalone installs there.")
                        } label: {
                            Text("OPEN")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(AetherPalette.uberBlack, in: Capsule())
                        }
                    }
                }

                AetherCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Apple's free-account limits")
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(AetherPalette.text)
                        Text("Standalone apps are real installs: up to 3 active at a time, ~10 App IDs per 7 days, each expiring after 7 days unless refreshed. Container mode has none of these limits.")
                            .font(.caption)
                            .foregroundStyle(AetherPalette.secondaryText)
                    }
                }
            } else {
                AetherCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Standalone mode needs the +SideStore build", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(AetherPalette.text)
                        Text("This build runs container apps only. Rebuild with the SideStore variant to install apps straight to the Home Screen.")
                            .font(.caption)
                            .foregroundStyle(AetherPalette.secondaryText)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44))
                .foregroundStyle(AetherPalette.accent.opacity(0.4))
            Text("No apps yet")
                .font(.headline)
                .foregroundStyle(AetherPalette.text)
            Text("Drop an IPA to begin")
                .font(.subheadline)
                .foregroundStyle(AetherPalette.secondaryText)
            Button {
                choosingIPA = true
            } label: {
                Text("Choose File")
                    .font(.subheadline).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(AetherPalette.uberBlack, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var aetherJITModal: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .font(.subheadline)
                        .foregroundStyle(AetherPalette.text)
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(AetherPalette.secondaryText)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.ok".loc) {
                        jitAlert.close(result: true)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func assignDelegates() {
        installer.delegate = self
        for app in sharedModel.apps { app.delegate = self }
        for app in sharedModel.hiddenApps { app.delegate = self }
    }

    private func launch(app: LCAppModel) {
        Task {
            do {
                try await app.runApp()
            } catch {
                AetherToast.shared.show(title: "Launch failed", message: error.localizedDescription, style: .error)
            }
        }
    }

    private func handleInstallChoice(_ url: URL, _ choice: AetherInstallChoice) {
        switch choice {
        case .container:
            Task {
                do {
                    try await installer.installIpaFile(url, onConflict: conflictHandler)
                    if installer.installError == nil {
                        AetherToast.shared.show(title: "Installed", message: "The app is ready to launch.", style: .success)
                    }
                } catch {
                    AetherToast.shared.show(title: "Install failed", message: error.localizedDescription, style: .error)
                }
            }
        case .standalone:
            do {
                let bookmark = try url.bookmarkData(
                    options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionFileBookmark")
                LCUtils.openSideStore(delegate: self, urlStr: url.absoluteString)
                AetherToast.shared.show(title: "Sent to SideStore", message: "Finish the install in SideStore.")
            } catch {
                AetherToast.shared.show(title: "Handoff failed", message: error.localizedDescription, style: .error)
            }
        }
    }

    private func conflictHandler(_ newApp: LCAppInfo, _ conflicts: [LCAppModel]) async throws -> AppReplaceOption? {
        let keepBoth = AppReplaceOption(
            isReplace: false,
            nameOfFolderToInstall: "\(newApp.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app",
            appToReplace: nil
        )
        installOptions = [keepBoth] + conflicts.map {
            AppReplaceOption(isReplace: true, nameOfFolderToInstall: $0.appInfo.relativeBundlePath, appToReplace: $0)
        }
        return await installReplaceAlert.open()
    }

    /// Archive the guest app back into an IPA and hand it to the embedded
    /// SideStore for a real, standalone install (same flow as
    /// LCMultiLCManagementView's install handoff).
    private func installStandalone(app: LCAppModel) {
        guard let bundleId = app.appInfo.bundleIdentifier() else { return }
        Task {
            do {
                let packedIpaUrl = try LCUtils.archiveIPA(withBundleName: bundleId, includingExtraInfoDict: [:])
                let bookmark = try packedIpaUrl.bookmarkData(
                    options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionFileBookmark")
                LCUtils.openSideStore(delegate: self, urlStr: packedIpaUrl.absoluteString)
                AetherToast.shared.show(title: "Sent to SideStore", message: "Finish the standalone install there.")
            } catch {
                AetherToast.shared.show(title: "Handoff failed", message: error.localizedDescription, style: .error)
            }
        }
    }

    private func beginRemoval(of app: LCAppModel) {
        appPendingRemoval = app
        Task {
            if await removeAppAlert.open() == true {
                let removeData = await removeDataAlert.open() ?? false
                removeApp(app: app, removeData: removeData)
            }
            await MainActor.run {
                if appPendingRemoval == app { appPendingRemoval = nil }
            }
        }
    }

    private func removeApp(app: LCAppModel, removeData: Bool) {
        do {
            if let path = app.appInfo.bundlePath() {
                try FileManager.default.removeItem(atPath: path)
            }
            if removeData, let dataUUID = app.appInfo.dataUUID {
                let base = app.uiIsShared ? LCPath.lcGroupDataPath : LCPath.dataPath
                try? FileManager.default.removeItem(at: base.appendingPathComponent(dataUUID))
                LCUtils.removeAppKeychain(dataUUID: dataUUID)
            }
            DispatchQueue.main.async {
                sharedModel.apps.removeAll { $0 == app }
                sharedModel.hiddenApps.removeAll { $0 == app }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            }
            AetherToast.shared.show(title: "Removed", message: app.displayName, style: .success)
        } catch {
            AetherToast.shared.show(title: "Remove failed", message: error.localizedDescription, style: .error)
        }
    }

    // MARK: - LCAppModelDelegate (ported from LCAppListView)

    func closeNavigationView() {}

    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { $0 == app }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { $0 == app }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
        }
    }

    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run { jitLog = "" }
        let enableJITTask = Task {
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run { self.jitLog += "\(newMsg)\n" } }
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
    }

    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                                (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false&forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            AetherToast.shared.show(title: "StosDebug not found", message: "Install it first and switch it to a shared app.", style: .error)
                            return
                        }
                    } else {
                        if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }

                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                                (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            AetherToast.shared.show(title: "StikDebug not found", message: "Install it first and switch it to a shared app.", style: .error)
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }

    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installer.installFromPlist(urlStr: urlString, onConflict: conflictHandler)
            return
        }
        await MainActor.run {
            webViewURL = urlToOpen.url!
            webViewOpened = true
        }
    }
}

// MARK: - Row

struct AetherAppRow: View {
    @ObservedObject var app: LCAppModel
    let colorScheme: ColorScheme
    let onLaunch: () -> Void

    private var icon: UIImage {
        app.appInfo.iconIsDarkIcon(colorScheme == .dark)
    }

    var body: some View {
        AetherCard {
            HStack(spacing: 12) {
                IconImageView(icon: icon)
                    .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.subheadline).fontWeight(.bold)
                        .foregroundStyle(AetherPalette.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(app.version)
                            .font(.caption)
                            .foregroundStyle(AetherPalette.secondaryText)
                        Circle()
                            .fill(AetherPalette.secondaryText.opacity(0.5))
                            .frame(width: 3, height: 3)
                        Text(statusCaption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                Spacer()
                launchButton
            }
        }
    }

    private var statusCaption: String {
        if app.isSigningInProgress { return "Signing…" }
        if app.uiIsJITNeeded { return "JIT Ready" }
        return "Sandbox Ready"
    }

    private var statusColor: Color {
        if app.isSigningInProgress { return AetherPalette.accent }
        if app.uiIsJITNeeded { return AetherPalette.warning }
        return AetherPalette.accent
    }

    @ViewBuilder
    private var launchButton: some View {
        Button(action: onLaunch) {
            Group {
                if app.isSigningInProgress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Text("LAUNCH")
                        .font(.caption).fontWeight(.bold)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(AetherPalette.uberBlack, in: Capsule())
        }
        .disabled(app.isSigningInProgress || app.isAppRunning)
        .opacity(app.isSigningInProgress ? 0.6 : 1)
    }
}

// MARK: - Shared card component

struct AetherCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AetherPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AetherPalette.border.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Install sheet

enum AetherInstallChoice { case container, standalone }

struct AetherInstallSheet: View {
    let pending: PendingIpa
    let onChoose: (AetherInstallChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(AetherPalette.secondaryText.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            VStack(spacing: 4) {
                Image(systemName: "app.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(AetherPalette.accent)
                Text(pending.name)
                    .font(.headline)
                    .foregroundStyle(AetherPalette.text)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: pending.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(AetherPalette.secondaryText)
            }

            Text("Choose how you want to install this application:")
                .font(.subheadline)
                .foregroundStyle(AetherPalette.secondaryText)

            VStack(spacing: 10) {
                modeCard(
                    title: "Run in LiveContainer",
                    subtitle: "Instant execution • No Apple 3-app limit",
                    icon: "shippingbox.fill",
                    tint: AetherPalette.accent
                ) {
                    onChoose(.container)
                }

                modeCard(
                    title: "Sideload Standard",
                    subtitle: "Installs directly to Home Screen via SideStore",
                    icon: "iphone",
                    tint: AetherPalette.success
                ) {
                    onChoose(.standalone)
                }
            }

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(AetherPalette.secondaryText)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
        .background(AetherPalette.background)
        .aetherSheetDetents()
    }

    private func modeCard(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.subheadline.bold())
                        .foregroundStyle(AetherPalette.text)
                        .labelStyle(.titleAndIcon)
                        .tint(tint)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AetherPalette.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AetherPalette.secondaryText)
            }
            .padding(14)
            .background(AetherPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AetherPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    @ViewBuilder
    func aetherSheetDetents() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }
}
