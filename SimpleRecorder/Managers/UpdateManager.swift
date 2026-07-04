import AppKit
import Foundation
import Sparkle

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private let userDriver = DirectInstallUpdateUserDriver()
    private lazy var updater = SPUUpdater(
        hostBundle: Bundle.main,
        applicationBundle: Bundle.main,
        userDriver: userDriver,
        delegate: self
    )

    private var onStatusChanged: (() -> Void)?
    private(set) var availableVersion: String?
    private(set) var isChecking = false
    private var didStart = false

    var menuTitle: String {
        if isChecking {
            return "正在检查更新..."
        }
        if let availableVersion {
            return "有新版本 \(availableVersion)..."
        }
        return "检查更新..."
    }

    var canSelectMenuItem: Bool {
        guard didStart else { return false }
        return !AudioRecorderManager.shared.isRecording && !isChecking
    }

    func start(onStatusChanged: @escaping () -> Void) {
        self.onStatusChanged = onStatusChanged
        guard !didStart else {
            notifyStatusChanged()
            return
        }
        didStart = true
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
            setChecking(true)
            updater.checkForUpdates()
            return
        }

        guard !updater.sessionInProgress else {
            LogManager.shared.warning("当前无法检查更新 | Sparkle 会话正在进行")
            NSSound.beep()
            return
        }

        setChecking(true)
        LogManager.shared.info("用户手动检查更新")
        updater.checkForUpdateInformation()
    }

    private func setChecking(_ checking: Bool) {
        guard isChecking != checking else { return }
        isChecking = checking
        notifyStatusChanged()
    }

    private func setAvailableVersion(_ version: String?) {
        guard availableVersion != version else {
            setChecking(false)
            return
        }
        availableVersion = version
        isChecking = false
        notifyStatusChanged()
    }

    private func notifyStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
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
        setAvailableVersion(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        LogManager.shared.info("未发现可用更新 | \(error.localizedDescription)")
        setAvailableVersion(nil)
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
        }
        setChecking(false)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        LogManager.shared.warning("更新流程中止 | \(error.localizedDescription)")
        setChecking(false)
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
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        LogManager.shared.info("开始下载更新包")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        LogManager.shared.info("更新包大小 | \(expectedContentLength) bytes")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
    }

    func showDownloadDidStartExtractingUpdate() {
        LogManager.shared.info("更新包下载完成，开始解压")
    }

    func showExtractionReceivedProgress(_ progress: Double) {
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        if AudioRecorderManager.shared.isRecording {
            LogManager.shared.warning("录音中禁止重启安装更新")
            return .dismiss
        }

        LogManager.shared.info("更新已准备好，开始重启安装")
        return .install
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        LogManager.shared.info("正在安装更新 | 应用已退出: \(applicationTerminated)")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        LogManager.shared.info("更新安装完成 | 已重启: \(relaunched)")
    }

    func dismissUpdateInstallation() {
        LogManager.shared.info("更新流程已结束")
    }
}
