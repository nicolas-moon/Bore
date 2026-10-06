import Foundation
import OSLog

/// Append-only text log at `~/Library/Logs/Bore/Bore.log`.
///
/// Every message also goes to OSLog via `BoreLogger`, but the unified log is
/// hard to find after the fact; this file is the thing a user can actually
/// open, read, and attach to a bug report. Only lifecycle events, concise
/// error reasons, and raw ssh stderr are written. Never credentials.
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()

    let directory: URL
    let fileURL: URL

    private let queue = DispatchQueue(label: "com.nmoon.Bore.filelog")
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 2 * 1024 * 1024
    private let timestamp: DateFormatter

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        directory = library.appendingPathComponent("Logs/Bore", isDirectory: true)
        fileURL = directory.appendingPathComponent("Bore.log")

        timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        queue.sync { open() }
    }

    /// Writes one line: `<timestamp> [<category>] <level> <message>`.
    func write(level: String, category: String, _ message: String) {
        let stamp = timestamp.string(from: Date())
        queue.async { [self] in
            rotateIfNeeded()
            let line = "\(stamp) [\(category)] \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            handle?.write(data)
        }
    }

    /// Blocks until all queued writes have reached the file. Call before exit.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: - File handling (always on `queue`)

    private func open() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: fileURL)
            fh.seekToEndOfFile()
            handle = fh
        } catch {
            // If the log file cannot be opened, Bore still works; it just stops
            // persisting. OSLog remains available.
            handle = nil
        }
    }

    private func rotateIfNeeded() {
        guard let fh = handle, fh.offsetInFile > maxBytes else { return }
        try? fh.close()
        handle = nil

        let previous = directory.appendingPathComponent("Bore.log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        open()
    }
}

/// Thin wrapper that sends each message to both OSLog and `FileLog`.
///
/// Messages are plain strings and are logged as public; callers must never
/// interpolate secrets.
struct BoreLogger {
    let category: String
    private let os: Logger

    init(category: String) {
        self.category = category
        os = Logger(subsystem: "com.nmoon.Bore", category: category)
    }

    func notice(_ message: String) {
        os.notice("\(message, privacy: .public)")
        FileLog.shared.write(level: "NOTICE", category: category, message)
    }

    func warning(_ message: String) {
        os.warning("\(message, privacy: .public)")
        FileLog.shared.write(level: "WARN", category: category, message)
    }

    func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        FileLog.shared.write(level: "ERROR", category: category, message)
    }

    /// Raw ssh stderr. Logged at debug level in OSLog (not persisted there) but
    /// always written to the file, since it is the most useful diagnostic.
    func ssh(_ line: String) {
        os.debug("ssh: \(line, privacy: .public)")
        FileLog.shared.write(level: "stderr", category: "ssh", line)
    }
}
