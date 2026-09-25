//
//  LCAppInstaller.swift
//  LiveContainerSwiftUI
//
//  Reusable install pipeline, ported verbatim from LCAppListView so the new
//  Aether Apps tab (and anything else) can import IPAs with identical
//  behavior: decompress, replace-or-new conflict flow, shared-app-group
//  support, on-device ZSign. Progress + errors are published for any host
//  view to bind a toast/progress bar to.
//

import Foundation
import Combine
import SwiftUI

/// Host decides what to do when an IPA conflicts with an existing install.
/// Returns nil if the user cancels. The host typically offers "keep both"
/// (install into a fresh folder) and "replace existing <app>".
typealias LCAppConflictHandler = (LCAppInfo, [LCAppModel]) async throws -> AppReplaceOption?

final class LCAppInstaller: ObservableObject {
    @Published var isInstalling = false
    @Published var installProgress: Double = 0
    @Published var installError: String?

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false

    private var cancellables = Set<AnyCancellable>()
    private(set) var downloadHelper = DownloadHelper()
    private var observer: NSKeyValueObservation?
    var delegate: LCAppModelDelegate?
    private var sharedModel = DataManager.shared.model

    init() {
        // DownloadHelper.downloadProgress is a Float; mirror as Double here.
        downloadHelper.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (fraction: Float) in self?.downloadProgress = Double(fraction) }
            .store(in: &cancellables)
        downloadHelper.$isDownloading
            .receive(on: DispatchQueue.main)
            .assign(to: &$isDownloading)
    }

    private func beginInstall() {
        isInstalling = true
        installProgress = 0
        installError = nil
        downloadProgress = 0
    }

    private func endInstall() {
        isInstalling = false
        installProgress = 0
        isDownloading = false
        observer = nil
    }

    // MARK: - IPA file (local or resolved)

    func installIpaFile(_ url: URL, onConflict: @escaping LCAppConflictHandler) async throws {
        let fm = FileManager()

        let progress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgress = 0
        self.observer = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.installProgress = p.fractionCompleted }
        }

        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        progress.addChild(decompressProgress, withPendingUnitCount: 80)

        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }

        // decompress (libarchive)
        let rc = extract(url.path, fm.temporaryDirectory.path, decompressProgress)
        guard rc == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName: String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace: LCAppModel? = nil

        // Folder exists or an app with the same bundle id is installed -> prompt.
        var sameBundleIdApp = sharedModel.apps.filter {
            $0.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.isEmpty {
            sameBundleIdApp = sharedModel.hiddenApps.filter {
                $0.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            // hidden match requires authentication before proceeding
            if !sameBundleIdApp.isEmpty && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) { return }
                } catch {
                    installError = error.localizedDescription
                    return
                }
            }
        }

        let folderExists = fm.fileExists(atPath: outputFolder.path)
        if folderExists || !sameBundleIdApp.isEmpty {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"

            guard let chosen = try await onConflict(newAppInfo, sameBundleIdApp) else {
                try? fm.removeItem(at: payloadPath)
                return
            }

            if let replaceApp = chosen.appToReplace, replaceApp.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(chosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(chosen.nameOfFolderToInstall)
            }
            appRelativePath = chosen.nameOfFolderToInstall
            appToReplace = chosen.appToReplace
            if chosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }

        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        guard let finalNewApp else {
            installError = "lc.appList.appInfoInitError".loc
            return
        }

        // patch & sign (signed-unsigned apps are kept; a sign failure is surfaced
        // but non-fatal, mirroring LCAppListView)
        finalNewApp.dontSign = finalNewApp.dontSign
            || (appToReplace?.uiDontSign ?? false)
            || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp")
        var signError: String? = nil
        var signSuccess = false
        await withUnsafeContinuation { c in
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                if let sp = signProgress {
                    progress.addChild(sp, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        }
        if let signError {
            self.installError = signSuccess
                ? "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
                : signError.loc
        }

        // carry over previous configuration when replacing
        if let appToReplace {
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now

        await MainActor.run {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self.delegate)
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self.delegate)
                sharedModel.apps.append(newAppModel)
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }
        }
    }

    // MARK: - URL / manifest install

    func installFromUrl(urlStr: String, onConflict: @escaping LCAppConflictHandler) async {
        if isInstalling { return }
        if sharedModel.multiLCStatus == 2 {
            installError = "lc.appList.manageInPrimaryTip".loc
            return
        }
        guard var installUrl = URL(string: urlStr) else {
            installError = "lc.appList.urlInvalidError".loc
            return
        }
        beginInstall()
        defer { endInstall() }

        if installUrl.isFileURL {
            let ext = installUrl.pathExtension.lowercased()
            if ext != "ipa" && ext != "tipa" {
                installError = "lc.appList.urlFileIsNotIpaError".loc
                return
            }
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(resolvingBookmarkData: bookmarkData,
                                              options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                                              relativeTo: nil, bookmarkDataIsStale: &isStale)
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    installError = "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    return
                }
            }
            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }
            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                installError = "lc.appList.ipaAccessError".loc
                return
            }
            defer { if didStartAccessing { installUrl.stopAccessingSecurityScopedResource() } }
            do {
                try await installIpaFile(installUrl, onConflict: onConflict)
            } catch {
                installError = error.localizedDescription
            }
            do {
                if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = docs.appendingPathComponent("Inbox")
                    if installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL {
                        try fm.removeItem(at: installUrl)
                    }
                }
            } catch {
                installError = error.localizedDescription
            }
            return
        }

        // remote URL
        do {
            let fm = FileManager.default
            let destinationURL = fm.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            isDownloading = true
            downloadProgress = 0
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            isDownloading = false
            if downloadHelper.cancelled { return }
            try await installIpaFile(destinationURL, onConflict: onConflict)
            try fm.removeItem(at: destinationURL)
        } catch {
            installError = error.localizedDescription
        }
    }

    func installFromPlist(urlStr: String, onConflict: @escaping LCAppConflictHandler) async {
        if isInstalling { return }
        if sharedModel.multiLCStatus == 2 {
            installError = "lc.appList.manageInPrimaryTip".loc
            return
        }
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let comps = URLComponents(string: plistUrlStr),
               let queryItems = comps.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                installError = "lc.appList.plistInvalidError".loc
                return
            }
        }
        guard let plistUrl = URL(string: plistUrlStr) else {
            installError = "lc.appList.urlInvalidError".loc
            return
        }
        beginInstall()
        defer { endInstall() }
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                installError = "lc.appList.plistParseError".loc
                return
            }
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            guard let ipaUrlStr else {
                installError = "lc.appList.plistNoIpaError".loc
                return
            }
            await installFromUrl(urlStr: ipaUrlStr, onConflict: onConflict)
        } catch {
            installError = error.localizedDescription
        }
    }
}
