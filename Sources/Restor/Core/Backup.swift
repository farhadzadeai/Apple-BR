import Foundation

@objc(RestorMBFile)
final class MBFileRecord: NSObject, NSCoding {
    let size: Int64
    let encryptionKey: Data?
    let lastModified: Date?

    init?(coder: NSCoder) {
        size = coder.decodeInt64(forKey: "Size")
        encryptionKey = coder.decodeObject(forKey: "EncryptionKey") as? Data
        let modified = coder.decodeInt64(forKey: "LastModified")
        lastModified = modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil
    }

    func encode(with coder: NSCoder) {}

    static func parse(_ blob: Data) -> MBFileRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(MBFileRecord.self, forClassName: "MBFile")
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? MBFileRecord
    }
}

struct ManifestEntry: Identifiable, Hashable {
    let fileID: String
    let domain: String
    let path: String
    let flags: Int64

    var id: String { fileID }
    var isDirectory: Bool { flags == 2 }
    var name: String { path.isEmpty ? domain : (path as NSString).lastPathComponent }
}

struct BackupInfo: Identifiable, Hashable {
    let url: URL
    let info: [String: Any]
    let manifest: [String: Any]
    let status: [String: Any]

    var id: String { url.path }
    static func == (a: BackupInfo, b: BackupInfo) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    var lockdown: [String: Any] { manifest["Lockdown"] as? [String: Any] ?? [:] }
    private func text(_ infoKey: String, _ lockdownKey: String) -> String? {
        info[infoKey] as? String ?? lockdown[lockdownKey] as? String
    }

    var deviceName: String { text("Device Name", "DeviceName") ?? url.lastPathComponent }
    var productType: String { text("Product Type", "ProductType") ?? "" }
    var productName: String { info["Product Name"] as? String ?? productType }
    var osVersion: String { text("Product Version", "ProductVersion") ?? "" }
    var buildVersion: String { text("Build Version", "BuildVersion") ?? "" }
    var serial: String { text("Serial Number", "SerialNumber") ?? "" }
    var udid: String { text("Unique Identifier", "UniqueDeviceID") ?? url.lastPathComponent }
    var date: Date? { info["Last Backup Date"] as? Date ?? manifest["Date"] as? Date ?? status["Date"] as? Date }
    var isEncrypted: Bool { manifest["IsEncrypted"] as? Bool ?? false }
    var deviceClass: String {
        let prefix = productType.prefix { $0.isLetter }
        return prefix.isEmpty ? "iOS Device" : String(prefix)
    }

    static func load(_ url: URL) -> BackupInfo? {
        func plist(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(name)) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        guard let manifest = plist("Manifest.plist"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Manifest.db").path) else { return nil }
        return BackupInfo(url: url, info: plist("Info.plist") ?? [:], manifest: manifest, status: plist("Status.plist") ?? [:])
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MobileSync/Backup")

    static func discover(in directory: URL) throws -> [BackupInfo] {
        if let single = load(directory) { return [single] }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var results: [BackupInfo] = []
        var queue: [(url: URL, depth: Int)] = children.map { ($0, 1) }
        var scanned = 0
        while let (url, depth) = queue.popLast() {
            if scanned > 300 { break }
            scanned += 1
            if let info = load(url) {
                results.append(info)
                continue
            }
            let name = url.lastPathComponent
            guard depth < 3, url.pathExtension != "backup", !name.hasPrefix(".") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  let grandchildren = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            queue += grandchildren.map { ($0, depth + 1) }
        }
        return results.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

final class Backup: @unchecked Sendable {
    let info: BackupInfo
    let manifest: SQLiteDB
    let keybag: Keybag?
    let cacheDir: URL

    let lock = NSLock()
    private var databases: [String: SQLiteDB?] = [:]
    private var cachedContacts: [Contact]?
    private var cachedNames: [String: String]?
    var cachedPhotos: PhotoLibrary?
    var cachedSlices: [StorageSlice]?
    private(set) lazy var thumbnails = Thumbnailer(backup: self)

    var isEncrypted: Bool { keybag != nil }

    static let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Restor")

    init(info: BackupInfo, password: String?) throws {
        Diag.log("backup init start: \(Diag.ref(info.deviceName)) encrypted=\(info.isEncrypted)") // TEMP-DIAG
        let initStart = Date() // TEMP-DIAG
        self.info = info
        let fm = FileManager.default
        cacheDir = Self.cacheRoot.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: cacheDir.appendingPathComponent("files"), withIntermediateDirectories: true)
        let source = info.url.appendingPathComponent("Manifest.db")
        let local = cacheDir.appendingPathComponent("Manifest.db")
        do {
            if info.isEncrypted {
                guard let bag = info.manifest["BackupKeyBag"] as? Data, let manifestKey = info.manifest["ManifestKey"] as? Data else {
                    throw BackupError.invalid("encryption keys are missing from Manifest.plist")
                }
                let keybag = try Keybag(data: bag, password: password ?? "")
                let dbData = try Data(contentsOf: source, options: .mappedIfSafe)
                guard let key = keybag.unwrap(manifestKey) else {
                    throw BackupError.invalid("The manifest key could not be unwrapped")
                }
                let magic = Data("SQLite format 3".utf8)
                var plain = Crypto.aesCBCDecrypt(key: key, data: dbData)
                if plain?.starts(with: magic) != true, dbData.count > 48 {
                    plain = Crypto.aesCBCDecrypt(key: key, iv: Data(dbData.prefix(16)), data: Data(dbData.dropFirst(16)))
                }
                guard let plain, plain.starts(with: magic) else {
                    throw BackupError.invalid("Manifest.db could not be decrypted — the backup password may be incorrect")
                }
                try plain.write(to: local)
                self.keybag = keybag
            } else {
                try fm.copyItem(at: source, to: local)
                keybag = nil
            }
            manifest = try SQLiteDB(path: local.path)
            guard manifest.hasTable("Files") else { throw BackupError.invalid("Manifest.db has no file index") }
            let indexStart = Date() // TEMP-DIAG
            _ = manifest.rows("CREATE INDEX IF NOT EXISTS FilesDomainPath ON Files(domain, relativePath)")
            Diag.log("manifest domain/path index ready in \(Int(Date().timeIntervalSince(indexStart) * 1000))ms") // TEMP-DIAG
        } catch {
            try? fm.removeItem(at: cacheDir)
            throw error
        }
        Diag.log("backup init done in \(Int(Date().timeIntervalSince(initStart) * 1000))ms") // TEMP-DIAG
    }

    deinit { try? FileManager.default.removeItem(at: cacheDir) }

    private func makeEntry(_ row: Row) -> ManifestEntry? {
        guard let id = row.string("fileID") else { return nil }
        return ManifestEntry(fileID: id, domain: row.string("domain") ?? "", path: row.string("relativePath") ?? "", flags: row.int("flags") ?? 1)
    }

    func entry(_ domain: String, _ path: String) -> ManifestEntry? {
        manifest.rows("SELECT fileID, domain, relativePath, flags FROM Files WHERE domain=? AND relativePath=? LIMIT 1", [domain, path])
            .first.flatMap(makeEntry)
    }

    func entries(domain: String, under prefix: String? = nil) -> [ManifestEntry] {
        var sql = "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain=?"
        var params: [Any?] = [domain]
        if let prefix {
            sql += " AND (relativePath=? OR relativePath LIKE ? ESCAPE '\\')"
            let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            params += [prefix, escaped + "/%"]
        }
        return manifest.rows(sql, params).compactMap(makeEntry)
    }

    func allFiles() -> [ManifestEntry] {
        manifest.rows("SELECT fileID, domain, relativePath, flags FROM Files WHERE flags=1").compactMap(makeEntry)
    }

    func domains() -> [(name: String, count: Int)] {
        manifest.rows("SELECT domain, COUNT(*) AS n FROM Files GROUP BY domain ORDER BY domain").compactMap { row in
            row.string("domain").map { ($0, Int(row.int("n") ?? 0)) }
        }
    }

    func record(for entry: ManifestEntry) -> MBFileRecord? {
        manifest.rows("SELECT file FROM Files WHERE fileID=?", [entry.fileID]).first?.data("file").flatMap(MBFileRecord.parse)
    }

    func sourceURL(_ fileID: String) -> URL {
        info.url.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID)
    }

    func diskSize(_ entry: ManifestEntry) -> Int64 {
        var st = stat()
        return stat(sourceURL(entry.fileID).path, &st) == 0 ? Int64(st.st_size) : 0
    }

    func extract(_ entry: ManifestEntry, to destination: URL) throws {
        let started = Date() // TEMP-DIAG
        defer {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if ms > 500 { Diag.log("slow extract \(ms)ms \(entry.domain)/\(entry.path)") } // TEMP-DIAG
        }
        let fm = FileManager.default
        let source = sourceURL(entry.fileID)
        guard fm.fileExists(atPath: source.path) else { throw BackupError.missingFile(entry.path) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".restor-\(UUID().uuidString)")
        do {
            if let keybag {
                guard let record = record(for: entry), let wrapped = record.encryptionKey, let key = keybag.unwrap(wrapped) else {
                    throw BackupError.invalid("no key for \(entry.path)")
                }
                try Crypto.decryptFile(key: key, from: source, to: temp, size: record.size)
            } else {
                try fm.copyItem(at: source, to: temp)
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    func localURL(_ entry: ManifestEntry, materialize: Bool = false) -> URL? {
        let fm = FileManager.default
        if keybag == nil && !materialize {
            let source = sourceURL(entry.fileID)
            return fm.fileExists(atPath: source.path) ? source : nil
        }
        let ext = (entry.path as NSString).pathExtension
        let local = cacheDir.appendingPathComponent("files").appendingPathComponent(ext.isEmpty ? entry.fileID : "\(entry.fileID).\(ext)")
        if fm.fileExists(atPath: local.path) { return local }
        return (try? extract(entry, to: local)) != nil ? local : nil
    }

    func localURL(_ domain: String, _ path: String, materialize: Bool = false) -> URL? {
        entry(domain, path).flatMap { localURL($0, materialize: materialize) }
    }

    func database(_ domain: String, _ path: String) -> SQLiteDB? {
        let key = domain + "|" + path
        lock.lock()
        defer { lock.unlock() }
        if let cached = databases[key] { return cached }
        var db: SQLiteDB?
        if let entry = entry(domain, path), let url = localURL(entry, materialize: true) {
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if !FileManager.default.fileExists(atPath: wal.path), let walEntry = self.entry(domain, path + "-wal") {
                try? extract(walEntry, to: wal)
            }
            let started = Date() // TEMP-DIAG
            db = try? SQLiteDB(path: url.path)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            Diag.log("db open \(domain)/\(path) bytes=\(bytes) ms=\(Int(Date().timeIntervalSince(started) * 1000)) ok=\(db != nil)") // TEMP-DIAG
        }
        databases[key] = db
        return db
    }

    func contacts() -> [Contact] {
        lock.lock()
        if let cachedContacts {
            lock.unlock()
            return cachedContacts
        }
        lock.unlock()
        let loaded = loadContacts()
        var names: [String: String] = [:]
        for contact in loaded where !contact.displayName.isEmpty {
            for value in contact.phones + contact.emails { names[Self.normalize(value.value)] = contact.displayName }
        }
        lock.lock()
        cachedContacts = loaded
        cachedNames = names
        lock.unlock()
        return loaded
    }

    func resolveMedia(_ domain: String, _ path: String) -> (domain: String, path: String)? {
        if entry(domain, path) != nil { return (domain, path) }
        if entry(domain, "Message/" + path) != nil { return (domain, "Message/" + path) }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let rows = manifest.rows("SELECT relativePath AS p FROM Files WHERE domain=? AND relativePath LIKE ? ESCAPE '\\' LIMIT 10",
                                 [domain, "%/" + escaped])
        guard let best = rows.compactMap({ $0.string("p") }).min(by: { $0.count < $1.count }) else { return nil }
        return (domain, best)
    }

    func contactName(for handle: String?) -> String? {
        guard let handle, !handle.isEmpty else { return nil }
        _ = contacts()
        lock.lock()
        defer { lock.unlock() }
        return cachedNames?[Self.normalize(handle)]
    }

    static func normalize(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : handle.lowercased()
    }
}
