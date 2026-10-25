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
let modShelfVersion = "0.1.0"

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


    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""
    private var activeMeta: WorkshopMetadata?
    private var queue: [String] = []
    private var didLaunchChecks = false
    private var customRoot: URL?
    private var scopedURL: URL?

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

    // MARK: download folder

    private func resolveCustomRoot() {
        guard let data = UserDefaults.standard.data(forKey: "options.folderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        customRoot = url
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "options.folderBookmark")
        }
    }
    func setCustomFolder(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        // Access must be started before the folder can be tested or bookmarked.
        let ok = url.startAccessingSecurityScopedResource()
        let probe = url.appendingPathComponent(".modshelf-write-test-\(UUID().uuidString)")
        let writable: Bool
        do {
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            writable = true
        } catch {
            writable = false
        }
        guard writable else {
            if ok { url.stopAccessingSecurityScopedResource() }
            errorMessage = "ModShelf can't save into that folder. Pick a folder on this iPhone or in iCloud Drive that ModShelf is allowed to write to."
            Haptics.error()
            return
        }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if ok { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Couldn't remember that folder. Try picking it again."
            return
        }
        UserDefaults.standard.set(data, forKey: "options.folderBookmark")
        customRoot = url
        if ok { scopedURL = url }
        updateFolderLabel()
        operationMessage = "New downloads will be saved to \(url.lastPathComponent)."
    }
    func resetCustomFolder() {
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        customRoot = nil
        UserDefaults.standard.removeObject(forKey: "options.folderBookmark")
        updateFolderLabel()
        operationMessage = "Download folder reset to the default."
    }
    private func updateFolderLabel() {
        if let root = customRoot {
            folderLabel = (try? root.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? root.lastPathComponent
        } else { folderLabel = "On My iPhone / ModShelf / Downloaded Mods" }
    }
    var usingCustomFolder: Bool { customRoot != nil }
    private func isManagedPath(_ path: String) -> Bool {
        var roots = [defaultRoot.path]
        if let c = customRoot { roots.append(c.path) }
        return roots.contains { path.hasPrefix($0 + "/") }
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
            errorMessage = "Paste a valid Steam Workshop URL or numeric item ID."
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
                errorMessage = "Workshop item \(id) could not be found or its details could not be loaded. It may be private, deleted, unavailable, or Steam may be rate-limiting requests. You can still try downloading it by ID."
                preview = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "Metadata was unavailable. Downloading may still work if this item is accessible to your Steam account.", imageURL: "", updatedAt: 0)
            }
            isFetching = false
        }
    }

    // MARK: sign in

    func signIn(automatic: Bool = false) async {
        if isBusy && needsGuardCode {
            let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { errorMessage = "Enter the Steam Guard code from the Steam app."; return }
            Haptics.tap()
            engine.submitGuardCode(code)
            guardCode = ""
            status = "Checking code…"
            return
        }
        guard !isBusy else { errorMessage = "Cancel the current download before signing in or out."; return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            if !automatic { showLogin = true }
            errorMessage = automatic ? "" : "Enter your Steam username and password."
            return
        }
        isBusy = true; status = "Signing in to Steam…"; errorMessage = ""; needsGuardCode = false
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
            Haptics.success()
        } else {
            errorMessage = result.isEmpty ? (engine.lastError().isEmpty ? "Steam sign-in did not complete." : engine.lastError()) : result
            if errorMessage.localizedCaseInsensitiveContains("guard") || errorMessage.localizedCaseInsensitiveContains("code") {
                status = "Steam Guard code required"
                needsGuardCode = true
            }
            if !automatic { showLogin = true; Haptics.error() }
            // An automatic launch sign-in that needs a code is not retried; it would only send another prompt.
            if automatic { errorMessage = "" }
        }
    }
    func signOut() {
        guard !isBusy else { errorMessage = "Cancel the current download before signing out."; return }
        engine.logout(); Keychain.delete("steam.password"); password = ""; guardCode = ""
        status = "Signed out"
    }

    // MARK: download

    func download(_ raw: String? = nil, meta override: WorkshopMetadata? = nil) {
        errorMessage = ""
        guard !isBusy else { errorMessage = "A download or sign-in is already running."; return }
        guard isAuthenticated else { operationMessage = "Sign in to Steam to download this item."; showLogin = true; return }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a valid Workshop URL or ID."; return }
        if UserDefaults.standard.bool(forKey: "options.wifiOnly") && NetworkWatcher.shared.isExpensive {
            errorMessage = "Wi-Fi only is on and you're on a cellular or hotspot connection."
            queue.removeAll()
            return
        }
        activeID = id
        let fallback = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "", imageURL: "", updatedAt: 0)
        let meta: WorkshopMetadata = override ?? ((preview?.id == id ? preview : nil) ?? fallback)
        activeMeta = meta
        activeTitle = meta.title
        let finalHint = downloadsRoot.appendingPathComponent(id, isDirectory: true)
        let staging = downloadsRoot.appendingPathComponent(".partial-\(id)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create a download folder: \(error.localizedDescription)"
            record(id, title: meta.title, result: "Failed", error: errorMessage, game: meta.gameName)
            return
        }
        let result = engine.downloadWorkshopItem(id, targetDir: staging.path)
        if !result.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            errorMessage = result; status = result
            record(id, title: meta.title, result: "Failed", error: result, imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL, game: meta.gameName)
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
        UserDefaults.standard.set(finalHint.path, forKey: "modshelf.activeFinal")
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
        UserDefaults.standard.removeObject(forKey: "modshelf.activeFinal")
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
                failureText = "Download could not be finalised: \(error.localizedDescription)"
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
            let reason = cancelled ? "Download cancelled." : (!error.isEmpty ? error : (!failureText.isEmpty ? failureText : "The download failed before it could be finalised."))
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
    private func uniqueDestination(name: String, id: String) -> URL {
        let fm = FileManager.default
        let root = downloadsRoot
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        candidate = root.appendingPathComponent("\(name) (\(id))", isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        return root.appendingPathComponent("\(name) (\(id)-\(UUID().uuidString.prefix(4)))", isDirectory: true)
    }

    private func finalizeDownload(staging: URL, id: String, meta: WorkshopMetadata, existing: WorkshopItem?) throws -> (url: URL, files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard !visibleChildren(staging).isEmpty else {
            throw NSError(domain: "ModShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Steam reported completion but the download folder is empty."])
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

        // Replace the previous copy completely if it is still inside the downloads folder.
        var destination: URL? = nil
        if let ex = existing, isManagedPath(ex.folder) {
            let exURL = URL(fileURLWithPath: ex.folder, isDirectory: true)
            if fm.fileExists(atPath: exURL.path) { try fm.removeItem(at: exURL) }
            if exURL.lastPathComponent != id { destination = exURL }   // old layouts used <id> as the folder name
        }
        let dest = destination ?? uniqueDestination(name: name, id: id)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }

        let counts = Self.scan(folder: payload.path)
        try fm.moveItem(at: payload, to: dest)
        try? fm.removeItem(at: staging)

        if UserDefaults.standard.object(forKey: "options.infoFile") as? Bool ?? true {
            let text = infoText(meta: meta, id: id, destination: dest, files: counts.count, bytes: counts.bytes, existing: existing, singleMod: singleMod)
            try? text.write(to: dest.appendingPathComponent(modShelfInfoFileName), atomically: true, encoding: .utf8)
        }
        return (dest, counts.count, counts.bytes)
    }

    private func infoText(meta: WorkshopMetadata, id: String, destination: URL, files: Int, bytes: Int64, existing: WorkshopItem?, singleMod: Bool) -> String {
        let stamp = DateFormatter(); stamp.dateFormat = "d MMM yyyy, h:mm a"
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        var lines: [String] = ["ModShelf Information", "===================="]
        lines.append("")
        lines.append("Title: \(meta.title)")
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
        lines.append("Installed with: ModShelf \(version) (build \(build))")
        lines.append("Size: \(Fmt.bytes(bytes)) - Files: \(files)")
        lines.append("")
        lines.append("This file is written by ModShelf and is safe to delete, turn future info files off in ModShelf's options.")
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

    // MARK: library actions

    func remove(_ item: WorkshopItem) {
        do { if FileManager.default.fileExists(atPath: item.folder) { try FileManager.default.removeItem(atPath: item.folder) } }
        catch { errorMessage = "Could not delete downloaded files: \(error.localizedDescription)"; return }
        library.removeAll { $0.id == item.id }; saveLibrary(); refreshLibraryBytes()
    }
    func requestDelete(_ item: WorkshopItem) {
        if UserDefaults.standard.object(forKey: "options.confirmDelete") as? Bool ?? true {
            pendingDelete = item; showDeleteConfirmation = true
        } else { remove(item) }
    }
    func toggleFavourite(_ item: WorkshopItem) {
        guard let i = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[i].isFavourite.toggle()
        saveLibrary()
        Haptics.tap()
    }
    func export(_ item: WorkshopItem) {
        let source = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { errorMessage = "Downloaded files could not be found. Use Verify files to check the library entry."; return }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.displayTitle.replacingOccurrences(of: "/", with: "-")).zip")
        do { try? FileManager.default.removeItem(at: zip); try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: true); shareURL = zip }
        catch { errorMessage = "ZIP export failed: \(error.localizedDescription)" }
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
        operationMessage = "Checking \(item.displayTitle)…"
        Task { @MainActor in
            let scan = await Task.detached(priority: .utility) { Self.scan(folder: folder) }.value
            guard scan.exists, scan.count > 0 else {
                applyCheck(item.id, broken: true)
                operationMessage = "\(item.displayTitle) is missing its files. Download it again."
                return
            }
            guard let meta = await SteamMeta.fetch(id: item.id, includePage: false), meta.fileSize > 0 else {
                operationMessage = "Couldn't get \(item.displayTitle)'s size from Steam. Check your connection and try again."
                return
            }
            let ok = Self.sizeMatches(disk: scan.bytes, steam: meta.fileSize)
            applyCheck(item.id, broken: !ok)
            operationMessage = ok
                ? "\(item.displayTitle) matches Steam (\(Fmt.bytes(scan.bytes)))."
                : "\(item.displayTitle) is \(Fmt.bytes(scan.bytes)) here, but Steam lists \(Fmt.bytes(meta.fileSize)). Try downloading it again."
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
                operationMessage = "Checking \(index + 1) of \(entries.count)…"
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
                operationMessage = "Could not check item \(item.id). It may be private, deleted, or Steam may be rate-limiting requests."
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
            // Leftover partial downloads from interrupted sessions
            for url in visibleAndHidden(downloadsRoot) where url.lastPathComponent.hasPrefix(".partial-") { try? FileManager.default.removeItem(at: url) }
            status = "Temporary files cleared"
            operationMessage = "Temporary files cleared."
        } catch { errorMessage = "Could not clear temporary files: \(error.localizedDescription)" }
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

// MARK: - Main view

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = true
    @AppStorage("options.haptics") private var haptics = true
    @AppStorage("browser.autoDownload") private var autoDownload = false
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @AppStorage("options.gifLibrary") private var gifLibrary = true
    @AppStorage("options.tabStyle") private var tabStyle = "bar"
    @AppStorage("options.sortOrder") private var sortOrder = "Recently added"
    @AppStorage("options.autoCheck") private var autoCheck = true
    @AppStorage("options.wifiOnly") private var wifiOnly = false
    @AppStorage("options.infoFile") private var infoFile = true
    @AppStorage("options.cleanBrowser") private var cleanBrowser = true
    @AppStorage("browser.zoom") private var browserZoom = 1.0
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
    @State private var showFolderPicker = false
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

    // MARK: body

    var body: some View {
        ZStack {
            mainStack
            overlays
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showShare, onDismiss: { store.shareURL = nil }) { if let url = store.shareURL { ShareSheet(activityItems: [url]) } }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(onPick: { url in
                showFolderPicker = false
                store.setCustomFolder(url)
            }, onCancel: { showFolderPicker = false })
        }
        .onChange(of: store.shareURL) { showShare = $0 != nil }
        .onChange(of: confirmDelete) { UserDefaults.standard.set($0, forKey: "options.confirmDelete") }
        .onChange(of: store.errorMessage) { message in
            guard !message.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if store.errorMessage == message { withAnimation { store.errorMessage = "" } }
            }
        }
        .onChange(of: store.operationMessage) { message in
            guard !message.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if store.operationMessage == message { withAnimation { store.operationMessage = "" } }
            }
        }
        .onChange(of: store.library.count) { _ in
            if let g = selectedGame, !installedGames.contains(where: { $0.id == g }) { selectedGame = nil }
            if let t = selectedTag, !installedTags.contains(t) { selectedTag = nil }
        }
        .task { store.runLaunchChecks() }
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            accountHeader
            errorBanner
            downloadBanner
            tabContent
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab, style: tabStyle, collapsed: tabCollapsed,
                      libraryBadge: store.library.contains(where: { $0.updateAvailable }))
                .frame(height: tabBarReserve, alignment: .bottom)
        }
        .tint(Color.accentColor)
        .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))
        .onChange(of: selectedTab) { _ in tabCollapsed = false }
    }

    private var tabContent: some View {
        ZStack {
            downloadView.tabLayer(0, selected: selectedTab)
            browserTab.tabLayer(1, selected: selectedTab)
            libraryView.tabLayer(2, selected: selectedTab)
            optionsView.tabLayer(3, selected: selectedTab)
        }
    }

    private var browserTab: some View {
        WorkshopBrowserView(onValidItem: { url in
                                store.browserURL = nil
                                store.input = url.absoluteString
                                inputWasSubmitted = false
                                selectedTab = 0
                                store.fetchPreview()
                            },
                            onOpenInApp: { id in
                                inputWasSubmitted = false
                                selectedTab = 0
                                if autoDownload {
                                    store.download(id)
                                } else {
                                    store.input = id
                                    store.fetchPreview()
                                }
                            },
                            requestedURL: $store.browserURL,
                            cleanPages: cleanBrowser,
                            zoom: browserZoom,
                            bottomInset: tabBarReserve,
                            onScroll: { y in handleScroll(y) })
            .ignoresSafeArea(edges: tabStyle == "bar" ? [] : .bottom)
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
    }

    /// Popups hold a snapshot; this returns the freshest copy so favourite/status changes show immediately.
    private func currentItem(_ item: WorkshopItem) -> WorkshopItem {
        store.library.first(where: { $0.id == item.id }) ?? item
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
        if !store.errorMessage.isEmpty || !store.operationMessage.isEmpty {
            let isError = !store.errorMessage.isEmpty
            let text = isError ? friendlyError(store.errorMessage) : store.operationMessage
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isError ? "Couldn't finish that" : "Update").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
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

    /// Turns raw engine text into something a person can act on.
    private func friendlyError(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("steam guard") || r.contains("guard code") {
            return "Steam wants a confirmation code. Enter the code from your Steam app and tap Submit code."
        }
        if r.contains("not entered in time") { return "The code wasn't entered in time. Tap Sign in to try again." }
        if r.contains("password") && (r.contains("invalid") || r.contains("incorrect") || r.contains("wrong")) {
            return "Steam didn't accept that username or password. Check them and try again."
        }
        if r.contains("rate limit") || r.contains("too many") { return "Steam is limiting requests right now. Wait a minute and try again." }
        if r.contains("timeout") || r.contains("timed out") || r.contains("network") || r.contains("offline") {
            return "No connection to Steam. Check your internet and try again."
        }
        if r.contains("cancel") { return "The download was cancelled." }
        return raw
    }

    @ViewBuilder private var downloadBanner: some View {
        if store.isDownloading && selectedTab != 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(store.activeTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int(store.progress * 100))%").font(.footnote.monospacedDigit().weight(.semibold))
                    Button { store.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                ProgressView(value: store.progress).tint(.accentColor)
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
        let total = max(3, store.phases.count)
        let filled = min(store.phases.count, total)
        let percent = Int(Double(filled) / Double(total) * 100)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Downloading").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(percent)%").font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Button { Haptics.tap(); store.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.red)
                        .frame(width: 30, height: 30).background(Circle().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Color.accentColor : Color.accentColor.opacity(0.18))
                        .frame(height: 8)
                }
            }
            .animation(.easeOut(duration: 0.25), value: filled)
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
                MediaCarousel(media: media).id(media.map { $0.id }.joined(separator: "|"))
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
                        if showIDs {
                            Text("ID: \(item.id)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
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
        if showingHistory {
            let failed = store.history.filter { $0.result == "Failed" }.count
            return "\(store.history.count) attempts · \(failed) failed"
        }
        let n = store.library.count
        return "\(n) mod\(n == 1 ? "" : "s") · \(Fmt.bytes(store.libraryStorageBytes))"
    }

    private func iconLabel(_ symbol: String, spinning: Bool = false) -> some View {
        Group {
            if spinning { ProgressView() } else { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor) }
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
            let pending = store.library.filter { $0.updateAvailable }.count
            Button { store.updateAll(); selectedTab = 0 } label: { Label("Update all (\(pending))", systemImage: "arrow.down.circle") }
                .disabled(pending == 0 || store.isBusy)
            Button { store.exportAll() } label: { Label("Export all as ZIP", systemImage: "square.and.arrow.up") }
        } label: { iconLabel("ellipsis") }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    // MARK: grid + list

    private func gridContent(_ items: [WorkshopItem]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ScrollSpy(onChange: handleScroll)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in gridCard(item) }
                }
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, tabBarReserve)
            }
        }
        .coordinateSpace(name: "scroll")
        .scrollDismissesKeyboard(.interactively)
    }

    private func listContent(_ items: [WorkshopItem]) -> some View {
        List {
            ScrollSpy(onChange: handleScroll).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
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
        }
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

    private func gridCard(_ item: WorkshopItem) -> some View {
        let line = dateLine(item)
        return VStack(alignment: .leading, spacing: 7) {
            Button { Haptics.tap(); popupItem = item } label: {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay(CachedImage(urlString: item.imageURL, fill: true, maxPixel: 520))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) { favouriteStar(item, size: 15).padding(8) }
            .overlay(alignment: .topTrailing) { dotsButton(item, circle: 29).padding(8) }

            Button { Haptics.tap(); popupItem = item } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        RatingLine(rating: item.rating, count: item.ratingCount, size: 12)
                        if showIDs {
                            Text("ID: \(item.id)").font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    HStack(spacing: 4) {
                        StatusGlyph(status: item.status, size: 11)
                        Text(line.0).font(.system(size: 11, weight: .medium)).foregroundStyle(line.1)
                    }
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
        return HStack(spacing: 12) {
            Button { Haptics.tap(); popupItem = item } label: {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 84, height: 84)
                        .overlay(CachedImage(urlString: item.imageURL, fill: true, maxPixel: 300))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            VStack(spacing: 8) {
                navCircle(item.isFavourite ? "star.fill" : "star") { store.toggleFavourite(item) }
                navCircle("ellipsis") { contextItem = item }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScrollSpy(onChange: handleScroll)
                    Text("Options").font(.system(size: 27, weight: .bold, design: .rounded)).padding(.top, 10)

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

                    settingsGroup("Browser") {
                        toggleRow("Workshop only (hide news, RSS and comments)", symbol: "newspaper", isOn: $cleanBrowser)
                        divider
                        toggleRow("Auto download from browser", symbol: "arrow.down.circle", isOn: $autoDownload)
                        divider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Text size", systemImage: "textformat.size").font(.system(size: 16))
                                Spacer()
                                Text("\(Int(browserZoom * 100))%").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Slider(value: $browserZoom, in: 0.8...1.4, step: 0.05).tint(.accentColor)
                        }
                        .padding(.horizontal, 15).padding(.vertical, 12)
                    }

                    settingsGroup("Downloads") {
                        toggleRow("Confirm before deleting", symbol: "trash", isOn: $confirmDelete)
                        divider
                        toggleRow("Check updates on launch", symbol: "arrow.clockwise", isOn: $autoCheck)
                        divider
                        toggleRow("Wi-Fi only downloads", symbol: "wifi", isOn: $wifiOnly)
                        divider
                        toggleRow("Write info file into each mod", symbol: "doc.text", isOn: $infoFile)
                        divider
                        Button { Haptics.tap(); showFolderPicker = true } label: {
                            rowContent("Download folder", symbol: "folder", detail: store.folderLabel)
                        }.buttonStyle(.plain)
                        if store.usingCustomFolder {
                            divider
                            Button { Haptics.tap(); store.resetCustomFolder() } label: {
                                rowContent("Reset to default folder", symbol: "arrow.uturn.backward", detail: nil, tint: .accentColor)
                            }.buttonStyle(.plain)
                        }
                        divider
                        Button { Haptics.tap(); store.clearTemporaryFiles() } label: {
                            rowContent("Clear temporary files", symbol: "trash.slash", detail: nil)
                        }.buttonStyle(.plain)
                    }

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
                }
                .padding(.horizontal, 15).padding(.bottom, tabBarReserve)
            }
            .coordinateSpace(name: "scroll")
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
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
                            Text(store.isAuthenticated ? "Your Steam session is active." : "Your password is stored in the Keychain on this device only.")
                                .font(.footnote).foregroundStyle(.secondary)
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
                    if !store.errorMessage.isEmpty {
                        Text(store.errorMessage).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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

struct ConfirmPopup: View {
    let heading: String
    let message: String
    let actionTitle: String
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
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red))
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
    @State private var index = 0
    var body: some View {
        VStack(spacing: 6) {
            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.offset) { i, item in
                    Group {
                        switch item {
                        case .image(let url):
                            CachedImage(urlString: url, fill: false, maxPixel: 1000, isDownloadPreview: true)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        case .video(let id):
                            YouTubeView(videoID: id)
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

/// Embeds a YouTube video using the player's own controls (mute, quality, fullscreen).
/// Links inside the player, such as "Watch on YouTube", open in the YouTube app or Safari instead of this page.
struct YouTubeView: UIViewRepresentable {
    let videoID: String
    private static let origin = "https://modshelf.app"

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != videoID else { return }
        context.coordinator.loaded = videoID
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&rel=0&modestbranding=1&origin=\(Self.origin)"
          referrerpolicy="strict-origin-when-cross-origin" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: Self.origin))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
}

// MARK: - Folder picker and share sheet

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    var onCancel: () -> Void = { }
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
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


// MARK: - Browser home (custom start page)

struct GameHit: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let tiny_image: String?
}

struct GameSearchResponse: Codable { let items: [GameHit] }

enum GameSearch {
    /// Finds games by name using Steam's public store search (no sign-in needed).
    static func search(_ term: String) async -> [GameHit] {
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
    @AppStorage("browser.recentGames") private var recentJSON = "[]"
    @AppStorage("browser.favGames") private var favJSON = "[]"

    private var recent: [GameHit] { GameListStore.decode(recentJSON) }
    private var favourites: [GameHit] { GameListStore.decode(favJSON) }

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
                    if recent.isEmpty && favourites.isEmpty {
                        Text("Search a game above to browse its Workshop.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }
            .padding(15)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: query) { await runSearch() }
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
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a game", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(favourites.prefix(4))) { hit in
                Button { openGame(hit) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 400)
                            .frame(height: 86)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(hit.name)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .contextMenu { favouriteButton(hit) }
            }
        }
    }

    private func gameRow(_ hit: GameHit) -> some View {
        Button { openGame(hit) } label: {
            HStack(spacing: 12) {
                CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 120)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(hit.name)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { favouriteButton(hit) }
    }

    private func favouriteButton(_ hit: GameHit) -> some View {
        let isFavourite = favourites.contains(hit)
        return Button {
            Haptics.tap()
            var list = favourites
            if let index = list.firstIndex(of: hit) { list.remove(at: index) } else { list.insert(hit, at: 0) }
            favJSON = GameListStore.encode(list)
        } label: {
            Label(isFavourite ? "Remove favourite" : "Favourite", systemImage: isFavourite ? "star.slash" : "star")
        }
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
                Image(systemName: "arrow.uturn.forward.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue where you left off").font(.system(size: 15, weight: .semibold))
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workshop browser

struct WorkshopBrowserView: View {
    let onValidItem: (URL) -> Void
    let onOpenInApp: (String) -> Void
    @Binding var requestedURL: URL?
    let cleanPages: Bool
    let zoom: Double
    let bottomInset: CGFloat
    let onScroll: (CGFloat) -> Void

    @State private var webView: WKWebView?
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showUse = false
    @State private var showHome = true

    static let home = URL(string: "https://steamcommunity.com/workshop/")!
    static let lastPageKey = "browser.lastURL"

    private var savedLastPage: URL? {
        UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap { URL(string: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !showHome { topBar }
            ZStack {
                WorkshopWebContainer(webView: $webView, currentURL: $currentURL, canGoBack: $canGoBack,
                                     canGoForward: $canGoForward, isLoading: $isLoading, showUse: $showUse,
                                     requestedURL: $requestedURL, cleanPages: cleanPages, zoom: zoom,
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
        .overlay(alignment: .bottomLeading) { bottomControls }
        .onChange(of: requestedURL) { url in
            if url != nil { showHome = false }
        }
    }

    private func open(_ url: URL) {
        showHome = false
        requestedURL = url
    }

    /// Home, Back and Forward sit at the bottom left, just above the tab bar.
    private var bottomControls: some View {
        HStack(spacing: 6) {
            controlButton("house.fill", "Browse home", enabled: true) { showHome = true }
            controlButton("chevron.left", "Back", enabled: canGoBack && !showHome) { webView?.goBack() }
            controlButton("chevron.right", "Forward", enabled: canGoForward && !showHome) { webView?.goForward() }
        }
        .padding(6)
        .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        .padding(.leading, 12)
        .padding(.bottom, bottomInset + 8)
    }

    private var addressText: String {
        guard let u = currentURL else { return "" }
        return (u.host ?? "") + u.path
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            controlButton("arrow.clockwise", "Reload", enabled: true) { webView?.reload() }
            Text(addressText)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            if isLoading { ProgressView().scaleEffect(0.8) }
            if showUse, let url = currentURL {
                Button { onValidItem(url) } label: {
                    Text("Use item")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func controlButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(enabled ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct WorkshopWebContainer: UIViewRepresentable {
    @Binding var webView: WKWebView?
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var showUse: Bool
    @Binding var requestedURL: URL?
    let cleanPages: Bool
    let zoom: Double
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

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor.systemBackground
        view.scrollView.backgroundColor = UIColor.systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.contentInset.bottom = bottomInset
        view.pageZoom = zoom
        context.coordinator.observe(view)
        webView = view

        let start = requestedURL ?? Self.lastPage() ?? WorkshopBrowserView.home
        DispatchQueue.main.async { self.requestedURL = nil }
        CookieVault.restore(into: view.configuration.websiteDataStore.httpCookieStore) {
            view.load(URLRequest(url: start))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
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
      var markers = ['LATEST WORKSHOP NEWS','Subscribe to RSS feed','ABOUT - THE WORKSHOP','Workshop Home About Workshop','Read the full post on our Steam Blog',"Here's a quick look"];
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
          var t=(el.innerText||'').trim();
          if(!t || t.length>6000) continue;
          var hit=markers.some(function(m){return t.indexOf(m)===0 || (t.indexOf(m)>=0 && t.length<600);});
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
        b.innerHTML = '<span style="font-size:24px;font-weight:300;line-height:1;margin-right:12px">+</span><span style="line-height:1.15">Download in<br>ModShelf</span>';
        b.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;box-sizing:border-box;width:100%;padding:12px 16px;margin-top:6px;background:#0A84FF;color:#fff;border-radius:4px;font:600 15px -apple-system,sans-serif;text-decoration:none;cursor:pointer';
        b.addEventListener('click', function(e){ e.preventDefault(); window.webkit.messageHandlers.modshelf.postMessage(id); });
        target.insertAdjacentElement('afterend', b);
      }
      addOpenButton(); setTimeout(addOpenButton, 800); setTimeout(addOpenButton, 2000);
      new MutationObserver(addOpenButton).observe(document.body, {childList: true, subtree: true});
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
            if let url = webView.url, url.host?.contains("steamcommunity.com") == true {
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
