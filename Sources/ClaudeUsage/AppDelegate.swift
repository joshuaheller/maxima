import AppKit
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var statusItemController: StatusItemController?
    private let notifications = NotificationManager()
    private let log = Logger(subsystem: AppInfo.subsystem, category: "app")

    private static let didRegisterLoginItemKey = "didRegisterLoginItem"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(model: model)

        notifications.requestAuthorization()
        registerLoginItemIfNeeded()
        observeWake()

        model.start()
        log.info("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Wake

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refresh(reason: "wake")
            }
        }
    }

    // MARK: Login item

    /// Registers as a login item exactly once, and only for a copy that actually
    /// lives in /Applications (registering a build-directory path would break as
    /// soon as the build directory moves).
    private func registerLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didRegisterLoginItemKey) else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard Bundle.main.bundlePath.hasPrefix("/Applications") else {
            log.info("not registering login item: not installed in /Applications")
            return
        }

        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: Self.didRegisterLoginItemKey)
            log.info("registered as login item, status=\(String(describing: SMAppService.mainApp.status), privacy: .public)")
        } catch {
            log.error("login item registration failed: \(error.localizedDescription, privacy: .public)")
        }

        if SMAppService.mainApp.status == .requiresApproval {
            log.info("login item requires approval — enable \(AppInfo.displayName, privacy: .public) in System Settings › General › Login Items")
        }
    }
}
