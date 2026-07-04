import AppKit
import Foundation
import Sparkle

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private enum DefaultsKey {
        static let pendingInstallDisplayVersion = "UpdateManager.pendingInstallDisplayVersion"
        static let pendingInstallBuildVersion = "UpdateManager.pendingInstallBuildVersion"
        static let pendingInstallStartedAt = "UpdateManager.pendingInstallStartedAt"
    }

    private enum UpdateStatus: Equatable {
        case idle
        case checking
        case downloading
        case extracting
        case readyToInstall
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .extracting, .readyToInstall, .installing:
                return true
            case .idle, .failed:
                return false
            }
        }
    }

    private let userDriver = DirectInstallUpdateUserDriver()
    private lazy var updater = SPUUpdater(
        hostBundle: Bundle.main,
        applicationBundle: Bundle.main,
        userDriver: userDriver,
        delegate: self
    )

    private var onStatusChanged: (() -> Void)?
    private(set) var availableVersion: String?
    private var availableBuildVersion: String?
    private var installingDisplayVersion: String?
    private var installingBuildVersion: String?
    private var status: UpdateStatus = .idle
    private var didStart = false

    var menuTitle: String {
        switch status {
        case .checking:
            return "正在检查更新..."
        case .downloading:
            return "正在下载更新..."
        case .extracting:
            return "正在准备安装..."
        case .readyToInstall, .installing:
            return "正在安装并重启..."
        case .idle, .failed:
            break
        }

        if let availableVersion {
            return "下载并安装 \(availableVersion)..."
        }
        return "当前版本 \(Self.currentDisplayVersion)"
    }

    var canSelectMenuItem: Bool {
        guard didStart else { return false }
        return availableVersion != nil
            && !AudioRecorderManager.shared.isRecording
            && !status.isBusy
    }

    func start(onStatusChanged: @escaping () -> Void) {
        self.onStatusChanged = onStatusChanged
        guard !didStart else {
            notifyStatusChanged()
            return
        }
        didStart = true
        restoreCompletedUpdateIfNeeded()
        do {
            try updater.start()
            LogManager.shared.info("自动更新已启动 | 检查间隔: 每天 | 更新源: GitHub Releases appcast")
        } catch {
            didStart = false
            LogManager.shared.error("自动更新启动失败 | \(error.localizedDescription)")
        }
        notifyStatusChanged()
    }

    func handleMenuSelection() {
        guard !AudioRecorderManager.shared.isRecording else {
            LogManager.shared.info("录音中禁止检查更新")
            NSSound.beep()
            return
        }

        if availableVersion != nil {
            guard updater.canCheckForUpdates else {
                LogManager.shared.warning("当前无法安装更新 | Sparkle 暂不可接收用户触发的更新检查")
                NSSound.beep()
                return
            }

            LogManager.shared.info("用户点击安装可用更新 | 版本: \(availableVersion ?? "未知")")
            installingDisplayVersion = availableVersion
            installingBuildVersion = availableBuildVersion
            setStatus(.checking)
            updater.checkForUpdates()
            return
        }

        LogManager.shared.info("当前已是最新版本 | 版本: \(Self.currentDisplayVersion)")
        NSSound.beep()
    }

    private func setStatus(_ newStatus: UpdateStatus) {
        guard status != newStatus else { return }
        status = newStatus
        notifyStatusChanged()
    }

    private func setAvailableUpdate(displayVersion: String?, buildVersion: String?) {
        availableVersion = displayVersion
        availableBuildVersion = buildVersion
        if status == .checking && installingDisplayVersion == nil {
            setStatus(.idle)
            return
        }
        notifyStatusChanged()
    }

    fileprivate func markDownloadStarted() {
        setStatus(.downloading)
    }

    fileprivate func markUserInitiatedUpdateFound(displayVersion: String, buildVersion: String) {
        installingDisplayVersion = displayVersion
        installingBuildVersion = buildVersion
        markDownloadStarted()
    }

    fileprivate func markExtractionStarted() {
        setStatus(.extracting)
    }

    fileprivate func markReadyToInstall() {
        let displayVersion = installingDisplayVersion ?? availableVersion
        let buildVersion = installingBuildVersion ?? availableBuildVersion
        if let displayVersion {
            UserDefaults.standard.set(displayVersion, forKey: DefaultsKey.pendingInstallDisplayVersion)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKey.pendingInstallStartedAt)
            if let buildVersion {
                UserDefaults.standard.set(buildVersion, forKey: DefaultsKey.pendingInstallBuildVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingInstallBuildVersion)
            }
        }
        setStatus(.readyToInstall)
    }

    fileprivate func markInstalling() {
        setStatus(.installing)
    }

    fileprivate func markUpdateFailed(_ error: any Error) {
        clearPendingInstallation()
        installingDisplayVersion = nil
        installingBuildVersion = nil
        setStatus(.failed(Self.shortErrorMessage(error)))
    }

    private func notifyStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    private func restoreCompletedUpdateIfNeeded() {
        let defaults = UserDefaults.standard
        guard let pendingDisplayVersion = defaults.string(
            forKey: DefaultsKey.pendingInstallDisplayVersion
        ) else {
            return
        }

        let pendingBuildVersion = defaults.string(forKey: DefaultsKey.pendingInstallBuildVersion)
        let didComplete: Bool
        if let pendingBuildVersion,
            let pendingBuildNumber = Int(pendingBuildVersion),
            let currentBuildNumber = Int(Self.currentBuildVersion)
        {
            didComplete = currentBuildNumber >= pendingBuildNumber
        } else {
            didComplete = Self.currentDisplayVersion == pendingDisplayVersion
        }

        let startedAt = defaults.double(forKey: DefaultsKey.pendingInstallStartedAt)
        clearPendingInstallation()

        if didComplete {
            LogManager.shared.info("更新安装完成确认 | 当前版本: \(Self.currentDisplayVersion)")
        } else if startedAt > 0 && Date().timeIntervalSince1970 - startedAt < 3600 {
            LogManager.shared.warning("更新安装未完成 | 目标版本: \(pendingDisplayVersion)")
            setStatus(.failed("安装未完成"))
        }
    }

    private func clearPendingInstallation() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.pendingInstallDisplayVersion)
        defaults.removeObject(forKey: DefaultsKey.pendingInstallBuildVersion)
        defaults.removeObject(forKey: DefaultsKey.pendingInstallStartedAt)
    }

    private static var currentDisplayVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private static var currentBuildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
    }

    private static func shortErrorMessage(_ error: any Error) -> String {
        let message = error.localizedDescription
        return message.count > 18 ? "请稍后重试" : message
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if AudioRecorderManager.shared.isRecording {
            throw NSError(
                domain: "MeetingRecorderProUpdate",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "正在录音，录音结束后再检查更新。"
                ]
            )
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        LogManager.shared.info("发现新版本 | 版本: \(item.displayVersionString)")
        setAvailableUpdate(displayVersion: item.displayVersionString, buildVersion: item.versionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        LogManager.shared.info("未发现可用更新 | \(error.localizedDescription)")
        installingDisplayVersion = nil
        installingBuildVersion = nil
        setAvailableUpdate(displayVersion: nil, buildVersion: nil)
        if status == .checking {
            setStatus(.idle)
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if let error {
            LogManager.shared.warning("更新检查结束 | \(error.localizedDescription)")
            if installingDisplayVersion != nil || status.isBusy {
                markUpdateFailed(error)
            }
            return
        }
        if status == .checking {
            setStatus(.idle)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        LogManager.shared.warning("更新流程中止 | \(error.localizedDescription)")
        if installingDisplayVersion != nil || status.isBusy {
            markUpdateFailed(error)
        }
    }
}

private final class DirectInstallUpdateUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: NSNumber(value: false),
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        LogManager.shared.info("开始检查更新")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        if !state.userInitiated {
            LogManager.shared.info("后台发现更新，仅更新菜单状态 | 版本: \(appcastItem.displayVersionString)")
            return .dismiss
        }

        if AudioRecorderManager.shared.isRecording {
            LogManager.shared.warning("录音中发现更新，已取消安装流程 | 版本: \(appcastItem.displayVersionString)")
            return .dismiss
        }

        if appcastItem.isInformationOnlyUpdate {
            LogManager.shared.warning("发现仅信息型更新，已忽略安装流程 | 版本: \(appcastItem.displayVersionString)")
            return .dismiss
        }

        LogManager.shared.info("开始下载并安装更新 | 版本: \(appcastItem.displayVersionString)")
        UpdateManager.shared.markUserInitiatedUpdateFound(
            displayVersion: appcastItem.displayVersionString,
            buildVersion: appcastItem.versionString
        )
        return .install
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // 产品策略不展示版本说明。
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        LogManager.shared.warning("更新版本说明下载失败，继续安装流程 | \(error.localizedDescription)")
    }

    func showUpdateNotFoundWithError(_ error: any Error) async {
        LogManager.shared.info("没有可用更新 | \(error.localizedDescription)")
    }

    func showUpdaterError(_ error: any Error) async {
        LogManager.shared.warning("更新失败 | \(error.localizedDescription)")
        UpdateManager.shared.markUpdateFailed(error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        LogManager.shared.info("开始下载更新包")
        UpdateManager.shared.markDownloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        LogManager.shared.info("更新包大小 | \(expectedContentLength) bytes")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
    }

    func showDownloadDidStartExtractingUpdate() {
        LogManager.shared.info("更新包下载完成，开始解压")
        UpdateManager.shared.markExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        if AudioRecorderManager.shared.isRecording {
            LogManager.shared.warning("录音中禁止重启安装更新")
            return .dismiss
        }

        LogManager.shared.info("更新已准备好，开始重启安装")
        UpdateManager.shared.markReadyToInstall()
        return .install
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        LogManager.shared.info("正在安装更新 | 应用已退出: \(applicationTerminated)")
        UpdateManager.shared.markInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        LogManager.shared.info("更新安装完成 | 已重启: \(relaunched)")
    }

    func dismissUpdateInstallation() {
        LogManager.shared.info("更新流程已结束")
    }
}
