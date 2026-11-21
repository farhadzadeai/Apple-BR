import Foundation

private func decodeTypedString(_ data: Data) -> String? {
    guard var bytes = data.range(of: Data("NSString".utf8)).map({ [UInt8](data[$0.upperBound...]) }) else { return nil }
    let limit = min(bytes.count, 12)
    var i = 0
    while i < limit, bytes[i] != 0x2B { i += 1 }
    guard i < limit else { return nil }
    i += 1
    guard i < bytes.count else { return nil }
    var length = Int(bytes[i])
    i += 1
    if length == 0x81, i + 2 <= bytes.count {
        length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
        i += 2
    } else if length == 0x82, i + 4 <= bytes.count {
        length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        i += 4
    }
    guard length > 0, i + length <= bytes.count else { return nil }
    bytes = Array(bytes[i..<i + length])
    if let text = String(bytes: bytes, encoding: .utf8), !text.contains("\0") { return text }
    if let text = String(bytes: bytes, encoding: .utf16BigEndian) { return text }
    return String(bytes: bytes, encoding: .utf16LittleEndian)
}

private func decodeAttributedBody(_ data: Data?) -> String? {
    guard let data else { return nil }
    return decodeTypedString(data)
}

private func clean(_ text: String?) -> String {
    (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

final class SMSSource: ChatSource, @unchecked Sendable {
    private let backup: Backup
    private let db: SQLiteDB?
    private let hasBody: Bool

    init(backup: Backup) {
        self.backup = backup
        db = backup.database("HomeDomain", "Library/SMS/sms.db")
        hasBody = db?.columns("message").contains("attributedBody") ?? false
    }

    var isAvailable: Bool { db != nil }
    private var body: String { hasBody ? "m.attributedBody" : "NULL" }

    func conversations() -> [Conversation] {
        guard let db else { return [] }
        let started = Date() // TEMP-DIAG
        let sql = """
            SELECT c.ROWID AS id, c.chat_identifier AS ident, c.display_name AS name, c.service_name AS service, l.text AS text, l.body AS body, l.d AS last
            FROM chat c LEFT JOIN (
                SELECT j.chat_id AS cid, m.text AS text, \(body) AS body, MAX(m.date) AS d
                FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id GROUP BY j.chat_id
            ) l ON l.cid = c.ROWID
            WHERE l.d IS NOT NULL ORDER BY l.d DESC
            """
        let result: [Conversation] = db.rows(sql).compactMap { row in
            guard let id = row.int("id") else { return nil }
            let ident = row.string("ident") ?? ""
            let name = row.string("name") ?? ""
            var snippet = clean(row.string("text"))
            if snippet.isEmpty { snippet = clean(decodeAttributedBody(row.data("body"))) }
            return Conversation(id: id, title: name.isEmpty ? (backup.contactName(for: ident) ?? ident) : name, identifier: ident,
                                service: row.string("service") ?? "", lastDate: appleDate(row.double("last")),
                                snippet: snippet.isEmpty ? "Attachment" : snippet)
        }
        Diag.log("sms conversations n=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))") // TEMP-DIAG
        return result
    }

    func messages(in conversation: Conversation) -> [ChatMessage] {
        guard let db else { return [] }
        let started = Date() // TEMP-DIAG
        var attachments: [Int64: [ChatAttachment]] = [:]
        let attachmentSQL = """
            SELECT maj.message_id AS mid, a.filename AS file, a.mime_type AS mime, a.transfer_name AS name
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (SELECT message_id FROM chat_message_join WHERE chat_id = ?)
            """
        for row in db.rows(attachmentSQL, [conversation.id]) {
            guard let mid = row.int("mid"), var file = row.string("file") else { continue }
            if file.hasPrefix("~/") { file = String(file.dropFirst(2)) }
            else if let range = file.range(of: "/var/mobile/") { file = String(file[range.upperBound...]) }
            let resolved = backup.resolveMedia("MediaDomain", file) ?? (domain: "MediaDomain", path: file)
            attachments[mid, default: []].append(ChatAttachment(domain: resolved.domain, path: resolved.path,
                                                                name: row.string("name") ?? (file as NSString).lastPathComponent,
                                                                mime: row.string("mime") ?? ""))
        }
        let sql = """
            SELECT m.ROWID AS id, m.text AS text, \(body) AS body, m.date AS date, m.date_read AS readdate, m.is_from_me AS me, h.id AS sender
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ? ORDER BY m.date
            """
        let result: [ChatMessage] = db.rows(sql, [conversation.id]).compactMap { row in
            guard let id = row.int("id") else { return nil }
            var text = clean(row.string("text"))
            if text.isEmpty { text = clean(decodeAttributedBody(row.data("body"))) }
            let files = attachments[id] ?? []
            guard !text.isEmpty || !files.isEmpty else { return nil }
            let sender = row.string("sender") ?? ""
            return ChatMessage(id: id, text: text, date: appleDate(row.double("date")), readDate: appleDate(row.double("readdate")),
                               fromMe: row.bool("me"), sender: backup.contactName(for: sender) ?? sender, attachments: files)
        }
        Diag.log("sms messages conv=\(conversation.id) n=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))") // TEMP-DIAG
        return result
    }
}

final class WhatsAppSource: ChatSource, @unchecked Sendable {
    private let backup: Backup
    private let domain: String
    private let db: SQLiteDB?

    init(backup: Backup, business: Bool) {
        self.backup = backup
        domain = business ? "AppDomainGroup-group.net.whatsapp.WhatsAppSMB.shared" : "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
        db = backup.database(domain, "ChatStorage.sqlite")
        if let db {
            let started = Date() // TEMP-DIAG
            if db.hasTable("ZWAMESSAGE") {
                _ = db.rows("CREATE INDEX IF NOT EXISTS idx_zwasession ON ZWAMESSAGE(ZCHATSESSION)")
            }
            if db.hasTable("ZWAMEDIAITEM") {
                _ = db.rows("CREATE INDEX IF NOT EXISTS idx_zwamedia ON ZWAMEDIAITEM(ZMESSAGE)")
            }
            Diag.log("whatsapp indexes ready in \(Int(Date().timeIntervalSince(started) * 1000))ms") // TEMP-DIAG
        }
    }

    var isAvailable: Bool { db != nil }

    private func handle(_ jid: String?) -> String {
        guard let jid, let user = jid.components(separatedBy: "@").first else { return "" }
        return user.allSatisfy(\.isNumber) && jid.hasSuffix("s.whatsapp.net") ? "+\(user)" : user
    }

    func conversations() -> [Conversation] {
        guard let db else { return [] }
        let started = Date() // TEMP-DIAG
        let cols = db.columns("ZWACHATSESSION")
        let text = cols.contains("ZLASTMESSAGETEXT") ? "s.ZLASTMESSAGETEXT" : "(SELECT m.ZTEXT FROM ZWAMESSAGE m WHERE m.Z_PK = s.ZLASTMESSAGE)"
        let filter = cols.contains("ZREMOVED") ? "AND IFNULL(s.ZREMOVED, 0) = 0" : ""
        let sql = "SELECT s.Z_PK AS id, s.ZCONTACTJID AS jid, s.ZPARTNERNAME AS name, s.ZLASTMESSAGEDATE AS last, \(text) AS text FROM ZWACHATSESSION s WHERE s.ZCONTACTJID IS NOT NULL \(filter) ORDER BY s.ZLASTMESSAGEDATE DESC"
        let result: [Conversation] = db.rows(sql).compactMap { row in
            guard let id = row.int("id") else { return nil }
            let jid = row.string("jid") ?? ""
            let name = row.string("name") ?? ""
            return Conversation(id: id, title: name.isEmpty ? handle(jid) : name, identifier: handle(jid),
                                service: jid.hasSuffix("@g.us") ? "Group" : "WhatsApp", lastDate: appleDate(row.double("last")), snippet: clean(row.string("text")))
        }
        Diag.log("whatsapp conversations n=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))") // TEMP-DIAG
        return result
    }

    func messages(in conversation: Conversation) -> [ChatMessage] {
        guard let db else { return [] }
        let started = Date() // TEMP-DIAG
        let memberCols = db.columns("ZWAGROUPMEMBER")
        let hasMembers = memberCols.contains("ZCONTACTNAME") && db.columns("ZWAMESSAGE").contains("ZGROUPMEMBER")
        let sql = """
            SELECT m.Z_PK AS id, m.ZTEXT AS text, m.ZMESSAGEDATE AS date, m.ZISFROMME AS me, m.ZFROMJID AS jid, m.ZPUSHNAME AS push,
            mi.ZMEDIALOCALPATH AS media, mi.ZTITLE AS caption, \(hasMembers ? "g.ZCONTACTNAME" : "NULL") AS member
            FROM ZWAMESSAGE m LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            \(hasMembers ? "LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER" : "")
            WHERE m.ZCHATSESSION = ? ORDER BY m.ZMESSAGEDATE
            """
        var seen = Set<Int64>()
        let result: [ChatMessage] = db.rows(sql, [conversation.id]).compactMap { row in
            guard let id = row.int("id"), seen.insert(id).inserted else { return nil }
            var text = clean(row.string("text"))
            var files: [ChatAttachment] = []
            if let media = row.string("media"), !media.isEmpty {
                let path = media.hasPrefix("Message/") ? media : "Message/" + media
                let resolved = backup.resolveMedia(domain, path) ?? (domain: domain, path: path)
                files.append(ChatAttachment(domain: resolved.domain, path: resolved.path, name: (media as NSString).lastPathComponent, mime: ""))
                if text.isEmpty { text = clean(row.string("caption")) }
            }
            guard !text.isEmpty || !files.isEmpty else { return nil }
            let member = row.string("member") ?? ""
            let sender = !member.isEmpty ? member : (conversation.service == "Group" ? (row.string("push") ?? "") : conversation.title)
            return ChatMessage(id: id, text: text, date: appleDate(row.double("date")), readDate: nil, fromMe: row.bool("me"),
                               sender: sender.isEmpty ? handle(row.string("jid")) : sender, attachments: files)
        }
        Diag.log("whatsapp messages conv=\(conversation.id) n=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))") // TEMP-DIAG
        return result
    }
}
