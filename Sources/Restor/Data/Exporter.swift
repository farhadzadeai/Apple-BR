import Foundation
import AppKit

typealias ProgressHandler = @Sendable (_ fraction: Double, _ detail: String) -> Bool

struct ExportCancelled: LocalizedError {
    var errorDescription: String? { "The export was cancelled." }
}

@MainActor
enum Panels {
    static func chooseFolder(prompt: String = "Export Here") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveText(_ text: @autoclosure () -> String, name: String) {
        guard let url = save(name: name) else { return }
        do {
            try text().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum Exporter {
    static func csv(_ header: [String], _ rows: [[String]]) -> String {
        func cell(_ value: String) -> String {
            value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return "\u{FEFF}" + ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t\0")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }

    static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return url
    }

    static func vcard(_ contacts: [Contact]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        func type(_ label: String) -> String {
            let cleaned = label.uppercased().filter { $0.isLetter && $0.isASCII }
            return cleaned.isEmpty ? "" : ";TYPE=\(cleaned)"
        }
        var out = ""
        for contact in contacts {
            out += "BEGIN:VCARD\r\nVERSION:3.0\r\n"
            out += "N:\(escape(contact.last));\(escape(contact.first));;;\r\nFN:\(escape(contact.title))\r\n"
            if !contact.organization.isEmpty { out += "ORG:\(escape(contact.organization))\r\n" }
            if !contact.jobTitle.isEmpty { out += "TITLE:\(escape(contact.jobTitle))\r\n" }
            for phone in contact.phones { out += "TEL\(type(phone.label)):\(phone.value)\r\n" }
            for email in contact.emails { out += "EMAIL\(type(email.label)):\(email.value)\r\n" }
            for url in contact.urls { out += "URL\(type(url.label)):\(url.value)\r\n" }
            for address in contact.addresses { out += "ADR\(type(address.label)):;;\(escape(address.value));;;;\r\n" }
            if let birthday = contact.birthday { out += "BDAY:\(ISO8601DateFormatter.string(from: birthday, timeZone: .gmt, formatOptions: [.withFullDate]))\r\n" }
            if !contact.note.isEmpty { out += "NOTE:\(escape(contact.note))\r\n" }
            out += "END:VCARD\r\n"
        }
        return out
    }

    static func transcript(_ conversation: Conversation, _ messages: [ChatMessage]) -> String {
        var out = "\(conversation.title) (\(conversation.identifier))\n\(String(repeating: "=", count: 40))\n\n"
        for message in messages {
            out += "[\(Fmt.date(message.date))] \(message.fromMe ? "Me" : message.sender): \(message.text)"
            for file in message.attachments { out += " <\(file.name)>" }
            out += "\n"
        }
        return out
    }

    static func callsCSV(_ calls: [CallRecord]) -> String {
        csv(["Date", "Name", "Number", "Direction", "Service", "Duration", "Location"],
            calls.map { [Fmt.date($0.date), $0.name, $0.address, $0.kind.rawValue, $0.service, Fmt.duration($0.duration), $0.location] })
    }

    static func webCSV(_ items: [WebItem]) -> String {
        csv(["Title", "URL", "Date", "Detail"], items.map { [$0.title, $0.url, Fmt.date($0.date), $0.detail] })
    }

    static func calendarCSV(_ events: [CalendarEvent]) -> String {
        csv(["Title", "Start", "End", "All Day", "Calendar", "Location", "Notes"],
            events.map { [$0.title, Fmt.date($0.start), Fmt.date($0.end), $0.allDay ? "Yes" : "No", $0.calendar, $0.location, $0.notes] })
    }

    static func appsCSV(_ apps: [AppItem]) -> String {
        csv(["Name", "Bundle ID", "Version", "Developer", "Files in Backup"], apps.map { [$0.name, $0.bundleID, $0.version, $0.vendor, "\($0.fileCount)"] })
    }

    static func infoText(_ rows: [LabeledValue]) -> String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") + "\n"
    }

    static func exportFiles(_ backup: Backup, _ files: [(entry: ManifestEntry, destination: URL)], progress: ProgressHandler) throws -> Int {
        var failed = 0
        for (index, file) in files.enumerated() {
            if index % 5 == 0, !progress(Double(index) / Double(max(files.count, 1)), file.entry.name) { throw ExportCancelled() }
            do { try backup.extract(file.entry, to: file.destination) } catch { failed += 1 }
        }
        return failed
    }

    static func exportPhotos(_ backup: Backup, _ assets: [PhotoAsset], to directory: URL, progress: ProgressHandler) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, asset) in assets.enumerated() {
            if !progress(Double(index) / Double(max(assets.count, 1)), asset.filename) { throw ExportCancelled() }
            guard asset.hasOriginal, let entry = backup.entry("CameraRollDomain", asset.path) else { continue }
            try? backup.extract(entry, to: uniqueURL(in: directory, name: asset.filename))
        }
    }

    static func exportAudio(_ backup: Backup, _ items: [AudioItem], to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in items {
            guard let entry = backup.entry(item.domain, item.path) else { continue }
            let ext = (item.path as NSString).pathExtension
            let stamp = item.date.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withFullDate]) + " " } ?? ""
            try? backup.extract(entry, to: uniqueURL(in: directory, name: safeName(stamp + item.title) + "." + ext))
        }
    }

    static func exportChats(_ source: ChatSource, to directory: URL, progress: ProgressHandler, range: ClosedRange<Double>) throws {
        guard source.isAvailable else { return }
        let conversations = source.conversations()
        guard !conversations.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, conversation) in conversations.enumerated() {
            let fraction = range.lowerBound + (range.upperBound - range.lowerBound) * Double(index) / Double(conversations.count)
            if !progress(fraction, conversation.title) { throw ExportCancelled() }
            let text = transcript(conversation, source.messages(in: conversation))
            try? text.write(to: uniqueURL(in: directory, name: safeName(conversation.title) + ".txt"), atomically: true, encoding: .utf8)
        }
    }

    static func exportAll(_ backup: Backup, to root: URL, progress: ProgressHandler) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ text: String, _ name: String) { try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func step(_ fraction: Double, _ name: String) throws { if !progress(fraction, name) { throw ExportCancelled() } }

        try step(0.01, "Device info")
        write(infoText(backup.deviceInfoRows(account: backup.appleAccount(), size: nil)), "Device Info.txt")
        try step(0.03, "Contacts")
        let contacts = backup.contacts()
        if !contacts.isEmpty { write(vcard(contacts), "Contacts.vcf") }
        try step(0.05, "Call history")
        let calls = backup.loadCalls()
        if !calls.isEmpty { write(callsCSV(calls), "Call History.csv") }
        try step(0.07, "Calendar")
        let events = backup.loadCalendar()
        if !events.isEmpty { write(calendarCSV(events), "Calendar.csv") }
        try step(0.09, "Safari")
        let history = backup.loadSafariHistory()
        if !history.isEmpty { write(webCSV(history), "Safari History.csv") }
        let bookmarks = backup.loadBookmarks(readingList: false)
        if !bookmarks.isEmpty { write(webCSV(bookmarks), "Safari Bookmarks.csv") }
        let reading = backup.loadBookmarks(readingList: true)
        if !reading.isEmpty { write(webCSV(reading), "Safari Reading List.csv") }
        write(appsCSV(backup.loadApps()), "Apps.csv")

        try step(0.11, "Notes")
        let notes = backup.loadNotes()
        if !notes.isEmpty {
            let directory = root.appendingPathComponent("Notes")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for note in notes {
                let text = "\(note.title)\n\(note.folder) — \(Fmt.date(note.modified))\n\n\(backup.noteBody(note))\n"
                try? text.write(to: uniqueURL(in: directory, name: safeName(note.title) + ".txt"), atomically: true, encoding: .utf8)
            }
        }

        try exportChats(SMSSource(backup: backup), to: root.appendingPathComponent("Messages"), progress: progress, range: 0.14...0.24)
        try exportChats(WhatsAppSource(backup: backup, business: false), to: root.appendingPathComponent("WhatsApp"), progress: progress, range: 0.24...0.32)
        try exportChats(WhatsAppSource(backup: backup, business: true), to: root.appendingPathComponent("WhatsApp Business"), progress: progress, range: 0.32...0.36)

        try step(0.36, "Voicemail")
        let voicemail = backup.loadVoicemail()
        if !voicemail.isEmpty { exportAudio(backup, voicemail, to: root.appendingPathComponent("Voicemail")) }
        try step(0.38, "Voice memos")
        let memos = backup.loadVoiceMemos()
        if !memos.isEmpty { exportAudio(backup, memos, to: root.appendingPathComponent("Voice Memos")) }

        let photos = backup.loadPhotos().assets.filter(\.hasOriginal)
        if !photos.isEmpty {
            try exportPhotos(backup, photos, to: root.appendingPathComponent("Photos")) { fraction, detail in
                progress(0.4 + fraction * 0.6, detail)
            }
        }
    }

    static func exportBackupTree(_ backup: Backup, entries: [ManifestEntry], to root: URL, progress: ProgressHandler) throws -> Int {
        let files = entries.filter { $0.flags == 1 && !$0.path.components(separatedBy: "/").contains("..") && !$0.domain.contains("/") }.map { entry in
            (entry: entry, destination: root.appendingPathComponent(entry.domain).appendingPathComponent(entry.path))
        }
        return try exportFiles(backup, files, progress: progress)
    }
}
