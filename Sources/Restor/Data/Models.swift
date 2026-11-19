import Foundation
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview, photos, messages, whatsapp, whatsappBusiness, calls, voicemail, notes, voiceMemos
    case contacts, calendar, safariHistory, bookmarks, readingList, apps, files

    var id: String { rawValue }
    static let data: [Pane] = [.photos, .messages, .whatsapp, .whatsappBusiness, .calls, .voicemail, .notes, .voiceMemos,
                               .contacts, .calendar, .safariHistory, .bookmarks, .readingList]
    static let tools: [Pane] = [.apps, .files]

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .photos: return "Photos"
        case .messages: return "Messages"
        case .whatsapp: return "WhatsApp"
        case .whatsappBusiness: return "WA Business"
        case .calls: return "Call History"
        case .voicemail: return "Voicemail"
        case .notes: return "Notes"
        case .voiceMemos: return "Voice Memos"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .safariHistory: return "Safari History"
        case .bookmarks: return "Bookmarks"
        case .readingList: return "Reading List"
        case .apps: return "Apps"
        case .files: return "File Browser"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "info.circle.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .messages: return "message.fill"
        case .whatsapp: return "phone.bubble.fill"
        case .whatsappBusiness: return "briefcase.fill"
        case .calls: return "phone.fill"
        case .voicemail: return "recordingtape"
        case .notes: return "note.text"
        case .voiceMemos: return "waveform"
        case .contacts: return "person.crop.circle.fill"
        case .calendar: return "calendar"
        case .safariHistory: return "clock.fill"
        case .bookmarks: return "bookmark.fill"
        case .readingList: return "eyeglasses"
        case .apps: return "square.grid.2x2.fill"
        case .files: return "folder.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: return Theme.accent
        case .photos: return .pink
        case .messages, .calls: return .green
        case .whatsapp, .whatsappBusiness: return Color(red: 0.15, green: 0.83, blue: 0.4)
        case .voicemail, .contacts, .safariHistory, .bookmarks, .readingList: return .blue
        case .notes: return .yellow
        case .voiceMemos, .calendar: return .red
        case .apps: return .indigo
        case .files: return .teal
        }
    }
}

struct LabeledValue: Hashable {
    let label: String
    let value: String
}

struct Contact: Identifiable, Hashable {
    let id: Int64
    var first = ""
    var last = ""
    var organization = ""
    var jobTitle = ""
    var note = ""
    var birthday: Date?
    var phones: [LabeledValue] = []
    var emails: [LabeledValue] = []
    var urls: [LabeledValue] = []
    var addresses: [LabeledValue] = []

    var displayName: String {
        let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? organization : name
    }
    var title: String { displayName.isEmpty ? (phones.first?.value ?? emails.first?.value ?? "No Name") : displayName }
}

struct Conversation: Identifiable, Hashable {
    let id: Int64
    var title: String
    var identifier: String
    var service: String
    var lastDate: Date?
    var snippet: String
}

struct ChatAttachment: Hashable {
    let domain: String
    let path: String
    let name: String
    let mime: String

    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isImage: Bool { mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff"].contains(ext) }
    var isVideo: Bool { mime.hasPrefix("video/") || ["mov", "mp4", "m4v"].contains(ext) }
}

struct ChatMessage: Identifiable, Hashable {
    let id: Int64
    var text: String
    var date: Date?
    var readDate: Date?
    var fromMe: Bool
    var sender: String
    var attachments: [ChatAttachment] = []
}

protocol ChatSource: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func conversations() -> [Conversation]
    func messages(in conversation: Conversation) -> [ChatMessage]
}

struct CallRecord: Identifiable, Hashable {
    enum Kind: String { case incoming = "Incoming", outgoing = "Outgoing", missed = "Missed" }
    let id: Int64
    var address: String
    var name: String
    var date: Date?
    var duration: Double
    var kind: Kind
    var service: String
    var location: String
}

struct AudioItem: Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var date: Date?
    var duration: Double
    var domain: String
    var path: String
}

struct Note: Identifiable, Hashable {
    let id: Int64
    var title: String
    var snippet: String
    var folder: String
    var created: Date?
    var modified: Date?
    var locked: Bool
    var legacyBody: String?
}

struct CalendarEvent: Identifiable, Hashable {
    let id: Int64
    var title: String
    var start: Date?
    var end: Date?
    var allDay: Bool
    var calendar: String
    var location: String
    var notes: String
}

struct WebItem: Identifiable, Hashable {
    let id: Int64
    var title: String
    var url: String
    var date: Date?
    var detail: String
}

struct AppItem: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var version: String
    var vendor: String
    var fileCount: Int
}

struct PhotoAsset: Identifiable, Hashable {
    let id: Int64
    var path: String
    var thumbPath: String?
    var hasOriginal: Bool
    var filename: String
    var date: Date?
    var isVideo = false
    var subtype: Int64 = 0
    var favorite = false
    var hidden = false
    var trashed = false
    var selfie = false
    var portrait = false
    var screenshot = false
    var raw = false
    var width: Int64 = 0
    var height: Int64 = 0
    var duration: Double = 0

    var isLive: Bool { subtype == 2 }
    var isPanorama: Bool { subtype == 1 }
}

struct PhotoAlbum: Identifiable, Hashable {
    let id: Int64
    let title: String
    let assets: Set<Int64>
}

struct PhotoLibrary {
    var assets: [PhotoAsset] = []
    var albums: [PhotoAlbum] = []
}

struct StorageSlice: Identifiable {
    var id: String { name }
    let name: String
    let bytes: Int64
    let color: Color
}

enum Fmt {
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func date(_ date: Date?) -> String { date.map(dateTime.string) ?? "" }
    static func short(_ date: Date?) -> String {
        guard let date else { return "" }
        return Calendar.current.isDateInToday(date) ? time.string(from: date) : day.string(from: date)
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func isRTL(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFEFC).contains(scalar.value) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }
}

func appleDate(_ value: Double?) -> Date? {
    guard var value, value > 0 else { return nil }
    if value > 1e11 { value /= 1e9 }
    return Date(timeIntervalSinceReferenceDate: value)
}
