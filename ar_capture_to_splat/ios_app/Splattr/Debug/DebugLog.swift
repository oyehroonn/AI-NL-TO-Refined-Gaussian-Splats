//
//  DebugLog.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  Singleton structured logger. Every call mirrors to:
//   1. NSLog — visible live in Xcode console.
//   2. A per-session file at
//      `FileManager.temporaryDirectory/splattr_debug_<timestamp>.log`,
//      shareable via "Share Debug Log" (UIActivityViewController) so the
//      user can AirDrop a real, complete log to a Mac in three taps —
//      no Xcode connection required, no log scrolling.
//
//  Format (one line per record):
//   "2026-05-14T18:31:07.412Z  warn  [bake]  selectBestView: 47% sentinel"
//
//  Threading: a single serial DispatchQueue serializes all writes so
//  records from main + background bake threads interleave cleanly.
//
//  Why file-backed: every grayscale-atlas attempt to date relied on
//  scrolling Xcode console output or recalling what a user saw mid-bake.
//  A real on-disk log means the post-mortem reads from data instead of
//  memory.
//

import Foundation
import os.log

enum DebugLogLevel: String {
    case info    = "info"
    case warn    = "warn"
    case error   = "error"
    /// GPU-side observations (command-buffer timings, errors).
    case gpu     = "gpu"
    /// Thermal / power observations.
    case thermal = "thermal"

    /// One-character ASCII for compact NSLog mirror lines.
    var glyph: String {
        switch self {
        case .info:    return "·"
        case .warn:    return "!"
        case .error:   return "X"
        case .gpu:     return "G"
        case .thermal: return "T"
        }
    }
}

final class DebugLog {

    static let shared = DebugLog()

    /// Absolute URL of the active log file for this session. Pass to a
    /// UIActivityViewController to share off-device.
    let logFileURL: URL

    private let writeQueue = DispatchQueue(label: "splattr.debug.log",
                                            qos: .utility)
    private let isoFormatter: ISO8601DateFormatter
    private var handle: FileHandle?

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,
                                    .withFractionalSeconds]
        self.isoFormatter = formatter

        // One log file per process launch — keeps sessions separate so a
        // bug repro can be matched 1:1 to a single file the user shared.
        let stamp = formatter
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("splattr_debug_\(stamp).log")
        self.logFileURL = url

        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: url)

        // Header — bake-investigations always start by asking "what build?
        // what date?". Stamp it once so the answer is unambiguous.
        let device = ProcessInfo.processInfo.hostName
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        writeRaw("=== Splattr debug log === device=\(device) os=\(osVer)\n")
    }

    // MARK: - Public API

    /// One-line structured log. Tag groups records by subsystem
    /// ("bake", "candidate", "scn") so a `grep` on the shared file isolates
    /// just the bake records.
    func log(_ level: DebugLogLevel,
             tag: String,
             _ message: @autoclosure () -> String) {
        let line = "\(isoFormatter.string(from: Date()))  " +
                   "\(level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  " +
                   "[\(tag)]  \(message())\n"
        writeRaw(line)
        // NSLog mirror is intentionally terser — Xcode console line noise
        // is real, especially during a bake's hundreds of GPU records.
        NSLog("[Splattr/\(level.glyph)/\(tag)] %@", message())
    }

    /// Convenience wrappers — same overload pattern as os_log.
    func info(_ tag: String, _ message: @autoclosure () -> String) {
        log(.info, tag: tag, message())
    }
    func warn(_ tag: String, _ message: @autoclosure () -> String) {
        log(.warn, tag: tag, message())
    }
    func error(_ tag: String, _ message: @autoclosure () -> String) {
        log(.error, tag: tag, message())
    }
    func gpu(_ tag: String, _ message: @autoclosure () -> String) {
        log(.gpu, tag: tag, message())
    }
    func thermal(_ tag: String, _ message: @autoclosure () -> String) {
        log(.thermal, tag: tag, message())
    }

    // MARK: - Internal

    private func writeRaw(_ line: String) {
        writeQueue.async { [weak self] in
            guard let self = self, let h = self.handle else { return }
            if let data = line.data(using: .utf8) {
                try? h.write(contentsOf: data)
            }
        }
    }

    /// Flush + fsync. Call before sharing the log file so the consumer
    /// sees every record written up to "now."
    func flush() {
        writeQueue.sync { [weak self] in
            try? self?.handle?.synchronize()
        }
    }
}
