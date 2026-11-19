import Foundation
import AppKit
import AVFoundation
import ImageIO

private let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi"]
private let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "gif", "tiff", "dng", "webp", "bmp"]

extension Backup {
    func loadPhotos() -> PhotoLibrary {
        lock.lock()
        if let cachedPhotos {
            lock.unlock()
            return cachedPhotos
        }
        lock.unlock()
        var library = PhotoLibrary()
        let domain = "CameraRollDomain"
        var originals = Set<String>()
        var thumbs: [String: String] = [:]
        let thumbRoot = "Media/PhotoData/Thumbnails/V2/"
        let sql = "SELECT relativePath AS p FROM Files WHERE domain=? AND flags=1 AND (relativePath LIKE 'Media/DCIM/%' OR relativePath LIKE 'Media/PhotoData/Thumbnails/V2/%')"
        for row in manifest.rows(sql, [domain]) {
            guard let path = row.string("p") else { continue }
            if path.hasPrefix(thumbRoot) {
                var key = (String(path.dropFirst(thumbRoot.count)) as NSString).deletingLastPathComponent
                if key.hasPrefix("Media/") { key = String(key.dropFirst(6)) }
                thumbs[key] = path
            } else {
                originals.insert(path)
            }
        }

        if let db = database(domain, "Media/PhotoData/Photos.sqlite") {
            let table = db.hasTable("ZASSET") ? "ZASSET" : "ZGENERICASSET"
            let cols = db.columns(table)
            func col(_ name: String, _ alias: String, _ fallback: String = "NULL") -> String {
                (cols.contains(name) ? "a.\(name)" : fallback) + " AS \(alias)"
            }
            var sql = "SELECT a.Z_PK AS id, a.ZDIRECTORY AS dir, a.ZFILENAME AS file, a.ZDATECREATED AS date, a.ZKIND AS kind, "
                + [col("ZKINDSUBTYPE", "sub", "0"), col("ZFAVORITE", "fav", "0"), col("ZHIDDEN", "hidden", "0"), col("ZTRASHEDSTATE", "trashed", "0"),
                   col("ZWIDTH", "w", "0"), col("ZHEIGHT", "h", "0"), col("ZDURATION", "dur", "0"), col("ZDEPTHTYPE", "depth", "0"),
                   col("ZUNIFORMTYPEIDENTIFIER", "uti"), col("ZISDETECTEDSCREENSHOT", "shot", "0")].joined(separator: ", ")
            let extra = db.columns("ZADDITIONALASSETATTRIBUTES")
            if extra.contains("ZCAMERACAPTUREDEVICE"), extra.contains("ZASSET") {
                sql += ", x.ZCAMERACAPTUREDEVICE AS cam FROM \(table) a LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK"
            } else {
                sql += ", 0 AS cam FROM \(table) a"
            }
            sql += " WHERE a.ZFILENAME IS NOT NULL AND a.ZDIRECTORY IS NOT NULL ORDER BY a.ZDATECREATED DESC"
            for row in db.rows(sql) {
                guard let id = row.int("id"), let dir = row.string("dir"), let file = row.string("file") else { continue }
                let rel = dir.hasPrefix("Media/") ? String(dir.dropFirst(6)) : dir
                let key = "\(rel)/\(file)"
                let path = "Media/\(key)"
                let hasOriginal = originals.contains(path)
                guard hasOriginal || thumbs[key] != nil else { continue }
                var asset = PhotoAsset(id: id, path: path, thumbPath: thumbs[key], hasOriginal: hasOriginal, filename: file, date: appleDate(row.double("date")))
                let ext = (file as NSString).pathExtension.lowercased()
                asset.isVideo = row.int("kind") == 1
                asset.subtype = row.int("sub") ?? 0
                asset.favorite = row.bool("fav")
                asset.hidden = row.bool("hidden")
                asset.trashed = row.bool("trashed")
                asset.selfie = row.int("cam") == 1
                asset.portrait = row.bool("depth")
                asset.screenshot = row.bool("shot") || asset.subtype == 10
                asset.raw = ext == "dng" || (row.string("uti") ?? "").contains("raw")
                asset.width = row.int("w") ?? 0
                asset.height = row.int("h") ?? 0
                asset.duration = row.double("dur") ?? 0
                library.assets.append(asset)
            }

            let albumTables = db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'Z_*ASSETS'").compactMap { $0.string("name") }
            let albumCols = db.columns("ZGENERICALBUM")
            for joinTable in albumTables {
                let joinCols = db.columns(joinTable)
                guard let albumCol = joinCols.first(where: { $0.hasSuffix("ALBUMS") }), let assetCol = joinCols.first(where: { $0.hasSuffix("ASSETS") }) else { continue }
                var members: [Int64: Set<Int64>] = [:]
                for row in db.rows("SELECT \(albumCol) AS album, \(assetCol) AS asset FROM \(joinTable)") {
                    if let album = row.int("album"), let asset = row.int("asset") { members[album, default: []].insert(asset) }
                }
                let known = Set(library.assets.map(\.id))
                let kindFilter = albumCols.contains("ZKIND") ? " AND ZKIND = 2" : ""
                let found = db.rows("SELECT Z_PK AS id, ZTITLE AS title FROM ZGENERICALBUM WHERE ZTITLE IS NOT NULL\(kindFilter) ORDER BY ZTITLE").compactMap { row -> PhotoAlbum? in
                    guard let id = row.int("id"), let title = row.string("title"), let assets = members[id]?.intersection(known), !assets.isEmpty else { return nil }
                    return PhotoAlbum(id: id, title: title, assets: assets)
                }
                if !found.isEmpty {
                    library.albums = found
                    break
                }
            }
        }

        if library.assets.isEmpty {
            var id: Int64 = 0
            for entry in entries(domain: domain, under: "Media/DCIM") where entry.flags == 1 {
                let ext = (entry.path as NSString).pathExtension.lowercased()
                guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else { continue }
                id += 1
                var asset = PhotoAsset(id: id, path: entry.path, thumbPath: nil, hasOriginal: true, filename: entry.name, date: record(for: entry)?.lastModified)
                asset.isVideo = videoExtensions.contains(ext)
                asset.raw = ext == "dng"
                asset.screenshot = ext == "png"
                library.assets.append(asset)
            }
            library.assets.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        lock.lock()
        cachedPhotos = library
        lock.unlock()
        return library
    }
}

final class Thumbnailer: @unchecked Sendable {
    private unowned let backup: Backup
    private let cache = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()

    init(backup: Backup) {
        self.backup = backup
        cache.countLimit = 3000
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
    }

    func image(domain: String, path: String, maxPixel: Int = 360) async -> NSImage? {
        let key = "\(domain)|\(path)|\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            queue.addOperation { [weak self] in
                guard let self, !Task.isCancelled else { return continuation.resume(returning: nil) }
                let image = self.render(domain: domain, path: path, maxPixel: maxPixel)
                if let image { self.cache.setObject(image, forKey: key as NSString) }
                continuation.resume(returning: image)
            }
        }
    }

    private func render(domain: String, path: String, maxPixel: Int) -> NSImage? {
        let isVideo = videoExtensions.contains((path as NSString).pathExtension.lowercased())
        guard let url = backup.localURL(domain, path, materialize: backup.isEncrypted) else { return nil }
        var cgImage: CGImage?
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}
