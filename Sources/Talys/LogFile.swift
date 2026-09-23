import Foundation

/// Sends everything Talys prints to ~/Library/Logs/Talys.log, timestamped, so a `.app` launch (whose stdout goes
/// nowhere) still leaves a record of what happened. Output keeps reaching the terminal too when run from one.
/// The file rolls over to Talys.old.log past 1 MB.
final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    private static let maxBytes: UInt64 = 1_000_000

    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Talys.log")
    private var oldURL: URL { url.deletingPathExtension().appendingPathExtension("old.log") }

    private var file: FileHandle?
    private var terminal: FileHandle?
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    private let drained = DispatchSemaphore(value: 0)
    private let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    /// Redirects stdout and stderr into the log. Call once, before anything is printed.
    func start() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
        openFile()

        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)
        if isatty(originalStdout) != 0 {
            terminal = FileHandle(fileDescriptor: originalStdout, closeOnDealloc: false)
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        setvbuf(stdout, nil, _IOLBF, 0)

        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let thread = Thread { [self] in pump(reader) }
        thread.name = "talys.log"
        thread.start()
    }

    /// Writes out whatever is still buffered and puts stdout/stderr back. Call on the way out.
    func stop() {
        guard originalStdout >= 0 else { return }
        fflush(stdout)
        fflush(stderr)
        dup2(originalStdout, STDOUT_FILENO)
        dup2(originalStderr, STDERR_FILENO)
        _ = drained.wait(timeout: .now() + 1)
    }

    private func pump(_ reader: FileHandle) {
        var pending = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            terminal?.write(chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                write(line: pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { write(line: pending) }
        try? file?.close()
        drained.signal()
    }

    private func write(line: Data) {
        var out = Data("\(timestamp.string(from: Date())) ".utf8)
        out.append(line)
        out.append(UInt8(ascii: "\n"))
        file?.write(out)
        if let size = try? file?.offset(), size > Self.maxBytes {
            try? file?.close()
            rotateIfNeeded()
            openFile()
        }
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > Self.maxBytes else { return }
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }

    private func openFile() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }
}
