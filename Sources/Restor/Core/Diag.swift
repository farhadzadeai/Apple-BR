import Foundation
import AppKit
import CryptoKit

// TEMP-DIAG: temporary production diagnostics for crash/hang investigation.
// Everything in this file (and its call sites, marked TEMP-DIAG) must be
// removed before the production release.
enum Diag {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Apple-BR", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var fileURL: URL { directory.appendingPathComponent("diagnostics.log") }

    private static let queue = DispatchQueue(label: "restor.diag")
    private static let sizeLimit = 512 * 1024
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func install() {
        log("=== launch pid=\(ProcessInfo.processInfo.processIdentifier) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") ===")
        NSSetUncaughtExceptionHandler(restorDiagException)
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, restorDiagSignal)
        }
    }

    // Runs inside a signal handler — keep it minimal and best-effort.
    fileprivate static func signalCrash(_ signum: Int32) {
        let name: String
        switch signum {
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS: name = "SIGBUS"
        case SIGABRT: name = "SIGABRT"
        case SIGILL: name = "SIGILL"
        case SIGFPE: name = "SIGFPE"
        default: name = "SIGTRAP"
        }
        let line = "\(stamp.string(from: Date())) CRASH signal=\(name)(\(signum))\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    // Stable short fingerprint so log entries can be correlated without
    // recording personal values (device names, identifiers, paths).
    static func ref(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static let homeDirectory = NSHomeDirectory()
    private static let usersPattern = try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#)
    private static let tempPattern = try? NSRegularExpression(pattern: #"/var/folders/[^\s]+"#)

    private static func sanitize(_ message: String) -> String {
        var result = message.replacingOccurrences(of: homeDirectory, with: "~")
        for (pattern, replacement) in [(usersPattern, "~/"), (tempPattern, "/tmp/")] {
            guard let pattern else { continue }
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                      withTemplate: replacement)
        }
        return result
    }

    static func log(_ message: String) {
        let thread = Thread.isMainThread ? "main" : "bg"
        let line = "\(stamp.string(from: Date())) [\(thread)] \(sanitize(message))\n"
        queue.async {
            append(line)
        }
    }

    private static func append(_ line: String) {
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > sizeLimit {
            truncate()
        }
        write(line)
    }

    private static func write(_ line: String) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func truncate() {
        guard let data = try? Data(contentsOf: fileURL), data.count > sizeLimit / 2 else { return }
        try? data.suffix(sizeLimit / 2).write(to: fileURL)
    }
}

private func restorDiagSignal(_ signum: Int32) {
    Diag.signalCrash(signum)
}

private func restorDiagException(_ exception: NSException) {
    var text = "CRASH exception=\(exception.name.rawValue) reason=\(exception.reason ?? "-")\n"
    for (index, frame) in exception.callStackSymbols.prefix(40).enumerated() {
        text += "  [\(index)] \(frame)\n"
    }
    Diag.log(text)
}
