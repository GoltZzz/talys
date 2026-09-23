import Foundation

public enum ShellRunner {
    /// Keeps running processes alive until they exit so they get reaped instead of lingering as zombies.
    private final class Registry: @unchecked Sendable {
        private var running: Set<Process> = []
        private let lock = NSLock()
        func insert(_ p: Process) { lock.lock(); running.insert(p); lock.unlock() }
        func remove(_ p: Process) { lock.lock(); running.remove(p); lock.unlock() }
    }
    private static let registry = Registry()

    /// Launched from a LaunchAgent, Talys inherits a minimal PATH; add the usual user tool locations.
    private static let extraPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.cargo/bin",
    ]

    /// Runs `command` via /bin/sh without waiting for it to finish.
    public static func run(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPath + [existing]).joined(separator: ":")
        process.environment = env

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { registry.remove($0) }
        registry.insert(process)

        do {
            try process.run()
            print("[Exec] \(command)")
        } catch {
            registry.remove(process)
            print("[Exec] Failed to run \"\(command)\": \(error)")
        }
    }
}
