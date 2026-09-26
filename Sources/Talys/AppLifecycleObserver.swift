import Cocoa

public final class AppLifecycleObserver: @unchecked Sendable {
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var runningAppsObservation: NSKeyValueObservation?
    /// Apps currently being polled for their first window after launch.
    private var launching: Set<pid_t> = []

    private static let pollInterval = 0.05
    private static let pollAttempts = 60 // ~3s

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
                self?.trackLaunch(of: app)
            }
        }
        workspaceNotificationTokens.append(launchToken)

        // KVO on runningApplications fires as soon as the process exists — well before
        // didLaunchApplication, which only arrives once the app has finished launching.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let pids = (change.newValue ?? []).map(\.processIdentifier)
            DispatchQueue.main.async {
                for pid in pids {
                    guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                    // Policy can still be unset this early; .prohibited apps (daemons) never get windows.
                    if app.activationPolicy != .prohibited {
                        self?.trackLaunch(of: app)
                    }
                }
            }
        }

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
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.activationPolicy == .regular {
                    self?.observe(app: app)
                    TilingController.shared.adoptWindows(of: app)
                    TilingController.shared.revealActivatedApp(app)
                }
                TilingController.shared.syncCurrentFocus()
            }
        }
        workspaceNotificationTokens.append(activateToken)

        print("[AppLifecycleObserver] Active. Monitoring app launches, terminations, and activations.")
    }

    public func stop() {
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceNotificationTokens.removeAll()

        for (_, obs) in observers {
            obs.stop()
        }
        observers.removeAll()
    }

    /// Tries to register the AX observer; returns true once it's in place.
    @discardableResult
    private func observe(app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if observers[pid] != nil { return true }
        guard !app.isTerminated else { return false }

        let observer = AppWindowObserver(pid: pid)
        guard observer.start() else { return false }
        observers[pid] = observer
        return true
    }

    /// Polls a freshly launched app every 50ms until its AX observer is registered and its first
    /// window has been tiled, so the window lands in its tile about as soon as it appears.
    private func trackLaunch(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard launching.insert(pid).inserted else { return }
        poll(app, attempt: 0)
    }

    private func poll(_ app: NSRunningApplication, attempt: Int) {
        let pid = app.processIdentifier
        guard !app.isTerminated, app.activationPolicy != .prohibited else {
            launching.remove(pid)
            return
        }

        let observing = app.activationPolicy == .regular && observe(app: app)
        let windows = observing ? MainActor.assumeIsolated { TilingController.shared.adoptWindows(of: app) } : 0

        if observing && windows > 0 {
            launching.remove(pid)
        } else if attempt < Self.pollAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
                self?.poll(app, attempt: attempt + 1)
            }
        } else {
            launching.remove(pid)
            if !observing && app.activationPolicy == .regular {
                print("[AppLifecycleObserver] Could not observe \(app.localizedName ?? "pid \(pid)"); relying on activation sweeps.")
            }
        }
    }

    private func unobserve(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            observer.stop()
        }
        Task { @MainActor in
            TilingController.shared.removeWindows(for: pid)
        }
    }
}
