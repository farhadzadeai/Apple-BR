import Foundation
import SwiftUI

private func cleanLabel(_ label: String?) -> String {
    guard var label, !label.isEmpty else { return "" }
    for (prefix, suffix) in [("_$!<", ">!$_"), ("_!<", "!_")] {
        if label.hasPrefix(prefix), label.hasSuffix(suffix), label.count > prefix.count + suffix.count {
            label = String(label.dropFirst(prefix.count).dropLast(suffix.count))
            break
        }
    }
    return label
}

extension Backup {
    func loadContacts() -> [Contact] {
        guard let db = database("HomeDomain", "Library/AddressBook/AddressBook.sqlitedb") else { return [] }
        let cols = db.columns("ABPerson")
        func col(_ name: String) -> String { cols.contains(name) ? name : "NULL" }
        var contacts: [Int64: Contact] = [:]
        for row in db.rows("SELECT ROWID AS id, First AS f, Last AS l, Organization AS o, \(col("JobTitle")) AS j, Note AS n, \(col("Birthday")) AS b FROM ABPerson") {
            guard let id = row.int("id") else { continue }
            var contact = Contact(id: id)
            contact.first = row.string("f") ?? ""
            contact.last = row.string("l") ?? ""
            contact.organization = row.string("o") ?? ""
            contact.jobTitle = row.string("j") ?? ""
            contact.note = row.string("n") ?? ""
            contact.birthday = row.double("b").map { Date(timeIntervalSinceReferenceDate: $0) }
            contacts[id] = contact
        }
        var labels: [Int64: String] = [:]
        for row in db.rows("SELECT ROWID AS id, value AS v FROM ABMultiValueLabel") {
            if let id = row.int("id") { labels[id] = cleanLabel(row.string("v")) }
        }
        var addresses: [Int64: [String]] = [:]
        for row in db.rows("SELECT parent_id AS p, value AS v FROM ABMultiValueEntry ORDER BY parent_id, key") {
            if let parent = row.int("p"), let value = row.string("v"), !value.isEmpty { addresses[parent, default: []].append(value) }
        }
        for row in db.rows("SELECT UID AS uid, record_id AS rid, property AS p, label AS lab, value AS v FROM ABMultiValue ORDER BY UID") {
            guard let rid = row.int("rid"), contacts[rid] != nil else { continue }
            let label = row.int("lab").flatMap { labels[$0] } ?? ""
            let value = row.string("v") ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if row.int("p") == 5 {
                if let parts = row.int("uid").flatMap({ addresses[$0] }) {
                    contacts[rid]?.addresses.append(LabeledValue(label: label, value: parts.joined(separator: ", ")))
                }
            } else if trimmed.contains("@") {
                contacts[rid]?.emails.append(LabeledValue(label: label, value: trimmed))
            } else if trimmed.lowercased().hasPrefix("http") || trimmed.lowercased().contains("www.") {
                contacts[rid]?.urls.append(LabeledValue(label: label, value: trimmed))
            } else {
                contacts[rid]?.phones.append(LabeledValue(label: label, value: trimmed))
            }
        }
        return contacts.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func contactImage(_ id: Int64) -> Data? {
        guard let db = database("HomeDomain", "Library/AddressBook/AddressBookImages.sqlitedb") else { return nil }
        return db.rows("SELECT * FROM ABThumbnailImage WHERE record_id=? ORDER BY ROWID DESC LIMIT 1", [id])
            .first?.values.values.compactMap { $0 as? Data }.max { $0.count < $1.count }
    }

    func loadCalls() -> [CallRecord] {
        guard let db = database("HomeDomain", "Library/CallHistoryDB/CallHistory.storedata") else { return [] }
        let cols = db.columns("ZCALLRECORD")
        func col(_ name: String, _ alias: String) -> String { (cols.contains(name) ? name : "NULL") + " AS \(alias)" }
        let sql = "SELECT Z_PK AS id, ZADDRESS AS addr, ZDATE AS date, ZDURATION AS dur, ZORIGINATED AS orig, ZANSWERED AS ans, "
            + [col("ZCALLTYPE", "type"), col("ZNAME", "name"), col("ZLOCATION", "loc"), col("ZSERVICE_PROVIDER", "provider")].joined(separator: ", ")
            + " FROM ZCALLRECORD ORDER BY ZDATE DESC"
        return db.rows(sql).compactMap { row in
            guard let id = row.int("id") else { return nil }
            let address = row.string("addr") ?? ""
            let service: String
            switch row.int("type") {
            case 8: service = "FaceTime Video"
            case 16: service = "FaceTime Audio"
            case 1: service = "Phone"
            default: service = row.string("provider")?.components(separatedBy: ".").last?.capitalized ?? "Phone"
            }
            let name = contactName(for: address) ?? row.string("name") ?? ""
            return CallRecord(id: id, address: address, name: name, date: appleDate(row.double("date")), duration: row.double("dur") ?? 0,
                              kind: row.bool("orig") ? .outgoing : (row.bool("ans") ? .incoming : .missed),
                              service: service, location: row.string("loc") ?? "")
        }
    }

    func loadVoicemail() -> [AudioItem] {
        guard let db = database("HomeDomain", "Library/Voicemail/voicemail.db") else { return [] }
        return db.rows("SELECT ROWID AS id, sender, date, duration, trashed_date AS trashed FROM voicemail ORDER BY date DESC").compactMap { row in
            guard let id = row.int("id") else { return nil }
            let sender = row.string("sender") ?? ""
            return AudioItem(id: "vm-\(id)", title: contactName(for: sender) ?? (sender.isEmpty ? "Unknown Caller" : sender),
                             subtitle: (row.int("trashed") ?? 0) > 0 ? "Deleted" : sender,
                             date: row.double("date").map { Date(timeIntervalSince1970: $0) }, duration: row.double("duration") ?? 0,
                             domain: "HomeDomain", path: "Library/Voicemail/\(id).amr")
        }
    }

    func loadVoiceMemos() -> [AudioItem] {
        let locations = [("AppDomainGroup-group.com.apple.VoiceMemos.shared", "Recordings"), ("MediaDomain", "Media/Recordings")]
        let dbNames = ["CloudRecordings.db", "CloudRecordings.sqlite", "Recordings.db", "Recordings.sqlite"]
        var items: [AudioItem] = []
        for (domain, folder) in locations {
            var found = Set<String>()
            for name in dbNames {
                guard let db = database(domain, "\(folder)/\(name)") else { continue }
                let table = db.hasTable("ZCLOUDRECORDING") ? "ZCLOUDRECORDING" : "ZRECORDING"
                let cols = db.columns(table)
                guard cols.contains("ZPATH") else { continue }
                let title = cols.contains("ZENCRYPTEDTITLE") ? "COALESCE(ZENCRYPTEDTITLE, ZCUSTOMLABEL)" : "ZCUSTOMLABEL"
                for row in db.rows("SELECT Z_PK AS id, \(title) AS title, ZDATE AS date, ZDURATION AS dur, ZPATH AS path FROM \(table) ORDER BY ZDATE DESC") {
                    guard let file = row.string("path").map({ ($0 as NSString).lastPathComponent }), !found.contains(file) else { continue }
                    found.insert(file)
                    items.append(AudioItem(id: "\(domain)/\(file)", title: row.string("title") ?? file, subtitle: file,
                                           date: appleDate(row.double("date")), duration: row.double("dur") ?? 0,
                                           domain: domain, path: "\(folder)/\(file)"))
                }
            }
            for entry in entries(domain: domain, under: folder) where entry.flags == 1 {
                let file = entry.name
                guard ["m4a", "qta", "caf"].contains((file as NSString).pathExtension.lowercased()), !found.contains(file) else { continue }
                found.insert(file)
                items.append(AudioItem(id: "\(domain)/\(file)", title: (file as NSString).deletingPathExtension, subtitle: file,
                                       date: record(for: entry)?.lastModified, duration: 0, domain: domain, path: entry.path))
            }
        }
        return items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func loadNotes() -> [Note] {
        var notes: [Note] = []
        if let db = database("AppDomainGroup-group.com.apple.notes", "NoteStore.sqlite") {
            let cols = db.columns("ZICCLOUDSYNCINGOBJECT")
            func first(_ names: [String]) -> String { names.first(where: cols.contains).map { "n.\($0)" } ?? "NULL" }
            let folder = cols.contains("ZTITLE2") ? "f.ZTITLE2" : "NULL"
            let sql = """
                SELECT n.Z_PK AS id, n.ZTITLE1 AS title, n.ZSNIPPET AS snippet, \(folder) AS folder,
                \(first(["ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"])) AS created, \(first(["ZMODIFICATIONDATE1"])) AS modified,
                \(first(["ZISPASSWORDPROTECTED"])) AS locked
                FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
                WHERE n.ZNOTEDATA IS NOT NULL ORDER BY modified DESC
                """
            for row in db.rows(sql) {
                guard let id = row.int("id") else { continue }
                notes.append(Note(id: id, title: row.string("title") ?? "Untitled", snippet: row.string("snippet") ?? "",
                                  folder: row.string("folder") ?? "Notes", created: appleDate(row.double("created")),
                                  modified: appleDate(row.double("modified")), locked: row.bool("locked"), legacyBody: nil))
            }
        }
        if let db = database("HomeDomain", "Library/Notes/notes.sqlite") {
            let sql = "SELECT n.Z_PK AS id, n.ZTITLE AS title, n.ZSUMMARY AS snippet, n.ZCREATIONDATE AS created, n.ZMODIFICATIONDATE AS modified, b.ZCONTENT AS body FROM ZNOTE n LEFT JOIN ZNOTEBODY b ON b.ZOWNER = n.Z_PK ORDER BY n.ZMODIFICATIONDATE DESC"
            for row in db.rows(sql) {
                guard let id = row.int("id") else { continue }
                let html = row.string("body") ?? ""
                let body = html.replacingOccurrences(of: "<br[^>]*>|</div>|</p>", with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                notes.append(Note(id: -id, title: row.string("title") ?? "Untitled", snippet: row.string("snippet") ?? "", folder: "On My iPhone",
                                  created: appleDate(row.double("created")), modified: appleDate(row.double("modified")), locked: false, legacyBody: body))
            }
        }
        return notes
    }

    func noteBody(_ note: Note) -> String {
        if let body = note.legacyBody { return body }
        if note.locked { return "This note is password protected on the device and cannot be displayed." }
        guard let db = database("AppDomainGroup-group.com.apple.notes", "NoteStore.sqlite"),
              let data = db.rows("SELECT ZDATA AS d FROM ZICNOTEDATA WHERE ZNOTE=?", [note.id]).first?.data("d"),
              let raw = gunzip(data) else {
            return note.snippet
        }
        if let document = Protobuf.field(2, in: raw), let content = Protobuf.field(3, in: document), let text = Protobuf.field(2, in: content),
           let decoded = String(data: text, encoding: .utf8) {
            return decoded.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        return Protobuf.longestText(in: raw)?.replacingOccurrences(of: "\u{FFFC}", with: "") ?? note.snippet
    }

    func loadCalendar() -> [CalendarEvent] {
        guard let db = database("HomeDomain", "Library/Calendar/Calendar.sqlitedb") else { return [] }
        let sql = """
            SELECT i.ROWID AS id, i.summary AS title, i.start_date AS s, i.end_date AS e, i.all_day AS allday, i.description AS notes,
            c.title AS cal, l.title AS loc
            FROM CalendarItem i LEFT JOIN Calendar c ON c.ROWID = i.calendar_id LEFT JOIN Location l ON l.ROWID = i.location_id
            WHERE i.summary IS NOT NULL ORDER BY i.start_date DESC
            """
        return db.rows(sql).compactMap { row in
            guard let id = row.int("id") else { return nil }
            func date(_ key: String) -> Date? { row.double(key).map { Date(timeIntervalSinceReferenceDate: $0) } }
            return CalendarEvent(id: id, title: row.string("title") ?? "", start: date("s"), end: date("e"), allDay: row.bool("allday"),
                                 calendar: row.string("cal") ?? "", location: row.string("loc") ?? "", notes: row.string("notes") ?? "")
        }
    }

    func loadSafariHistory() -> [WebItem] {
        for (domain, path) in [("AppDomain-com.apple.mobilesafari", "Library/Safari/History.db"), ("HomeDomain", "Library/Safari/History.db")] {
            guard let db = database(domain, path) else { continue }
            let sql = "SELECT v.id AS id, i.url AS url, v.title AS title, v.visit_time AS t, i.visit_count AS n FROM history_visits v JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC"
            let items = db.rows(sql).compactMap { row -> WebItem? in
                guard let id = row.int("id"), let url = row.string("url") else { return nil }
                return WebItem(id: id, title: row.string("title") ?? "", url: url, date: appleDate(row.double("t")), detail: "\(row.int("n") ?? 1) visits")
            }
            if !items.isEmpty { return items }
        }
        return []
    }

    func loadBookmarks(readingList: Bool) -> [WebItem] {
        guard let db = database("HomeDomain", "Library/Safari/Bookmarks.db") else { return [] }
        let cols = db.columns("bookmarks")
        let deleted = cols.contains("deleted") ? "WHERE deleted = 0" : ""
        let rows = db.rows("SELECT id, title, url, type, parent, \(cols.contains("special_id") ? "special_id" : "0") AS special FROM bookmarks \(deleted) ORDER BY parent, \(cols.contains("order_index") ? "order_index" : "id")")
        var folders: [Int64: (title: String, parent: Int64, special: Int64)] = [:]
        for row in rows where row.int("type") == 1 {
            if let id = row.int("id") { folders[id] = (row.string("title") ?? "", row.int("parent") ?? 0, row.int("special") ?? 0) }
        }
        func location(_ start: Int64) -> (path: String, reading: Bool) {
            var names: [String] = []
            var reading = false
            var current = start
            var depth = 0
            while let folder = folders[current], depth < 32 {
                if folder.special == 3 || folder.title == "com.apple.ReadingList" { reading = true }
                else if !folder.title.isEmpty, folder.title != "Root" { names.insert(folder.title == "BookmarksBar" ? "Favorites" : folder.title, at: 0) }
                current = folder.parent
                depth += 1
            }
            return (names.joined(separator: " › "), reading)
        }
        return rows.compactMap { row in
            guard row.int("type") == 0, let id = row.int("id"), let url = row.string("url"), !url.isEmpty else { return nil }
            let place = location(row.int("parent") ?? 0)
            guard place.reading == readingList else { return nil }
            return WebItem(id: id, title: row.string("title") ?? "", url: url, date: nil, detail: place.path)
        }
    }

    func loadApps() -> [AppItem] {
        var counts: [String: Int] = [:]
        for domain in domains() where domain.name.hasPrefix("AppDomain-") {
            counts[String(domain.name.dropFirst("AppDomain-".count))] = domain.count
        }
        var metadata: [String: [String: Any]] = [:]
        let metaRows = manifest.rows("SELECT domain AS d, relativePath AS p FROM Files WHERE flags=1 AND relativePath LIKE '%iTunesMetadata.plist' ORDER BY LENGTH(relativePath)")
        for row in metaRows {
            guard let domain = row.string("d"), let path = row.string("p"), metadata[domain] == nil,
                  let entry = self.entry(domain, path), let url = localURL(entry),
                  let data = try? Data(contentsOf: url),
                  let meta = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
            metadata[domain] = meta
        }
        let details = info.info["Applications"] as? [String: Any] ?? [:]
        var ids = Set(info.info["Installed Applications"] as? [String] ?? [])
        ids.formUnion((info.manifest["Applications"] as? [String: Any] ?? [:]).keys)
        ids.formUnion(counts.keys)
        return ids.map { id in
            var item = AppItem(bundleID: id, name: id.components(separatedBy: ".").last ?? id, version: "", vendor: "", fileCount: counts[id] ?? 0)
            if let meta = metadata["AppDomain-\(id)"] {
                item.name = meta["itemName"] as? String ?? item.name
                item.version = meta["bundleShortVersionString"] as? String ?? meta["bundleVersion"] as? String ?? ""
                item.vendor = meta["artistName"] as? String ?? ""
            } else if let entry = details[id] as? [String: Any], let data = entry["iTunesMetadata"] as? Data,
                      let meta = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                item.name = meta["itemName"] as? String ?? item.name
                item.version = meta["bundleShortVersionString"] as? String ?? meta["bundleVersion"] as? String ?? ""
                item.vendor = meta["artistName"] as? String ?? ""
            }
            return item
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func appleAccount() -> String? {
        guard let db = database("HomeDomain", "Library/Accounts/Accounts3.sqlite") else { return nil }
        let sql = "SELECT a.ZUSERNAME AS u, t.ZIDENTIFIER AS t FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON t.Z_PK = a.ZACCOUNTTYPE WHERE a.ZUSERNAME LIKE '%@%' ORDER BY t.ZIDENTIFIER"
        let rows = db.rows(sql)
        return rows.first { ($0.string("t") ?? "").contains("Apple") }?.string("u")
            ?? rows.first { ($0.string("t") ?? "").contains("iTunes") }?.string("u")
            ?? rows.first?.string("u")
    }

    func storageBreakdown() -> [StorageSlice] {
        lock.lock()
        if let cachedSlices {
            lock.unlock()
            return cachedSlices
        }
        lock.unlock()
        var totals: [String: Int64] = [:]
        for entry in allFiles() {
            let category: String
            if entry.domain == "CameraRollDomain" { category = "Photos" }
            else if entry.domain.hasPrefix("AppDomain") { category = "Apps" }
            else if entry.domain == "MediaDomain" { category = "Media" }
            else { category = "System & Other" }
            totals[category, default: 0] += diskSize(entry)
        }
        let colors: [(String, Color)] = [("Photos", .pink), ("Apps", .blue), ("Media", .orange), ("System & Other", .gray)]
        let slices = colors.compactMap { name, color in
            totals[name].flatMap { $0 > 0 ? StorageSlice(name: name, bytes: $0, color: color) : nil }
        }
        lock.lock()
        cachedSlices = slices
        lock.unlock()
        return slices
    }

    func deviceInfoRows(account: String?, size: Int64?) -> [LabeledValue] {
        let i = info.info, m = info.manifest, s = info.status
        var rows: [LabeledValue] = []
        func add(_ label: String, _ value: Any?) {
            switch value {
            case let v as String where !v.isEmpty: rows.append(LabeledValue(label: label, value: v))
            case let v as Date: rows.append(LabeledValue(label: label, value: Fmt.date(v)))
            case let v as Bool: rows.append(LabeledValue(label: label, value: v ? "Yes" : "No"))
            case let v as NSNumber: rows.append(LabeledValue(label: label, value: v.stringValue))
            default: break
            }
        }
        add("Apple Account", account)
        add("Latest Backup", info.date)
        add("Name", info.deviceName)
        add("Model", info.productName)
        add("Operating System", "iOS \(info.osVersion)" + (info.buildVersion.isEmpty ? "" : " (\(info.buildVersion))"))
        add("Serial Number", info.serial)
        add("Unique Device ID", info.udid)
        add("Device Class", info.deviceClass)
        add("Model Product Type", info.productType)
        add("Phone Number", i["Phone Number"])
        add("IMEI 1", i["IMEI"])
        add("IMEI 2", i["IMEI 2"])
        add("MEID", i["MEID"])
        add("ICCID", i["ICCID"])
        add("Backup Size", size.map(Fmt.bytes))
        add("Backup Path", info.url.path)
        add("Backup Encrypted", info.isEncrypted)
        add("Passcode Set", m["WasPasscodeSet"])
        add("Full Backup", s["IsFullBackup"])
        add("Backup State", s["BackupState"])
        add("Snapshot State", s["SnapshotState"])
        add("Backup Format Version", s["Version"] ?? m["Version"])
        add("Backup GUID", i["GUID"])
        add("Target Identifier", i["Target Identifier"])
        add("Created With", (i["macOS Version"] as? String).map { "macOS \($0)" } ?? (i["iTunes Version"] as? String).map { "iTunes \($0)" })
        add("Installed Apps", (i["Installed Applications"] as? [String]).map { "\($0.count)" })
        add("Wi-Fi Address", info.lockdown["WiFiAddress"])
        add("Bluetooth Address", info.lockdown["BluetoothAddress"])
        return rows
    }
}

func gunzip(_ data: Data) -> Data? {
    let bytes = [UInt8](data.prefix(10))
    guard bytes.count == 10, bytes[0] == 0x1f, bytes[1] == 0x8b else {
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }
    let flags = bytes[3]
    var offset = 10
    let all = [UInt8](data)
    if flags & 4 != 0, offset + 2 <= all.count { offset += 2 + Int(all[offset]) + Int(all[offset + 1]) << 8 }
    for bit in [UInt8(8), 16] where flags & bit != 0 {
        while offset < all.count, all[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 2 != 0 { offset += 2 }
    guard offset < all.count - 8 else { return nil }
    return try? (Data(all[offset..<all.count - 8]) as NSData).decompressed(using: .zlib) as Data
}

enum Protobuf {
    static func longestText(in data: Data) -> String? {
        var best = ""
        func printable(_ text: String) -> Bool {
            guard text.count > 3 else { return false }
            let bad = text.unicodeScalars.filter { $0.value < 0x20 && $0.value != 0xA && $0.value != 0x9 && $0.value != 0xD }.count
            return bad * 20 < text.count
        }
        func visit(_ blob: Data, _ depth: Int) {
            guard depth < 8, blob.count < 20_000_000 else { return }
            let bytes = [UInt8](blob)
            var i = 0
            func varint() -> UInt64? {
                var result: UInt64 = 0
                var shift: UInt64 = 0
                while i < bytes.count, shift < 64 {
                    let b = bytes[i]
                    i += 1
                    result |= UInt64(b & 0x7f) << shift
                    if b & 0x80 == 0 { return result }
                    shift += 7
                }
                return nil
            }
            while i < bytes.count {
                guard let key = varint() else { return }
                switch key & 7 {
                case 0: guard varint() != nil else { return }
                case 1: i += 8
                case 5: i += 4
                case 2:
                    guard let length = varint(), i + Int(length) <= bytes.count else { return }
                    let slice = Data(bytes[i..<i + Int(length)])
                    i += Int(length)
                    if let text = String(data: slice, encoding: .utf8), printable(text), text.count > best.count { best = text }
                    visit(slice, depth + 1)
                default: return
                }
            }
        }
        visit(data, 0)
        return best.isEmpty ? nil : best
    }

    static func field(_ number: Int, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint(), i + Int(length) <= bytes.count else { return nil }
                if Int(key >> 3) == number { return Data(bytes[i..<i + Int(length)]) }
                i += Int(length)
            default: return nil
            }
        }
        return nil
    }
}
