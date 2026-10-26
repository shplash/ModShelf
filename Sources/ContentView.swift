import SwiftUI
import UIKit
import WebKit
import Security
import ZIPFoundation
import Network
import ImageIO
import UniformTypeIdentifiers
import SteamEngine

@main
struct ModShelfApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

let modShelfInfoFileName = "ModShelf Information.txt"
let modShelfVersion = "0.1b"
let modShelfBuild = "30"

// MARK: - Models

enum ModStatus { case upToDate, needsUpdate, unverified }

struct WorkshopItem: Identifiable, Codable, Equatable {
    var id: String
    var folder: String
    var addedAt: Date
    var updatedAt: Date
    var title: String? = nil
    var author: String? = nil
    var description: String? = nil
    var imageURL: String? = nil
    var publishedUpdatedAt: Int? = nil
    var lastCheckedAt: Date? = nil
    var updateAvailable: Bool = false
    var isFavourite: Bool = false
    var appID: String? = nil
    var gameName: String? = nil
    var tags: [String] = []
    var rating: Double? = nil
    var ratingCount: Int? = nil
    var checkFailed: Bool = false
    var filesBroken: Bool = false
    var fileCount: Int? = nil
    var byteCount: Int64? = nil

    init(id: String, folder: String, addedAt: Date, updatedAt: Date, title: String? = nil, author: String? = nil,
         description: String? = nil, imageURL: String? = nil, publishedUpdatedAt: Int? = nil, lastCheckedAt: Date? = nil,
         updateAvailable: Bool = false) {
        self.id = id; self.folder = folder; self.addedAt = addedAt; self.updatedAt = updatedAt
        self.title = title; self.author = author; self.description = description; self.imageURL = imageURL
        self.publishedUpdatedAt = publishedUpdatedAt; self.lastCheckedAt = lastCheckedAt; self.updateAvailable = updateAvailable
    }

    // Tolerant decoding so libraries saved by older builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folder = try c.decode(String.self, forKey: .folder)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        publishedUpdatedAt = try c.decodeIfPresent(Int.self, forKey: .publishedUpdatedAt)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
        gameName = try c.decodeIfPresent(String.self, forKey: .gameName)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        ratingCount = try c.decodeIfPresent(Int.self, forKey: .ratingCount)
        checkFailed = try c.decodeIfPresent(Bool.self, forKey: .checkFailed) ?? false
        filesBroken = try c.decodeIfPresent(Bool.self, forKey: .filesBroken) ?? false
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount)
        byteCount = try c.decodeIfPresent(Int64.self, forKey: .byteCount)
    }

    var displayTitle: String { title ?? "Workshop item \(id)" }
    var status: ModStatus {
        if filesBroken || checkFailed || lastCheckedAt == nil { return .unverified }
        return updateAvailable ? .needsUpdate : .upToDate
    }
}

struct WorkshopMetadata: Equatable {
    var id: String
    var title: String
    var author: String
    var description: String
    var imageURL: String
    var updatedAt: Int
    var appID: String? = nil
    var gameName: String? = nil
    var tags: [String] = []
    var fileSize: Int64 = 0
    var rating: Double? = nil
    var ratingCount: Int? = nil
    var screenshots: [String] = []
    var videos: [String] = []
    var pageURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }
}

struct DownloadRecord: Identifiable, Codable {
    var id = UUID()
    var workshopID: String
    var title: String
    var date: Date
    var result: String
    var error: String? = nil
    var imageURL: String? = nil
    var attempt: Int? = nil
    var gameName: String? = nil
}

enum MediaItem: Identifiable, Equatable {
    case image(String)
    case video(String)
    var id: String {
        switch self {
        case .image(let u): return "i:" + u
        case .video(let v): return "v:" + v
        }
    }
}

/// The media the focused viewer was opened on, with the rest of that item's media to swipe through.
struct MediaViewer: Identifiable {
    let id = UUID()
    let media: [MediaItem]
    let index: Int
}

/// A folder choice: the shared mod folder, one game's folder, or where moved mods should go.
enum FolderSheet: Identifiable {
    case shared
    case game(String)
    case moveDestination

    var id: String {
        switch self {
        case .shared: return "shared"
        case .game(let appID): return "game-" + appID
        case .moveDestination: return "move"
        }
    }
}

struct RelocateRequest: Identifiable {
    let id = UUID()
    let gameName: String
    let root: URL
    let folderName: String
    /// Where the mods live now, shown as "Before" beside the new folder.
    let previousFolder: String
    let ids: [String]
}

/// A place the selected mods can be moved to.
struct MoveDestination: Identifiable {
    let id: String
    let title: String
    let detail: String
}

// MARK: - Keychain

enum Keychain {
    static func write(_ value: String, key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.shplash.modshelf",
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.shplash.modshelf",
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "com.shplash.modshelf",
                       kSecAttrAccount as String: key] as CFDictionary)
    }
}

// MARK: - Small helpers

enum Haptics {
    private static var enabled: Bool { UserDefaults.standard.object(forKey: "options.haptics") as? Bool ?? true }
    static func tap() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func select() { guard enabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
    static func date(_ d: Date) -> String { day.string(from: d) }
    static func date(unix: Int) -> String { day.string(from: Date(timeIntervalSince1970: TimeInterval(unix))) }
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    /// Same day: "Just now", "5 min ago", "3 h ago". Any other day: a plain date.
    static func historyTime(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) {
            let s = max(0, Date().timeIntervalSince(d))
            if s < 60 { return "Just now" }
            if s < 3600 { return "\(Int(s / 60)) min ago" }
            return "\(Int(s / 3600)) h ago"
        }
        return date(d)
    }
}

/// One place that turns Steam's raw wording into a short line someone can act on.
enum ErrorText {
    static func friendly(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Something went wrong. Try again." }
        let r = text.lowercased()
        if r.contains("not own") || r.contains("own this game") || r.contains("don't own")
            || r.contains("no license") || r.contains("licen") || r.contains("not purchased") {
            return "You don't own this game on Steam, so Steam won't give you its Workshop items."
        }
        if r.contains("private") { return "That Workshop item is private, so it can't be downloaded." }
        if r.contains("not found") || r.contains("doesn't exist") || r.contains("does not exist")
            || r.contains("invalid item") || r.contains("no such item") {
            return "Steam couldn't find that item. It may have been deleted."
        }
        if r.contains("window") && r.contains("item") { return "Steam doesn't allow this item to be downloaded." }
        if r.contains("rate limit") || r.contains("too many") {
            return "Steam is limiting requests. Wait a minute and try again."
        }
        if r.contains("without a completion event") { return "The download stopped before it finished. Try again." }
        if r.contains("timeout") || r.contains("timed out") || r.contains("network")
            || r.contains("offline") || r.contains("connection") || r.contains("reach") {
            return "Couldn't reach Steam. Check your internet connection."
        }
        if r.contains("no space") || r.contains("disk full") || r.contains("not enough space") {
            return "There isn't enough free space on this iPhone."
        }
        if r.contains("cancel") { return "The download was cancelled." }
        return text
    }
}

final class NetworkWatcher {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private(set) var isExpensive = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.isExpensive = path.isExpensive }
        monitor.start(queue: DispatchQueue(label: "modshelf.network"))
    }
}

// MARK: - Image cache

final class ImageStore {
    static let shared = ImageStore()
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private init() {
        memory.countLimit = 160
        memory.totalCostLimit = 80 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, diskPath: "modshelf-images")
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    private func key(_ url: URL, animate: Bool) -> NSString { (url.absoluteString + (animate ? "|anim" : "|still")) as NSString }
    func cached(_ url: URL, animate: Bool) -> UIImage? { memory.object(forKey: key(url, animate: animate)) }

    func load(_ url: URL, maxPixel: CGFloat, animate: Bool) async -> UIImage? {
        let k = key(url, animate: animate)
        if let hit = memory.object(forKey: k) { return hit }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let shouldAnimate = animate && Self.isGIF(data)
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            shouldAnimate ? Self.animatedGIF(data, maxPixel: maxPixel) : Self.still(data, maxPixel: maxPixel)
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: k, cost: cost)
        }
        return image
    }

    static func isGIF(_ data: Data) -> Bool {
        data.count > 3 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46
    }

    static func still(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return UIImage(cgImage: cg) }
        return UIImage(data: data)
    }

    /// Every frame of the GIF, with its real timing, as one animated UIImage.
    static func animatedGIF(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return still(data, maxPixel: maxPixel) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        var frames: [UIImage] = []
        var total: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                delay = d > 0.011 ? d : 0.1
            }
            total += delay
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

/// Plays an animated image. "loops" is the repeat count; 0 loops forever.
/// The animation starts again each time this view is created, which happens every time a mod's view opens.
struct AnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    var fill = true
    var loops = 0

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.animationRepeatCount = loops
        view.image = image
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.image = image
            view.animationRepeatCount = loops
            view.startAnimating()
        }
    }
}

struct CachedImage: View {
    let urlString: String?
    var fill = true
    var maxPixel: CGFloat = 600
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @AppStorage("options.gifLibrary") private var gifLibrary = true
    var isDownloadPreview = false
    @State private var image: UIImage?
    private var animate: Bool { isDownloadPreview ? gifDownloads : gifLibrary }

    var body: some View {
        ZStack {
            if let image {
                if image.images != nil {
                    AnimatedUIImageView(image: image, fill: fill, loops: 5)
                } else if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .task(id: (urlString ?? "") + (animate ? "|1" : "|0")) {
            guard let s = urlString, !s.isEmpty, let url = URL(string: s) else { image = nil; return }
            if let hit = ImageStore.shared.cached(url, animate: animate) { image = hit; return }
            image = await ImageStore.shared.load(url, maxPixel: maxPixel, animate: animate)
        }
    }
}

// MARK: - Browser cookie vault (keeps Steam logged in between launches)

enum CookieVault {
    private static let key = "browser.cookies"
    private static func isSteam(_ c: HTTPCookie) -> Bool {
        let d = c.domain.lowercased()
        return d.hasSuffix("steamcommunity.com") || d.hasSuffix("steampowered.com")
    }
    static func save(from store: WKHTTPCookieStore) {
        store.getAllCookies { cookies in
            let rows: [[String: String]] = cookies.filter(isSteam).map { c in
                var r: [String: String] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                           "secure": c.isSecure ? "1" : "0"]
                let exp = c.expiresDate ?? Date().addingTimeInterval(60 * 60 * 24 * 30)
                r["expires"] = String(exp.timeIntervalSince1970)
                return r
            }
            if let data = try? JSONEncoder().encode(rows), let s = String(data: data, encoding: .utf8) { Keychain.write(s, key: key) }
        }
    }
    static func restore(into store: WKHTTPCookieStore, completion: @escaping () -> Void) {
        guard let s = Keychain.read(key), let data = s.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: String]].self, from: data), !rows.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for r in rows {
            guard let name = r["name"], let value = r["value"], let domain = r["domain"], let path = r["path"] else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if r["secure"] == "1" { props[.secure] = "TRUE" }
            if let e = r["expires"], let t = Double(e) {
                let date = Date(timeIntervalSince1970: t)
                if date < Date() { continue }
                props[.expires] = date
            }
            if let cookie = HTTPCookie(properties: props) {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
        }
        group.notify(queue: .main) { completion() }
    }
    static func hasSteamLogin() -> Bool {
        guard let text = Keychain.read(key), let data = text.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: String]].self, from: data) else { return false }
        return rows.contains { $0["name"] == "steamLoginSecure" }
    }
    static func clear(from store: WKHTTPCookieStore) {
        store.getAllCookies { cookies in
            for c in cookies where isSteam(c) { store.delete(c) }
        }
        Keychain.delete(key)
    }
}

// MARK: - Steam metadata (public API + Workshop page)

enum SteamMeta {
    static let ageCookie = "birthtime=631152001; lastagecheckage=1-0-1990; wants_mature_content=1; Steam_Language=english"

    static func fetch(id: String, includePage: Bool) async -> WorkshopMetadata? {
        guard var meta = await fetchAPI(id: id) else { return nil }
        if includePage { await enrichFromPage(&meta) }
        if meta.gameName == nil, let app = meta.appID { meta.gameName = await gameName(appID: app) }
        return meta
    }

    private static func fetchAPI(id: String) async -> WorkshopMetadata? {
        guard let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = root["response"] as? [String: Any],
                  let details = resp["publishedfiledetails"] as? [[String: Any]],
                  let item = details.first, (item["result"] as? Int) == 1 else { return nil }
            var meta = WorkshopMetadata(id: id,
                                        title: item["title"] as? String ?? "Workshop item \(id)",
                                        author: "",
                                        description: cleanHTML(item["description"] as? String ?? "No description provided."),
                                        imageURL: item["preview_url"] as? String ?? "",
                                        updatedAt: item["time_updated"] as? Int ?? 0)
            if let app = item["consumer_app_id"] as? Int { meta.appID = String(app) }
            else if let app = item["consumer_app_id"] as? String { meta.appID = app }
            if let tags = item["tags"] as? [[String: Any]] {
                meta.tags = tags.compactMap { $0["tag"] as? String }.filter { !$0.isEmpty }
            }
            if let s = item["file_size"] as? String, let n = Int64(s) { meta.fileSize = n }
            else if let n = item["file_size"] as? Int { meta.fileSize = Int64(n) }
            return meta
        } catch { return nil }
    }

    /// Ratings, screenshots, videos and the game name are not in the keyless API, so they are read from the public item page.
    private static func enrichFromPage(_ meta: inout WorkshopMetadata) async {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(meta.id)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(ageCookie, forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return }

        if let m = firstMatch(#"class="fileRating"[^>]*?src="[^"]*?/(\d)-star"#, in: html), let n = Double(m) { meta.rating = n }
        else if let m = firstMatch(#"(\d)-star(?:_large)?\.png"#, in: html), let n = Double(m) { meta.rating = n }
        if let m = firstMatch(#"class="numRatings"[^>]*>\s*([\d,\.\s]+)\s*(?:rating|Rating)"#, in: html) {
            let digits = m.filter { $0.isNumber }
            if let n = Int(digits) { meta.ratingCount = n }
        }
        if meta.rating == 0 && (meta.ratingCount ?? 0) == 0 { meta.rating = nil }

        if let m = firstMatch(#"class="apphub_AppName[^"]*"[^>]*>([^<]+)<"#, in: html) {
            meta.gameName = decodeEntities(m).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // YouTube videos
        var videos: [String] = []
        for pattern in [#"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#, #"highlight_youtube_([A-Za-z0-9_-]{11})"#, #"img\.youtube\.com/vi/([A-Za-z0-9_-]{11})"#] {
            for m in allMatches(pattern, in: html) where !videos.contains(m) { videos.append(m) }
        }
        meta.videos = videos

        // Screenshots: full-size links inside the media area, falling back to any user-image links on the page.
        var shots: [String] = []
        let area = mediaArea(in: html)
        for pattern in [#"<a[^>]+class="[^"]*modalContentLink[^"]*"[^>]+href="([^"]+)""#, #"<a[^>]+href="([^"]+)"[^>]+class="[^"]*modalContentLink[^"]*""#] {
            for m in allMatches(pattern, in: area) { addShot(m, to: &shots, preview: meta.imageURL) }
        }
        if shots.isEmpty {
            let pattern = #"https://(?:steamuserimages-a\.akamaihd\.net|images\.steamusercontent\.com|cdn\.[a-z\.]*steamstatic\.com)/ugc/[A-Za-z0-9_\-/]+/?(?:\?[^"'\s<>]*)?"#
            for m in allMatches(pattern, in: area, group: 0) { addShot(m, to: &shots, preview: meta.imageURL) }
        }
        meta.screenshots = Array(shots.prefix(12))
    }

    private static func mediaArea(in html: String) -> String {
        guard let r = html.range(of: "highlight_player_area") ?? html.range(of: "highlight_strip") else { return html }
        let end = html.index(r.lowerBound, offsetBy: 60000, limitedBy: html.endIndex) ?? html.endIndex
        return String(html[r.lowerBound..<end])
    }

    private static func addShot(_ raw: String, to shots: inout [String], preview: String) {
        let clean = decodeEntities(raw)
        guard clean.hasPrefix("http") else { return }
        let stem = clean.components(separatedBy: "?").first ?? clean
        let previewStem = preview.components(separatedBy: "?").first ?? preview
        if stem == previewStem { return }
        if shots.contains(where: { ($0.components(separatedBy: "?").first ?? $0) == stem }) { return }
        shots.append(clean)
    }

    static func gameName(appID: String) async -> String? {
        let cacheKey = "modshelf.gameNames"
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        if let hit = cache[appID] { return hit }
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appID] as? [String: Any], (entry["success"] as? Bool) == true,
              let d = entry["data"] as? [String: Any], let name = d["name"] as? String else { return nil }
        cache[appID] = name
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return name
    }

    // MARK: regex helpers
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
    private static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > group else { return nil }
            return ns.substring(with: m.range(at: group))
        }
    }
    private static func decodeEntities(_ s: String) -> String {
        var v = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            v = v.replacingOccurrences(of: a, with: b)
        }
        return v
    }

    static func cleanHTML(_ html: String) -> String {
        var value = html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: "\\[img\\][\\s\\S]*?\\[/img\\]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "<img\\b[^>]*>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<h[1-6]\\b[^>]*>(.*?)</h[1-6]>", with: "\n\n**$1**\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<(?:b|strong)\\b[^>]*>(.*?)</(?:b|strong)>", with: "**$1**", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<(?:i|em)\\b[^>]*>(.*?)</(?:i|em)>", with: "*$1*", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<li\\b[^>]*>(.*?)</li>", with: "\n• $1", options: .regularExpression)
        value = value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "</p\\s*>", with: "\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)\\[h[1-6]\\](.*?)\\[/h[1-6]\\]", with: "\n\n**$1**\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)\\[(?:b|strong)\\](.*?)\\[/(?:b|strong)\\]", with: "**$1**", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)\\[(?:i|em)\\](.*?)\\[/(?:i|em)\\]", with: "*$1*", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[\\*\\]", with: "\n• ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[/?(?:u|strike|list|olist|hr)\\]", with: "\n", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[url(?:=[^\\]]*)?\\]", with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[/url\\]", with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[[a-zA-Z][a-zA-Z0-9_]*(?:=[^\\]]*)?\\]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[/[a-zA-Z][a-zA-Z0-9_]*\\]", with: "", options: .regularExpression)
        value = decodeEntities(value).replacingOccurrences(of: "&#10;", with: "\n")
        value = value.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Store

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var input = ""
    @Published var username = Keychain.read("steam.username") ?? ""
    @Published var password = Keychain.read("steam.password") ?? ""
    @Published var guardCode = ""
    @Published var status = "Ready"
    @Published var errorMessage = ""
    /// Sign-in problems stay in the login sheet, so they never sit in the banner behind it.
    @Published var loginError = ""
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var isBusy = false
    @Published var isDownloading = false
    @Published var isFetching = false
    @Published var preview: WorkshopMetadata?
    @Published var library: [WorkshopItem] = []
    @Published var history: [DownloadRecord] = []
    @Published var showLogin = false
    @Published var needsGuardCode = false
    @Published var pendingDelete: WorkshopItem?
    @Published var showDeleteConfirmation = false
    @Published var shareURL: URL?
    @Published var lastOutcome = ""
    @Published var browserURL: URL?
    @Published var operationMessage = ""
    @Published var isCheckingUpdates = false
    @Published var isVerifyingAll = false
    @Published var libraryStorageBytes: Int64 = 0
    @Published var folderLabel = ""
    @Published var activeTitle = ""
    @Published var phases: [String] = []
    @Published var revealFolderURL: URL?
    /// Folder names chosen per game, keyed by Steam App ID. A game without an entry uses the shared folder.
    @Published var customGameFolders: [String: String] = [:]

    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""
    private var activeMeta: WorkshopMetadata?
    private var queue: [String] = []
    private var didLaunchChecks = false
    private var customRoot: URL?
    private var scopedURL: URL?
    private var gameRoots: [String: URL] = [:]
    private var gameScopes: [String: URL] = [:]
    private var didLoadGameFolders = false

    var isAuthenticated: Bool { engine.isAuthenticated() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var defaultRoot: URL {
        let url = documents.appendingPathComponent("Downloaded Mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var downloadsRoot: URL {
        let url = customRoot ?? defaultRoot
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var sessionPath: String {
        let fm = FileManager.default
        let library = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = library.appendingPathComponent("ModShelf/SteamSession", isDirectory: true)
        let legacyURL = documents.appendingPathComponent("SteamSession", isDirectory: true)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: legacyURL.path) {
            if !fm.fileExists(atPath: url.path) {
                try? fm.moveItem(at: legacyURL, to: url)
            } else if let children = try? fm.contentsOfDirectory(at: legacyURL, includingPropertiesForKeys: nil) {
                for child in children {
                    let destination = url.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                    if !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: child, to: destination) }
                }
                if (try? fm.contentsOfDirectory(atPath: legacyURL.path).isEmpty) == true { try? fm.removeItem(at: legacyURL) }
            }
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        let cacheURL = url.appendingPathComponent("steam-session", isDirectory: true)
        try? fm.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        if let documentChildren = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            for child in documentChildren {
                let name = child.lastPathComponent
                let isSteamCacheFile = name == "depot.keys.json" || name.hasPrefix("session_") || name.hasPrefix("token_")
                guard isSteamCacheFile else { continue }
                let destination = cacheURL.appendingPathComponent(name)
                if !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: child, to: destination) }
            }
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: cacheURL.path)
        return url.path
    }
    private var temporaryPath: URL { documents.appendingPathComponent("ModShelfTemporary", isDirectory: true) }

    init() {
        library = Self.load([WorkshopItem].self, key: "library") ?? []
        let oldHistory = Self.load([String].self, key: "history") ?? []
        history = Self.load([DownloadRecord].self, key: "modshelf.history") ?? oldHistory.map {
            DownloadRecord(workshopID: $0, title: "Workshop item \($0)", date: Date(), result: "Attempted")
        }
        // A "Downloading" entry left over from a previous launch can never finish.
        var fixed = false
        for i in history.indices where history[i].result == "Downloading" {
            history[i].result = "Failed"
            history[i].error = "ModShelf was closed before this download finished."
            fixed = true
        }
        if fixed { saveHistory() }
        status = engine.status()
        _ = NetworkWatcher.shared
        _ = sessionPath
        resolveCustomRoot()
        updateFolderLabel()
        refreshLibraryBytes()
        if !username.isEmpty && !password.isEmpty { Task { await signIn(automatic: true) } }
    }

    deinit { poller?.invalidate() }

    // MARK: polling / persistence

    private func startPolling() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
    }
    private func stopPolling() { poller?.invalidate(); poller = nil }
    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func saveLibrary() { save(library, key: "library") }
    private func saveHistory() { save(history, key: "modshelf.history") }
    private func record(_ id: String, title: String, result: String, error: String? = nil, imageURL: String? = nil, game: String? = nil) {
        let attempt = history.filter { $0.workshopID == id }.count + 1
        history.insert(DownloadRecord(workshopID: id, title: title, date: Date(), result: result, error: error, imageURL: imageURL, attempt: attempt, gameName: game), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        saveHistory()
    }

    // MARK: download folders

    static let gameFoldersKey = "options.gameFolders"

    private func resolveCustomRoot() {
        guard let data = UserDefaults.standard.data(forKey: "options.folderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // A bookmark saved by an older install can no longer resolve; forget it instead of retrying every launch.
            UserDefaults.standard.removeObject(forKey: "options.folderBookmark")
            return
        }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        customRoot = url
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "options.folderBookmark")
        }
    }

    /// Per-game bookmarks are resolved the first time they are needed, so launch stays quick.
    private func loadGameFolders() {
        guard !didLoadGameFolders else { return }
        didLoadGameFolders = true
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.gameFoldersKey), !stored.isEmpty else { return }
        var refreshed = stored
        for (app, value) in stored {
            guard let data = value as? Data else {
                refreshed.removeValue(forKey: app)
                continue
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                refreshed.removeValue(forKey: app)
                continue
            }
            if url.startAccessingSecurityScopedResource() { gameScopes[app] = url }
            gameRoots[app] = url
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshed[app] = fresh
            }
        }
        UserDefaults.standard.set(refreshed, forKey: Self.gameFoldersKey)
        rebuildGameFolderLabels()
    }

    private func rebuildGameFolderLabels() {
        var labels: [String: String] = [:]
        for (app, url) in gameRoots { labels[app] = Self.displayName(url) }
        customGameFolders = labels
    }

    nonisolated static func displayName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    /// The folder new downloads for `appID` go into: that game's own folder when one is set.
    func root(forGame appID: String?) -> URL {
        if let appID {
            loadGameFolders()
            if let custom = gameRoots[appID] {
                try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
                return custom
            }
        }
        return downloadsRoot
    }

    func setCustomFolder(_ url: URL) { setFolder(url, for: nil) }

    func setFolder(_ url: URL, for game: String?) {
        // Access has to be started before the folder can be tested or bookmarked.
        let started = url.startAccessingSecurityScopedResource()
        guard Self.canWrite(into: url) else {
            if started { url.stopAccessingSecurityScopedResource() }
            errorMessage = "ModShelf can't write to that folder. Pick another one."
            Haptics.error()
            return
        }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if started { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Couldn't save that folder. Try again."
            Haptics.error()
            return
        }
        if let game {
            loadGameFolders()
            if let previous = gameScopes[game], previous.path != url.path { previous.stopAccessingSecurityScopedResource() }
            // Picking the folder that is already set must not start a second access to it.
            if let previous = gameScopes[game], previous.path == url.path {
                if started { url.stopAccessingSecurityScopedResource() }
            } else {
                gameScopes[game] = started ? url : nil
            }
            gameRoots[game] = url
            var stored = UserDefaults.standard.dictionary(forKey: Self.gameFoldersKey) ?? [:]
            stored[game] = data
            UserDefaults.standard.set(stored, forKey: Self.gameFoldersKey)
            rebuildGameFolderLabels()
        } else {
            if let previous = scopedURL, previous.path != url.path { previous.stopAccessingSecurityScopedResource() }
            if let previous = scopedURL, previous.path == url.path {
                if started { url.stopAccessingSecurityScopedResource() }
            } else {
                scopedURL = started ? url : nil
            }
            customRoot = url
            UserDefaults.standard.set(data, forKey: "options.folderBookmark")
            updateFolderLabel()
            operationMessage = "New downloads will be saved to \(Self.displayName(url))."
        }
    }

    func resetCustomFolder() { resetFolder(for: nil) }

    func resetFolder(for game: String?) {
        if let game {
            loadGameFolders()
            gameScopes[game]?.stopAccessingSecurityScopedResource()
            gameScopes[game] = nil
            gameRoots[game] = nil
            var stored = UserDefaults.standard.dictionary(forKey: Self.gameFoldersKey) ?? [:]
            stored.removeValue(forKey: game)
            UserDefaults.standard.set(stored, forKey: Self.gameFoldersKey)
            rebuildGameFolderLabels()
            operationMessage = "This game now uses the shared download folder."
        } else {
            scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
            customRoot = nil
            UserDefaults.standard.removeObject(forKey: "options.folderBookmark")
            updateFolderLabel()
            operationMessage = "Download folder reset to the default."
        }
    }

    private func updateFolderLabel() {
        if let root = customRoot {
            folderLabel = Self.displayName(root)
        } else { folderLabel = "On My iPhone / ModShelf / Downloaded Mods" }
    }

    var usingCustomFolder: Bool { customRoot != nil }
    var currentRootURL: URL { customRoot ?? defaultRoot }

    func gameDisplayName(_ appID: String) -> String {
        if let name = library.first(where: { $0.appID == appID })?.gameName { return name }
        let cache = UserDefaults.standard.dictionary(forKey: "modshelf.gameNames") as? [String: String] ?? [:]
        return cache[appID] ?? "this game"
    }

    func revealInFiles(_ item: WorkshopItem) {
        let path = item.folder
        if path.hasPrefix(documents.path + "/") {
            // Inside ModShelf's own storage: Files can open it directly.
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "shareddocuments://" + encoded) else { return }
            UIApplication.shared.open(url)
        } else if FileManager.default.fileExists(atPath: path) {
            // A folder you picked: show the Files browser opened at the mod's folder.
            revealFolderURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            operationMessage = "That mod's folder is missing. Download it again."
        }
    }

    /// Opens any folder in Files: ModShelf's own folders directly, a picked one through the browser.
    func revealFolder(_ url: URL) {
        let path = url.path
        if path.hasPrefix(documents.path + "/") {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let shared = URL(string: "shareddocuments://" + encoded) else { return }
            UIApplication.shared.open(shared)
        } else if FileManager.default.fileExists(atPath: path) {
            revealFolderURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            operationMessage = "That folder doesn't exist any more."
        }
    }

    /// A mod keeps the folder it already lives in, so an update replaces it in place.
    private func installRoot(for item: WorkshopItem?, appID: String?) -> URL {
        if let item, FileManager.default.fileExists(atPath: item.folder) {
            let parent = URL(fileURLWithPath: item.folder, isDirectory: true).deletingLastPathComponent()
            if (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return parent }
        }
        return root(forGame: appID)
    }

    nonisolated static func canWrite(into url: URL) -> Bool {
        let probe = url.appendingPathComponent(".modshelf-write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch { return false }
    }

    // MARK: lookup

    static func workshopID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value.allSatisfy({ $0.isNumber }) && value != "0" { return value }
        guard let c = URLComponents(string: value), let host = c.host?.lowercased(),
              ["steamcommunity.com", "www.steamcommunity.com"].contains(host),
              c.path.contains("/sharedfiles/filedetails"),
              let id = c.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.allSatisfy({ $0.isNumber }), id != "0" else { return nil }
        return id
    }

    func fetchPreview() {
        guard !isFetching, !isBusy else { return }
        guard let id = Self.workshopID(from: input) else {
            preview = nil
            errorMessage = "Enter a Workshop link or item ID."
            return
        }
        isFetching = true
        preview = nil
        errorMessage = ""
        Task {
            let result = await SteamMeta.fetch(id: id, includePage: true)
            if let result {
                preview = result
            } else {
                errorMessage = "Couldn't load item \(id). It may be private, deleted or unavailable."
                preview = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "Metadata was unavailable. Downloading may still work if this item is accessible to your Steam account.", imageURL: "", updatedAt: 0)
            }
            isFetching = false
        }
    }

    // MARK: sign in

    func signIn(automatic: Bool = false) async {
        loginError = ""
        if isBusy && needsGuardCode {
            let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { loginError = "Enter the Steam Guard code."; return }
            Haptics.tap()
            engine.submitGuardCode(code)
            guardCode = ""
            status = "Checking code…"
            return
        }
        guard !isBusy else { loginError = "Finish or cancel the download first."; return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            if !automatic { showLogin = true; loginError = "Enter your username and password." }
            return
        }
        isBusy = true; status = "Signing in to Steam…"; needsGuardCode = false
        startPolling()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = sessionPath
        let activeEngine = engine
        let result = await Task.detached(priority: .userInitiated) {
            activeEngine.login(user, password: pass, guardCode: code, cachePath: path)
        }.value
        isBusy = false
        stopPolling()
        status = engine.status()
        if engine.isAuthenticated() {
            Keychain.write(user, key: "steam.username")
            Keychain.write(pass, key: "steam.password")
            guardCode = ""; showLogin = false; status = "Signed in to Steam"
            loginError = ""
            Haptics.success()
        } else {
            let raw = result.isEmpty ? engine.lastError() : result
            loginError = Self.signInMessage(raw)
            if raw.localizedCaseInsensitiveContains("guard") || raw.localizedCaseInsensitiveContains("code") {
                status = "Steam Guard code required"
                needsGuardCode = true
            }
            if !automatic { showLogin = true; Haptics.error() }
        }
    }

    /// Steam's own sign-in wording, keeping what went wrong so the login sheet can say it clearly.
    nonisolated static func signInMessage(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Sign-in didn't complete. Try again." }
        let r = text.lowercased()
        if r.contains("not entered in time") { return "The code wasn't entered in time. Try signing in again." }
        if r.contains("guard") || r.contains("two-factor") || r.contains("2fa") {
            if r.contains("waiting") || r.contains("already") {
                return "Steam is still waiting on the previous code. Finish that prompt first."
            }
            return "Steam wants a Steam Guard code, or an approval in the Steam app."
        }
        // Steam reports repeated bad sign-ins as a rate limit, so name both causes.
        if r.contains("too many") || r.contains("rate limit") {
            return "Steam blocked this sign-in after too many attempts. Wait a few minutes, and check the username and password are right."
        }
        if r.contains("invalid password") || r.contains("incorrect password") || r.contains("wrong password") {
            return "Steam didn't accept that password."
        }
        if r.contains("password") || r.contains("account name") || r.contains("username")
            || r.contains("invalid login") || r.contains("denied") || r.contains("credential") {
            return "Steam didn't accept that username or password."
        }
        if r.contains("network") || r.contains("connection") || r.contains("timeout") || r.contains("timed out") {
            return "Couldn't reach Steam. Check your connection."
        }
        if r.contains("download") || r.contains("already running") {
            return "Finish or cancel the download first."
        }
        return text
    }
    func signOut() {
        guard !isBusy else { errorMessage = "Finish or cancel the download first."; return }
        engine.logout(); Keychain.delete("steam.password"); password = ""; guardCode = ""
        status = "Signed out"
    }

    // MARK: download

    func download(_ raw: String? = nil, meta override: WorkshopMetadata? = nil) {
        errorMessage = ""
        guard !isBusy else { errorMessage = "Something is already running. Wait for it to finish."; return }
        guard isAuthenticated else { operationMessage = "Sign in to Steam to download this item."; showLogin = true; return }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a Workshop link or item ID."; return }
        if UserDefaults.standard.bool(forKey: "options.wifiOnly") && NetworkWatcher.shared.isExpensive {
            errorMessage = "Wi-Fi only is on. Connect to Wi-Fi to download."
            queue.removeAll()
            return
        }
        activeID = id
        let fallback = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "", imageURL: "", updatedAt: 0)
        let meta: WorkshopMetadata = override ?? ((preview?.id == id ? preview : nil) ?? fallback)
        activeMeta = meta
        activeTitle = meta.title
        // Updates stage next to the current installation, so the swap is a rename rather than a copy.
        let targetRoot = installRoot(for: library.first(where: { $0.id == id }), appID: meta.appID)
        let staging = targetRoot.appendingPathComponent(".partial-\(id)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the download folder."
            record(id, title: meta.title, result: "Failed", error: errorMessage, game: meta.gameName)
            return
        }
        let result = engine.downloadWorkshopItem(id, targetDir: staging.path)
        if !result.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            let message = ErrorText.friendly(result)
            errorMessage = message; status = "Download failed"
            record(id, title: meta.title, result: "Failed", error: message, imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL, game: meta.gameName)
            Haptics.error()
            return
        }
        isBusy = true
        isDownloading = true
        progress = 0
        currentFile = ""
        status = "Starting download…"
        phases = []
        lastOutcome = ""
        record(id, title: meta.title, result: "Downloading", imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL, game: meta.gameName)
        startPolling()
        UserDefaults.standard.set(staging.path, forKey: "modshelf.activeStaging")
    }

    func update(_ item: WorkshopItem) {
        var meta = WorkshopMetadata(id: item.id, title: item.displayTitle, author: "", description: item.description ?? "",
                                    imageURL: item.imageURL ?? "", updatedAt: item.publishedUpdatedAt ?? 0)
        meta.appID = item.appID; meta.gameName = item.gameName; meta.tags = item.tags
        meta.rating = item.rating; meta.ratingCount = item.ratingCount
        download(item.id, meta: meta)
    }
    func updateAll() {
        queue = library.filter { $0.updateAvailable }.map { $0.id }
        guard !queue.isEmpty else { operationMessage = "Everything is up to date."; return }
        operationMessage = "Updating \(queue.count) mod\(queue.count == 1 ? "" : "s")…"
        startNextInQueue()
    }
    private func startNextInQueue() {
        guard !isBusy else { return }
        while let id = queue.first {
            queue.removeFirst()
            if let item = library.first(where: { $0.id == id }) { update(item); return }
        }
    }

    func refreshState() {
        let nextStatus = engine.status()
        // Each new step Steam reports becomes its own segment of the progress bar.
        if isDownloading, !nextStatus.isEmpty, phases.last != nextStatus { phases.append(nextStatus) }
        let nextProgress = min(1, max(0, engine.progress()))
        let nextFile = engine.currentFile()
        let waitingForCode = nextStatus == "Steam Guard code required"
        if waitingForCode != needsGuardCode { needsGuardCode = waitingForCode }
        if waitingForCode && !showLogin { showLogin = true }
        if status != nextStatus { status = nextStatus }
        if abs(progress - nextProgress) > 0.001 { progress = nextProgress }
        if currentFile != nextFile { currentFile = nextFile }
        guard isBusy else { stopPolling(); return }

        let s = nextStatus.lowercased()
        guard ["download complete", "download failed", "download cancelled"].contains(where: { s.contains($0) }) else { return }
        isBusy = false
        isDownloading = false
        stopPolling()
        let stagingPath = UserDefaults.standard.string(forKey: "modshelf.activeStaging") ?? ""
        UserDefaults.standard.removeObject(forKey: "modshelf.activeStaging")
        let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let error = engine.lastError()
        let successStatus = s.contains("download complete")
        let cancelled = s.contains("download cancelled")
        let meta = activeMeta ?? WorkshopMetadata(id: activeID, title: activeTitle, author: "", description: "", imageURL: "", updatedAt: 0)
        var success = false
        var failureText = ""
        if successStatus, !stagingPath.isEmpty {
            do {
                let existing = library.first(where: { $0.id == activeID })
                let done = try finalizeDownload(staging: staging, id: activeID, meta: meta, existing: existing)
                var item = existing ?? WorkshopItem(id: activeID, folder: done.url.path, addedAt: Date(), updatedAt: Date())
                item.folder = done.url.path
                item.updatedAt = Date()
                item.title = meta.title
                item.description = meta.description.isEmpty ? item.description : meta.description
                item.imageURL = meta.imageURL.isEmpty ? item.imageURL : meta.imageURL
                if meta.updatedAt > 0 { item.publishedUpdatedAt = meta.updatedAt }
                item.lastCheckedAt = Date()
                item.updateAvailable = false
                item.checkFailed = false
                item.filesBroken = false
                item.appID = meta.appID ?? item.appID
                item.gameName = meta.gameName ?? item.gameName
                if !meta.tags.isEmpty { item.tags = meta.tags }
                if meta.rating != nil { item.rating = meta.rating; item.ratingCount = meta.ratingCount }
                item.fileCount = done.files
                item.byteCount = done.bytes
                if let old = library.firstIndex(where: { $0.id == activeID }) { library[old] = item } else { library.insert(item, at: 0) }
                saveLibrary()
                success = true
            } catch {
                failureText = "Couldn't finish the download."
                errorMessage = failureText
                try? FileManager.default.removeItem(at: staging)
            }
        } else if !stagingPath.isEmpty {
            try? FileManager.default.removeItem(at: staging)
        }
        if success {
            updateHistory(id: activeID, result: "Downloaded", error: nil)
            refreshLibraryBytes()
            lastOutcome = "Download completed"
            Haptics.success()
        } else {
            let reason = cancelled
                ? "The download was cancelled."
                : ErrorText.friendly(!error.isEmpty ? error : (!failureText.isEmpty ? failureText : "The download didn't finish."))
            updateHistory(id: activeID, result: cancelled ? "Cancelled" : "Failed", error: reason)
            if !cancelled { errorMessage = reason }
            lastOutcome = cancelled ? "Download cancelled" : "Download failed"
            if cancelled { queue.removeAll() }
            Haptics.error()
        }
        saveHistory()
        if !queue.isEmpty { Task { @MainActor in self.startNextInQueue() } }
    }

    private func updateHistory(id: String, result: String, error: String?) {
        if let index = history.firstIndex(where: { $0.workshopID == id && $0.result == "Downloading" }) {
            history[index].result = result; history[index].date = Date(); history[index].error = error
            if let m = activeMeta, m.id == id, !m.imageURL.isEmpty { history[index].imageURL = m.imageURL }
        } else { record(id, title: activeTitle, result: result, error: error) }
    }
    func cancel() { queue.removeAll(); engine.cancelDownload(); status = "Cancelling download…" }

    // MARK: finalising a download (flatten Steam's <id>/mods/<mod> layout, write info file)

    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
    private func visibleChildren(_ url: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return all.filter { !$0.lastPathComponent.hasPrefix(".") }
    }
    private func sanitize(_ name: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80))
        return limited.isEmpty ? fallback : limited
    }
    /// A free folder under `root`: the plain name, then the name with the Workshop ID, then a unique one.
    nonisolated static func availableURL(name: String, id: String, in root: URL) -> URL {
        let fm = FileManager.default
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        candidate = root.appendingPathComponent("\(name) (\(id))", isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        return root.appendingPathComponent("\(name) (\(id)-\(UUID().uuidString.prefix(4)))", isDirectory: true)
    }

    /// Renames when both folders share a volume, which is instant, and copies when they do not.
    nonisolated static func place(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
            } catch let copyError {
                try? fm.removeItem(at: destination)
                throw copyError
            }
        }
    }

    /// Installs a finished download. The old installation is moved aside first and only removed once
    /// the replacement is verified, so a failed update puts the previous version back.
    private func finalizeDownload(staging: URL, id: String, meta: WorkshopMetadata, existing: WorkshopItem?) throws -> (url: URL, files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard !visibleChildren(staging).isEmpty else {
            throw NSError(domain: "ModShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "The download came back empty."])
        }
        // Steam lays files out as <id>/mods/<ModName>/... ; keep only the mod itself.
        var base = staging
        let idDir = staging.appendingPathComponent(id, isDirectory: true)
        if isDir(idDir) { base = idDir }
        var payload = base
        var singleMod = false
        let modsDir = base.appendingPathComponent("mods", isDirectory: true)
        if isDir(modsDir) {
            let mods = visibleChildren(modsDir)
            let dirs = mods.filter { isDir($0) }
            if mods.count == 1, dirs.count == 1 { payload = dirs[0]; singleMod = true }
            else if !mods.isEmpty { payload = modsDir }
        }
        let name = singleMod ? sanitize(payload.lastPathComponent, fallback: id) : sanitize(meta.title, fallback: id)

        // An update replaces the installation in the folder it already lives in; a new download goes into
        // the folder set for its game.
        let destination: URL
        if let existing, fm.fileExists(atPath: existing.folder) {
            destination = URL(fileURLWithPath: existing.folder, isDirectory: true)
        } else {
            destination = Self.availableURL(name: name, id: id, in: root(forGame: meta.appID))
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let backup = parent.appendingPathComponent(".modshelf-replacing-\(id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }

        do {
            try Self.place(from: payload, to: destination)
        } catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            throw NSError(domain: "ModShelf", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't put the new files in place. Your previous version is still there."])
        }

        let counts = Self.scan(folder: destination.path)
        guard counts.exists, counts.count > 0 else {
            try? fm.removeItem(at: destination)
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            throw NSError(domain: "ModShelf", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The download had no files. Your previous version is still there."])
        }

        if hadPrevious { try? fm.removeItem(at: backup) }
        try? fm.removeItem(at: staging)

        let infoURL = destination.appendingPathComponent(modShelfInfoFileName)
        if UserDefaults.standard.object(forKey: "options.infoFile") as? Bool ?? true {
            let text = infoText(meta: meta, id: id, files: counts.count, bytes: counts.bytes, existing: existing, singleMod: singleMod)
            try? text.write(to: infoURL, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: infoURL)
        }
        return (destination, counts.count, counts.bytes)
    }

    /// Starts with the first real detail line: the old "ModShelf Information" heading is gone.
    private func infoText(meta: WorkshopMetadata, id: String, files: Int, bytes: Int64, existing: WorkshopItem?, singleMod: Bool) -> String {
        let stamp = DateFormatter(); stamp.dateFormat = "d MMM yyyy, h:mm a"
        var lines: [String] = ["Title: \(meta.title)"]
        lines.append("Workshop ID: \(id)")
        lines.append("Workshop page: https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
        if let game = meta.gameName ?? existing?.gameName {
            lines.append("Game: \(game)\(meta.appID.map { " (App ID \($0))" } ?? "")")
        } else if let app = meta.appID { lines.append("Game: App ID \(app)") }
        if !meta.tags.isEmpty { lines.append("Tags: \(meta.tags.joined(separator: ", "))") }
        if let r = meta.rating {
            let n = meta.ratingCount.map { " from \($0) ratings" } ?? ""
            lines.append("Workshop rating: \(Int(r))/5 stars\(n)")
        }
        if meta.updatedAt > 0 { lines.append("Last updated on Workshop: \(Fmt.date(unix: meta.updatedAt))") }
        lines.append("")
        lines.append("Installed on: \(stamp.string(from: Date()))")
        lines.append("Installed with: ModShelf \(modShelfVersion) (build \(modShelfBuild))")
        lines.append("Size: \(Fmt.bytes(bytes)) - Files: \(files)")
        lines.append("")
        lines.append("This file is written by ModShelf and is safe to delete or leave as is, turn future info files off in ModShelf's options.")
        return lines.joined(separator: "\n")
    }

    nonisolated static func scan(folder: String) -> (exists: Bool, count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return (false, 0, 0) }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return (true, 0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let file as URL in en {
            if file.lastPathComponent == modShelfInfoFileName { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { count += 1; bytes += Int64(values?.fileSize ?? 0) }
        }
        return (true, count, bytes)
    }

    nonisolated static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    // MARK: library actions

    func remove(_ item: WorkshopItem) {
        do { if FileManager.default.fileExists(atPath: item.folder) { try FileManager.default.removeItem(atPath: item.folder) } }
        catch { errorMessage = "Couldn't delete those files."; return }
        library.removeAll { $0.id == item.id }; saveLibrary(); refreshLibraryBytes()
    }
    func requestDelete(_ item: WorkshopItem) {
        if UserDefaults.standard.object(forKey: "options.confirmDelete") as? Bool ?? true {
            pendingDelete = item; showDeleteConfirmation = true
        } else { remove(item) }
    }

    /// Mods for `appID` that are installed somewhere other than `root`, e.g. after the game's folder changed.
    func modsOutside(_ root: URL, forGame appID: String) -> [WorkshopItem] {
        library.filter { item in
            guard item.appID == appID else { return false }
            let parent = URL(fileURLWithPath: item.folder, isDirectory: true).deletingLastPathComponent()
            return parent.path != root.path
        }
    }

    func move(_ ids: [String], toPicked url: URL, onDone: (([String]) -> Void)? = nil) {
        let started = url.startAccessingSecurityScopedResource()
        move(ids, toRoot: url, label: Self.displayName(url), scope: started ? url : nil, onDone: onDone)
    }

    /// Moves whole installations, keeping each mod's folder name. Only mods whose files really moved get
    /// their recorded path changed, so a failure never leaves a library entry pointing at nothing.
    func move(_ ids: [String], toRoot root: URL, label: String, scope: URL? = nil, onDone: (([String]) -> Void)? = nil) {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return }
        let entries = library.filter { wanted.contains($0.id) }.map { (id: $0.id, folder: $0.folder, title: $0.displayTitle) }
        guard !entries.isEmpty else { scope?.stopAccessingSecurityScopedResource(); return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            scope?.stopAccessingSecurityScopedResource()
            errorMessage = "Couldn't use that folder."
            Haptics.error()
            return
        }
        guard Self.canWrite(into: root) else {
            scope?.stopAccessingSecurityScopedResource()
            errorMessage = "Can't save to \(label). Pick another folder."
            Haptics.error()
            return
        }
        operationMessage = "Moving \(entries.count) mod\(entries.count == 1 ? "" : "s") to \(label)…"

        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (moved: [(String, String)], failed: [String]) in
                var moved: [(String, String)] = []
                var failed: [String] = []
                let fm = FileManager.default
                for entry in entries {
                    let source = URL(fileURLWithPath: entry.folder, isDirectory: true)
                    guard fm.fileExists(atPath: source.path) else {
                        failed.append("\(entry.title) (files missing)")
                        continue
                    }
                    if source.deletingLastPathComponent().path == root.path { continue }
                    let destination = Self.availableURL(name: source.lastPathComponent, id: entry.id, in: root)
                    do {
                        try Self.place(from: source, to: destination)
                        moved.append((entry.id, destination.path))
                    } catch {
                        failed.append("\(entry.title) (\(error.localizedDescription))")
                    }
                }
                return (moved, failed)
            }.value

            scope?.stopAccessingSecurityScopedResource()
            var movedIDs: [String] = []
            for (id, path) in outcome.moved {
                guard let index = self.library.firstIndex(where: { $0.id == id }) else { continue }
                self.library[index].folder = path
                self.library[index].filesBroken = false
                movedIDs.append(id)
            }
            if !movedIDs.isEmpty { self.saveLibrary(); self.refreshLibraryBytes() }
            onDone?(movedIDs)
            if outcome.failed.isEmpty {
                operationMessage = movedIDs.isEmpty
                    ? "Those mods are already in \(label)."
                    : "Moved \(movedIDs.count) mod\(movedIDs.count == 1 ? "" : "s") to \(label)."
                Haptics.success()
            } else if movedIDs.isEmpty {
                errorMessage = "Nothing was moved. \(outcome.failed.joined(separator: ", "))"
                Haptics.error()
            } else {
                errorMessage = "Moved \(movedIDs.count), but \(outcome.failed.count) failed: \(outcome.failed.joined(separator: ", "))"
                Haptics.error()
            }
        }
    }

    /// Deletes several installations. An entry stays in the library when its files can't be removed.
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let entries = library.filter { wanted.contains($0.id) }
        var removed: [String] = []
        var failed: [String] = []
        for item in entries {
            do {
                if FileManager.default.fileExists(atPath: item.folder) {
                    try FileManager.default.removeItem(atPath: item.folder)
                }
                removed.append(item.id)
            } catch {
                failed.append("\(item.displayTitle) (\(error.localizedDescription))")
            }
        }
        if !removed.isEmpty {
            library.removeAll { removed.contains($0.id) }
            saveLibrary()
            refreshLibraryBytes()
        }
        if failed.isEmpty {
            operationMessage = "Deleted \(removed.count) mod\(removed.count == 1 ? "" : "s")."
            Haptics.success()
        } else {
            errorMessage = "Couldn't delete \(failed.count) mod\(failed.count == 1 ? "" : "s"): \(failed.joined(separator: ", "))"
            Haptics.error()
        }
    }

    func toggleFavourite(_ item: WorkshopItem) {
        guard let i = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[i].isFavourite.toggle()
        saveLibrary()
        Haptics.tap()
    }
    func export(_ item: WorkshopItem) {
        let source = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { errorMessage = "Those files are missing. Download the mod again."; return }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.displayTitle.replacingOccurrences(of: "/", with: "-")).zip")
        do { try? FileManager.default.removeItem(at: zip); try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: true); shareURL = zip }
        catch { errorMessage = "Couldn't build the ZIP." }
    }
    func exportAll() {
        guard !library.isEmpty else { operationMessage = "Your library is empty."; return }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ModShelf-Library", isDirectory: true)
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("ModShelf-Library.zip")
        let entries = library.map { ($0.folder, $0.displayTitle) }
        operationMessage = "Building ZIP of your library…"
        Task { @MainActor in
            let ok: Bool = await Task.detached(priority: .utility) { () -> Bool in
                let fm = FileManager.default
                try? fm.removeItem(at: staging); try? fm.removeItem(at: zip)
                do {
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    for (folder, _) in entries where fm.fileExists(atPath: folder) {
                        let src = URL(fileURLWithPath: folder, isDirectory: true)
                        try fm.copyItem(at: src, to: staging.appendingPathComponent(src.lastPathComponent, isDirectory: true))
                    }
                    try fm.zipItem(at: staging, to: zip, shouldKeepParent: false)
                    try? fm.removeItem(at: staging)
                    return true
                } catch { return false }
            }.value
            if ok { operationMessage = ""; shareURL = zip } else { operationMessage = "Couldn't build the library ZIP." }
        }
    }

    /// Steam's size and the files on disk are close, not always identical, so allow a small margin.
    nonisolated static func sizeMatches(disk: Int64, steam: Int64) -> Bool {
        let tolerance = max(256 * 1024, steam / 10)
        return abs(disk - steam) <= tolerance
    }

    private func applyCheck(_ id: String, broken: Bool) {
        if let i = library.firstIndex(where: { $0.id == id }) { library[i].filesBroken = broken; saveLibrary() }
    }

    func verify(_ item: WorkshopItem) {
        guard !isVerifyingAll else { return }
        let folder = item.folder
        operationMessage = "Validating \(item.displayTitle)…"
        Task { @MainActor in
            let scan = await Task.detached(priority: .utility) { Self.scan(folder: folder) }.value
            guard scan.exists, scan.count > 0 else {
                applyCheck(item.id, broken: true)
                operationMessage = scan.exists
                    ? "\(item.displayTitle) has no files left. Download it again."
                    : "\(item.displayTitle) is missing from its folder."
                return
            }
            guard let meta = await SteamMeta.fetch(id: item.id, includePage: false), meta.fileSize > 0 else {
                operationMessage = "Couldn't check \(item.displayTitle) with Steam."
                return
            }
            let ok = Self.sizeMatches(disk: scan.bytes, steam: meta.fileSize)
            applyCheck(item.id, broken: !ok)
            operationMessage = ok
                ? "\(item.displayTitle) matches Steam (\(Fmt.bytes(scan.bytes)))."
                : "\(item.displayTitle) doesn't match Steam (\(Fmt.bytes(scan.bytes)) here, \(Fmt.bytes(meta.fileSize)) expected)."
        }
    }

    func verifyAllFiles() {
        guard !isVerifyingAll else { return }
        guard !library.isEmpty else { operationMessage = "Your library is empty."; return }
        isVerifyingAll = true
        let entries = library.map { ($0.id, $0.displayTitle, $0.folder) }
        Task { @MainActor in
            var localTotal: Int64 = 0
            var steamTotal: Int64 = 0
            var mismatches: [String] = []
            var checked = 0
            for (index, entry) in entries.enumerated() {
                operationMessage = "Validating \(index + 1) of \(entries.count)…"
                let folder = entry.2
                let scan = await Task.detached(priority: .utility) { Self.scan(folder: folder) }.value
                guard scan.exists, scan.count > 0 else {
                    applyCheck(entry.0, broken: true)
                    mismatches.append(entry.1)
                    continue
                }
                guard let meta = await SteamMeta.fetch(id: entry.0, includePage: false), meta.fileSize > 0 else { continue }
                checked += 1
                localTotal += scan.bytes
                steamTotal += meta.fileSize
                let ok = Self.sizeMatches(disk: scan.bytes, steam: meta.fileSize)
                applyCheck(entry.0, broken: !ok)
                if !ok { mismatches.append(entry.1) }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            isVerifyingAll = false
            operationMessage = mismatches.isEmpty
                ? "All \(checked) mods match Steam (\(Fmt.bytes(localTotal)) of \(Fmt.bytes(steamTotal)))."
                : "\(mismatches.count) of \(checked) mods don't match Steam: \(mismatches.joined(separator: ", "))."
        }
    }

    // MARK: update checks

    func checkUpdates(_ item: WorkshopItem) {
        guard !isCheckingUpdates else { operationMessage = "An update check is already running."; return }
        isCheckingUpdates = true
        operationMessage = "Checking for updates…"
        Task { @MainActor in
            let success = await refreshMetadata(for: item, full: true)
            isCheckingUpdates = false
            if success, let latest = library.first(where: { $0.id == item.id }) {
                operationMessage = latest.updateAvailable ? "Update available: \(latest.displayTitle)" : "\(latest.displayTitle) is up to date."
            } else {
                operationMessage = "Couldn't check item \(item.id). It may be private or deleted."
            }
        }
    }

    private func refreshMetadata(for item: WorkshopItem, full: Bool) async -> Bool {
        let needPage = full || item.rating == nil || item.gameName == nil
        guard let meta = await SteamMeta.fetch(id: item.id, includePage: needPage) else {
            if let i = library.firstIndex(where: { $0.id == item.id }) { library[i].checkFailed = true; saveLibrary() }
            return false
        }
        guard let index = library.firstIndex(where: { $0.id == item.id }) else { return false }
        let installedStamp = library[index].publishedUpdatedAt ?? 0
        if installedStamp == 0 {
            library[index].publishedUpdatedAt = meta.updatedAt   // legacy entry: treat the current version as installed
            library[index].updateAvailable = false
        } else {
            library[index].updateAvailable = meta.updatedAt > installedStamp   // installed stamp is only changed by a real download
        }
        library[index].lastCheckedAt = Date()
        library[index].checkFailed = false
        library[index].title = meta.title
        if !meta.description.isEmpty { library[index].description = meta.description }
        if !meta.imageURL.isEmpty { library[index].imageURL = meta.imageURL }
        if let app = meta.appID { library[index].appID = app }
        if let game = meta.gameName { library[index].gameName = game }
        if !meta.tags.isEmpty { library[index].tags = meta.tags }
        if meta.rating != nil { library[index].rating = meta.rating; library[index].ratingCount = meta.ratingCount }
        saveLibrary()
        return true
    }

    func checkAllUpdates(silent: Bool = false) {
        guard !isCheckingUpdates else { if !silent { operationMessage = "An update check is already running." }; return }
        guard !library.isEmpty else { if !silent { operationMessage = "Your library is empty." }; return }
        isCheckingUpdates = true
        let entries = library
        Task { @MainActor in
            var checked = 0, updated = 0, failed = 0
            for item in entries {
                if !silent { operationMessage = "Checking updates: \(checked + failed + 1) of \(entries.count)…" }
                if await refreshMetadata(for: item, full: false) {
                    checked += 1
                    if library.first(where: { $0.id == item.id })?.updateAvailable == true { updated += 1 }
                } else { failed += 1 }
                if checked + failed < entries.count { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            isCheckingUpdates = false
            if silent {
                operationMessage = updated > 0 ? "\(updated) mod update\(updated == 1 ? "" : "s") available." : ""
            } else {
                operationMessage = "Update check complete: \(checked) checked, \(updated) update(s) available, \(failed) failed."
            }
        }
    }

    /// Runs once per launch: quick folder check, then an update check for every mod.
    func runLaunchChecks() {
        guard !didLaunchChecks else { return }
        didLaunchChecks = true
        var changed = false
        for i in library.indices {
            let missing = !FileManager.default.fileExists(atPath: library[i].folder)
            if library[i].filesBroken != missing { library[i].filesBroken = missing; changed = true }
        }
        if changed { saveLibrary() }
        if UserDefaults.standard.object(forKey: "options.autoCheck") as? Bool ?? true { checkAllUpdates(silent: true) }
    }

    func retry(_ record: DownloadRecord) {
        input = record.workshopID
        if let item = library.first(where: { $0.id == record.workshopID }) { update(item) }
        else { download(record.workshopID) }
    }
    func clearHistory() { history.removeAll(); saveHistory(); UserDefaults.standard.removeObject(forKey: "history") }
    func clearTemporaryFiles() {
        do {
            try FileManager.default.createDirectory(at: temporaryPath, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: temporaryPath, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
            // Leftover partial downloads and replaced copies from interrupted sessions, in every folder
            // ModShelf writes to.
            loadGameFolders()
            var roots = [downloadsRoot]
            roots.append(contentsOf: gameRoots.values)
            for root in roots {
                for url in visibleAndHidden(root)
                where url.lastPathComponent.hasPrefix(".partial-") || url.lastPathComponent.hasPrefix(".modshelf-replacing-") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            status = "Temporary files cleared"
            operationMessage = "Temporary files cleared."
        } catch { errorMessage = "Couldn't clear temporary files." }
    }
    private func visibleAndHidden(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    func refreshLibraryBytes() {
        let folders = library.map(\.folder)
        Task { @MainActor in
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                var sum: Int64 = 0
                for folder in folders { sum += Self.scan(folder: folder).bytes }
                return sum
            }.value
            libraryStorageBytes = total
        }
    }
}

// MARK: - Scroll tracking

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// Reads the scroll position from the UIScrollView that contains it, so folding works in every tab.
struct ScrollSpy: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> SpyView {
        let view = SpyView()
        view.onChange = onChange
        return view
    }
    func updateUIView(_ view: SpyView, context: Context) { view.onChange = onChange }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SpyView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 0)
    }

    final class SpyView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?
        private weak var scroll: UIScrollView?

        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }

        private func attach() {
            guard scroll == nil else { return }
            var view: UIView? = superview
            while let v = view {
                if let s = v as? UIScrollView {
                    scroll = s
                    // Scrolling down gives negative values, the same convention the browser uses.
                    observation = s.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                        self?.onChange?(-(sv.contentOffset.y + sv.adjustedContentInset.top))
                    }
                    return
                }
                view = v.superview
            }
        }
    }
}

struct ScrollOffsetReader: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("scroll")).minY)
        }.frame(height: 0)
    }
}

extension View {
    func tabLayer(_ index: Int, selected: Int) -> some View {
        self.opacity(index == selected ? 1 : 0)
            .allowsHitTesting(index == selected)
            .accessibilityHidden(index != selected)
    }
}

// MARK: - Tab bar

struct AppTabBar: View {
    @Binding var selected: Int
    let style: String          // "pill" (shrinks on scroll), "pillFull", "bar"
    let collapsed: Bool
    let libraryBadge: Bool
    var onTap: (Int) -> Void = { _ in }
    private let items: [(String, String)] = [("Download", "arrow.down.circle.fill"), ("Workshop", "safari.fill"),
                                             ("Library", "square.grid.2x2.fill"), ("Options", "gearshape.fill")]

    var body: some View {
        if style == "bar" { bar } else { pill }
    }

    private var pill: some View {
        let compact = collapsed && style == "pill"
        return HStack(spacing: compact ? 2 : 4) {
            ForEach(0..<items.count, id: \.self) { i in pillButton(i, compact: compact) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 5 : 7)
        .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: compact)
    }

    private func pillButton(_ i: Int, compact: Bool) -> some View {
        let on = selected == i
        return Button {
            if selected != i { Haptics.select() }
            onTap(i)
            selected = i
        } label: {
            VStack(spacing: compact ? 0 : 3) {
                icon(i, size: compact ? 22 : 24, compact: compact)
                if !compact { Text(items[i].0).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: compact ? 54 : 78, height: compact ? 40 : 54)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(items[i].0)
    }

    private func icon(_ i: Int, size: CGFloat, compact: Bool = false) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: items[i].1).font(.system(size: size, weight: .semibold))
            if i == 2 && libraryBadge {
                // Blue update badge; scaled down when the pill is folded.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: compact ? 7 : 9, height: compact ? 7 : 9)
                    .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.5))
                    .offset(x: compact ? 3 : 5, y: compact ? -1 : -2)
                    .accessibilityLabel("Updates available")
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { i in
                Button {
                    if selected != i { Haptics.select() }
                    onTap(i)
                    selected = i
                } label: {
                    VStack(spacing: 3) {
                        icon(i, size: 26)
                        Text(items[i].0).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selected == i ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }
}

// MARK: - Small shared controls

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 38
    var tint: Color = .accentColor
    let action: () -> Void
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

struct FilterPill: View {
    let symbol: String
    let title: String
    var active = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(active ? Color.white : Color.primary)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(active ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

struct StatusGlyph: View {
    let status: ModStatus
    var size: CGFloat = 14
    var body: some View {
        switch status {
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(Color.green)
        case .needsUpdate:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size)).foregroundStyle(Color.accentColor)
        case .unverified:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size)).foregroundStyle(Color.yellow)
        }
    }
}

struct RatingLine: View {
    let rating: Double?
    let count: Int?
    var size: CGFloat = 12
    var body: some View {
        if let rating {
            HStack(spacing: 3) {
                Image(systemName: "star.fill").font(.system(size: size - 1)).foregroundStyle(Color.yellow)
                Text(String(format: "%.0f", rating)).font(.system(size: size, weight: .semibold))
                if let count { Text("(\(Fmt.count(count)))").font(.system(size: size)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// One line of text that slides sideways when it doesn't fit, so a long mod name never makes a
/// grid cell taller than its neighbours. It rests a second, slides the whole name into view, holds
/// a second, slides back, then rests again before the next pass. Changing `restartToken` (or the
/// text, or the space it has) starts the cycle over from the beginning.
struct MarqueeText: View {
    let text: String
    let font: Font
    var height: CGFloat = 17
    var speed: CGFloat = 26
    var active = true
    var restartToken = 0

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    /// Any change here cancels the running pass and starts a fresh one.
    private var cycleKey: String {
        "\(restartToken)|\(active)|\(Int(textWidth.rounded()))|\(Int(boxWidth.rounded()))|\(text)"
    }

    var body: some View {
        GeometryReader { geo in
            label
                .fixedSize()
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { setTextWidth(g.size.width) }
                            .onChange(of: g.size.width) { setTextWidth($0) }
                    }
                )
                .offset(x: offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .onAppear { setBoxWidth(geo.size.width) }
                .onChange(of: geo.size.width) { setBoxWidth($0) }
        }
        .frame(height: height)
        .accessibilityLabel(text)
        .onChange(of: restartToken) { _ in snapToStart() }
        .onChange(of: active) { isActive in
            if !isActive { snapToStart() }
        }
        .onDisappear { snapToStart() }
        .task(id: cycleKey) { await run() }
    }

    /// Puts the name back at its first letter without animating the change.
    private func snapToStart() {
        withTransaction(Transaction(animation: nil)) { offset = 0 }
    }

    private var label: some View {
        Text(text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    private func setTextWidth(_ width: CGFloat) {
        guard abs(width - textWidth) > 0.5 else { return }
        textWidth = width
    }

    private func setBoxWidth(_ width: CGFloat) {
        guard abs(width - boxWidth) > 0.5 else { return }
        boxWidth = width
    }

    @MainActor
    private func run() async {
        // Always begin on the first letter, with no animation carrying over.
        snapToStart()
        guard active, overflow > 0.5 else { return }
        while !Task.isCancelled {
            // A second at rest before setting off.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }

            let distance = overflow
            let travel = max(1.2, Double(distance / max(1, speed)))
            withAnimation(.linear(duration: travel)) { offset = -distance }
            // A second with the end of the name showing.
            try? await Task.sleep(nanoseconds: UInt64((travel + 1.0) * 1_000_000_000))
            if Task.isCancelled { return }

            // Snap back to the start, then rest before the next pass.
            snapToStart()
            try? await Task.sleep(nanoseconds: 1_250_000_000)
        }
    }
}

/// Three dots that ripple while mods are selected, so the actions button waves instead of sitting still.
struct SelectionWaveDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 4)
                        .offset(y: sin(t * 5 - Double(index) * 0.8) * 2.2)
                }
            }
            .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Selection actions")
    }
}

/// A word followed by an ellipsis that grows and resets, so "Downloading" reads as active.
struct DottedLabel: View {
    let text: String
    var interval: Double = 0.45

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let step = Int(abs(context.date.timeIntervalSinceReferenceDate) / interval) % 4
            Text(text + String(repeating: ".", count: step))
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = true
    @AppStorage("options.haptics") private var haptics = true
    @AppStorage("browser.autoDownload") private var autoDownload = false
    @AppStorage("browser.confirmAutoDownload") private var confirmAutoDownload = false
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @AppStorage("options.gifLibrary") private var gifLibrary = true
    @AppStorage("options.tabStyle") private var tabStyle = "bar"
    @AppStorage("options.sortOrder") private var sortOrder = "Recently added"
    @AppStorage("options.autoCheck") private var autoCheck = true
    @AppStorage("options.wifiOnly") private var wifiOnly = false
    @AppStorage("options.infoFile") private var infoFile = true
    @State private var selectedTab = 0
    @State private var showShare = false
    @State private var popupItem: WorkshopItem?
    @State private var contextItem: WorkshopItem?
    @State private var contextHistory: DownloadRecord?
    @State private var searchText = ""
    @State private var showingHistory = false
    @State private var inputWasSubmitted = false
    @State private var pendingDeleteItem: WorkshopItem?
    @State private var tabCollapsed = false
    @State private var scrollAnchor: CGFloat = 0
    @State private var folderSheet: FolderSheet?
    @State private var moveSheetOpen = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var pendingRelocate: RelocateRequest?
    @State private var mediaViewer: MediaViewer?
    @State private var mediaIndex = 0
    @State private var marqueeToken = 0
    @State private var showFolderTip = false
    @State private var scrollToGameFolders = 0
    @State private var pendingAutoDownload: String?
    @AppStorage("options.folderTipShown") private var folderTipShown = false
    @State private var selectedGame: String? = nil
    @State private var selectedTag: String? = nil
    @State private var favouritesOnly = false
    @State private var themeOpen = false
    @State private var tabStyleOpen = false
    @State private var sortOpen = false
    @State private var confirmClearHistory = false
    @State private var lastScrollY: CGFloat = 0
    @State private var libraryFilter = "All"
    @State private var upwardRun: CGFloat = 0
    @State private var browserHomeToken = 0
    @State private var lastWorkshopTap = Date.distantPast

    /// Space reserved under every tab for the tab bar, so content can always scroll clear of it.
    private var tabBarReserve: CGFloat { tabStyle == "bar" ? 84 : 100 }

    private let sortOrders = ["Recently added", "Oldest added", "Name", "Updates first", "Highest rated", "Favourites first"]

    // MARK: derived library data

    private var installedGames: [(id: String, name: String)] {
        var seen: [String: String] = [:]
        for item in store.library { if let app = item.appID { seen[app] = item.gameName ?? "App \(app)" } }
        return seen.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var installedTags: [String] {
        let pool = store.library.filter { selectedGame == nil || $0.appID == selectedGame }
        let all = Set(pool.flatMap { $0.tags })
        return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    private var selectedGameName: String? {
        guard let g = selectedGame else { return nil }
        return installedGames.first(where: { $0.id == g })?.name
    }
    private var filteredLibrary: [WorkshopItem] {
        let filtered = store.library.filter { item in
            if libraryFilter == "Favourites" && !item.isFavourite { return false }
            if libraryFilter == "Updates" && !item.updateAvailable { return false }
            if libraryFilter == "Problems" && !(item.filesBroken || item.checkFailed) { return false }
            if let g = selectedGame, item.appID != g { return false }
            if let t = selectedTag, !item.tags.contains(t) { return false }
            if searchText.isEmpty { return true }
            if item.displayTitle.localizedCaseInsensitiveContains(searchText) { return true }
            if item.id.contains(searchText) { return true }
            return (item.gameName ?? "").localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case "Name": return filtered.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case "Updates first": return filtered.sorted { $0.updateAvailable && !$1.updateAvailable }
        case "Oldest added": return filtered.sorted { $0.addedAt < $1.addedAt }
        case "Highest rated": return filtered.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case "Favourites first": return filtered.sorted { $0.isFavourite && !$1.isFavourite }
        default: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    /// Every game that gets a folder row: the ones in the library plus any game with a chosen folder.
    private var gamesForFolders: [(id: String, name: String)] {
        var map: [String: String] = [:]
        for game in installedGames { map[game.id] = game.name }
        for id in store.customGameFolders.keys where map[id] == nil {
            map[id] = store.gameDisplayName(id)
        }
        return map.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var moveDestinations: [MoveDestination] {
        var list: [MoveDestination] = [
            MoveDestination(id: "shared", title: "Shared mod folder", detail: store.folderLabel)
        ]
        for game in gamesForFolders {
            list.append(MoveDestination(id: game.id, title: "\(game.name) folder",
                                        detail: store.customGameFolders[game.id] ?? store.folderLabel))
        }
        return list
    }

    private func toggleSelection(_ item: WorkshopItem) {
        Haptics.select()
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        if selection.isEmpty { selecting = false }
    }

    private func selectAllVisible() {
        selection.formUnion(filteredLibrary.map(\.id))
        Haptics.select()
    }

    /// Bulk delete respects the same confirmation setting as deleting one mod.
    private func requestDeleteSelected() {
        guard !selection.isEmpty else { return }
        if confirmDelete { confirmBulkDelete = true } else { deleteSelected() }
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        store.remove(Array(selection))
        let liveIDs = Set(store.library.map(\.id))
        selection = selection.intersection(liveIDs)
        if selection.isEmpty { selecting = false }
        confirmBulkDelete = false
    }

    /// After a folder change, mods still in the old place are offered a move rather than silently left behind.
    private func offerRelocation(for appID: String) {
        let root = store.root(forGame: appID)
        let items = store.modsOutside(root, forGame: appID)
        guard !items.isEmpty else { return }
        // The folder the mods are in now becomes the "Before" side of the offer.
        let previous = items.first.map {
            WorkshopStore.displayName(URL(fileURLWithPath: $0.folder, isDirectory: true).deletingLastPathComponent())
        } ?? "the old folder"
        pendingRelocate = RelocateRequest(gameName: store.gameDisplayName(appID),
                                          root: root,
                                          folderName: WorkshopStore.displayName(root),
                                          previousFolder: previous,
                                          ids: items.map(\.id))
    }

    private func destinationRoot(_ destination: MoveDestination) -> URL {
        destination.id == "shared" ? store.root(forGame: nil) : store.root(forGame: destination.id)
    }

    // MARK: body

    var body: some View {
        ZStack {
            mainStack
            overlays
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showShare, onDismiss: { store.shareURL = nil }) { if let url = store.shareURL { ShareSheet(activityItems: [url]) } }
        .sheet(isPresented: Binding(get: { store.revealFolderURL != nil },
                                    set: { if !$0 { store.revealFolderURL = nil } })) {
            FolderPicker(onPick: { _ in store.revealFolderURL = nil },
                         onCancel: { store.revealFolderURL = nil },
                         startURL: store.revealFolderURL)
        }
        .sheet(item: $folderSheet) { sheet in
            switch sheet {
            case .shared:
                FolderPicker(onPick: { url in
                    folderSheet = nil
                    store.setFolder(url, for: nil)
                }, onCancel: { folderSheet = nil }, startURL: store.currentRootURL)
            case .game(let appID):
                FolderPicker(onPick: { url in
                    folderSheet = nil
                    store.setFolder(url, for: appID)
                    offerRelocation(for: appID)
                }, onCancel: { folderSheet = nil }, startURL: store.root(forGame: appID))
            case .moveDestination:
                FolderPicker(onPick: { url in
                    folderSheet = nil
                    store.move(Array(selection), toPicked: url) { moved in
                        selection.subtract(moved)
                        if selection.isEmpty { selecting = false }
                    }
                }, onCancel: { folderSheet = nil }, startURL: store.currentRootURL)
            }
        }
        .sheet(isPresented: $moveSheetOpen) {
            MoveDestinationSheet(destinations: moveDestinations,
                                 onPick: { destination in
                                     moveSheetOpen = false
                                     let ids = Array(selection)
                                     guard !ids.isEmpty else { return }
                                     store.move(ids, toRoot: destinationRoot(destination), label: destination.title) { moved in
                                         selection.subtract(moved)
                                         if selection.isEmpty { selecting = false }
                                     }
                                 },
                                 onChooseFolder: {
                                     moveSheetOpen = false
                                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { folderSheet = .moveDestination }
                                 },
                                 onCancel: { moveSheetOpen = false })
        }
        .onChange(of: store.shareURL) { showShare = $0 != nil }
        .onChange(of: confirmDelete) { UserDefaults.standard.set($0, forKey: "options.confirmDelete") }
        .onChange(of: scenePhase) { phase in
            // Coming back from another app restarts the scrolling names, like arriving on the tab does.
            if phase == .active, selectedTab == 2 { marqueeToken += 1 }
        }
        .onChange(of: store.errorMessage) { message in
            guard !message.isEmpty, !store.showLogin else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if store.errorMessage == message && !store.showLogin { withAnimation { store.errorMessage = "" } }
            }
        }
        .onChange(of: store.operationMessage) { message in
            guard !message.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if store.operationMessage == message { withAnimation { store.operationMessage = "" } }
            }
        }
        .onChange(of: store.library.count) { count in
            if let g = selectedGame, !installedGames.contains(where: { $0.id == g }) { selectedGame = nil }
            if let t = selectedTag, !installedTags.contains(t) { selectedTag = nil }
            // A selection can never keep mods that are no longer in the library.
            let liveIDs = Set(store.library.map(\.id))
            selection = selection.intersection(liveIDs)
            if selection.isEmpty { selecting = false }
            if let request = pendingRelocate {
                let remaining = request.ids.filter { liveIDs.contains($0) }
                pendingRelocate = remaining.isEmpty ? nil
                    : RelocateRequest(gameName: request.gameName, root: request.root,
                                      folderName: request.folderName,
                                      previousFolder: request.previousFolder,
                                      ids: remaining)
            }
            // The first mod that lands is the moment to mention per-game folders.
            if count == 1, !folderTipShown { withAnimation(.easeOut(duration: 0.2)) { showFolderTip = true } }
        }
        .onChange(of: autoDownload) { on in
            // Auto download starts with its confirmation armed, and off with it off.
            confirmAutoDownload = on
        }
        .onChange(of: store.preview) { _ in
            mediaIndex = 0
            mediaViewer = nil
        }
        .task { store.runLaunchChecks() }
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            accountHeader
            if !store.showLogin { errorBanner }
            downloadBanner
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab, style: tabStyle, collapsed: tabCollapsed,
                      libraryBadge: store.library.contains(where: { $0.updateAvailable }),
                      onTap: { tabTapped($0) })
                .frame(height: tabBarReserve, alignment: .bottom)
        }
        .tint(Color.accentColor)
        .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))
        .onChange(of: selectedTab) { tab in
            tabCollapsed = false
            // Every arrival on the library restarts the scrolling names from their resting place.
            if tab == 2 { marqueeToken += 1 }
        }
    }

    private var tabContent: some View {
        ZStack(alignment: .top) {
            downloadView.tabLayer(0, selected: selectedTab)
            browserTab.tabLayer(1, selected: selectedTab)
            libraryView.tabLayer(2, selected: selectedTab)
            optionsView.tabLayer(3, selected: selectedTab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var browserTab: some View {
        WorkshopBrowserView(onOpenInApp: { id in
                                inputWasSubmitted = false
                                selectedTab = 0
                                if autoDownload {
                                    if confirmAutoDownload {
                                        pendingAutoDownload = id
                                    } else {
                                        store.download(id)
                                    }
                                } else {
                                    store.input = id
                                    store.fetchPreview()
                                }
                            },
                            requestedURL: $store.browserURL,
                            cleanPages: true,
                            bottomInset: tabBarReserve,
                            homeToken: browserHomeToken,
                            onScroll: { y in handleScroll(y) })
            .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder private var overlays: some View {
        if let item = popupItem {
            Color.black.opacity(0.34).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } }
            ItemDetailPopup(item: currentItem(item), store: store, showIDs: showIDs,
                            onClose: { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } },
                            onOpenWorkshop: { openWorkshop(item.id); popupItem = nil },
                            onDelete: { store.requestDelete(item); popupItem = nil })
                .padding(20).transition(.scale(scale: 0.97).combined(with: .opacity)).zIndex(5)
        }
        if let item = contextItem {
            Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.14)) { contextItem = nil } }.zIndex(6)
            ItemActionPopup(item: currentItem(item),
                            openWorkshop: { openWorkshop(item.id); contextItem = nil },
                            copyID: { UIPasteboard.general.string = item.id; store.operationMessage = "Workshop ID copied."; contextItem = nil },
                            share: { store.shareURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)"); contextItem = nil },
                            reveal: { store.revealInFiles(item); contextItem = nil },
                            favourite: { store.toggleFavourite(item); contextItem = nil },
                            updateNow: { store.update(item); selectedTab = 0; contextItem = nil },
                            checkUpdates: { store.checkUpdates(item); contextItem = nil },
                            verify: { store.verify(item); contextItem = nil },
                            export: { store.export(item); contextItem = nil },
                            delete: { store.requestDelete(item); contextItem = nil })
                .padding(28).transition(.scale(scale: 0.96).combined(with: .opacity)).zIndex(7)
        }
        if let record = contextHistory {
            Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.14)) { contextHistory = nil } }.zIndex(8)
            HistoryActionPopup(record: record,
                               openWorkshop: { openWorkshop(record.workshopID); contextHistory = nil },
                               copyID: { UIPasteboard.general.string = record.workshopID; store.operationMessage = "Workshop ID copied."; contextHistory = nil },
                               retry: { store.retry(record); selectedTab = 0; contextHistory = nil },
                               close: { contextHistory = nil })
                .padding(28).transition(.scale(scale: 0.96).combined(with: .opacity)).zIndex(9)
        }
        if confirmClearHistory {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { confirmClearHistory = false }.zIndex(12)
            ConfirmPopup(heading: "Clear download history?",
                         message: "This removes the list of attempts. Your downloaded mods are not affected.",
                         actionTitle: "Clear",
                         confirm: { store.clearHistory(); confirmClearHistory = false },
                         cancel: { confirmClearHistory = false })
                .padding(30).zIndex(13)
        }
        if store.showDeleteConfirmation, let item = store.pendingDelete {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { store.showDeleteConfirmation = false }.zIndex(10)
            DeleteConfirmationPopup(title: item.displayTitle,
                                    confirm: { store.remove(item); store.showDeleteConfirmation = false },
                                    cancel: { store.showDeleteConfirmation = false })
                .padding(30).zIndex(11)
        }
        if confirmBulkDelete {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { confirmBulkDelete = false }.zIndex(14)
            ConfirmPopup(heading: "Delete \(selection.count) mod\(selection.count == 1 ? "" : "s")?",
                         message: "Their downloaded files will be removed from this iPhone. You can download them again later.",
                         actionTitle: "Delete",
                         confirm: {
                             deleteSelected()
                         },
                         cancel: { confirmBulkDelete = false })
                .padding(30).zIndex(15)
        }
        if let request = pendingRelocate {
            Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { pendingRelocate = nil }.zIndex(16)
            ConfirmPopup(heading: "Move \(request.ids.count) mod\(request.ids.count == 1 ? "" : "s")?",
                         message: "Before: \(request.previousFolder)\nNow: \(request.folderName)\n\nModShelf can move the existing \(request.gameName) mods to the new folder now, or leave them where they are.",
                         actionTitle: "Move them",
                         tint: .accentColor,
                         confirm: {
                             let ids = request.ids
                             let root = request.root
                             pendingRelocate = nil
                             store.move(ids, toRoot: root, label: request.folderName)
                         },
                         cancel: { pendingRelocate = nil })
                .padding(30).zIndex(17)
        }
        if let viewer = mediaViewer {
            ExpandedMediaView(media: viewer.media, startIndex: viewer.index,
                              onIndexChange: { mediaIndex = $0 }) {
                withAnimation(.easeOut(duration: 0.18)) { mediaViewer = nil }
            }
            .transition(.opacity)
            .zIndex(20)
        }
        if showFolderTip {
            Color.black.opacity(0.34).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { dismissFolderTip() }.zIndex(21)
            FolderTipPopup(onDetails: {
                dismissFolderTip()
                selectedTab = 3
                scrollToGameFolders += 1
            }, onClose: { dismissFolderTip() })
                .padding(30).zIndex(22)
        }
        if let id = pendingAutoDownload {
            Color.black.opacity(0.34).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { pendingAutoDownload = nil }.zIndex(23)
            ConfirmPopup(heading: "Download this mod?",
                         message: "Start downloading \(downloadName(for: id)) now?",
                         actionTitle: "Download",
                         tint: .accentColor,
                         confirm: {
                             pendingAutoDownload = nil
                             store.download(id)
                         },
                         cancel: { pendingAutoDownload = nil })
                .padding(30).zIndex(24)
        }
    }

    private func downloadName(for id: String) -> String {
        if let preview = store.preview, preview.id == id { return preview.title }
        if let item = store.library.first(where: { $0.id == id }) { return item.displayTitle }
        return "Workshop item \(id)"
    }

    /// Popups hold a snapshot; this returns the freshest copy so favourite/status changes show immediately.
    private func currentItem(_ item: WorkshopItem) -> WorkshopItem {
        store.library.first(where: { $0.id == item.id }) ?? item
    }

    private func dismissFolderTip() {
        withAnimation(.easeOut(duration: 0.16)) { showFolderTip = false }
        folderTipShown = true
    }

    // MARK: header

    private var accountHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text("ModShelf").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                signInPill
            }
            .padding(.horizontal, 16).padding(.top, 0).padding(.bottom, 14)
            fadingLine
        }
    }

    private var signInPill: some View {
        Button {
            if !store.isAuthenticated { store.showLogin = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                Text(store.isAuthenticated ? "Signed in" : "Sign in")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(store.isAuthenticated ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(store.isAuthenticated ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isAuthenticated ? "Signed in to Steam" : "Sign in to Steam")
    }

    private var fadingLine: some View {
        LinearGradient(stops: [.init(color: Color.accentColor.opacity(0), location: 0),
                               .init(color: Color.accentColor, location: 0.3),
                               .init(color: Color.accentColor, location: 0.7),
                               .init(color: Color.accentColor.opacity(0), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 2)
            .shadow(color: Color.accentColor.opacity(0.55), radius: 4)
            .padding(.horizontal, 12)
    }

    @ViewBuilder private var errorBanner: some View {
        if (!store.errorMessage.isEmpty && !store.showLogin) || !store.operationMessage.isEmpty {
            let isError = !store.errorMessage.isEmpty && !store.showLogin
            let text = isError ? friendlyError(store.errorMessage) : store.operationMessage
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isError ? "Couldn't finish that" : bannerTitle).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    if isError { store.errorMessage = "" } else { store.operationMessage = "" }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isError ? Color.red : Color.accentColor))
            .shadow(color: (isError ? Color.red : Color.accentColor).opacity(0.35), radius: 10, y: 4)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Turns raw engine text into one short line a person can act on.
    private func friendlyError(_ raw: String) -> String {
        ErrorText.friendly(raw)
    }

    /// The heading of the info banner, so it names what is actually running.
    private var bannerTitle: String {
        if store.isVerifyingAll { return "Validating files" }
        if store.isCheckingUpdates { return "Checking for updates" }
        if store.isDownloading { return "Downloading" }
        if store.isBusy { return "Please wait" }
        return "Status"
    }

    /// How far the download has gone, shown in the three steps Steam reports: the manifest, the
    /// chunk download, then the install.
    private var downloadPercent: Int {
        guard store.isDownloading else { return 100 }
        switch store.phases.count {
        case 0: return 0
        case 1: return 33
        default: return 66
        }
    }

    private var downloadProgress: Double { Double(downloadPercent) / 100 }

    private func progressBar(_ fraction: Double) -> some View {
        let clamped = min(1, max(0, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: clamped > 0 ? max(8, geo.size.width * clamped) : 0)
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.3), value: clamped)
        .accessibilityLabel("Download progress")
    }

    @ViewBuilder private var downloadBanner: some View {
        if store.isDownloading && selectedTab != 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.accentColor)
                    Text(store.activeTitle.isEmpty ? "Downloading" : store.activeTitle)
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(downloadPercent)%")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Button { store.cancel() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel download")
                }
                progressBar(downloadProgress)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.top, 8)
        }
    }

    // MARK: scrolling → tab bar shrink

    private func handleScroll(_ y: CGFloat) {
        guard tabStyle == "pill" else { return }
        let delta = y - lastScrollY
        lastScrollY = y
        if y > -8 {
            // At the top the bar always opens.
            if tabCollapsed { tabCollapsed = false }
            upwardRun = 0
            return
        }
        if delta < 0 {
            // Scrolling down: fold once past the first part of the page, and stay folded.
            upwardRun = 0
            if y < -40 && !tabCollapsed { tabCollapsed = true }
        } else if delta > 0 {
            // Scrolling up: only open after a real upward run, so small bounces don't reopen it.
            upwardRun += delta
            if upwardRun > 40 && tabCollapsed { tabCollapsed = false; upwardRun = 0 }
        }
    }

    private func tabTapped(_ index: Int) {
        guard index == 1 else { lastWorkshopTap = .distantPast; return }
        // Two taps on the Workshop tab within about half a second go back to the start page.
        let now = Date()
        let gap = now.timeIntervalSince(lastWorkshopTap)
        if selectedTab == 1 && gap > 0.08 && gap < 0.45 {
            browserHomeToken += 1
            lastWorkshopTap = .distantPast
            return
        }
        lastWorkshopTap = now
    }

    private func openWorkshop(_ id: String) {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else { return }
        store.browserURL = url
        selectedTab = 1
    }

    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }

    // MARK: - Download tab

    private var downloadView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ScrollSpy(onChange: handleScroll)
                    VStack(alignment: .leading, spacing: 14) {
                        lookupCard
                        if store.isFetching {
                            HStack(spacing: 10) { ProgressView(); Text("Loading Workshop details…").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 2)
                        }
                        if let item = store.preview { metadataCard(item) }
                        if store.isDownloading { progressCard }
                        else if let item = store.preview { downloadButton(item) }
                        if store.preview == nil && !store.isDownloading { browseRow }
                    }
                    .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, tabBarReserve)
                }
            }
            .coordinateSpace(name: "scroll")
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var inputIsInvalid: Bool { inputWasSubmitted && WorkshopStore.workshopID(from: store.input) == nil }

    private var lookupCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Workshop URL or ID", text: $store.input)
                    .accessibilityLabel("Workshop URL or ID")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                    .onSubmit { submitLookup() }
                    .onChange(of: store.input) { _ in if inputWasSubmitted { inputWasSubmitted = false } }
                if !store.input.isEmpty {
                    Button { store.input = ""; store.preview = nil; inputWasSubmitted = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.accessibilityLabel("Clear Workshop URL or ID")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(inputIsInvalid ? Color.red.opacity(0.75) : Color.clear, lineWidth: 1))
            if inputIsInvalid {
                Text("Enter a Workshop URL or numeric item ID.").font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
            }
            Button(action: submitLookup) {
                HStack(spacing: 7) {
                    if store.isFetching { ProgressView().tint(.white) } else { Image(systemName: "magnifyingglass") }
                    Text(store.isFetching ? "Looking up…" : "Look up item")
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(store.isFetching || store.isBusy)
            .opacity(store.isFetching || store.isBusy ? 0.6 : 1)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var browseRow: some View {
        Button { selectedTab = 1 } label: {
            HStack(spacing: 12) {
                Image(systemName: "safari.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                Text("Browse the Workshop").font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func submitLookup() {
        dismissKeyboard()
        guard WorkshopStore.workshopID(from: store.input) != nil else { inputWasSubmitted = true; return }
        inputWasSubmitted = false
        Haptics.tap()
        store.fetchPreview()
    }

    private var operationBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            if store.isCheckingUpdates || store.isVerifyingAll { ProgressView().scaleEffect(0.8) }
            else { Image(systemName: "info.circle.fill").foregroundStyle(.secondary) }
            Text(store.operationMessage).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.operationMessage = "" } label: { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary) }.accessibilityLabel("Dismiss status")
        }
        .padding(11).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 44, height: 44)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                DottedLabel(text: "Downloading")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(downloadPercent)%")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Button { Haptics.tap(); store.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
            progressBar(downloadProgress)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func downloadButton(_ item: WorkshopMetadata) -> some View {
        let existing = store.library.first(where: { $0.id == item.id })
        var label = "Download mod"
        if let existing { label = existing.updateAvailable ? "Update mod" : "Download again" }
        return Button {
            dismissKeyboard(); Haptics.medium(); store.download(item.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 15, weight: .semibold))
                Text(label).font(.system(size: 16, weight: .semibold))
                if item.fileSize > 0 {
                    Text("· \(Fmt.bytes(item.fileSize))")
                        .font(.system(size: 14, weight: .medium))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }

    private func mediaList(for item: WorkshopMetadata) -> [MediaItem] {
        var list: [MediaItem] = []
        if !item.imageURL.isEmpty { list.append(.image(item.imageURL)) }
        for s in item.screenshots { list.append(.image(s)) }
        for v in item.videos { list.append(.video(v)) }
        return list
    }

    private func metadataCard(_ item: WorkshopMetadata) -> some View {
        let media = mediaList(for: item)
        return VStack(alignment: .leading, spacing: 11) {
            if !media.isEmpty {
                MediaCarousel(media: media, index: $mediaIndex, onExpand: { item, index in
                    withAnimation(.easeOut(duration: 0.18)) { mediaViewer = MediaViewer(media: media, index: index) }
                })
                .id(media.map { $0.id }.joined(separator: "|"))
            }
            Text(item.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            infoRow(item)
            if !item.description.isEmpty { ExpandableDescription(text: item.description, lineLimit: 7) }
            workshopRow(item)
        }
        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ item: WorkshopMetadata) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                RatingLine(rating: item.rating, count: item.ratingCount, size: 14)
                if let game = item.gameName {
                    HStack(spacing: 4) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 11))
                        Text(game).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !item.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        }
                    }
                }
            }
        }
    }

    private func workshopRow(_ item: WorkshopMetadata) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button { Haptics.tap(); openWorkshop(item.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "safari").font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Workshop").font(.system(size: 15, weight: .semibold))
                        Text("ID: \(item.id)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            if item.updatedAt > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Updated").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(Fmt.date(unix: item.updatedAt)).font(.system(size: 14, weight: .semibold)).fixedSize()
                    }
                }
                .padding(.horizontal, 12).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill)))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Library tab

    private var libraryView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryHeader
                if showingHistory { historyContent } else { libraryBody }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var librarySubtitle: String {
        if selecting { return "\(selection.count) selected" }
        if showingHistory {
            let failed = store.history.filter { $0.result == "Failed" }.count
            return "\(store.history.count) attempts · \(failed) failed"
        }
        let n = store.library.count
        return "\(n) mod\(n == 1 ? "" : "s") · \(Fmt.bytes(store.libraryStorageBytes))"
    }

    private func iconLabel(_ symbol: String, spinning: Bool = false, waving: Bool = false) -> some View {
        Group {
            if spinning {
                ProgressView()
            } else if waving {
                SelectionWaveDots()
            } else {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 36, height: 36)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.14)))
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showingHistory ? "Download history" : "Library")
                    .font(.system(size: 27, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
                Text(librarySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if showingHistory {
                IconButton(symbol: "trash", size: 36) { if confirmDelete { confirmClearHistory = true } else { store.clearHistory() } }.disabled(store.history.isEmpty)
                IconButton(symbol: "xmark", size: 36) { showingHistory = false }
            } else {
                IconButton(symbol: "clock.arrow.circlepath", size: 36) { showingHistory = true }
                sortMenu
                Button { Haptics.tap(); store.checkAllUpdates() } label: { iconLabel("arrow.clockwise", spinning: store.isCheckingUpdates) }
                    .buttonStyle(.plain).disabled(store.isCheckingUpdates)
                Button { Haptics.tap(); store.verifyAllFiles() } label: { iconLabel("checkmark.shield", spinning: store.isVerifyingAll) }
                    .buttonStyle(.plain).disabled(store.isVerifyingAll)
                moreMenu
            }
        }
        .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 10)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(sortOrders, id: \.self) { order in
                Button {
                    Haptics.select(); sortOrder = order
                } label: {
                    if order == sortOrder { Label(order, systemImage: "checkmark") } else { Text(order) }
                }
            }
        } label: { iconLabel("arrow.up.arrow.down") }
    }

    private var moreMenu: some View {
        Menu {
            if selecting {
                Button { selectAllVisible() } label: { Label("Select all", systemImage: "checkmark.circle") }
                Button { selection.removeAll() } label: { Label("Deselect all", systemImage: "circle.dashed") }
                Divider()
                Button { moveSheetOpen = true } label: { Label("Move selected (\(selection.count))", systemImage: "folder") }
                    .disabled(selection.isEmpty)
                Button(role: .destructive) { requestDeleteSelected() } label: {
                    Label("Delete selected (\(selection.count))", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            } else {
                let pending = store.library.filter { $0.updateAvailable }.count
                Button { store.updateAll(); selectedTab = 0 } label: { Label("Update all (\(pending))", systemImage: "arrow.down.circle") }
                    .disabled(pending == 0 || store.isBusy)
                Button { store.exportAll() } label: { Label("Export all as ZIP", systemImage: "square.and.arrow.up") }
            }
        } label: { iconLabel("ellipsis", waving: selecting) }
    }

    private var libraryBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search library", text: $searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.bottom, 8)

            if !store.library.isEmpty { chipRow; filterRow }

            let items = filteredLibrary
            if store.library.isEmpty {
                emptyState("Your library is empty", detail: "Downloaded mods will appear here.", symbol: "square.grid.2x2")
                Button { selectedTab = 1 } label: {
                    Label("Browse Workshop", systemImage: "safari").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                }.buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 20)
            } else if items.isEmpty {
                emptyState("No matches", detail: "Try a different search or filter.", symbol: "magnifyingglass")
            } else if compactLibrary {
                gridContent(items)
            } else {
                listContent(items)
            }
        }
    }

    private func chipCount(_ name: String) -> Int {
        switch name {
        case "Updates": return store.library.filter { $0.updateAvailable }.count
        case "Favourites": return store.library.filter { $0.isFavourite }.count
        case "Problems": return store.library.filter { $0.filesBroken || $0.checkFailed }.count
        default: return 0
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["All", "Updates", "Favourites", "Problems"], id: \.self) { name in
                    let count = chipCount(name)
                    let on = libraryFilter == name
                    Button { Haptics.select(); libraryFilter = name } label: {
                        HStack(spacing: 5) {
                            Text(name)
                            if count > 0 { Text("\(count)").font(.system(size: 12, weight: .bold).monospacedDigit()).opacity(0.85) }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    if !installedGames.isEmpty {
                        Menu {
                            Button { Haptics.select(); selectedGame = nil; selectedTag = nil } label: {
                                if selectedGame == nil { Label("All games", systemImage: "checkmark") } else { Text("All games") }
                            }
                            ForEach(installedGames, id: \.id) { game in
                                Button { Haptics.select(); selectedGame = game.id; selectedTag = nil } label: {
                                    if selectedGame == game.id { Label(game.name, systemImage: "checkmark") } else { Text(game.name) }
                                }
                            }
                        } label: { FilterPill(symbol: "gamecontroller.fill", title: selectedGameName ?? "All games", active: selectedGame != nil) }
                    }
                    if !installedTags.isEmpty {
                        Menu {
                            Button { Haptics.select(); selectedTag = nil } label: {
                                if selectedTag == nil { Label("All tags", systemImage: "checkmark") } else { Text("All tags") }
                            }
                            ForEach(installedTags, id: \.self) { tag in
                                Button { Haptics.select(); selectedTag = tag } label: {
                                    if selectedTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                                }
                            }
                        } label: { FilterPill(symbol: "tag.fill", title: selectedTag ?? "Tags", active: selectedTag != nil) }
                    }
                    selectPill
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 8)
    }

    /// Selection lives beside the tags, so bulk actions are one tap away without a second menu.
    private var selectPill: some View {
        Button {
            Haptics.select()
            withAnimation(.easeOut(duration: 0.18)) {
                selecting.toggle()
                if !selecting { selection.removeAll() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(selecting ? "Done" : "Select").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(selecting ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selecting ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selecting ? "Finish selecting" : "Select mods")
    }

    // MARK: grid + list

    private func gridContent(_ items: [WorkshopItem]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ScrollSpy(onChange: handleScroll)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in gridCard(item) }
                }
                .padding(.horizontal, 14).padding(.top, 0).padding(.bottom, tabBarReserve)
            }
        }
        .coordinateSpace(name: "scroll")
        .scrollDismissesKeyboard(.interactively)
    }

    private func listContent(_ items: [WorkshopItem]) -> some View {
        List {
            ScrollSpy(onChange: handleScroll)
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(items) { item in
                listRow(item)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color(uiColor: .systemGroupedBackground))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { store.requestDelete(item) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if item.updateAvailable {
                            Button { Haptics.tap(); store.update(item); selectedTab = 0 } label: {
                                Label("Update", systemImage: "arrow.down.circle")
                            }
                            .tint(Color.accentColor)
                        }
                        Button { store.toggleFavourite(item) } label: {
                            Label(item.isFavourite ? "Unfavourite" : "Favourite", systemImage: item.isFavourite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
            }
            // Keeps the last row clear of the tab bar.
            Color.clear.frame(height: tabBarReserve)
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .environment(\.defaultMinListRowHeight, 0)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private func dateLine(_ item: WorkshopItem) -> (String, Color) {
        if item.filesBroken || item.checkFailed { return ("Couldn't verify", Color.yellow) }
        if item.updateAvailable { return ("New update available", Color.orange) }
        if item.updatedAt.timeIntervalSince(item.addedAt) > 60 { return ("Updated \(Fmt.date(item.updatedAt))", Color.secondary) }
        return ("Installed \(Fmt.date(item.addedAt))", Color.secondary)
    }

    private func favouriteStar(_ item: WorkshopItem, size: CGFloat) -> some View {
        Button { store.toggleFavourite(item) } label: {
            Image(systemName: item.isFavourite ? "star.fill" : "star")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isFavourite ? "Remove favourite" : "Add favourite")
    }

    private func dotsButton(_ item: WorkshopItem, circle: CGFloat) -> some View {
        Button { Haptics.tap(); contextItem = item } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(item.displayTitle)")
    }

    private func selectionBadge(_ picked: Bool) -> some View {
        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(picked ? Color.accentColor : Color.white)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .accessibilityHidden(true)
    }

    private func gridCard(_ item: WorkshopItem) -> some View {
        let line = dateLine(item)
        let picked = selecting && selection.contains(item.id)
        let tap = {
            if selecting { toggleSelection(item) } else { Haptics.tap(); popupItem = item }
        }
        return VStack(alignment: .leading, spacing: 7) {
            Button(action: tap) {
                GeometryReader { proxy in
                    CachedImage(urlString: item.imageURL, fill: true, maxPixel: 520)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: picked ? 3 : 0))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                if selecting { selectionBadge(picked).padding(8) } else { favouriteStar(item, size: 15).padding(8) }
            }
            .overlay(alignment: .topTrailing) {
                if !selecting { dotsButton(item, circle: 29).padding(8) }
            }

            Button(action: tap) {
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: item.displayTitle, font: .system(size: 14, weight: .semibold),
                                height: 17, active: selectedTab == 2, restartToken: marqueeToken)
                    HStack(spacing: 6) {
                        if item.rating != nil {
                            RatingLine(rating: item.rating, count: item.ratingCount, size: 12)
                        }
                        if showIDs {
                            Text("ID: \(item.id)").font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    .frame(height: 15, alignment: .leading)
                    HStack(spacing: 4) {
                        StatusGlyph(status: item.status, size: 11)
                        Text(line.0).font(.system(size: 11, weight: .medium)).foregroundStyle(line.1).lineLimit(1)
                    }
                    .frame(height: 14, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func navCircle(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }

    private func listRow(_ item: WorkshopItem) -> some View {
        let line = dateLine(item)
        let picked = selecting && selection.contains(item.id)
        let tap = {
            if selecting { toggleSelection(item) } else { Haptics.tap(); popupItem = item }
        }
        return HStack(spacing: 12) {
            if selecting { selectionBadge(picked) }
            Button(action: tap) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 84, height: 84)
                        .overlay(CachedImage(urlString: item.imageURL, fill: true, maxPixel: 300).allowsHitTesting(false))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: picked ? 3 : 0))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            RatingLine(rating: item.rating, count: item.ratingCount, size: 13)
                            if showIDs {
                                Text("ID: \(item.id)").font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                        if let game = item.gameName { Text(game).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                        HStack(spacing: 5) {
                            StatusGlyph(status: item.status, size: 12)
                            Text(line.0).font(.system(size: 12, weight: .medium)).foregroundStyle(line.1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !selecting {
                VStack(spacing: 8) {
                    navCircle(item.isFavourite ? "star.fill" : "star") { store.toggleFavourite(item) }
                    navCircle("ellipsis") { contextItem = item }
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    // MARK: - History

    private var historyContent: some View {
        Group {
            if store.history.isEmpty {
                emptyState("No download history", detail: "Download attempts and results will appear here.", symbol: "clock.arrow.circlepath")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ScrollSpy(onChange: handleScroll)
                        LazyVStack(spacing: 0) {
                            ForEach(store.history) { record in
                                historyRow(record)
                                Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5).padding(.leading, 83)
                            }
                        }
                        .padding(.bottom, tabBarReserve)
                    }
                }
                .coordinateSpace(name: "scroll")
                }
        }
    }

    private func historyColor(_ result: String) -> Color {
        switch result {
        case "Downloaded": return .green
        case "Failed": return .red
        case "Cancelled": return .secondary
        default: return .accentColor
        }
    }

    private func historyRow(_ record: DownloadRecord) -> some View {
        let failed = record.result == "Failed" || record.result == "Cancelled"
        return HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 56, height: 56)
                .overlay(CachedImage(urlString: record.imageURL, fill: true, maxPixel: 200))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.result)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(historyColor(record.result))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(historyColor(record.result).opacity(0.15)))
                    TimelineView(.everyMinute) { _ in
                        Text(Fmt.historyTime(record.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let attempt = record.attempt, attempt > 1 {
                        Text("Attempt \(attempt)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if failed, let error = record.error, !error.isEmpty {
                    Text(error).font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.9)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let game = record.gameName { Text(game).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if failed {
                    Button { Haptics.tap(); store.retry(record); selectedTab = 0 } label: {
                        Label("Try again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 11).frame(height: 30)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Haptics.tap(); contextHistory = record } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 40).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }

    // MARK: - Options tab

    private var optionsView: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ScrollSpy(onChange: handleScroll)
                        Text("Options").font(.system(size: 27, weight: .bold, design: .rounded)).padding(.top, 10)
                        appearanceSettings
                        downloadsSettings
                        browserSettings
                        gameFoldersSettings
                            .id("gameFolders")
                        steamAccountSettings
                        creditsSettings
                    }
                    .padding(.horizontal, 15)
                    .padding(.bottom, tabBarReserve)
                }
                .onChange(of: scrollToGameFolders) { _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("gameFolders", anchor: .top)
                    }
                }
            }
            .coordinateSpace(name: "scroll")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // Each options section is its own type-erased view, so this screen never becomes one enormous
    // nested view type. Deep generic metadata from a single big expression is what the launch
    // crash log pointed at.
    private var appearanceSettings: AnyView {
        AnyView(
            settingsGroup("Appearance") {
                row("Theme", symbol: "circle.lefthalf.filled") {
                    Menu {
                        ForEach(["System", "Light", "Dark"], id: \.self) { mode in
                            Button { Haptics.select(); appearance = mode } label: {
                                if appearance == mode { Label(mode, systemImage: "checkmark") } else { Text(mode) }
                            }
                        }
                    } label: { menuChip(appearance) }
                }
                divider
                row("Tab bar style", symbol: "rectangle.bottomhalf.filled") {
                    Menu {
                        Button { Haptics.select(); tabStyle = "bar" } label: { Label("Classic bar", systemImage: tabStyle == "bar" ? "checkmark" : "circle") }
                        Button { Haptics.select(); tabStyle = "pill" } label: { Label("Pill (shrinks on scroll)", systemImage: tabStyle == "pill" ? "checkmark" : "circle") }
                        Button { Haptics.select(); tabStyle = "pillFull" } label: { Label("Pill (always full)", systemImage: tabStyle == "pillFull" ? "checkmark" : "circle") }
                    } label: { menuChip(tabStyle == "bar" ? "Classic" : (tabStyle == "pill" ? "Pill" : "Pill full")) }
                }
                divider
                row("Workshop GIFs", symbol: "sparkles") {
                    Menu {
                        Section("Downloads") {
                            Button { Haptics.select(); gifDownloads = true } label: {
                                if gifDownloads { Label("On", systemImage: "checkmark") } else { Text("On") }
                            }
                            Button { Haptics.select(); gifDownloads = false } label: {
                                if !gifDownloads { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                            }
                        }
                        Section("Library & History") {
                            Button { Haptics.select(); gifLibrary = true } label: {
                                if gifLibrary { Label("On", systemImage: "checkmark") } else { Text("On") }
                            }
                            Button { Haptics.select(); gifLibrary = false } label: {
                                if !gifLibrary { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                            }
                        }
                    } label: {
                        menuChip(gifDownloads == gifLibrary ? (gifDownloads ? "On" : "Off") : "Mixed")
                    }
                }
                divider
                toggleRow("Compact library grid", symbol: "square.grid.2x2", isOn: $compactLibrary)
                divider
                toggleRow("Show Workshop IDs", symbol: "number", isOn: $showIDs)
                divider
                toggleRow("Haptic feedback", symbol: "iphone.radiowaves.left.and.right", isOn: $haptics)
            }
        )
    }

    private var browserSettings: AnyView {
        AnyView(
            settingsGroup("Browser") {
                toggleRow("Auto download from browser", symbol: "arrow.down.circle", isOn: $autoDownload)
                divider
                toggleRow("Confirm auto download", symbol: "checkmark.circle", isOn: $confirmAutoDownload)
            }
        )
    }

    private var downloadsSettings: AnyView {
        AnyView(
            settingsGroup("Downloads") {
                toggleRow("Confirm before deleting", symbol: "trash", isOn: $confirmDelete)
                divider
                toggleRow("Check updates on launch", symbol: "arrow.clockwise", isOn: $autoCheck)
                divider
                toggleRow("Wi-Fi only downloads", symbol: "wifi", isOn: $wifiOnly)
                divider
                toggleRow("Write info file into each mod", symbol: "doc.text", isOn: $infoFile)
                divider
                Button { Haptics.tap(); folderSheet = .shared } label: {
                    rowContent("Shared mod folder", symbol: "folder", detail: store.folderLabel)
                }.buttonStyle(.plain)
                if store.usingCustomFolder {
                    divider
                    Button { Haptics.tap(); store.resetFolder(for: nil) } label: {
                        rowContent("Reset to default folder", symbol: "arrow.uturn.backward", detail: nil, tint: .accentColor)
                    }.buttonStyle(.plain)
                }
                divider
                Button { Haptics.tap(); store.clearTemporaryFiles() } label: {
                    rowContent("Clear temporary files", symbol: "trash.slash", detail: nil)
                }.buttonStyle(.plain)
            }
        )
    }

    private var gameFoldersSettings: AnyView {
        AnyView(
            settingsGroup("Game folders") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Each game can keep its mods in its own folder.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("New downloads for a game go there; mods you already have stay where they are until you move them.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("This is useful for installing mods directly to the games specified mod folder, ensure you select the correct folder if you are going to do so.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15).padding(.vertical, 11)
                ForEach(gamesForFolders, id: \.id) { game in
                    divider
                    HStack(spacing: 6) {
                        Button { Haptics.tap(); folderSheet = .game(game.id) } label: {
                            rowContent(game.name, symbol: "folder",
                                       detail: store.customGameFolders[game.id] ?? "Shared folder")
                        }
                        .buttonStyle(.plain)
                        Button { Haptics.tap(); store.revealFolder(store.root(forGame: game.id)) } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(game.name)'s folder")
                        if store.customGameFolders[game.id] != nil {
                            Button { Haptics.tap(); store.resetFolder(for: game.id) } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reset \(game.name)'s folder")
                        }
                    }
                    .padding(.trailing, 12)
                }
                if gamesForFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Games appear here once you have downloaded a mod for them.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                }
            }
        )
    }

    private var steamAccountSettings: AnyView {
        AnyView(
            settingsGroup("Steam account") {
                HStack(spacing: 12) {
                    Image(systemName: store.isAuthenticated ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .font(.system(size: 20)).foregroundStyle(store.isAuthenticated ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isAuthenticated ? "Connected to Steam" : "Not signed in").font(.system(size: 16, weight: .semibold))
                        Text(store.isAuthenticated ? "Your Steam session is active." : "Sign in to download mods.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                divider
                if store.isAuthenticated {
                    Button { Haptics.tap(); store.signOut() } label: { rowContent("Sign out", symbol: "rectangle.portrait.and.arrow.right", detail: nil, tint: .red) }.buttonStyle(.plain)
                } else {
                    Button { Haptics.tap(); store.showLogin = true } label: { rowContent("Sign in to Steam", symbol: "person.crop.circle", detail: nil) }.buttonStyle(.plain)
                }
            }
        )
    }

    private var creditsSettings: AnyView {
        AnyView(
            settingsGroup("Credits") {
                creditRow("ModShelf", "Created by Splash (@shplash)")
                divider
                creditLicenseRow("go-steam", "Engine by Alexander Birkner (@BirknerAlex)", license: "MIT License")
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steam and the Steam Workshop are trademarks of Valve Corporation. ModShelf is not made by or endorsed by Valve.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
            }
        )
    }

    private func creditRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private func creditLicenseRow(_ title: String, _ detail: String, license: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(license).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private var divider: some View { Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5).padding(.leading, 48) }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
    }

    private func row<Trailing: View>(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24)
            Text(title).font(.system(size: 16))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private func toggleRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        row(title, symbol: symbol) {
            Toggle("", isOn: Binding(get: { isOn.wrappedValue }, set: { isOn.wrappedValue = $0; Haptics.select() })).labelsHidden()
        }
    }

    private func menuChip(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 15, weight: .semibold))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }

    private func rowContent(_ title: String, symbol: String, detail: String?, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint == .primary ? Color.secondary : tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if tint == .primary { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 15).padding(.vertical, 11).contentShape(Rectangle())
    }

    // MARK: - Login sheet

    private var loginSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: store.isAuthenticated ? "checkmark.shield.fill" : "person.crop.circle.badge.key")
                            .font(.system(size: 26)).foregroundStyle(store.isAuthenticated ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.isAuthenticated ? "Connected to Steam" : "Sign in to Steam").font(.title3.bold())
                            Text(store.isAuthenticated
                                 ? "Your Steam session is active."
                                 : "Your password is stored in the keychain on this device only, ModShelf signs in so Steam will serve workshop mods to your own account.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !store.isAuthenticated {
                        VStack(spacing: 10) {
                            loginField("Steam username", text: $store.username, secure: false)
                            loginField("Password", text: $store.password, secure: true)
                            if store.needsGuardCode || !store.guardCode.isEmpty {
                                loginField("Steam Guard code", text: $store.guardCode, secure: false)
                                    .textContentType(.oneTimeCode)
                                Text("Enter the code from the Steam app. ModShelf sends one request, so you won't get a second confirmation.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            dismissKeyboard(); Haptics.medium()
                            Task { await store.signIn() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isBusy && !store.needsGuardCode { ProgressView().tint(.white) }
                                Text(store.needsGuardCode ? "Submit code" : (store.isBusy ? "Signing in…" : "Sign in"))
                            }
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 13).fill(Color.accentColor))
                        }
                        .buttonStyle(.plain).disabled(store.isBusy && !store.needsGuardCode)
                    } else {
                        Button { store.showLogin = false } label: {
                            Text("Done").font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 13).fill(Color.accentColor))
                        }.buttonStyle(.plain)
                    }
                    if !store.loginError.isEmpty {
                        Text(store.loginError).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .onDisappear { store.loginError = "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { store.showLogin = false } }
            }
        }
    }

    private func loginField(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(title, text: text) } else { TextField(title, text: text) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(.horizontal, 13).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

// MARK: - Popups

struct ItemDetailPopup: View {
    let item: WorkshopItem
    @ObservedObject var store: WorkshopStore
    let showIDs: Bool
    let onClose: () -> Void
    let onOpenWorkshop: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                CachedImage(urlString: item.imageURL, fill: true, maxPixel: 300)
                    .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    RatingLine(rating: item.rating, count: item.ratingCount, size: 13)
                    if let game = item.gameName { Text(game).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) { StatusGlyph(status: item.status, size: 13); Text(statusText).font(.caption.weight(.semibold)) }
                }
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .accessibilityLabel("Close")
            }
            if showIDs { IDChip(id: item.id) }
            if let d = item.description, !d.isEmpty {
                ScrollView { ExpandableDescription(text: d, lineLimit: 5) }.frame(maxHeight: 130)
            }
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Installed \(Fmt.date(item.addedAt))" + (item.fileCount.map { " · \($0) files" } ?? "") + (item.byteCount.map { " · \(Fmt.bytes($0))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Haptics.tap(); onOpenWorkshop() } label: {
                    Label("Workshop", systemImage: "safari").font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.14)))
                }.buttonStyle(.plain)
                if item.updateAvailable {
                    Button { Haptics.medium(); store.update(item) } label: {
                        Label("Update", systemImage: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.orange))
                    }.buttonStyle(.plain)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                        .frame(width: 42, height: 42).background(RoundedRectangle(cornerRadius: 11).fill(Color.red.opacity(0.12)))
                }.buttonStyle(.plain).accessibilityLabel("Delete download")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    private var statusText: String {
        switch item.status {
        case .upToDate: return "Up to date"
        case .needsUpdate: return "Update available"
        case .unverified: return item.filesBroken ? "Files missing or changed" : "Couldn't verify"
        }
    }
}

struct ItemActionPopup: View {
    let item: WorkshopItem
    let openWorkshop: () -> Void
    let copyID: () -> Void
    let share: () -> Void
    let reveal: () -> Void
    let favourite: () -> Void
    let updateNow: () -> Void
    let checkUpdates: () -> Void
    let verify: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StatusGlyph(status: item.status, size: 16)
                Text(item.displayTitle).font(.headline).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            action("Open Workshop page", "safari", favourite: false, action: openWorkshop)
            action(item.isFavourite ? "Remove favourite" : "Add favourite", item.isFavourite ? "star.fill" : "star", favourite: true, action: favourite)
            if item.updateAvailable { action("Update now", "arrow.down.circle", favourite: false, action: updateNow) }
            action("Check for updates", "arrow.clockwise", favourite: false, action: checkUpdates)
            action("Verify files", "checkmark.shield", favourite: false, action: verify)
            action("Export as ZIP", "square.and.arrow.up", favourite: false, action: export)
            action("Reveal in Files", "folder", favourite: false, action: reveal)
            action("Share link", "square.and.arrow.up", favourite: false, action: share)
            action("Copy Workshop ID", "doc.on.doc", favourite: false, action: copyID)
            action("Delete download", "trash", favourite: false, tint: .red, action: delete)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    private func action(_ title: String, _ symbol: String, favourite: Bool, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24)
                    .foregroundStyle(tint == .primary ? Color.accentColor : tint)
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HistoryActionPopup: View {
    let record: DownloadRecord
    let openWorkshop: () -> Void
    let copyID: () -> Void
    let retry: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(record.title).font(.headline).lineLimit(1).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            row("Open Workshop page", "safari", action: openWorkshop)
            row("Copy Workshop ID", "doc.on.doc", action: copyID)
            if record.result == "Failed" || record.result == "Cancelled" { row("Try again", "arrow.clockwise", action: retry) }
            row("Close", "xmark", action: close)
        }
        .padding(.bottom, 8).frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 46).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A one-time tip after the first successful download, pointing at per-game folders.
struct FolderTipPopup: View {
    let onDetails: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("First mod installed").font(.headline)
            }
            Text("You can give each game its own mod folder.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onDetails) {
                    Text("Details").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                Button(action: onClose) {
                    Text("Got it").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16).frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

struct ConfirmPopup: View {
    let heading: String
    let message: String
    let actionTitle: String
    var tint: Color = .red
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text(heading).font(.headline).multilineTextAlignment(.center)
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("Cancel").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill)))
                }.buttonStyle(.plain)
                Button { Haptics.medium(); confirm() } label: {
                    Text(actionTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(tint))
                }.buttonStyle(.plain)
            }
        }
        .padding(20).frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

struct DeleteConfirmationPopup: View {
    let title: String
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash.fill").font(.system(size: 30)).foregroundStyle(.red)
            Text("Delete \(title)?").font(.headline).multilineTextAlignment(.center)
            Text("The downloaded files will be removed from this iPhone. You can download the mod again later.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("Cancel").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill)))
                }.buttonStyle(.plain)
                Button { Haptics.medium(); confirm() } label: {
                    Text("Delete").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red))
                }.buttonStyle(.plain)
            }
        }
        .padding(20).frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

// MARK: - Description, IDs, media

struct ExpandableDescription: View {
    let text: String
    let lineLimit: Int
    @State private var expanded = false

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(attributed)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > 260 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Text(expanded ? "Show less" : "Read more").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct IDChip: View {
    let id: String
    var small = false
    var body: some View {
        Text("Workshop ID: \(id)")
            .font(.system(size: small ? 11 : 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }
}

struct MediaCarousel: View {
    let media: [MediaItem]
    @Binding var index: Int
    var onExpand: (MediaItem, Int) -> Void = { _, _ in }
    /// The page that was showing before the swipe, so only a video being left is paused.
    @State private var lastIndex = 0

    init(media: [MediaItem], index: Binding<Int>, onExpand: @escaping (MediaItem, Int) -> Void = { _, _ in }) {
        self.media = media
        self._index = index
        self.onExpand = onExpand
        _lastIndex = State(initialValue: index.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 6) {
            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.offset) { i, item in
                    Group {
                        switch item {
                        case .image(let url):
                            Button { Haptics.tap(); onExpand(item, i) } label: {
                                CachedImage(urlString: url, fill: false, maxPixel: 1000, isDownloadPreview: true)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open image larger")
                        case .video(let id):
                            YouTubePlayerView(videoID: id)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 2)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .onChange(of: index) { newIndex in
                if media.indices.contains(lastIndex), case .video = media[lastIndex] {
                    YouTubePlayers.shared.pause()
                }
                lastIndex = newIndex
            }
            if media.count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<media.count, id: \.self) { i in
                        Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                    }
                }
            }
        }
    }
}

/// A tapped image or video opens here, over a dark blurred backdrop. It is the same pager as the
/// carousel, so swiping moves through the item's media, and the page dots sit just under the media.
struct ExpandedMediaView: View {
    let media: [MediaItem]
    let startIndex: Int
    let onIndexChange: (Int) -> Void
    let onClose: () -> Void
    @State private var index: Int
    @State private var lastIndex: Int

    init(media: [MediaItem], startIndex: Int, onIndexChange: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.media = media
        self.onIndexChange = onIndexChange
        self.onClose = onClose
        self.startIndex = startIndex
        let start = max(0, min(startIndex, max(0, media.count - 1)))
        _index = State(initialValue: start)
        _lastIndex = State(initialValue: start)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                TabView(selection: $index) {
                    ForEach(Array(media.enumerated()), id: \.offset) { i, item in
                        ExpandedMediaPage(item: item, index: i, count: media.count, onClose: onClose)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear { onIndexChange(index) }
        .onChange(of: index) { newIndex in
            onIndexChange(newIndex)
            // Only a video that has been left behind is paused; a video being opened keeps playing.
            if media.indices.contains(lastIndex), case .video = media[lastIndex] {
                YouTubePlayers.shared.pause()
            }
            lastIndex = newIndex
        }
    }
}

/// One page of the focused viewer: the media sized to its own shape, with the dots right under it.
struct ExpandedMediaPage: View {
    let item: MediaItem
    let index: Int
    let count: Int
    let onClose: () -> Void
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tapping anywhere around the media dismisses the viewer, the same as the backdrop.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                VStack(spacing: 12) {
                    content(in: geo.size)
                    if count > 1 { dots }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }
        }
        .task(id: item.id) { await load() }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let fitting = fittingSize(size)
        switch item {
        case .video(let id):
            videoPlayer(id, in: fitting)
        case .image:
            imageBody(in: fitting)
        }
    }

    /// The screen, less room for the dots and a little breathing space.
    private func fittingSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(160, size.height - (count > 1 ? 34 : 0) - 40))
    }

    private func videoPlayer(_ id: String, in size: CGSize) -> some View {
        let width = max(160, min(size.width - 20, size.height * 16 / 9))
        let height = width * 9 / 16
        return YouTubePlayerView(videoID: id, fullSize: true)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    private func imageBody(in size: CGSize) -> some View {
        let frame = imageFrame(in: size)
        return Group {
            if let image {
                ZoomableImage(image: image, animate: image.images != nil && gifDownloads)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.white.opacity(0.7))
                    Text("Couldn't load this image").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }

    /// Wide images fill the width; square ones stop at the height there is, so nothing is cut off.
    private func imageFrame(in size: CGSize) -> CGSize {
        let maxWidth = max(160, size.width - 20)
        let maxHeight = max(160, size.height)
        let ratio = max(0.2, aspectRatio)
        var width = ratio >= 1.2 ? maxWidth : min(maxWidth, maxHeight)
        var height = width / ratio
        if height > maxHeight { height = maxHeight; width = height * ratio }
        return CGSize(width: width, height: height)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    private var aspectRatio: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 16.0 / 9.0 }
        return image.size.width / image.size.height
    }

    private func load() async {
        guard case .image(let urlString) = item, let url = URL(string: urlString) else { return }
        if let hit = ImageStore.shared.cached(url, animate: gifDownloads) { image = hit; return }
        let loaded = await ImageStore.shared.load(url, maxPixel: 2000, animate: gifDownloads)
        if Task.isCancelled { return }
        image = loaded
        failed = loaded == nil
    }
}

/// An image that pinches to zoom around your fingers and pans while zoomed in. At normal size the
/// pan gesture is off, so a sideways swipe still moves the focused viewer to the next image.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var animate = false

    func makeUIView(context: Context) -> ZoomImageView {
        let view = ZoomImageView()
        view.set(image: image, animated: animate)
        return view
    }

    func updateUIView(_ view: ZoomImageView, context: Context) {
        if view.shownImage !== image { view.set(image: image, animated: animate) }
    }
}

final class ZoomImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private(set) var shownImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 1
        maximumZoomScale = 5
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        // Pinching keeps working while the pan gesture is off, so the pager keeps the swipes at 1x.
        panGestureRecognizer.isEnabled = false
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(image: UIImage, animated: Bool) {
        shownImage = image
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        zoomScale = 1
        contentSize = bounds.size
        if animated { imageView.startAnimating() } else { imageView.stopAnimating() }
        setNeedsLayout()
        updatePanGesture()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.01, imageView.frame.size != bounds.size {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        let insetY = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        updatePanGesture()
    }

    private func updatePanGesture() {
        panGestureRecognizer.isEnabled = zoomScale > 1.01
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let width = bounds.width / 2.6
        let height = bounds.height / 2.6
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
             animated: true)
    }
}

/// One live YouTube player, kept between the carousel and the expanded preview, so enlarging a video
/// that is already playing moves the player instead of loading it again.
final class YouTubePlayers {
    static let shared = YouTubePlayers()
    private static let origin = "https://modshelf.app"

    private var webView: WKWebView?
    private var loadedID: String?
    private weak var carouselHost: YouTubeHostView?
    private weak var previewHost: YouTubeHostView?
    private let parking = UIView()
    private let links = YouTubeLinkHandler()

    func attach(_ videoID: String, to host: YouTubeHostView, fullSize: Bool) {
        let player = view(for: videoID)
        if fullSize {
            previewHost = host
        } else {
            carouselHost = host
            // While the preview is on screen it keeps the player.
            if let previewHost, previewHost.window != nil, player.superview === previewHost { return }
        }
        if player.superview !== host { host.adopt(player) }
    }

    /// The preview closed: hand the player back so the carousel keeps the page it had.
    func release(from host: YouTubeHostView) {
        guard let player = webView, player.superview === host else { return }
        if let carouselHost, carouselHost !== host, carouselHost.window != nil {
            carouselHost.adopt(player)
        } else {
            player.removeFromSuperview()
            parking.addSubview(player)
        }
    }

    /// Pauses the live player, used when its page is swiped away in a carousel.
    func pause() {
        guard let webView else { return }
        let script = """
        (function(){
          var f = document.querySelector('iframe');
          if (f && f.contentWindow) {
            f.contentWindow.postMessage('{"event":"command","func":"pauseVideo","args":[]}', '*');
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func view(for id: String) -> WKWebView {
        if let webView, loadedID == id { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = links
        view.loadHTMLString(Self.page(id), baseURL: URL(string: Self.origin))
        webView = view
        loadedID = id
        return view
    }

    private static func page(_ videoID: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&rel=0&modestbranding=1&enablejsapi=1&origin=\(Self.origin)"
          referrerpolicy="strict-origin-when-cross-origin" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>
        </body></html>
        """
    }
}

final class YouTubeHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
    func adopt(_ view: UIView) {
        view.removeFromSuperview()
        addSubview(view)
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews { sub.frame = bounds }
    }
}

/// Opens "Watch on YouTube" and similar links in the YouTube app instead of inside the player.
final class YouTubeLinkHandler: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil,
           Self.isYouTube(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    var fullSize = false

    final class Coordinator {
        let id: String
        init(id: String) { self.id = id }
    }

    func makeCoordinator() -> Coordinator { Coordinator(id: videoID) }

    func makeUIView(context: Context) -> YouTubeHostView {
        let host = YouTubeHostView()
        YouTubePlayers.shared.attach(videoID, to: host, fullSize: fullSize)
        return host
    }

    func updateUIView(_ host: YouTubeHostView, context: Context) {
        YouTubePlayers.shared.attach(videoID, to: host, fullSize: fullSize)
    }

    static func dismantleUIView(_ host: YouTubeHostView, coordinator: Coordinator) {
        YouTubePlayers.shared.release(from: host)
    }
}

// MARK: - Folder picker and share sheet

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    var onCancel: () -> Void = { }
    var startURL: URL? = nil
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.directoryURL = startURL
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct MoveDestinationSheet: View {
    let destinations: [MoveDestination]
    let onPick: (MoveDestination) -> Void
    let onChooseFolder: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(destinations) { destination in
                        Button { onPick(destination) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.title).font(.system(size: 16)).foregroundStyle(.primary)
                                Text(destination.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } footer: {
                    Text("Each mod keeps its folder name. If a folder with that name is already there, the Workshop ID is added.")
                }
                Section {
                    Button { onChooseFolder() } label: { Label("Choose another folder…", systemImage: "folder.badge.plus") }
                }
            }
            .navigationTitle("Move selected")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
        }
    }
}


// MARK: - Browser home (custom start page)

struct GameHit: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let tiny_image: String?
}

struct GameSearchResponse: Codable { let items: [GameHit] }

/// Steam's own list of games that have a Workshop ("Browse All Workshops"). It is downloaded once,
/// cached, and then searched by name, so only games with a real Workshop are offered.
final class WorkshopCatalogue {
    static let shared = WorkshopCatalogue()

    private var entries: [GameHit]?
    private var loading: Task<[GameHit], Never>?

    private init() {
        let cached = Self.loadCache()
        entries = cached.isEmpty ? nil : cached
    }

    func games() async -> [GameHit] {
        if let entries { return entries }
        if let loading { return await loading.value }

        let task = Task { await Self.download() }
        loading = task
        let fetched = await task.value
        loading = nil

        if fetched.isEmpty {
            let cached = Self.loadCache()
            if !cached.isEmpty { entries = cached }
            return cached
        }
        entries = fetched
        Self.saveCache(fetched)
        return fetched
    }

    /// The pages are independent, so a few at a time keeps the first search quick.
    private static func download() async -> [GameHit] {
        let size = 100
        guard let first = await page(start: 0, size: size) else { return [] }
        var games = first.games
        let total = max(first.total, games.count)

        var starts = Array(stride(from: size, to: max(total, size), by: size))
        while !starts.isEmpty && !Task.isCancelled {
            let chunk = Array(starts.prefix(5))
            starts.removeFirst(chunk.count)
            let pages = await withTaskGroup(of: [GameHit].self) { group in
                for start in chunk {
                    group.addTask { await page(start: start, size: size)?.games ?? [] }
                }
                var collected: [GameHit] = []
                for await result in group { collected.append(contentsOf: result) }
                return collected
            }
            if pages.isEmpty { break }
            games.append(contentsOf: pages)
        }
        return deduplicate(games)
    }

    private static func page(start: Int, size: Int) async -> (games: [GameHit], total: Int)? {
        guard let url = URL(string: "https://steamcommunity.com/workshop/ajaxgetworkshops/?start=\(start)&count=\(size)&sort=alpha&l=english") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = root["results_html"] as? String else { return nil }
        let total = (root["total_count"] as? String).flatMap { Int($0) }
            ?? (root["total_count"] as? Int) ?? 0
        return (parse(html), total)
    }

    private static func parse(_ html: String) -> [GameHit] {
        var games: [GameHit] = []
        let blocks = html.components(separatedBy: "onClick=\"top.location.href=")
        for block in blocks.dropFirst() {
            guard let idText = firstGroup(#"/app/(\d+)/workshop/"#, in: block), let id = Int(idText) else { continue }
            let name = firstGroup(#"class="appLogo"[^>]*alt="([^"]*)""#, in: block).map(decodeEntities) ?? ""
            let image = firstGroup(#"class="appLogo"[^>]*src="([^"]*)""#, in: block)
            guard !name.isEmpty else { continue }
            games.append(GameHit(id: id, name: name, tiny_image: image))
        }
        return games
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
        for (raw, read) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            value = value.replacingOccurrences(of: raw, with: read)
        }
        return value
    }

    private static func deduplicate(_ games: [GameHit]) -> [GameHit] {
        var seen = Set<Int>()
        var unique: [GameHit] = []
        for game in games where seen.insert(game.id).inserted { unique.append(game) }
        return unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("modshelf-workshop-games.json")
    }

    private static func loadCache() -> [GameHit] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let games = try? JSONDecoder().decode([GameHit].self, from: data) else { return [] }
        return games
    }

    private static func saveCache(_ games: [GameHit]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum GameSearch {
    /// Steam's own Workshop game list, searched by name, so only games that really have a Workshop
    /// appear. The catalogue is cached after the first use.
    static func search(_ term: String) async -> [GameHit] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let catalogue = await WorkshopCatalogue.shared.games()
        guard !catalogue.isEmpty else { return await storeSearch(query) }

        let lowered = query.lowercased()
        let matches = catalogue.filter { $0.name.lowercased().contains(lowered) }
        let ranked = matches.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(lowered)
            let bPrefix = b.name.lowercased().hasPrefix(lowered)
            if aPrefix != bPrefix { return aPrefix }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(30))
    }

    /// The catalogue could not be fetched: fall back to Steam's store search rather than nothing.
    private static func storeSearch(_ term: String) async -> [GameHit] {
        guard let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(q)&l=english&cc=US"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONDecoder().decode(GameSearchResponse.self, from: data) else { return [] }
        return root.items
    }
}

enum GameListStore {
    static func decode(_ text: String) -> [GameHit] {
        (try? JSONDecoder().decode([GameHit].self, from: Data(text.utf8))) ?? []
    }
    static func encode(_ list: [GameHit]) -> String {
        guard let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

struct BrowserHome: View {
    let lastPage: URL?
    let onOpenURL: (URL) -> Void
    let onScroll: (CGFloat) -> Void

    @State private var query = ""
    @State private var results: [GameHit] = []
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @AppStorage("browser.recentGames") private var recentJSON = "[]"
    @AppStorage("browser.favGames") private var favJSON = "[]"

    private var recent: [GameHit] { GameListStore.decode(recentJSON) }
    private var favourites: [GameHit] { GameListStore.decode(favJSON) }
    /// True until the first game is opened or favourited; the search box is then ready to type in.
    private var isFirstRun: Bool { recent.isEmpty && favourites.isEmpty && lastPage == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollSpy(onChange: onScroll)
                Text("Browse Workshop")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .padding(.top, 6)
                searchField
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    resultsSection
                } else {
                    if let lastPage { continueCard(lastPage) }
                    if !favourites.isEmpty {
                        sectionTitle("Favourites")
                        favouritesGrid
                    }
                    if !recent.isEmpty {
                        sectionTitle("Recently opened")
                        ForEach(recent) { hit in gameRow(hit) }
                    }
                    if isFirstRun {
                        Text("Search for a game above to start browsing its Workshop.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }
            .padding(15)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: query) { await runSearch() }
        .onAppear { if isFirstRun { searchFocused = true } }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let found = await GameSearch.search(term)
        if Task.isCancelled { return }
        results = found
        searching = false
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Search a game", text: $query)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searching {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 8)
            } else if results.isEmpty {
                Text("No games found for \"\(query)\".").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(results) { hit in gameRow(hit) }
        }
    }

    private var favouritesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(favourites.prefix(4))) { hit in favouriteTile(hit) }
        }
    }

    private func favouriteTile(_ hit: GameHit) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { openGame(hit) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .overlay(CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 300))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(hit.name)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(7)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            starButton(hit).padding(2)
        }
    }

    private func gameRow(_ hit: GameHit) -> some View {
        HStack(spacing: 0) {
            Button { openGame(hit) } label: {
                HStack(spacing: 12) {
                    CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 120)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(hit.name)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 10).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            starButton(hit).padding(.trailing, 4)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The star has a large invisible tap area, so you only favourite when you mean to.
    private func starButton(_ hit: GameHit) -> some View {
        let isFavourite = favourites.contains(hit)
        return Button {
            Haptics.tap()
            var list = favourites
            if let index = list.firstIndex(of: hit) { list.remove(at: index) } else { list.insert(hit, at: 0) }
            favJSON = GameListStore.encode(list)
        } label: {
            Image(systemName: isFavourite ? "star.fill" : "star")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFavourite ? Color.yellow : Color.secondary)
                .frame(width: 20, height: 20)
                .padding(14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavourite ? "Remove favourite" : "Add favourite")
    }

    private func openGame(_ hit: GameHit) {
        var list = recent.filter { $0.id != hit.id }
        list.insert(hit, at: 0)
        recentJSON = GameListStore.encode(Array(list.prefix(8)))
        query = ""
        Haptics.tap()
        onOpenURL(URL(string: "https://steamcommunity.com/app/\(hit.id)/workshop/")!)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func continueCard(_ url: URL) -> some View {
        Button { Haptics.tap(); onOpenURL(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue where you left off").font(.system(size: 15, weight: .semibold))
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workshop browser

/// Holds the browser's one WKWebView, so the toolbar can drive it without the
/// representable having to push a view back into SwiftUI state.
final class BrowserWebViewHandle {
    weak var webView: WKWebView?
}

struct WorkshopBrowserView: View {
    let onOpenInApp: (String) -> Void
    @Binding var requestedURL: URL?
    let cleanPages: Bool
    let bottomInset: CGFloat
    let homeToken: Int
    let onScroll: (CGFloat) -> Void

    @State private var handle = BrowserWebViewHandle()
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showUse = false
    @State private var showHome = true
    @State private var copied = false

    static let lastPageKey = "browser.lastURL"

    private var savedLastPage: URL? {
        UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap { URL(string: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                WorkshopWebContainer(handle: handle, currentURL: $currentURL, canGoBack: $canGoBack,
                                     canGoForward: $canGoForward, isLoading: $isLoading, showUse: $showUse,
                                     requestedURL: $requestedURL, cleanPages: cleanPages,
                                     bottomInset: bottomInset, onScroll: onScroll, onOpenInApp: onOpenInApp)
                    .opacity(showHome ? 0 : 1)
                    .allowsHitTesting(!showHome)
                if showHome {
                    BrowserHome(lastPage: savedLastPage,
                                onOpenURL: { open($0) },
                                onScroll: onScroll)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: requestedURL) { url in
            if url != nil { showHome = false }
        }
        .onChange(of: homeToken) { _ in showHome = true }
        .onAppear { if requestedURL != nil { showHome = false } }
    }

    private func open(_ url: URL) {
        showHome = false
        requestedURL = url
    }

    /// Back, Forward, the address (tap to copy) and Home, all across the top.
    private var topBar: some View {
        HStack(spacing: 8) {
            navButton("chevron.left", "Back", enabled: canGoBack && !showHome) { handle.webView?.goBack() }
            navButton("chevron.right", "Forward", enabled: canGoForward && !showHome) { handle.webView?.goForward() }
            addressField
            navButton("house.fill", "Browse home", enabled: true) { showHome = true }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var addressText: String {
        guard let u = currentURL else { return "" }
        return (u.host ?? "") + u.path
    }

    /// Tapping the address copies the page link. "Copied" shows in its place for a moment.
    private var addressField: some View {
        Button { copyLink() } label: {
            HStack(spacing: 6) {
                Text(copied ? "Copied to clipboard" : ((showHome || currentURL == nil) ? "…" : addressText))
                    .font(.system(size: 13, weight: copied ? .bold : .regular))
                    .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isLoading && !copied { ProgressView().scaleEffect(0.7) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .disabled(showHome || currentURL == nil)
        .animation(.easeOut(duration: 0.2), value: copied)
    }

    private func copyLink() {
        guard let url = currentURL else { return }
        UIPasteboard.general.string = url.absoluteString
        Haptics.tap()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    private func navButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct WorkshopWebContainer: UIViewRepresentable {
    let handle: BrowserWebViewHandle
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var showUse: Bool
    @Binding var requestedURL: URL?
    let cleanPages: Bool
    let bottomInset: CGFloat
    let onScroll: (CGFloat) -> Void
    let onOpenInApp: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()           // keeps the Steam sign-in between launches
        let controller = config.userContentController
        controller.add(context.coordinator, name: "modshelf")
        controller.addUserScript(WKUserScript(source: Self.hideScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.openButtonScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.cookieScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor.systemBackground
        view.scrollView.backgroundColor = UIColor.systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentInset.bottom = bottomInset
        context.coordinator.observe(view)
        handle.webView = view

        // Only a page the user actually asked for is loaded: never a generic Workshop page, which
        // would show up as a surprise destination when the history runs out.
        let start = requestedURL ?? Self.lastPage()
        DispatchQueue.main.async { self.requestedURL = nil }
        CookieVault.restore(into: view.configuration.websiteDataStore.httpCookieStore) {
            if let start { view.load(URLRequest(url: start)) }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if abs(view.scrollView.contentInset.bottom - bottomInset) > 0.5 { view.scrollView.contentInset.bottom = bottomInset }
        if let url = requestedURL {
            view.load(URLRequest(url: url))
            DispatchQueue.main.async { self.requestedURL = nil }
        }
        if cleanPages != context.coordinator.lastClean {
            context.coordinator.lastClean = cleanPages
            view.evaluateJavaScript(cleanPages ? Self.hideScript : Self.showScript, completionHandler: nil)
        }
    }

    static func lastPage() -> URL? {
        UserDefaults.standard.string(forKey: WorkshopBrowserView.lastPageKey).flatMap { URL(string: $0) }
    }

    /// Hides Steam's header, store link, the game tab row, news, RSS and the About box.
    /// Most of this works by matching visible text, so it doesn't depend on Steam's class names.
    static let hideScript = """
    (function(){
      var markers = ['LATEST WORKSHOP NEWS','Subscribe to RSS feed','ABOUT - THE WORKSHOP','Workshop Home About Workshop','Read the full post on our Steam Blog',"Here's a quick look",'About - The Workshop','About this Workshop','About the Workshop','About this Workshop item','About this game','About This Game'];
      var css = '#global_header,.global_header,[id*="global_header"],[class*="global_header"],header,#footer,.footer,.supernav_container,.store_header,#store_nav_area,.responsive_header,#workshop_header,.workshop_header,.workshopBanner,.workshop_banner{display:none!important}' +
                ' body{padding-top:0!important;margin-top:0!important;margin-left:0!important;margin-right:0!important;background:#1b2838!important}' +
                ' html,body{width:100%!important;min-width:0!important;max-width:100%!important}' +
                ' .responsive_page_content{padding-top:0!important;max-width:100%!important}';
      if(!document.getElementById('ms-clean')){var s=document.createElement('style');s.id='ms-clean';s.innerHTML=css;document.head.appendChild(s);}
      function hide(){
        var all=document.querySelectorAll('div,section,table,td,p,h1,h2,h3,h4,span,a,nav,ul');
        for(var i=0;i<all.length;i++){
          var el=all[i];
          if(el.dataset.msHidden) continue;
          // Never touch a mod's own description, even if the author titled it "About".
          if(el.closest && el.closest('.workshopItemDescription')) continue;
          var t=(el.innerText||'').trim();
          if(!t || t.length>6000) continue;
          var lower=t.toLowerCase();
          var hit=markers.some(function(m){var key=m.toLowerCase();return lower.indexOf(key)===0 || (lower.indexOf(key)>=0 && t.length<600);});
          // Steam's store link.
          if(t==='Store Page') hit=true;
          // Steam's row of game tabs (All, Discussions, Screenshots, Artwork, ...).
          if(t.length<400 && t.indexOf('Screenshots')>=0 && t.indexOf('Artwork')>=0 && t.indexOf('Discussions')>=0) hit=true;
          if(hit && !el.querySelector('input[type=text],input[type=search]')){
            var box=el; var up=el.parentElement;
            if(up && (up.innerText||'').trim().length<=t.length+40 && !up.querySelector('input[type=text],input[type=search]')) box=up;
            box.style.setProperty('display','none','important'); box.dataset.msHidden='1';
          }
        }
        // Steam's green Subscribe button is replaced by the ModShelf button.
        var sub=document.getElementById('SubscribeItemBtn');
        if(sub){ var holder=sub.closest('a,button')||sub; holder.style.setProperty('display','none','important'); }
      }
      hide(); setTimeout(hide,600); setTimeout(hide,1800);
    })();
    """

    static let showScript = """
    (function(){var s=document.getElementById('ms-clean'); if(s) s.innerHTML='';
      document.querySelectorAll('[data-ms-hidden]').forEach(function(e){e.style.removeProperty('display');e.removeAttribute('data-ms-hidden');});})();
    """

    /// Adds a blue "+ Download in / ModShelf" button where Steam's green Subscribe button was.
    static let openButtonScript = """
    (function(){
      function addOpenButton(){
        if (document.getElementById('ms-open')) return;
        if (location.pathname.indexOf('filedetails') < 0) return;
        var id = new URLSearchParams(location.search).get('id');
        if (!id) return;
        var sub = document.getElementById('SubscribeItemBtn');
        if (!sub) {
          var els = Array.prototype.slice.call(document.querySelectorAll('a,button,span,div'));
          sub = els.find(function(e){ return /^\\s*subscribe\\s*$/i.test(e.textContent || ''); });
        }
        if (!sub) return;
        var target = sub.closest('a,button') || sub;
        target.style.setProperty('display','none','important');
        var b = document.createElement('a');
        b.id = 'ms-open';
        b.href = '#';
        b.innerHTML = '<span style="font-size:22px;font-weight:300;line-height:1;margin-right:12px">+</span><span style="line-height:1.2;white-space:nowrap">Download in<br>ModShelf</span>';
        b.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;box-sizing:border-box;width:100%;padding:10px 16px;margin-top:6px;background:#0A84FF;color:#fff;border:2px solid #000;border-radius:4px;font:600 14px -apple-system,sans-serif;white-space:nowrap;text-decoration:none;cursor:pointer';
        b.addEventListener('click', function(e){ e.preventDefault(); window.webkit.messageHandlers.modshelf.postMessage(id); });
        target.insertAdjacentElement('afterend', b);
      }
      addOpenButton(); setTimeout(addOpenButton, 800); setTimeout(addOpenButton, 2000);
      new MutationObserver(addOpenButton).observe(document.body, {childList: true, subtree: true});
    })();
    """

    /// Accepts Steam's cookie notice. If the notice still covers the page, it is hidden so the page can be used.
    static let cookieScript = """
    (function(){
      var words = /^(accept|accept all|accept all cookies|i accept|i agree|agree|allow all|allow cookies|got it)$/i;
      function dismiss(){
        if (!document.body) return;
        var text = document.body.innerText || '';
        if (!/cookie/i.test(text)) return;
        var buttons = Array.prototype.slice.call(document.querySelectorAll('button,a,input[type=button],input[type=submit]'));
        var accept = buttons.find(function(e){ return words.test((e.textContent || e.value || '').replace(/[,.!]/g,'').trim()); });
        if (accept) { accept.click(); }
        var boxes = Array.prototype.slice.call(document.querySelectorAll('div,section,aside,dialog,form'));
        boxes.forEach(function(e){
          var t = (e.innerText || '').trim();
          if (!t || t.length > 2500 || !/cookie/i.test(t)) return;
          var cs = getComputedStyle(e);
          if (cs.position === 'fixed' || cs.position === 'absolute' || parseInt(cs.zIndex, 10) > 0) {
            e.style.setProperty('display', 'none', 'important');
          }
        });
      }
      dismiss(); setTimeout(dismiss, 800); setTimeout(dismiss, 2500); setTimeout(dismiss, 5000);
      var pending = false;
      new MutationObserver(function(){
        if (pending) return;
        pending = true;
        setTimeout(function(){ pending = false; dismiss(); }, 300);
      }).observe(document.body, {childList: true, subtree: true});
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        var parent: WorkshopWebContainer
        var lastClean: Bool
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: WorkshopWebContainer) {
            self.parent = parent
            self.lastClean = parent.cleanPages
        }

        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoBack = v.canGoBack } },
                view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoForward = v.canGoForward } },
                view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.isLoading = v.isLoading } },
                view.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.updateURL(v.url) } }
            ]
            view.scrollView.delegate = self
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll(-(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
        }

        func updateURL(_ url: URL?) {
            parent.currentURL = url
            guard let url, WorkshopStore.workshopID(from: url.absoluteString) != nil,
                  url.path.contains("/sharedfiles/filedetails") else {
                parent.showUse = false
                return
            }
            parent.showUse = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateURL(webView.url)
            if let url = webView.url, url.host?.contains("steamcommunity.com") == true,
               url.path.contains("/app/") || url.path.contains("/sharedfiles/") {
                UserDefaults.standard.set(url.absoluteString, forKey: WorkshopBrowserView.lastPageKey)
            }
            CookieVault.save(from: webView.configuration.websiteDataStore.httpCookieStore)
            if parent.cleanPages {
                webView.evaluateJavaScript(WorkshopWebContainer.hideScript, completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Steam often uses target="_blank". Keep those links in this same web view.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "modshelf", let id = message.body as? String else { return }
            parent.onOpenInApp(id)
        }
    }
}
