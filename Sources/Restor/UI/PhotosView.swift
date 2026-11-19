import SwiftUI
import AppKit
import AVKit
import ImageIO

enum PhotoFilter: Hashable {
    case all, favorites, hidden, deleted, photos, videos, selfies, live, portrait, panoramas, screenshots, raw
    case album(Int64)

    static let library: [PhotoFilter] = [.all, .favorites, .hidden, .deleted]
    static let mediaTypes: [PhotoFilter] = [.photos, .videos, .selfies, .live, .portrait, .panoramas, .screenshots, .raw]

    var title: String {
        switch self {
        case .all: return "All Photos"
        case .favorites: return "Favorites"
        case .hidden: return "Hidden"
        case .deleted: return "Recently Deleted"
        case .photos: return "Standard Photos"
        case .videos: return "Videos"
        case .selfies: return "Selfies"
        case .live: return "Live Photos"
        case .portrait: return "Portrait"
        case .panoramas: return "Panoramas"
        case .screenshots: return "Screenshots"
        case .raw: return "RAW"
        case .album: return "Album"
        }
    }

    var icon: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .favorites: return "heart"
        case .hidden: return "eye.slash"
        case .deleted: return "trash"
        case .photos: return "photo"
        case .videos: return "video"
        case .selfies: return "person.crop.square"
        case .live: return "livephoto"
        case .portrait: return "cube"
        case .panoramas: return "pano"
        case .screenshots: return "camera.viewfinder"
        case .raw: return "r.square"
        case .album: return "rectangle.stack"
        }
    }

    func matches(_ asset: PhotoAsset, albums: [Int64: Set<Int64>]) -> Bool {
        if self == .deleted { return asset.trashed }
        if asset.trashed { return false }
        if self == .hidden { return asset.hidden }
        if asset.hidden { return false }
        switch self {
        case .all: return true
        case .favorites: return asset.favorite
        case .photos: return !asset.isVideo && !asset.screenshot
        case .videos: return asset.isVideo
        case .selfies: return asset.selfie
        case .live: return asset.isLive
        case .portrait: return asset.portrait
        case .panoramas: return asset.isPanorama
        case .screenshots: return asset.screenshot
        case .raw: return asset.raw
        case .album(let id): return albums[id]?.contains(asset.id) ?? false
        default: return false
        }
    }
}

struct DayGroup: Identifiable {
    let id: Date
    let assets: [PhotoAsset]
}

struct PhotosView: View {
    let backup: Backup
    @Environment(AppModel.self) private var model
    @State private var library: PhotoLibrary?
    @State private var filter: PhotoFilter = .all
    @State private var counts: [PhotoFilter: Int] = [:]
    @State private var groups: [DayGroup] = []
    @State private var visibleCount = 0
    @State private var cell: CGFloat = 118
    @State private var selection = Set<Int64>()
    @State private var quickLook: PhotoAsset?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                PaneHeader(pane: .photos, subtitle: library == nil ? "" : "\(visibleCount) items" + (selection.isEmpty ? "" : " · \(selection.count) selected")) {
                    Image(systemName: "photo").font(.caption).foregroundStyle(Theme.dim)
                    Slider(value: $cell, in: 70...240).frame(width: 110).controlSize(.small)
                    Image(systemName: "photo").foregroundStyle(Theme.dim)
                    ExportButton(title: selection.isEmpty ? "Export All" : "Export Selected", action: export)
                        .disabled(visibleCount == 0)
                }
                PaneContainer(items: library?.assets, icon: Pane.photos.icon, emptyTitle: "No Photos") { _ in
                    HStack(spacing: 0) {
                        filters.frame(width: 190)
                        grid
                    }
                }
            }
            if let asset = quickLook {
                QuickLookView(backup: backup, asset: asset) { quickLook = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: quickLook != nil)
        .task {
            let backup = backup
            let loaded = await Task.detached { backup.loadPhotos() }.value
            let albums = Dictionary(uniqueKeysWithValues: loaded.albums.map { ($0.id, $0.assets) })
            var counts: [PhotoFilter: Int] = [:]
            for candidate in PhotoFilter.library + PhotoFilter.mediaTypes {
                counts[candidate] = loaded.assets.reduce(0) { $0 + (candidate.matches($1, albums: albums) ? 1 : 0) }
            }
            self.counts = counts
            library = loaded
            regroup()
        }
        .onChange(of: filter) {
            selection = []
            regroup()
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private func installKeyMonitor() {
        let selection = $selection, groups = $groups, quickLook = $quickLook
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isSpace = event.keyCode == 49
            let isEsc = event.keyCode == 53
            guard isSpace || isEsc,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            if quickLook.wrappedValue != nil {
                guard isSpace || isEsc else { return event }
                quickLook.wrappedValue = nil
                return nil
            }
            guard isSpace,
                  selection.wrappedValue.count == 1, let id = selection.wrappedValue.first,
                  let asset = groups.wrappedValue.flatMap(\.assets).first(where: { $0.id == id }) else { return event }
            quickLook.wrappedValue = asset
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func regroup() {
        guard let library else { return }
        let albums = Dictionary(uniqueKeysWithValues: library.albums.map { ($0.id, $0.assets) })
        let calendar = Calendar.current
        var result: [DayGroup] = []
        var day: Date?
        var bucket: [PhotoAsset] = []
        var total = 0
        for asset in library.assets where filter.matches(asset, albums: albums) {
            let assetDay = calendar.startOfDay(for: asset.date ?? .distantPast)
            if assetDay != day {
                if let day, !bucket.isEmpty { result.append(DayGroup(id: day, assets: bucket)) }
                day = assetDay
                bucket = []
            }
            bucket.append(asset)
            total += 1
        }
        if let day, !bucket.isEmpty { result.append(DayGroup(id: day, assets: bucket)) }
        var merged: [Date: Int] = [:]
        var unique: [DayGroup] = []
        for group in result {
            if let index = merged[group.id] {
                unique[index] = DayGroup(id: group.id, assets: unique[index].assets + group.assets)
            } else {
                merged[group.id] = unique.count
                unique.append(group)
            }
        }
        groups = unique
        visibleCount = total
    }

    private var filters: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                filterHeader("Library")
                ForEach(PhotoFilter.library, id: \.self) { filterRow($0, title: $0.title, count: counts[$0] ?? 0) }
                filterHeader("Media Types")
                ForEach(PhotoFilter.mediaTypes.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { filterRow($0, title: $0.title, count: counts[$0] ?? 0) }
                if let albums = library?.albums, !albums.isEmpty {
                    filterHeader("Albums")
                    ForEach(albums) { filterRow(.album($0.id), title: $0.title, count: $0.assets.count) }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    private func filterHeader(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).padding(.leading, 8).padding(.top, 12).padding(.bottom, 3)
    }

    private func filterRow(_ value: PhotoFilter, title: String, count: Int) -> some View {
        Button {
            filter = value
        } label: {
            HStack(spacing: 8) {
                Image(systemName: value.icon).foregroundStyle(Theme.accent).frame(width: 18)
                Text(title).lineLimit(1).natural(title)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).foregroundStyle(Theme.dim)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(filter == value ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.id == Calendar.current.startOfDay(for: .distantPast) ? "Unknown Date" : Fmt.day.string(from: group.id))
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.6), spacing: 6)], spacing: 6) {
                            ForEach(group.assets) { asset in
                                PhotoCell(backup: backup, asset: asset, selected: selection.contains(asset.id))
                                    .aspectRatio(1, contentMode: .fit)
                                    .gesture(TapGesture(count: 2).onEnded { quickLook = asset })
                                    .simultaneousGesture(TapGesture().onEnded { select(asset) })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .overlay {
            if groups.isEmpty { EmptyState(icon: filter.icon, title: "Nothing Here") }
        }
    }

    private func select(_ asset: PhotoAsset) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if !selection.insert(asset.id).inserted { selection.remove(asset.id) }
        } else {
            selection = selection == [asset.id] ? [] : [asset.id]
        }
    }

    private func export() {
        let visible = groups.flatMap(\.assets)
        let assets = selection.isEmpty ? visible : visible.filter { selection.contains($0.id) }
        guard !assets.isEmpty, let folder = Panels.chooseFolder() else { return }
        let backup = backup
        let directory = Exporter.uniqueURL(in: folder, name: "Photos")
        model.run("Exporting \(assets.count) Photos", reveal: directory) { progress in
            try Exporter.exportPhotos(backup, assets, to: directory, progress: progress)
            let missing = assets.filter { !$0.hasOriginal }.count
            return missing > 0 ? "\(missing) items were skipped because their originals are stored in iCloud and not in this backup." : nil
        }
    }
}

struct PhotoCell: View {
    let backup: Backup
    let asset: PhotoAsset
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.panel
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: asset.isVideo ? "video" : "photo").foregroundStyle(Theme.dim)
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) { badges.padding(5) }
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo {
                    Text(Fmt.duration(asset.duration)).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule()).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: selected ? 3 : 0)
            }
            .contentShape(Rectangle())
        }
        .task(id: asset.id) {
            image = await backup.thumbnails.image(domain: "CameraRollDomain", path: asset.thumbPath ?? asset.path)
        }
    }

    private var badges: some View {
        HStack(spacing: 3) {
            if asset.raw { badge("RAW") }
            if asset.isLive { badge("LIVE") }
            if asset.portrait { badge("PORTRAIT") }
            if asset.favorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2) }
            if !asset.hasOriginal { Image(systemName: "icloud").font(.caption2).foregroundStyle(.white).shadow(radius: 2) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct PlayerView: NSViewRepresentable {
    let url: URL
    var autoplay = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .floating
        if autoplay { view.player?.play() }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

struct QuickLookView: View {
    let backup: Backup
    let asset: PhotoAsset
    let onClose: () -> Void
    @State private var image: NSImage?
    @State private var video: URL?
    @State private var loaded = false

    private var meta: String {
        [Fmt.date(asset.date), asset.width > 0 ? "\(asset.width) × \(asset.height)" : "",
         asset.hasOriginal ? "" : "Preview only — original is in iCloud"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.filename).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(meta).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer()
                    if asset.hasOriginal {
                        Button("Save…", action: save)
                    }
                    Text("Space / Esc").font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .tint(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)

                ZStack {
                    if let video {
                        PlayerView(url: video)
                    } else if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else if loaded {
                        ContentUnavailableView("Preview Unavailable", systemImage: "photo")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView().tint(.white).scaleEffect(1.4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded {})
                .padding(.bottom, 10)
            }
            .padding(.top, 6)
        }
        .task {
            let backup = backup, asset = asset
            if asset.isVideo && asset.hasOriginal {
                video = await Task.detached { backup.localURL("CameraRollDomain", asset.path, materialize: backup.isEncrypted) }.value
            } else {
                image = await backup.thumbnails.image(domain: "CameraRollDomain", path: asset.hasOriginal ? asset.path : (asset.thumbPath ?? asset.path), maxPixel: 3200)
            }
            loaded = true
        }
    }

    private func save() {
        guard let url = Panels.save(name: asset.filename), let entry = backup.entry("CameraRollDomain", asset.path) else { return }
        do { try backup.extract(entry, to: url) } catch { NSAlert(error: error).runModal() }
    }
}
