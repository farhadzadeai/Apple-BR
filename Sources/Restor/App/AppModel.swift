import Foundation
import AppKit
import Observation

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor @Observable
final class Job {
    let title: String
    var detail = ""
    var fraction = 0.0
    let flag = CancelFlag()

    init(title: String) { self.title = title }
}

@MainActor @Observable
final class AppModel {
    var backups: [BackupInfo] = []
    var selected: BackupInfo?
    var backup: Backup?
    var pane: Pane = .overview {
        didSet { Diag.log("pane → \(pane.rawValue)") } // TEMP-DIAG
    }
    var isOpening = false
    var passwordError: String?
    var openError: String?
    var accessDenied = false
    var job: Job?
    var notice: String?
    private var extras: [BackupInfo] = CommandLine.arguments.dropFirst()
        .flatMap { (try? BackupInfo.discover(in: URL(fileURLWithPath: $0))) ?? [] }
    private var customRoots: [URL] = []
    private let bookmarksKey = "customBackupLocations"
    private let lastBackupKey = "lastBackupPath"

    private func storedBookmarks() -> [[String: Any]] {
        UserDefaults.standard.array(forKey: bookmarksKey) as? [[String: Any]] ?? []
    }

    private func resolveBookmark(_ entry: [String: Any]) -> URL? {
        if let data = entry["bookmark"] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if let path = entry["path"] as? String { return URL(fileURLWithPath: path) }
        return nil
    }

    private func rememberRoot(_ url: URL) {
        let standardized = url.standardizedFileURL.path
        _ = url.startAccessingSecurityScopedResource()
        if !customRoots.contains(where: { $0.standardizedFileURL.path == standardized }) { customRoots.append(url) }
        var entries = storedBookmarks().filter { ($0["path"] as? String) != url.path }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            entries.append(["path": url.path, "bookmark": data])
        } else {
            entries.append(["path": url.path])
        }
        UserDefaults.standard.set(entries, forKey: bookmarksKey)
    }

    private func isInside(_ backup: BackupInfo, of root: URL) -> Bool {
        backup.url.path == root.path || backup.url.path.hasPrefix(root.path + "/")
    }

    func refresh() {
        var found: [BackupInfo] = []
        do {
            found = try BackupInfo.discover(in: BackupInfo.defaultDirectory)
            accessDenied = false
        } catch {
            accessDenied = (error as NSError).code == NSFileReadNoPermissionError
        }
        for entry in storedBookmarks() {
            guard let url = resolveBookmark(entry) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            if !customRoots.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { customRoots.append(url) }
            if let list = try? BackupInfo.discover(in: url) { found += list }
        }
        for root in customRoots {
            if let list = try? BackupInfo.discover(in: root) { found += list }
        }
        var seen = Set<String>()
        let merged = (found + extras).filter { seen.insert($0.url.path).inserted }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        backups = merged
        if let current = selected, merged.contains(current) {
            return
        }
        if let last = UserDefaults.standard.string(forKey: lastBackupKey),
           let match = merged.first(where: { $0.url.path == last }) {
            select(match)
        } else if let first = merged.first {
            select(first)
        } else {
            selected = nil
            backup = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = BackupInfo.defaultDirectory
        panel.prompt = "Open Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocation(url)
    }

    func handleDrop(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                openLocation(url)
                return
            }
        }
        notice = urls.isEmpty ? nil : "The dropped item is not an iPhone backup. Drop a .backup package or a folder that contains one."
    }

    func openLocation(_ url: URL) {
        rememberRoot(url)
        refresh()
        if let match = backups.first(where: { isInside($0, of: url) }) {
            select(match)
        } else {
            notice = "No iPhone backup was found in “\(url.lastPathComponent)”. Choose the .backup package or a folder that contains it (Manifest.plist and Manifest.db)."
        }
    }

    func select(_ info: BackupInfo) {
        Diag.log("select backup: \(Diag.ref(info.deviceName)) encrypted=\(info.isEncrypted)") // TEMP-DIAG
        UserDefaults.standard.set(info.url.path, forKey: lastBackupKey)
        backup = nil
        selected = info
        pane = .overview
        passwordError = nil
        openError = nil
        if !info.isEncrypted { open(password: nil) }
    }

    func open(password: String?) {
        guard let info = selected, !isOpening else { return }
        Diag.log("open start: \(Diag.ref(info.deviceName))") // TEMP-DIAG
        let started = Date() // TEMP-DIAG
        isOpening = true
        passwordError = nil
        openError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Backup(info: info, password: password) } }.value
            isOpening = false
            guard selected == info else { return }
            switch result {
            case .success(let opened):
                backup = opened
                Diag.log("open ok in \(Int(Date().timeIntervalSince(started) * 1000))ms") // TEMP-DIAG
            case .failure(let error):
                Diag.log("open failed in \(Int(Date().timeIntervalSince(started) * 1000))ms: \(error.localizedDescription)") // TEMP-DIAG
                if info.isEncrypted { passwordError = error.localizedDescription } else { openError = error.localizedDescription }
            }
        }
    }

    func lock() {
        guard let info = selected else { return }
        select(info)
    }

    func run(_ title: String, reveal: URL? = nil, _ work: @escaping @Sendable (ProgressHandler) throws -> String?) {
        guard job == nil else { return }
        let job = Job(title: title)
        self.job = job
        let flag = job.flag
        let handler: ProgressHandler = { fraction, detail in
            Task { @MainActor in
                job.fraction = fraction
                job.detail = detail
            }
            return !flag.isCancelled
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work(handler) } }.value
            self.job = nil
            switch result {
            case .success(let message):
                if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                notice = message
            case .failure(let error):
                if !(error is ExportCancelled) { notice = error.localizedDescription }
            }
        }
    }

    func airdrop(_ title: String, _ work: @escaping @Sendable (ProgressHandler) throws -> [URL]) {
        guard job == nil else { return }
        let job = Job(title: title)
        self.job = job
        let flag = job.flag
        let handler: ProgressHandler = { fraction, detail in
            Task { @MainActor in
                job.fraction = fraction
                job.detail = detail
            }
            return !flag.isCancelled
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work(handler) } }.value
            self.job = nil
            switch result {
            case .success(let urls) where !urls.isEmpty:
                AirDrop.share(urls)
            case .success:
                notice = "No files were ready to share."
            case .failure(let error):
                if !(error is ExportCancelled) { notice = error.localizedDescription }
            }
        }
    }

    func exportAll() {
        guard let backup, let folder = Panels.chooseFolder() else { return }
        let root = Exporter.uniqueURL(in: folder, name: Exporter.safeName(backup.info.deviceName) + " Export")
        run("Exporting All Data", reveal: root) { progress in
            try Exporter.exportAll(backup, to: root, progress: progress)
            return nil
        }
    }

    func exportBackupAsFolder() {
        guard let backup, let folder = Panels.chooseFolder() else { return }
        let root = Exporter.uniqueURL(in: folder, name: Exporter.safeName(backup.info.deviceName) + " Backup Files")
        run("Exporting Backup as Folder", reveal: root) { progress in
            let failed = try Exporter.exportBackupTree(backup, entries: backup.allFiles(), to: root, progress: progress)
            return failed > 0 ? "\(failed) files could not be exported." : nil
        }
    }
}
