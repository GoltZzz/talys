import Cocoa

public final class AppLifecycleObserver: @unchecked Sendable {
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceNotificationTokens: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            observe(app: app)
        }

        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            if app.activationPolicy == .regular {
                self?.observe(app: app)
            }
        }
        workspaceNotificationTokens.append(launchToken)

        let termToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.unobserve(pid: app.processIdentifier)
        }
        workspaceNotificationTokens.append(termToken)

        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            TilingController.shared.syncCurrentFocus()
        }
        workspaceNotificationTokens.append(activateToken)

        print("[AppLifecycleObserver] Active. Monitoring app launches, terminations, and activations.")
    }

    public func stop() {
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceNotificationTokens.removeAll()

        for (_, obs) in observers {
            obs.stop()
        }
        observers.removeAll()
    }

    private func observe(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        let observer = AppWindowObserver(pid: pid)
        observer.start()
        observers[pid] = observer
    }

    private func unobserve(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            observer.stop()
        }
        TilingController.shared.removeWindows(for: pid)
    }
}
