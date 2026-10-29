import SwiftUI
import UIKit
import WebKit
import Security
import ZIPFoundation
import Network
import ImageIO
import SteamEngine

@main
struct ModShelfApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

let modShelfInfoFileName = "ModShelf Information.txt"
/// A second record, written into every install whether the visible info file is switched on or not,
/// so a folder on disk can say what it is when the library has lost track of it.
let modShelfManifestName = ".modshelf.json"
/// The version comes from the bundle, so bumping MARKETING_VERSION in project.yml is the only edit.
let modShelfVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
/// The build number CI stamps in, taken from the bundle so it follows the commit count.
let modShelfBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"

// MARK: - Models

/// What ModShelf can say about a mod: its Workshop state, and whether its files are still here to
/// be checked. Moving a mod into a game is normal use, so that alone is not a problem.
enum ModStatus { case upToDate, needsUpdate, moved, notChecked, broken }

extension ModStatus {
    /// Whether a mod deserves a look in the library: its files are missing or changed, or ModShelf
    /// has never managed to check it.
    var needsAttention: Bool { self == .broken || self == .notChecked }

    /// The colour of a status text, the same as its icon: only a pending update or files that don't
    /// match Steam are worth colour; everything else is calm grey.
    var textColor: Color {
        switch self {
        case .upToDate, .moved, .notChecked: return .secondary
        case .needsUpdate: return .accentColor
        case .broken: return .yellow
        }
    }
}

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
    /// The files are no longer where they were installed, which normally means the user moved the
    /// mod into the game. That is ordinary use, so it counts as moved out rather than as damage.
    var filesMoved: Bool = false
    var fileCount: Int? = nil
    var byteCount: Int64? = nil
    /// The last time ModShelf could actually read this mod's files on disk.
    var lastVerifiedAt: Date? = nil
    var lastVerifiedBytes: Int64? = nil
    var lastVerifiedFiles: Int? = nil

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
        filesMoved = try c.decodeIfPresent(Bool.self, forKey: .filesMoved) ?? false
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount)
        byteCount = try c.decodeIfPresent(Int64.self, forKey: .byteCount)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        lastVerifiedBytes = try c.decodeIfPresent(Int64.self, forKey: .lastVerifiedBytes)
        lastVerifiedFiles = try c.decodeIfPresent(Int.self, forKey: .lastVerifiedFiles)
    }

    var displayTitle: String { title ?? "Workshop item \(id)" }

    /// Where ModShelf keeps its downloads. A mod outside this folder was moved by the user, so
    /// its files can no longer be read here — but its Workshop details still can.
    static let managedRoot: String = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

    var isInsideModShelf: Bool {
        folder == Self.managedRoot || folder.hasPrefix(Self.managedRoot + "/")
    }

    var status: ModStatus {
        if filesBroken { return .broken }
        if updateAvailable { return .needsUpdate }
        if checkFailed || lastCheckedAt == nil { return .notChecked }
        if !isInsideModShelf || filesMoved { return .moved }
        return .upToDate
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

/// The hidden record ModShelf keeps inside each installed mod. It is always written, so the folder
/// can be identified and put back in the library even when the library file or the visible info file
/// is gone, and the version that is installed can be compared with Steam again.
struct InstalledModManifest: Codable {
    var workshopID: String
    var title: String? = nil
    var appID: String? = nil
    var gameName: String? = nil
    var publishedUpdatedAt: Int? = nil
    var installedAt: Date? = nil
    var fileCount: Int? = nil
    var byteCount: Int64? = nil
    var modShelfVersion: String? = nil
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

/// One line of the download queue shown on the download screen while a batch runs.
struct DownloadQueueRow: Identifiable, Equatable {
    enum State: Equatable { case waiting, downloading, done, failed }
    let id: String
    var title: String
    var imageURL: String?
    var gameName: String? = nil
    /// The mod's expected size, used to weigh it in the batch percentage.
    var fileSize: Int64 = 0
    var progress: Double = 0
    var state: State = .waiting
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

/// One place that turns Steam's raw wording into a short line someone can act on. The wording stays
/// calm on purpose: a failed download is a small thing, not an alarm.
enum ErrorText {
    static func friendly(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "That didn't go through just now. Try it again." }
        let r = text.lowercased()
        if r.contains("own this game") || r.contains("not own") || r.contains("don't own")
            || r.contains("no license") || r.contains("licen") || r.contains("not purchased") {
            return "Steam only hands over a game's Workshop items when the game is in your library. Free-to-play games are covered once you add them."
        }
        if r.contains("removed") || r.contains("banned") || r.contains("violat") {
            return "Steam has taken this item down, so it can't be downloaded any more."
        }
        if r.contains("private") { return "This item is private, so Steam won't hand it over." }
        if r.contains("not found") || r.contains("doesn't exist") || r.contains("does not exist")
            || r.contains("invalid item") || r.contains("no such item") {
            return "Steam can't find that item any more. It may have been deleted."
        }
        if r.contains("window") && r.contains("item") { return "Steam doesn't allow this item to be downloaded." }
        if r.contains("rate limit") || r.contains("too many") {
            return "Steam is asking us to slow down. Give it a minute and try again."
        }
        if r.contains("without a completion event") { return "The download stopped early. Nothing was replaced." }
        if r.contains("stopped sending") {
            return "Steam stopped sending data. Try again — it picks up where it left off."
        }
        if r.contains("timeout") || r.contains("timed out") || r.contains("network")
            || r.contains("offline") || r.contains("connection") || r.contains("reach") {
            return "We couldn't reach Steam just now. Check the connection and try again."
        }
        if r.contains("no space") || r.contains("disk full") || r.contains("not enough space") {
            return "There isn't quite enough free space for this one."
        }
        if r.contains("cancel") { return "That download was cancelled." }
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

    /// Empties the in-memory images and the image cache on disk.
    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
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
    /// Tried in order when the main address has no picture, so an older or smaller artwork is used
    /// instead of leaving the space empty.
    var fallbackURLStrings: [String] = []
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @AppStorage("options.gifLibrary") private var gifLibrary = true
    var isDownloadPreview = false
    @State private var image: UIImage?
    private var animate: Bool { isDownloadPreview ? gifDownloads : gifLibrary }

    private var taskKey: String {
        ([urlString ?? ""] + fallbackURLStrings).joined(separator: "|") + (animate ? "|1" : "|0")
    }

    var body: some View {
        // A clear base takes whatever size the parent offers, and the picture is drawn on top of it:
        // a wide landscape image can then never decide the layout and blow a cell or row apart.
        Color.clear
            .overlay { picture }
            .clipped()
            .task(id: taskKey) {
                let candidates = ([urlString ?? ""] + fallbackURLStrings).filter { !$0.isEmpty }
                guard !candidates.isEmpty else { image = nil; return }
                for candidate in candidates {
                    guard let url = URL(string: candidate) else { continue }
                    if let hit = ImageStore.shared.cached(url, animate: animate) { image = hit; return }
                    if let loaded = await ImageStore.shared.load(url, maxPixel: maxPixel, animate: animate) {
                        image = loaded
                        return
                    }
                }
                image = nil
            }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            if image.images != nil {
                AnimatedUIImageView(image: image, fill: fill, loops: 5)
            } else if fill {
                // Filled to cover and centred, so a landscape preview is cropped to the same square
                // as a square one.
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(uiImage: image).resizable().scaledToFit()
            }
        } else {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
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
        if let m = firstMatch(#"class="numRatings"[^>]*>[\s\S]{0,64}?([\d][\d,\.\s]*)"#, in: html) {
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
        // An app ID Steam has no name for stays unknown, so a folder named "App <id>" left alone
        // does not cost a request on every launch.
        let unknownKey = "modshelf.gameNamesUnknown"
        var unknown = Set(UserDefaults.standard.stringArray(forKey: unknownKey) ?? [])
        if unknown.contains(appID) { return nil }
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appID] as? [String: Any], (entry["success"] as? Bool) == true,
              let d = entry["data"] as? [String: Any], let name = d["name"] as? String else {
            unknown.insert(appID)
            UserDefaults.standard.set(Array(unknown), forKey: unknownKey)
            return nil
        }
        cache[appID] = name
        UserDefaults.standard.set(cache, forKey: cacheKey)
        if unknown.remove(appID) != nil { UserDefaults.standard.set(Array(unknown), forKey: unknownKey) }
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
    /// A finished transfer is moved into the library after Steam is done with it, which for a big
    /// item means tens of thousands of files and takes a few seconds.
    @Published var isInstalling = false
    /// A ZIP is being written from the library's own folders.
    @Published var isExporting = false
    /// A transfer stopped on purpose, keeping what it had already written so it can carry on.
    @Published var isPaused = false
    /// A resume asked for while the paused transfer was still winding down.
    private var resumePending = false
    /// When the transfer was paused and where its half-written files live, so a long pause can start
    /// again from scratch rather than trusting a staging folder the engine may have lost.
    private var pausedAt: Date?
    private var pausedStaging: URL?
    /// Set while a moved mod is waiting for the current transfer to let go of the engine.
    private var startAfterCancel: String?
    private var keepActiveOnCancel = false
    /// A cancellation that should leave the rest of the batch in the queue.
    private var keepQueueOnCancel = false
    /// The small ring beside the sign-in pill: shown while a transfer runs and for ten seconds after
    /// it finishes, when its arrow turns blue.
    @Published var ringVisible = false
    @Published var ringDone = false
    @Published var ringProgress = 0.0
    private var ringHideTask: Task<Void, Never>?
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
    @Published var activeTitle = ""
    @Published var phases: [String] = []
    @Published var revealFolderURL: URL?
    @Published var appUpdateMessage = ""
    @Published var isCheckingAppUpdate = false

    /// The Go engine. Signing in and downloading need it, so a failure to create it is reported
    /// instead of crashing the app on launch. Its type comes from the generated binding, so it is
    /// left to inference rather than named here.
    private let engine = SteamengineNewEngine()
    private var poller: Timer?
    private(set) var activeID = ""
    private var activeMeta: WorkshopMetadata?
    private var queue: [String] = []
    /// How far through "Update all" the run is, so the download screen can say which one it is on.
    @Published var queueStep = 0
    @Published var queueTotal = 0
    /// The rows drawn on the download screen while a batch runs (or a simulated one).
    @Published var queueRows: [DownloadQueueRow] = []
    /// Everything worth knowing when something goes wrong: download starts, phases, progress and errors.
    @Published var runtimeLog: [String] = []
    private var lastLoggedDecade = -1
    private var autoRetries = 0
    private var autoRetryItem = ""
    private var queueFailed = 0
    private var devTask: Task<Void, Never>?
    // Progress follows the size of the folder the mod is written into, which rises with the bytes as
    // they land. Steam's own counter only appears in a burst at the end, so it cannot drive the bar.
    @Published var isDownloadStalled = false
    private var downloadActiveSeconds: Double = 0
    private var lastTickAt: Date?
    private var lastEngineSeen: Double = -1
    private var lastStatusSeen = ""
    private var lastMovementAt: Date?
    private var downloadExpectedBytes: Int64 = 0
    private var downloadBytesPerSecond: Double = 0
    /// Mods waiting their turn, with the details they were started from.
    private var pendingMeta: [String: WorkshopMetadata] = [:]
    // The folder being written is measured now and then, which is the only honest sign of progress
    // for big items where Steam's own counter stays at zero.
    private var activeStaging: URL?
    private var stagingProbeInFlight = false
    private var lastStagingProbe = Date.distantPast
    private var receivedBytes: Int64 = 0
    private var lastReceivedSeen: Int64 = -1
    private var stagingBaselineBytes: Int64 = 0
    private var lastDiskSample: (Date, Int64)?
    private var lastProgressLogAt = Date.distantPast
    private var didLaunchChecks = false

    var isAuthenticated: Bool { engine?.isAuthenticated() ?? false }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var defaultRoot: URL {
        let url = documents.appendingPathComponent("Downloaded Mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var downloadsRoot: URL {
        try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        return defaultRoot
    }
    var downloadsFolderURL: URL { downloadsRoot }

    /// The folder as the Files app shows it, past the top level: the app's own folder for a normal
    /// install, or LiveContainer's chain when the app is running inside it.
    nonisolated static func readablePath(_ url: URL) -> String {
        let path = url.path
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ModShelf"
        // Everything from the first Documents folder down is how Files shows it. Inside LiveContainer
        // that folder belongs to LiveContainer itself, so its name goes in front, not ModShelf's.
        if let docs = path.range(of: "/Documents") {
            let tail = String(path[docs.upperBound...])
            let inLiveContainer = Bundle.main.bundlePath.range(of: "/Documents/Applications/") != nil
                || path.range(of: "/Documents/Applications/") != nil
            return (inLiveContainer ? "LiveContainer" : name) + tail
        }
        if let range = path.range(of: "LiveContainer/", options: [.caseInsensitive]) {
            return String(path[range.lowerBound...])
        }
        var stripped = path
        for prefix in ["/private/var/mobile/Containers/", "/var/mobile/Containers/",
                       "/private/var/mobile/", "/var/mobile/"] where stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
        return stripped
    }

    /// "ModShelf/Downloaded Mods", as Files shows it.
    var downloadsFolderLabel: String { Self.readablePath(downloadsFolderURL) }
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
    init() {
        runtimeLog = Self.loadRuntimeLog()
        library = Self.loadLibrary()
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
        status = engine?.status() ?? "Ready"
        log("launch \(modShelfVersion) (\(modShelfBuild)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        log("library \(library.count) mods · \(history.count) history · engine \(status)")
        _ = NetworkWatcher.shared
        _ = sessionPath
        repairFolders()
        migrateRecords()
        refreshLibraryBytes()
        resolveGameNames()
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
    private func saveLibrary() {
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? data.write(to: Self.libraryFileURL, options: .atomic)
    }
    /// The library lives in its own JSON file: a big collection has no place in the small
    /// UserDefaults budget. Older builds kept it under the "library" key, so that is carried over.
    private static var libraryFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModShelf", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }
    private static func loadLibrary() -> [WorkshopItem] {
        if let data = try? Data(contentsOf: libraryFileURL),
           let items = try? JSONDecoder().decode([WorkshopItem].self, from: data) { return items }
        let legacy = load([WorkshopItem].self, key: "library") ?? []
        if !legacy.isEmpty, let data = try? JSONEncoder().encode(legacy) {
            try? data.write(to: libraryFileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: "library")
        }
        return legacy
    }
    private func saveHistory() { save(history, key: "modshelf.history") }
    private func record(_ id: String, title: String, result: String, error: String? = nil, imageURL: String? = nil, game: String? = nil) {
        let attempt = history.filter { $0.workshopID == id }.count + 1
        history.insert(DownloadRecord(workshopID: id, title: title, date: Date(), result: result, error: error, imageURL: imageURL, attempt: attempt, gameName: game), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        saveHistory()
    }

    // MARK: download folders

    /// Where the files for a game belong: a folder named after it inside ModShelf's download folder.
    func root(forGame appID: String?) -> URL {
        guard let appID else { return downloadsRoot }
        let folder = gameFolderURL(appID: appID, name: knownGameName(appID))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The game's name as ModShelf already knows it, from the library or the last lookup.
    func knownGameName(_ appID: String) -> String? {
        if let name = library.first(where: { $0.appID == appID })?.gameName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let cache = UserDefaults.standard.dictionary(forKey: "modshelf.gameNames") as? [String: String]
        return cache?[appID]
    }

    /// A game's folder, named after the game once that is known. Two games whose names come out the
    /// same never share a folder: the second one gets the app ID after its name instead.
    private func gameFolderURL(appID: String, name: String?) -> URL {
        let base = Self.sanitizedName(name ?? "", fallback: "App \(appID)")
        let plain = downloadsRoot.appendingPathComponent(base, isDirectory: true)
        let claimedByAnotherGame = library.contains { other in
            guard other.appID != appID else { return false }
            return other.folder == plain.path || other.folder.hasPrefix(plain.path + "/")
        }
        guard claimedByAnotherGame else { return plain }
        return downloadsRoot.appendingPathComponent("\(base) (\(appID))", isDirectory: true)
    }

    /// The app ID an "App <id>" folder stands for, or nil for any other folder name.
    nonisolated static func appID(fromLegacyFolder name: String) -> String? {
        guard name.hasPrefix("App ") else { return nil }
        let id = name.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return !id.isEmpty && id.allSatisfy { $0.isNumber } ? id : nil
    }

    /// Fills in missing game names from Steam, then renames the "App <id>" folders that stand for
    /// them. Folders left behind without a library entry are named too, so no game stays "App <id>".
    func resolveGameNames() {
        var apps = Set(library.compactMap { $0.appID })
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: downloadsRoot.path)) ?? [] {
            if let id = Self.appID(fromLegacyFolder: folder) { apps.insert(id) }
        }
        guard !apps.isEmpty else { return }
        Task { @MainActor in
            for app in apps.sorted() {
                var name = self.knownGameName(app)
                if name?.isEmpty != false {
                    guard let fetched = await SteamMeta.gameName(appID: app) else { continue }
                    name = fetched
                    for i in self.library.indices where self.library[i].appID == app {
                        self.library[i].gameName = fetched
                    }
                    self.saveLibrary()
                }
                if let name { self.renameGameFolder(appID: app, to: name) }
            }
        }
    }

    /// Gives a game's folder its real name, merging into a folder of that name when one is already
    /// there so mods left behind by an older build end up together.
    private func renameGameFolder(appID: String, to name: String) {
        let fm = FileManager.default
        let old = downloadsRoot.appendingPathComponent("App \(appID)", isDirectory: true)
        let new = gameFolderURL(appID: appID, name: name)
        guard old.path != new.path, fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            guard (try? fm.moveItem(at: old, to: new)) != nil else { return }
        } else {
            for child in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
                let target = new.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try? fm.moveItem(at: child, to: target)
            }
            if (try? fm.contentsOfDirectory(atPath: old.path).isEmpty) == true { try? fm.removeItem(at: old) }
        }
        var changed = false
        for i in library.indices {
            let path = library[i].folder
            guard path == old.path || path.hasPrefix(old.path + "/") else { continue }
            let updated = new.path + String(path.dropFirst(old.path.count))
            guard fm.fileExists(atPath: updated) else { continue }
            library[i].folder = updated
            changed = true
        }
        if changed { saveLibrary(); refreshLibraryBytes() }
    }

    nonisolated static func sanitizedName(_ name: String, fallback: String = "") -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80))
        return limited.isEmpty ? fallback : limited
    }

    func revealInFiles(_ item: WorkshopItem) {
        let path = item.folder
        log("reveal in Files: \(item.id)")
        guard FileManager.default.fileExists(atPath: path) else {
            // Files that were moved into a game aren't here to open, and ModShelf can't know where
            // the game keeps them, so it says what happened instead of opening nothing.
            operationMessage = item.filesMoved || !item.isInsideModShelf
                ? "\(item.displayTitle)'s files were moved out of ModShelf, so there's no folder to open here."
                : "That mod's folder is missing. Download the mod again."
            return
        }
        if path.hasPrefix(documents.path + "/") {
            // Inside ModShelf's own storage: Files can open it directly.
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = URL(string: "shareddocuments://" + encoded) else { return }
            UIApplication.shared.open(url)
        } else {
            revealFolderURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Opens any folder in Files: ModShelf's own folders directly, another app's folder in an
    /// in-app listing (iOS has no way to hand the Files app a folder inside someone else's container).
    func revealFolder(_ url: URL) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            operationMessage = "That folder doesn't exist any more."
            return
        }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let shared = URL(string: "shareddocuments://" + encoded) else {
            revealFolderURL = url
            return
        }
        UIApplication.shared.open(shared, options: [:]) { opened in
            // Files only understands folders it manages; anything else gets the list instead.
            if !opened { Task { @MainActor in self.revealFolderURL = url } }
        }
    }

    /// A mod keeps the folder it already lives in, so an update replaces it in place. A mod whose
    /// files were moved into a game is installed fresh in ModShelf's own storage instead.
    private func installRoot(for item: WorkshopItem?, appID: String?) -> URL {
        if let item, FileManager.default.fileExists(atPath: item.folder) {
            let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
            guard Self.isInsideAppStorage(folder) else { return root(forGame: appID) }
            let parent = folder.deletingLastPathComponent()
            if (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return parent }
        }
        return root(forGame: appID)
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

    /// Keeps the last dozen mods that were looked at, so the Workshop launcher can offer them again.
    nonisolated static func rememberViewedMod(_ meta: WorkshopMetadata) {
        guard let id = Int(meta.id) else { return }
        let key = "browser.recentMods"
        let defaults = UserDefaults.standard
        var list = GameListStore.decode(defaults.string(forKey: key) ?? "[]")
        list.removeAll { $0.id == id }
        list.insert(GameHit(id: id, name: meta.title, tiny_image: meta.imageURL.isEmpty ? nil : meta.imageURL), at: 0)
        defaults.set(GameListStore.encode(Array(list.prefix(12))), forKey: key)
    }

    func fetchPreview() {
        guard !isFetching else { return }
        guard let id = Self.workshopID(from: input) else {
            preview = nil
            errorMessage = "Enter a Workshop link or item ID."
            log("lookup rejected: \"\(input)\"")
            return
        }
        isFetching = true
        preview = nil
        errorMessage = ""
        Task {
            let result = await SteamMeta.fetch(id: id, includePage: true)
            if let result {
                preview = result
                Self.rememberViewedMod(result)
                log("lookup \(id): \"\(result.title)\" · \(result.gameName ?? "-") · \(Fmt.bytes(result.fileSize))")
            } else {
                errorMessage = "We couldn't load that item just now. It may be private or gone."
                log("lookup failed \(id)")
                preview = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "Metadata was unavailable. Downloading may still work if this item is accessible to your Steam account.", imageURL: "", updatedAt: 0)
            }
            isFetching = false
        }
    }

    // MARK: sign in

    func signIn(automatic: Bool = false) async {
        loginError = ""
        log("sign-in start (\(automatic ? "automatic" : "manual"))")
        if isBusy && needsGuardCode {
            let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { loginError = "Enter the Steam Guard code."; return }
            Haptics.tap()
            engine?.submitGuardCode(code)
            guardCode = ""
            status = "Checking code…"
            return
        }
        guard !isBusy else { loginError = "Finish or cancel the download first."; return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            if !automatic { showLogin = true; loginError = "Enter your username and password." }
            return
        }
        guard let activeEngine = engine else {
            loginError = "The Steam engine didn't start. Reinstall ModShelf."
            status = "Ready"
            if !automatic { showLogin = true }
            return
        }
        isBusy = true; status = "Signing in to Steam…"; needsGuardCode = false
        startPolling()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        let code = guardCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = sessionPath
        let result = await Task.detached(priority: .userInitiated) {
            activeEngine.login(user, password: pass, guardCode: code, cachePath: path)
        }.value
        isBusy = false
        stopPolling()
        status = engine?.status() ?? "Ready"
        if engine?.isAuthenticated() == true {
            Keychain.write(user, key: "steam.username")
            Keychain.write(pass, key: "steam.password")
            guardCode = ""; showLogin = false; status = "Signed in to Steam"
            loginError = ""
            log("signed in as \(user)")
            Haptics.success()
        } else {
            let raw = result.isEmpty ? (engine?.lastError() ?? "") : result
            log("sign-in failed: \(raw.isEmpty ? "no reason given" : raw)")
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
        guard !isBusy else { errorMessage = "Let the current download finish first."; return }
        log("signed out")
        engine?.logout(); Keychain.delete("steam.password"); password = ""; guardCode = ""
        status = "Signed out"
    }

    // MARK: download

    func download(_ raw: String? = nil, meta override: WorkshopMetadata? = nil) {
        errorMessage = ""
        guard devTask == nil else { errorMessage = "A simulated run is on screen. Let it finish first."; return }
        guard isAuthenticated else { operationMessage = "Sign in to Steam and this download can start."; showLogin = true; return }
        guard engine != nil else {
            errorMessage = "The Steam engine didn't start. Reopening the app usually sorts it."
            return
        }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a Workshop link or item ID."; return }
        if UserDefaults.standard.bool(forKey: "options.wifiOnly") && NetworkWatcher.shared.isExpensive {
            errorMessage = "Wi-Fi only is on, so this will wait until you're on Wi-Fi."
            queue.removeAll()
            return
        }
        let fallback = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "", description: "", imageURL: "", updatedAt: 0)
        let meta: WorkshopMetadata = override ?? ((preview?.id == id ? preview : nil) ?? fallback)
        // One transfer at a time, so anything else joins the queue and starts when its turn comes.
        // A paused transfer still owns the engine's slot, so new mods wait rather than taking over.
        if isBusy || isPaused {
            enqueue(id, meta: meta)
            return
        }
        beginDownload(id: id, meta: meta, keepQueue: false)
    }

    /// Adds a mod to the back of the queue, drawn as a waiting row straight away.
    private func enqueue(_ id: String, meta: WorkshopMetadata) {
        guard !queue.contains(id), activeID != id, !queueRows.contains(where: { $0.id == id }) else {
            operationMessage = "That one is already on its way."
            return
        }
        queue.append(id)
        pendingMeta[id] = meta
        queueRows.append(DownloadQueueRow(id: id, title: meta.title,
                                         imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL,
                                         gameName: meta.gameName, fileSize: meta.fileSize))
        queueTotal = queueRows.count
        operationMessage = "\(meta.title) joins the queue."
        log("queued \(id) \"\(meta.title)\" at \(queueRows.count) in line")
        Haptics.tap()
    }

    private func beginDownload(id: String, meta: WorkshopMetadata, keepQueue: Bool) {
        activeID = id
        activeMeta = meta
        activeTitle = meta.title
        downloadActiveSeconds = 0
        lastTickAt = nil
        lastEngineSeen = -1
        lastStatusSeen = ""
        lastMovementAt = nil
        isDownloadStalled = false
        isInstalling = false
        isPaused = false
        resumePending = false
        // A new transfer takes the ring back over from a finished one.
        ringHideTask?.cancel()
        ringVisible = true
        ringDone = false
        ringProgress = 0
        downloadExpectedBytes = meta.fileSize > 0
            ? meta.fileSize
            : (library.first(where: { $0.id == id })?.byteCount ?? 0)
        downloadBytesPerSecond = 0
        lastDiskSample = nil
        receivedBytes = 0
        lastReceivedSeen = -1
        stagingBaselineBytes = 0
        lastProgressLogAt = .distantPast
        stagingProbeInFlight = false
        lastStagingProbe = .distantPast
        lastLoggedDecade = -1
        if autoRetryItem != id { autoRetryItem = id; autoRetries = 0 }
        // Fail before touching the disk when the item obviously cannot fit.
        if downloadExpectedBytes > 0,
           let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0,
           Int64(free) < downloadExpectedBytes {
            errorMessage = "Not enough space: this needs \(Fmt.bytes(downloadExpectedBytes)) and \(Fmt.bytes(Int64(free))) is free."
            log("not enough space: need \(Fmt.bytes(downloadExpectedBytes)), free \(Fmt.bytes(Int64(free)))")
            record(id, title: meta.title, result: "Failed", error: errorMessage, game: meta.gameName)
            Haptics.error()
            return
        }
        log("start \(id) \"\(meta.title)\" expected \(Fmt.bytes(downloadExpectedBytes)), game \(meta.gameName ?? "-")")
        // However a download starts (library update, history retry, auto download), the download
        // screen shows that item rather than whatever was looked up last.
        if preview?.id != id {
            input = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)"
            preview = meta
            if meta.title == "Workshop item \(id)" { fetchPreview() }
        }
        // A fixed staging folder per mod, so a download that stops can be retried and pick up the
        // chunks it already wrote instead of starting the whole thing again.
        let targetRoot = installRoot(for: library.first(where: { $0.id == id }), appID: meta.appID)
        let staging = targetRoot.appendingPathComponent(".partial-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            errorMessage = "We couldn't make a place for that download."
            log("staging failed for \(id): \(error)")
            record(id, title: meta.title, result: "Failed", error: errorMessage, game: meta.gameName)
            return
        }
        guard let engine else { return }
        let result = engine.downloadWorkshopItem(id, targetDir: staging.path)
        if !result.isEmpty {
            // Whatever is already in the staging folder is kept: the engine may have written chunks
            // before refusing, and a retry can carry on from them.
            let message = ErrorText.friendly(result)
            errorMessage = message; status = "Download failed"
            log("engine refused \(id): \(result)")
            record(id, title: meta.title, result: "Failed", error: message, imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL, game: meta.gameName)
            Haptics.error()
            return
        }
        if !keepQueue {
            queueRows.removeAll()
            queueTotal = 0
            queueStep = 0
            queueFailed = 0
        }
        if let index = queueRows.firstIndex(where: { $0.id == id }) {
            queueRows[index].state = .downloading
            queueRows[index].progress = 0
            queueRows[index].fileSize = meta.fileSize
            queueStep = index + 1
        } else {
            queueRows.append(DownloadQueueRow(id: id, title: meta.title,
                                              imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL,
                                              gameName: meta.gameName,
                                              fileSize: meta.fileSize,
                                              state: .downloading))
            queueStep = queueRows.count
        }
        queueTotal = max(1, queueRows.count)
        activeStaging = staging
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

    /// The Workshop details already known about a library mod, used to start a queued update.
    private func metaFor(_ id: String) -> WorkshopMetadata? {
        guard let item = library.first(where: { $0.id == id }) else { return nil }
        var meta = WorkshopMetadata(id: item.id, title: item.displayTitle, author: item.author ?? "",
                                    description: item.description ?? "", imageURL: item.imageURL ?? "",
                                    updatedAt: item.publishedUpdatedAt ?? 0)
        meta.appID = item.appID; meta.gameName = item.gameName; meta.tags = item.tags
        meta.rating = item.rating; meta.ratingCount = item.ratingCount
        meta.fileSize = item.byteCount ?? 0
        return meta
    }

    func update(_ item: WorkshopItem) {
        // An app update can leave the files somewhere else, so find them again before installing in place.
        repairFolders()
        let latest = library.first(where: { $0.id == item.id }) ?? item
        // The download screen shows the mod being updated, not whatever was looked up last.
        showOnDownloadPage(latest)
        var meta = WorkshopMetadata(id: latest.id, title: latest.displayTitle, author: "", description: latest.description ?? "",
                                    imageURL: latest.imageURL ?? "", updatedAt: latest.publishedUpdatedAt ?? 0)
        meta.appID = latest.appID; meta.gameName = latest.gameName; meta.tags = latest.tags
        meta.rating = latest.rating; meta.ratingCount = latest.ratingCount
        download(latest.id, meta: meta)
    }

    /// Puts a library mod on the download screen: its Workshop link in the field and its known details
    /// on the card, so an update opens the Workshop page it is updating.
    func showOnDownloadPage(_ item: WorkshopItem) {
        input = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)"
        var meta = WorkshopMetadata(id: item.id, title: item.displayTitle, author: item.author ?? "",
                                    description: item.description ?? "", imageURL: item.imageURL ?? "",
                                    updatedAt: item.publishedUpdatedAt ?? 0)
        meta.appID = item.appID; meta.gameName = item.gameName; meta.tags = item.tags
        meta.rating = item.rating; meta.ratingCount = item.ratingCount
        preview = meta
    }
    func updateAll() {
        guard devTask == nil else { operationMessage = "A simulated run is on screen. Let it finish first."; return }
        let picks = library.filter { $0.updateAvailable }
        guard !picks.isEmpty else { operationMessage = "Everything is up to date."; log("update all: nothing to do"); return }
        // If something is already running, these updates join its queue rather than replacing it.
        if isBusy || !queue.isEmpty {
            var added = 0
            for item in picks where !queue.contains(item.id) && activeID != item.id {
                if let meta = metaFor(item.id) {
                    enqueue(item.id, meta: meta)
                    added += 1
                }
            }
            operationMessage = added == 0
                ? "Those updates are already queued."
                : "\(added) mod\(added == 1 ? "" : "s") of updates added to the queue."
            return
        }
        queue = picks.map(\.id)
        queueRows = picks.map { DownloadQueueRow(id: $0.id, title: $0.displayTitle,
                                                 imageURL: $0.imageURL, gameName: $0.gameName,
                                                 fileSize: $0.byteCount ?? 0) }
        queueStep = 0
        queueTotal = queue.count
        queueFailed = 0
        startNextInQueue()
    }
    private func startNextInQueue() {
        guard !isBusy else { return }
        while let id = queue.first {
            queue.removeFirst()
            guard let meta = pendingMeta.removeValue(forKey: id) ?? metaFor(id) else { continue }
            updateRow(id, progress: 0, state: .downloading)
            beginDownload(id: id, meta: meta, keepQueue: true)
            if isBusy {
                log("started queued \(id) as item \(queueStep) of \(max(queueTotal, queueRows.count))")
                return
            }
            // Nothing could start (signed out, no space, Wi-Fi only), so the rest cannot run either.
            queue.removeAll()
            finishQueue()
            return
        }
        finishQueue()
    }

    private func updateRow(_ id: String, progress: Double? = nil, state: DownloadQueueRow.State? = nil) {
        guard let index = queueRows.firstIndex(where: { $0.id == id }) else { return }
        if let progress { queueRows[index].progress = max(0, min(1, progress)) }
        if let state { queueRows[index].state = state }
    }

    /// The end of a batch: the queue card goes away and the banner carries a short summary, so a run
    /// of several updates does not just go quiet when it is done.
    private func finishQueue(cancelled: Bool = false) {
        let total = queueTotal
        let done = max(0, queueStep - (cancelled ? 1 : 0))
        let failed = queueFailed
        queueStep = 0; queueTotal = 0; queueFailed = 0
        // The finished rows stay for a moment so the last 100% is actually seen.
        let endedRows = queueRows
        if !endedRows.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if queueRows == endedRows { queueRows.removeAll() }
            }
        }
        guard total > 0 else { return }
        if total == 1 {
            operationMessage = cancelled ? "Download cancelled." : (failed > 0 ? "That one didn't finish." : "Downloaded.")
            log("queue end: \(operationMessage)")
            return
        }
        if cancelled {
            operationMessage = "Stopped after \(min(done, total)) of \(total)."
        } else if done == 0 {
            operationMessage = "Nothing could be downloaded just now."
        } else if failed == 0 {
            operationMessage = done >= total ? "Downloaded all \(total) mods." : "Downloaded \(done) of \(total) mods."
        } else {
            operationMessage = "Downloaded \(max(0, done - min(failed, done))) of \(total) mods; \(failed) didn't finish."
        }
        log("queue end: \(operationMessage)")
    }

    /// Where the bar sits. The folder the mod is written into is measured as it grows, so when the
    /// file system hands out space with the data the bar only moves once bytes have really landed
    /// and holds still while a transfer stalls. Some file systems give a file its whole length up
    /// front, and then the folder size says nothing mid-download; only in that case does an estimate
    /// from the clock keep the bar moving instead.
    private func displayProgress(engineValue: Double, diskFraction: Double, diskIsReal: Bool) -> Double {
        guard isDownloading else { return min(1, max(0, engineValue)) }
        let known = max(engineValue, diskFraction)
        guard !diskIsReal else { return min(0.99, known) }
        return Self.pacedProgress(elapsed: downloadActiveSeconds, expectedBytes: downloadExpectedBytes,
                                  bytesPerSecond: downloadBytesPerSecond, engineValue: known)
    }

    /// The estimate used only when the folder cannot be trusted, kept separate so the curve is easy
    /// to reason about. It slows down near the end and never shows 100% before the download is done.
    nonisolated static func pacedProgress(elapsed: TimeInterval, expectedBytes: Int64,
                                          bytesPerSecond: Double, engineValue: Double) -> Double {
        var value = max(0, engineValue)
        let duration: Double
        if expectedBytes > 0 {
            let speed = bytesPerSecond > 0 ? bytesPerSecond : 3_500_000
            duration = max(1.5, Double(expectedBytes) / speed)
        } else {
            duration = 25
        }
        if elapsed <= duration {
            value = max(value, elapsed / duration * 0.9)
        } else {
            let past = (elapsed - duration) / duration
            value = max(value, 0.9 + 0.08 * (1 - exp(-past)))
        }
        // Smooth, so the bar creeps forward even between whole percent marks; the label rounds.
        return min(0.99, min(1, max(0, value)))
    }

    /// Small mods finish in a second or two, so their folder is re-measured often; a big item has
    /// thousands of files, so it is measured less often to keep the cost down.
    private var stagingProbeInterval: TimeInterval {
        if downloadExpectedBytes <= 0 { return 1 }
        if downloadExpectedBytes < 100_000_000 { return 0.4 }
        if downloadExpectedBytes < 500_000_000 { return 1 }
        return 2
    }

    /// Whether Steam is still resolving, fetching manifests or checking files already on disk: a
    /// stage that can sit quietly for a while without meaning the download has hung.
    var isPreparingDownload: Bool {
        let s = status.lowercased()
        return s.contains("preparing") || s.contains("manifest") || s.contains("checking")
    }

    func refreshState() {
        let nextStatus = engine?.status() ?? ""
        // Each new step Steam reports becomes its own segment of the progress bar.
        if isDownloading, !nextStatus.isEmpty, phases.last != nextStatus { phases.append(nextStatus) }
        let engineValue = min(1, max(0, engine?.progress() ?? 0))
        // Steam knows the uncompressed size it will write, which can differ from the compressed
        // figure the Workshop page shows; prefer the larger of the two as the denominator.
        if let engineBytes = engine?.downloadBytes(), engineBytes > 0,
           Int64(engineBytes) > downloadExpectedBytes {
            downloadExpectedBytes = Int64(engineBytes)
        }
        let now = Date()
        let statusChanged = nextStatus != lastStatusSeen
        let valueChanged = engineValue != lastEngineSeen
        lastStatusSeen = nextStatus
        lastEngineSeen = engineValue
        if statusChanged || valueChanged { lastMovementAt = now }
        let dt = lastTickAt.map { max(0, min(1.5, now.timeIntervalSince($0))) } ?? 0
        lastTickAt = now
        // The folder on disk is the only honest sign of life for large items, where Steam's own
        // counter can sit at zero for the whole download. Files are pre-allocated to their full
        // length before any data arrives, so the allocated size (not the logical size) is what grows.
        if isDownloading, !isPreparingDownload, let staging = activeStaging, !stagingProbeInFlight,
           now.timeIntervalSince(lastStagingProbe) > stagingProbeInterval {
            stagingProbeInFlight = true
            lastStagingProbe = now
            Task { @MainActor in
                let size = await Task.detached(priority: .utility) { Self.directoryBytes(staging) }.value
                stagingProbeInFlight = false
                // A measurement that arrives after the download ended belongs to nothing.
                guard isDownloading, activeStaging == staging else { return }
                if lastReceivedSeen < 0 {
                    lastReceivedSeen = size
                    receivedBytes = size
                    // Space handed out up front shows the folder already at its full size, and that
                    // reading is a baseline rather than progress. Anything under the full size is
                    // bytes that really are here (a retry picking up where it stopped), so those
                    // count towards the bar straight away.
                    let preAllocated = downloadExpectedBytes > 0
                        && size >= downloadExpectedBytes - downloadExpectedBytes / 50
                    stagingBaselineBytes = preAllocated ? size : 0
                    log(preAllocated
                        ? "disk baseline \(Fmt.bytes(size)) of \(Fmt.bytes(downloadExpectedBytes)) expected"
                        : "disk start \(Fmt.bytes(size)) of \(Fmt.bytes(downloadExpectedBytes)) counts as progress")
                } else {
                    if size > lastReceivedSeen {
                        lastReceivedSeen = size
                        lastMovementAt = Date()
                    }
                    receivedBytes = size
                    // Steam's counter arrives in one burst near the end, so the speed is taken from
                    // the folder instead: what landed, over the time it took to land.
                    if let sample = lastDiskSample {
                        let elapsed = now.timeIntervalSince(sample.0)
                        if elapsed > 0.2, size > sample.1 {
                            let measured = Double(size - sample.1) / elapsed
                            downloadBytesPerSecond = downloadBytesPerSecond > 0
                                ? downloadBytesPerSecond * 0.7 + measured * 0.3
                                : measured
                        }
                    }
                }
                lastDiskSample = (now, size)
            }
        }
        // A folder that was handed its whole size up front got a baseline, and then its size says
        // nothing about progress; otherwise what it holds is exactly what has landed.
        let diskIsReal = lastReceivedSeen >= 0 && stagingBaselineBytes == 0
        if isDownloading, !isPreparingDownload, !diskIsReal { downloadActiveSeconds += dt }
        let preparing = isPreparingDownload
        let stalled = isDownloading && !preparing && (lastMovementAt.map { now.timeIntervalSince($0) > 8 } ?? false)
        if isDownloadStalled != stalled {
            isDownloadStalled = stalled
            log(stalled ? "download looks stalled at \(Int(progress * 100))%" : "download moving again")
        }
        let grownBytes = max(0, receivedBytes - stagingBaselineBytes)
        let diskFraction = diskIsReal && downloadExpectedBytes > 0
            ? min(0.99, Double(grownBytes) / Double(downloadExpectedBytes))
            : 0
        var nextProgress = displayProgress(engineValue: engineValue, diskFraction: diskFraction, diskIsReal: diskIsReal)
        // The denominator can grow when Steam reports a larger uncompressed total, so the figure on
        // screen only ever moves forward within one download.
        if isDownloading, nextProgress < progress { nextProgress = progress }
        // A figure that came out of a division must never reach Int(), which traps on NaN.
        if !nextProgress.isFinite { nextProgress = progress.isFinite ? progress : 0 }
        let nextFile = engine?.currentFile() ?? ""
        let waitingForCode = nextStatus == "Steam Guard code required"
        if waitingForCode != needsGuardCode { needsGuardCode = waitingForCode }
        if waitingForCode && !showLogin { showLogin = true }
        if status != nextStatus {
            status = nextStatus
            log("phase: \(nextStatus)")
        }
        if abs(progress - nextProgress) > 0.001 {
            progress = nextProgress
            let decade = Int(nextProgress * 10)
            if isDownloading, decade != lastLoggedDecade {
                lastLoggedDecade = decade
                log("progress \(Int(nextProgress * 100))% · engine \(String(format: "%.0f", engineValue * 100))% · disk \(Fmt.bytes(grownBytes)) of \(Fmt.bytes(downloadExpectedBytes))")
            }
        }
        // A steady line every few seconds, so a run that never changes percent still shows what the
        // engine and the disk are doing.
        if isDownloading, now.timeIntervalSince(lastProgressLogAt) > 5 {
            lastProgressLogAt = now
            log("tick \(Int(nextProgress * 100))% · engine \(String(format: "%.0f", engineValue * 100))% · disk \(Fmt.bytes(grownBytes)) of \(Fmt.bytes(downloadExpectedBytes)) · \(nextStatus)")
        }
        if currentFile != nextFile { currentFile = nextFile }
        if isDownloading, let index = queueRows.firstIndex(where: { $0.id == activeID }),
           queueRows[index].state == .downloading {
            queueRows[index].progress = nextProgress
        }
        if ringVisible, !ringDone { ringProgress = ringBatchProgress }
        guard isBusy else { stopPolling(); return }

        let s = nextStatus.lowercased()
        guard ["download complete", "download failed", "download cancelled"].contains(where: { s.contains($0) }) else { return }
        isBusy = false
        isDownloading = false
        isDownloadStalled = false
        activeStaging = nil
        stopPolling()
        let stagingPath = UserDefaults.standard.string(forKey: "modshelf.activeStaging") ?? ""
        UserDefaults.standard.removeObject(forKey: "modshelf.activeStaging")
        let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let error = engine?.lastError() ?? ""
        let successStatus = s.contains("download complete")
        let cancelled = s.contains("download cancelled")
        // A row moved onto the running one: let the engine go, keep the running mod in the queue,
        // then start the moved one.
        if cancelled, keepActiveOnCancel {
            keepActiveOnCancel = false
            isPaused = false
            resumePending = false
            if let index = queueRows.firstIndex(where: { $0.id == activeID }) {
                queueRows[index].state = .waiting
            }
            status = "Paused"
            history.removeAll { $0.workshopID == activeID && $0.result == "Downloading" }
            saveHistory()
            // The stopped mod keeps its place in the queue, and the one dropped on top of it goes
            // first, so the order the rows show is the order they will run in.
            syncQueueOrder()
            log("stopped \(activeID), kept in the queue")
            let next = startAfterCancel
            startAfterCancel = nil
            if let next, let meta = pendingMeta.removeValue(forKey: next) ?? metaFor(next) {
                queue.removeAll { $0 == next }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self.beginDownload(id: next, meta: meta, keepQueue: true)
                }
            } else if !queue.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self.startNextInQueue()
                }
            }
            return
        }
        // A paused transfer stops the engine but keeps its staging folder, so resuming carries on
        // from the chunks already written instead of starting again.
        if cancelled, isPaused {
            if let index = queueRows.firstIndex(where: { $0.id == activeID }) {
                queueRows[index].state = .waiting
            }
            status = "Paused"
            log("paused \(activeID)")
            // Pausing is not an attempt: take the placeholder entry back out of history.
            history.removeAll { $0.workshopID == activeID && $0.result == "Downloading" }
            saveHistory()
            if resumePending {
                resumePending = false
                resumeActive()
            }
            return
        }
        // A move that asked the engine to stop is over: if Steam reported something other than a
        // cancellation, the flags must not change how the next download ends.
        keepActiveOnCancel = false
        startAfterCancel = nil
        let meta = activeMeta ?? WorkshopMetadata(id: activeID, title: activeTitle, author: "", description: "", imageURL: "", updatedAt: 0)
        var success = false
        var failureText = ""
        if successStatus, !stagingPath.isEmpty {
            isInstalling = true
            do {
                let existing = library.first(where: { $0.id == activeID })
                let previousVersion = existing?.publishedUpdatedAt ?? 0
                let done = try finalizeDownload(staging: staging, id: activeID, meta: meta, existing: existing)
                var item = existing ?? WorkshopItem(id: activeID, folder: done.url.path, addedAt: Date(), updatedAt: Date())
                item.folder = done.url.path
                // The "Updated" date only moves when the Workshop version really changed, so
                // re-installing the same version is not reported as an update.
                let sameVersion = previousVersion > 0 && meta.updatedAt == previousVersion
                item.updatedAt = sameVersion ? (existing?.updatedAt ?? Date()) : Date()
                item.title = meta.title
                item.description = meta.description.isEmpty ? item.description : meta.description
                item.imageURL = meta.imageURL.isEmpty ? item.imageURL : meta.imageURL
                if meta.updatedAt > 0 { item.publishedUpdatedAt = meta.updatedAt }
                item.lastCheckedAt = Date()
                item.updateAvailable = false
                item.checkFailed = false
                item.filesBroken = false
                item.filesMoved = false
                item.appID = meta.appID ?? item.appID
                item.gameName = meta.gameName ?? item.gameName
                if !meta.tags.isEmpty { item.tags = meta.tags }
                if meta.rating != nil { item.rating = meta.rating; item.ratingCount = meta.ratingCount }
                item.fileCount = done.files
                item.byteCount = done.bytes
                item.lastVerifiedAt = Date()
                item.lastVerifiedFiles = done.files
                item.lastVerifiedBytes = done.bytes
                if let old = library.firstIndex(where: { $0.id == activeID }) { library[old] = item } else { library.insert(item, at: 0) }
                saveLibrary()
                log("finalised \(activeID): \(done.files) files, \(Fmt.bytes(done.bytes))")
                success = true
            } catch {
                // The reason a finished download could not be put in place is the only way to see
                // whether it is a bad file name, a refused move or an empty folder.
                let failure = error as NSError
                let staged = visibleChildren(staging).count
                log("install failed \(activeID): \(failure.domain) \(failure.code) - \(failure.localizedDescription) · \(staged) items, \(Fmt.bytes(Self.directoryBytes(staging)))")
                failureText = failure.code == 1 ? "The download came back empty." : "Couldn't finish the download."
                errorMessage = failureText
                // What was downloaded is kept for a retry; only an empty folder has nothing to keep.
                if staged == 0 {
                    try? FileManager.default.removeItem(at: staging)
                } else {
                    log("kept the downloaded files for \(activeID)")
                }
            }
            isInstalling = false
        } else if cancelled, !stagingPath.isEmpty {
            // A cancelled download throws its half-written files away; a failed one keeps them so a
            // retry can resume from the chunks it already has.
            try? FileManager.default.removeItem(at: staging)
        }
        if success {
            updateHistory(id: activeID, result: "Downloaded", error: nil)
            refreshLibraryBytes()
            resolveGameNames()
            // An update carries the metadata the mod already had, so Workshop is asked once more for
            // the version that really landed, and the info file is rewritten with it.
            refreshInstalledMetadata(id: activeID)
            updateRow(activeID, progress: 1, state: .done)
            // A finished mod drops to the bottom of the card, so the top shows what is running next.
            if let index = queueRows.firstIndex(where: { $0.id == activeID }) {
                let finished = queueRows.remove(at: index)
                queueRows.append(finished)
            }
            progress = 1
            ringFinished()
            lastOutcome = "Download completed"
            Haptics.success()
        } else {
            let reason = cancelled
                ? "The download was cancelled."
                : ErrorText.friendly(!error.isEmpty ? error : (!failureText.isEmpty ? failureText : "The download didn't finish."))
            updateHistory(id: activeID, result: cancelled ? "Cancelled" : "Failed", error: reason)
            if !cancelled { errorMessage = reason }
            lastOutcome = cancelled ? "Download cancelled" : "Download failed"
            if !cancelled { ringStopped() }
            log("failed \(activeID): \(reason)")
            if !error.isEmpty { log("engine said: \(error)") }
            if cancelled {
                if keepQueueOnCancel {
                    keepQueueOnCancel = false
                    // This one is out of the batch; the rest of the queue carries on.
                    queueRows.removeAll { $0.id == activeID }
                    queueTotal = queueRows.count
                    queueStep = min(queueStep, max(queueTotal, 1))
                    log("cancelled \(activeID); the rest of the queue continues")
                } else {
                    queue.removeAll()
                }
            } else {
                queueFailed += 1
                updateRow(activeID, state: .failed)
            }
            // A stalled transfer keeps its half-written files, so one quiet retry can carry on from
            // the chunks that already landed instead of starting the whole download again.
            if !cancelled, queue.isEmpty, autoRetries < 2,
               error.localizedCaseInsensitiveContains("stopped sending"),
               FileManager.default.fileExists(atPath: staging.path) {
                autoRetries += 1
                log("auto-retry \(autoRetries) for \(activeID)")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.download(activeID, meta: meta)
                }
            }
            Haptics.error()
        }
        saveHistory()
        if !queue.isEmpty {
            // A short pause lets the finished row show its last percent, and gives the engine time to
            // release its download slot before the next one asks for it.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.startNextInQueue()
            }
        } else if !success, !cancelled {
            // The run is over but something failed: its row stays on screen to be read and retried.
        } else {
            finishQueue(cancelled: cancelled)
        }
    }

    private func updateHistory(id: String, result: String, error: String?) {
        if let index = history.firstIndex(where: { $0.workshopID == id && $0.result == "Downloading" }) {
            history[index].result = result; history[index].date = Date(); history[index].error = error
            if let m = activeMeta, m.id == id, !m.imageURL.isEmpty { history[index].imageURL = m.imageURL }
        } else { record(id, title: activeTitle, result: result, error: error) }
    }
    /// Stops or carries on with the transfer in progress. Pausing keeps the files that already
    /// landed, so resuming picks up from them rather than downloading everything again.
    func togglePause() {
        if isPaused {
            isPaused = false
            if isBusy {
                // The engine has not reported the cancellation yet; resume once it has.
                resumePending = true
            } else {
                resumeActive()
            }
        } else if isDownloading {
            isPaused = true
            resumePending = false
            pausedAt = Date()
            pausedStaging = activeStaging
            status = "Paused"
            engine?.cancelDownload()
            log("pause requested")
        }
    }

    private func resumeActive() {
        guard !activeID.isEmpty else { return }
        // A long pause can outlive whatever the engine cached; start that download cleanly again.
        if let at = pausedAt, let url = pausedStaging,
           Date().timeIntervalSince(at) > 30 {
            try? FileManager.default.removeItem(at: url)
            log("cleared staging after a long pause")
        }
        pausedAt = nil
        pausedStaging = nil
        let meta = activeMeta ?? WorkshopMetadata(id: activeID, title: activeTitle, author: "",
                                                  description: "", imageURL: "", updatedAt: 0)
        log("resume \(activeID)")
        beginDownload(id: activeID, meta: meta, keepQueue: true)
    }

    /// The ring shows the whole batch when several mods are queued, weighted by each mod's size so a
    /// big mod does not count the same as a tiny one.
    private var ringBatchProgress: Double {
        guard !queueRows.isEmpty else { return 0 }
        let weights = queueRows.map { max(1, Double($0.fileSize)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var done = 0.0
        for (index, row) in queueRows.enumerated() {
            let fraction = row.state == .done ? 1 : min(1, max(0, row.progress))
            done += weights[index] * fraction
        }
        return min(1, done / total)
    }

    /// Marks the ring finished and keeps it on screen for ten seconds before it goes.
    private func ringFinished() {
        guard ringVisible else { return }
        ringProgress = 1
        ringDone = true
        ringHideTask?.cancel()
        ringHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !isDownloading, !isPaused else { return }
            ringVisible = false
            ringDone = false
            ringProgress = 0
        }
    }

    private func ringStopped() {
        ringHideTask?.cancel()
        ringVisible = false
        ringDone = false
        ringProgress = 0
    }

    /// Moves a row within the queue and rebuilds the order the batch will follow.
    func moveRow(_ id: String, to target: Int) {
        guard let from = queueRows.firstIndex(where: { $0.id == id }) else { return }
        let row = queueRows.remove(at: from)
        let clamped = max(0, min(target, queueRows.count))
        queueRows.insert(row, at: clamped)
        syncQueueOrder()
        log("moved \(id) to \(clamped + 1) in the queue")
    }

    /// The queue array only holds mods that have not started, in display order.
    private func syncQueueOrder() {
        queue = queueRows.filter { $0.state == .waiting }.map(\.id)
        queueTotal = queueRows.count
        queueStep = min(queueStep, max(queueTotal, 1))
    }

    /// Drops a moved mod on the place held by the running one, asking the engine to let go first.
    /// The running mod is kept at the top of the queue so nothing is lost.
    func startMovedMod(_ id: String) {
        guard let meta = pendingMeta[id] ?? metaFor(id) else { return }
        moveRow(id, to: 0)
        // A paused transfer is not running in the engine, so there is nothing to stop: the moved mod
        // goes first and starts now. Waiting for a cancellation that never arrives is what left the
        // whole queue sitting still.
        guard isDownloading, isBusy else {
            isPaused = false
            resumePending = false
            pausedAt = nil
            pausedStaging = nil
            startAfterCancel = nil
            keepActiveOnCancel = false
            if !isBusy {
                queue.removeAll { $0 == id }
                pendingMeta.removeValue(forKey: id)
                beginDownload(id: id, meta: meta, keepQueue: true)
            }
            // Still busy putting the last one away: the queue starts it as soon as that is done.
            return
        }
        startAfterCancel = id
        keepActiveOnCancel = true
        isPaused = false
        resumePending = false
        status = "Paused"
        engine?.cancelDownload()
        log("stopping \(activeID) to start \(id)")
    }

    /// Stops the running download but leaves it first in the queue, for when it has been moved.
    func stopActiveKeepingInQueue() {
        guard isDownloading, isBusy else { return }
        keepActiveOnCancel = true
        startAfterCancel = nil
        isPaused = false
        resumePending = false
        status = "Paused"
        engine?.cancelDownload()
        log("stopping \(activeID) to move it in the queue")
    }

    /// Stops one download: a waiting one leaves the queue, and the one running hands over to the rest.
    func cancelItem(_ id: String) {
        if id == activeID, isDownloading || isPaused {
            cancel(keepingQueue: true)
            return
        }
        queue.removeAll { $0 == id }
        pendingMeta[id] = nil
        queueRows.removeAll { $0.id == id }
        queueTotal = queueRows.count
        queueStep = min(queueStep, queueTotal)
        // A mod taken out of the queue must not come back as the one on display.
        if preview?.id == id {
            preview = nil
            input = ""
        }
        log("removed \(id) from the queue")
        if queueRows.isEmpty, !isBusy { finishQueue() }
    }

    /// Stops the batch, or just the transfer that is running when the rest of the queue should stay.
    func cancel(keepingQueue: Bool = false) {
        isPaused = false
        resumePending = false
        pausedAt = nil
        pausedStaging = nil
        // Cancelling calls off any move that was waiting on the engine to let go.
        keepActiveOnCancel = false
        startAfterCancel = nil
        keepQueueOnCancel = keepingQueue
        if !keepingQueue { ringStopped() }
        log("cancel requested (queue \(queue.count), active \(activeID)")
        if let task = devTask {
            task.cancel()
            devTask = nil
            queueRows.removeAll()
            queueStep = 0; queueTotal = 0; queueFailed = 0
            status = "Ready"
            return
        }
        if !keepingQueue { queue.removeAll() }
        engine?.cancelDownload()
        isInstalling = false
        status = "Cancelling download…"
    }

    // MARK: developer tools
    //
    // Reachable only from the hidden menu behind the logo taps. Nothing else in the app uses these.

    var devSnapshot: String {
        """
        version: \(modShelfVersion) (build \(modShelfBuild))
        engine: \(devEngineStatus)
        engineProgress: \(String(format: "%.2f", devEngineProgress))
        engineFile: \(devEngineFile)
        engineError: \(devEngineError)
        signedIn: \(isAuthenticated)
        library: \(library.count)
        updates: \(library.filter { $0.updateAvailable }.count)
        queue: \(queueStep)/\(queueTotal)
        """
    }
    var devEngineStatus: String { engine?.status() ?? "none" }
    var devEngineProgress: Double { engine?.progress() ?? 0 }
    var devEngineFile: String { engine?.currentFile() ?? "" }
    var devEngineError: String { engine?.lastError() ?? "" }

    /// A batch that runs entirely in the app: no Steam, no engine, no files touched.
    func devFakeUpdateAll(count: Int, failEvery: Int, seconds: Double) {
        guard devTask == nil, !isBusy else { operationMessage = "A download is already running."; return }
        guard !library.isEmpty else { operationMessage = "The library is empty."; return }
        let picks = Array(library.shuffled().prefix(max(1, min(count, library.count))))
        devRunFake(ids: picks.map(\.id), failEvery: failEvery, seconds: seconds)
    }

    func devFakeDownload(fail: Bool, seconds: Double) {
        guard devTask == nil, !isBusy else { operationMessage = "A download is already running."; return }
        guard let item = library.first else { operationMessage = "The library is empty."; return }
        devRunFake(ids: [item.id], failEvery: fail ? 1 : 0, seconds: seconds)
    }

    private func devRunFake(ids: [String], failEvery: Int, seconds: Double) {
        queueRows = ids.compactMap { id in
            library.first(where: { $0.id == id }).map {
                DownloadQueueRow(id: id, title: $0.displayTitle, imageURL: $0.imageURL,
                                 fileSize: $0.byteCount ?? 0)
            }
        }
        queueStep = 0
        queueTotal = queueRows.count
        queueFailed = 0
        let stepSeconds = max(0.05, seconds) / 24
        devTask = Task { @MainActor in
            for (index, id) in ids.enumerated() {
                if Task.isCancelled { return }
                queueStep = index + 1
                updateRow(id, progress: 0, state: .downloading)
                for step in 1...24 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
                    updateRow(id, progress: Double(step) / 24)
                }
                let ok = failEvery == 0 || (index + 1) % failEvery != 0
                if ok {
                    // Simulation only: the library itself is left exactly as it was.
                    updateRow(id, progress: 1, state: .done)
                } else {
                    updateRow(id, state: .failed)
                    queueFailed += 1
                }
            }
            devTask = nil
            finishQueue()
        }
    }

    func devMarkUpdates(count: Int) -> String {
        guard !library.isEmpty else { return "The library is empty." }
        let picks = library.shuffled().prefix(max(1, count))
        for item in picks {
            if let i = library.firstIndex(where: { $0.id == item.id }) { library[i].updateAvailable = true }
        }
        saveLibrary()
        return "\(picks.count) mod\(picks.count == 1 ? "" : "s") marked as having updates."
    }

    func devRepairReport() -> String {
        let fm = FileManager.default
        let before = library.filter { !fm.fileExists(atPath: $0.folder) }.count
        let countBefore = library.count
        repairFolders()
        let after = library.filter { !fm.fileExists(atPath: $0.folder) }.count
        let added = library.count - countBefore
        var parts = ["\(library.count) mods", "\(before) without a folder before", "\(after) still without"]
        if before > after { parts.append("\(before - after) found") }
        if added > 0 { parts.append("\(added) re-adopted") }
        return parts.joined(separator: " · ")
    }

    func devRewriteManifests() -> String {
        var written = 0
        for item in library {
            let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            Self.writeManifest(InstalledModManifest(workshopID: item.id,
                                                    title: item.displayTitle,
                                                    appID: item.appID,
                                                    gameName: item.gameName,
                                                    publishedUpdatedAt: item.publishedUpdatedAt,
                                                    installedAt: item.addedAt,
                                                    fileCount: item.fileCount,
                                                    byteCount: item.byteCount,
                                                    modShelfVersion: modShelfVersion),
                               in: folder)
            written += 1
        }
        return "\(written) manifest\(written == 1 ? "" : "s") written."
    }

    func devManifestJSON(for item: WorkshopItem) -> String {
        let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard let manifest = Self.readManifest(in: folder) ?? Self.readInfoFile(in: folder),
              let data = try? JSONEncoder().encode(manifest),
              let text = String(data: data, encoding: .utf8) else { return "No manifest in this folder." }
        return text
    }

    func devStorageReport() -> String {
        let missing = library.filter { !FileManager.default.fileExists(atPath: $0.folder) }.count
        let bytes = library.compactMap { $0.byteCount }.reduce(0, +)
        return """
        version: \(modShelfVersion) (build \(modShelfBuild))
        documents: \(documents.path)
        downloads: \(downloadsRoot.path)
        library: \(library.count) mods, \(missing) without files, \(Fmt.bytes(bytes))
        history: \(history.count) entries
        """
    }

    func devClearSteamCache() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModShelf/SteamSession/steam-session", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return "Nothing to clear."
        }
        var removed = 0
        for file in files where (try? fm.removeItem(at: file)) != nil { removed += 1 }
        return "\(removed) Steam cache file\(removed == 1 ? "" : "s") removed."
    }

    func devResetFlags() -> String {
        var changed = 0
        for i in library.indices {
            guard library[i].filesMoved || library[i].filesBroken || library[i].checkFailed else { continue }
            library[i].filesMoved = false
            library[i].filesBroken = false
            library[i].checkFailed = false
            changed += 1
        }
        if changed > 0 { saveLibrary() }
        return "\(changed) mod\(changed == 1 ? "" : "s") reset."
    }

    /// Clears the update badges a simulated run or a previous check may have left on real mods.
    func devClearUpdateFlags() -> String {
        var cleared = 0
        for i in library.indices where library[i].updateAvailable {
            library[i].updateAvailable = false
            cleared += 1
        }
        if cleared > 0 { saveLibrary() }
        return "\(cleared) update flag\(cleared == 1 ? "" : "s") cleared."
    }

    func devResetSettings() -> String {
        let defaults = UserDefaults.standard
        var removed = 0
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("options.") || key.hasPrefix("browser.") {
            defaults.removeObject(forKey: key)
            removed += 1
        }
        return "\(removed) setting\(removed == 1 ? "" : "s") reset."
    }

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
        Self.sanitizedName(name, fallback: fallback)
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

    /// Moves a finished download into place, falling back to a copy when the move is refused (a
    /// folder can refuse a rename across containers while still accepting the bytes).
    nonisolated static func place(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
            try? fm.removeItem(at: source)
        }
    }

    /// Whether a URL lives in ModShelf's own storage, where plain file operations are enough.
    nonisolated static func isInsideAppStorage(_ url: URL) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        return url.path == documents || url.path.hasPrefix(documents + "/")
    }

    /// The path a saved folder points at now. A reinstalled app gets a fresh data container, so an
    /// absolute path saved by the previous install would read as "the files were moved"; only what
    /// follows Documents is kept, and put in front of the container that is running.
    nonisolated static func currentPath(for saved: String) -> String {
        guard !saved.isEmpty else { return saved }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        if saved == documents || saved.hasPrefix(documents + "/") { return saved }
        if saved.hasPrefix("/") {
            if let range = saved.range(of: "/Documents") { return documents + String(saved[range.upperBound...]) }
            return saved
        }
        return documents + "/" + saved
    }

    /// Finds a folder the library has lost track of: sitting where an installer left it, next to
    /// "Downloaded Mods" instead of inside it, or one level down from where the record points.
    nonisolated static func locateFolder(named name: String, near documents: URL) -> URL? {
        let fm = FileManager.default
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        let roots = [documents, documents.appendingPathComponent("Downloaded Mods", isDirectory: true)]
        for root in roots {
            let direct = root.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let candidate = child.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// The hidden manifest that lives inside every mod's folder.
    nonisolated static func manifestURL(in folder: URL) -> URL {
        folder.appendingPathComponent(modShelfManifestName)
    }

    nonisolated static func writeManifest(_ manifest: InstalledModManifest, in folder: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(in: folder), options: .atomic)
    }

    nonisolated static func readManifest(in folder: URL) -> InstalledModManifest? {
        guard let data = try? Data(contentsOf: manifestURL(in: folder)) else { return nil }
        return try? JSONDecoder().decode(InstalledModManifest.self, from: data)
    }

    /// Reads the visible info file, for downloads made before the hidden manifest existed. It is a
    /// plain "Key: value" list, so a few lines are enough to identify the mod again.
    nonisolated static func readInfoFile(in folder: URL) -> InstalledModManifest? {
        let url = folder.appendingPathComponent(modShelfInfoFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, h:mm a"
        var manifest = InstalledModManifest(workshopID: "")
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Workshop ID": manifest.workshopID = value
            case "Title": manifest.title = value
            case "Game":
                if let open = value.lastIndex(of: "("), value.hasSuffix(")") {
                    let appID = value[value.index(after: open)..<value.index(before: value.endIndex)].filter { $0.isNumber }
                    manifest.gameName = String(value[value.startIndex..<open]).trimmingCharacters(in: .whitespaces)
                    if !appID.isEmpty { manifest.appID = appID }
                } else {
                    manifest.gameName = value
                }
            case "Last updated on Workshop":
                if let date = formatter.date(from: value) { manifest.publishedUpdatedAt = Int(date.timeIntervalSince1970) }
            case "Installed on":
                if let date = formatter.date(from: value) { manifest.installedAt = date }
            default: break
            }
        }
        guard !manifest.workshopID.isEmpty else { return nil }
        return manifest
    }

    /// Every folder under `root` that carries a manifest, by Workshop ID, `depth` levels down.
    nonisolated static func foldersWithManifest(in root: URL, depth: Int) -> [String: URL] {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        func walk(_ url: URL, _ remaining: Int) {
            guard remaining > 0 else { return }
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                guard !child.lastPathComponent.hasPrefix("."),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let manifest = readManifest(in: child) ?? readInfoFile(in: child), found[manifest.workshopID] == nil {
                    found[manifest.workshopID] = child
                }
                walk(child, remaining - 1)
            }
        }
        walk(root, depth)
        return found
    }

    /// Points every saved mod path at this install's storage, and at wherever its folder is now, so
    /// an app update no longer leaves the whole library reading as moved and unable to be updated.
    /// A folder that cannot be matched by name is matched by the Workshop ID in its hidden manifest.
    func repairFolders() {
        let fm = FileManager.default
        let root = downloadsRoot
        var changed = false
        var missing = false
        var diskIndex: [String: URL]?

        /// Built once, and only when a path is actually lost: it reads every mod folder's manifest.
        func foldersOnDisk() -> [String: URL] {
            if let diskIndex { return diskIndex }
            var found = Self.foldersWithManifest(in: root, depth: 2)
            for (id, url) in Self.foldersWithManifest(in: documents, depth: 2) where found[id] == nil { found[id] = url }
            diskIndex = found
            return found
        }

        for i in library.indices {
            let current = Self.currentPath(for: library[i].folder)
            if current != library[i].folder { library[i].folder = current; changed = true }
            var folder = URL(fileURLWithPath: library[i].folder, isDirectory: true)

            if !fm.fileExists(atPath: folder.path) {
                missing = true
                if let found = foundFolder(named: folder.lastPathComponent, id: library[i].id,
                                           root: root, index: foldersOnDisk) {
                    folder = found
                    library[i].folder = found.path
                    changed = true
                }
            }
            guard fm.fileExists(atPath: folder.path) else { continue }
            if library[i].filesMoved { library[i].filesMoved = false; changed = true }

            // A mod installed by an older build has no manifest yet; the library fills one in, so this
            // is the last launch that has to work anything out from the folder name.
            if Self.readManifest(in: folder) == nil {
                Self.writeManifest(InstalledModManifest(workshopID: library[i].id,
                                                        title: library[i].displayTitle,
                                                        appID: library[i].appID,
                                                        gameName: library[i].gameName,
                                                        publishedUpdatedAt: library[i].publishedUpdatedAt,
                                                        installedAt: library[i].addedAt,
                                                        fileCount: library[i].fileCount,
                                                        byteCount: library[i].byteCount,
                                                        modShelfVersion: modShelfVersion),
                                   in: folder)
            }

            // Whatever the folder itself remembers fills in what the library lost, so an update is
            // compared against the version that is really installed.
            if let manifest = Self.readManifest(in: folder) {
                if library[i].publishedUpdatedAt == nil, let stamp = manifest.publishedUpdatedAt, stamp > 0 {
                    library[i].publishedUpdatedAt = stamp; changed = true
                }
                if library[i].appID == nil, let app = manifest.appID { library[i].appID = app; changed = true }
                if (library[i].gameName ?? "").isEmpty, let game = manifest.gameName, !game.isEmpty {
                    library[i].gameName = game; changed = true
                }
                if (library[i].title ?? "").isEmpty, let title = manifest.title, !title.isEmpty {
                    library[i].title = title; changed = true
                }
            }
        }

        // A folder with a manifest but no library entry (a library file that went missing, or a game
        // folder put back by hand) is taken back into the library as it was installed.
        if missing || library.isEmpty {
            let known = Set(library.map(\.id))
            for (id, folder) in foldersOnDisk() where !known.contains(id) {
                guard let manifest = Self.readManifest(in: folder) ?? Self.readInfoFile(in: folder) else { continue }
                let counts = Self.scan(folder: folder.path)
                guard counts.exists, counts.count > 0 else { continue }
                Self.writeManifest(manifest, in: folder)
                var item = WorkshopItem(id: id, folder: folder.path,
                                        addedAt: manifest.installedAt ?? Date(),
                                        updatedAt: manifest.installedAt ?? Date())
                item.title = manifest.title
                item.appID = manifest.appID
                item.gameName = manifest.gameName
                item.publishedUpdatedAt = manifest.publishedUpdatedAt
                item.fileCount = counts.count
                item.byteCount = counts.bytes
                library.append(item)
                changed = true
            }
        }

        if changed { saveLibrary(); refreshLibraryBytes(); log("repaired folder paths for \(library.count) mods") }
    }

    /// A mod folder whose saved path is gone: matched by name first, then by the Workshop ID in its
    /// manifest, which also survives the folder being renamed. A game folder that ended up loose in
    /// the app's storage is moved back under "Downloaded Mods" so Files shows one tidy tree.
    private func foundFolder(named name: String, id: String,
                             root: URL, index: () -> [String: URL]) -> URL? {
        let fm = FileManager.default
        if var found = Self.locateFolder(named: name, near: documents) {
            if !found.path.hasPrefix(root.path + "/") {
                let game = found.deletingLastPathComponent()
                let target = root.appendingPathComponent(game.lastPathComponent, isDirectory: true)
                if game.deletingLastPathComponent().path == documents.path,
                   !fm.fileExists(atPath: target.path),
                   (try? fm.moveItem(at: game, to: target)) != nil {
                    let oldPrefix = game.path, newPrefix = target.path
                    for j in library.indices {
                        let path = library[j].folder
                        guard path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { continue }
                        library[j].folder = newPrefix + String(path.dropFirst(oldPrefix.count))
                    }
                    found = target.appendingPathComponent(name, isDirectory: true)
                }
            }
            return found
        }
        return index()[id]
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
        let name: String
        // Some items unpack a level deeper than expected, which would move nothing into place; in
        // that case whatever really came down is used instead of an empty folder.
        if Self.scan(folder: payload.path).count == 0,
           let filled = [base, staging].first(where: { isDir($0) && Self.scan(folder: $0.path).count > 0 }) {
            log("unpacked \(id) deeper than expected, using \(filled.lastPathComponent)")
            payload = filled
            singleMod = false
        }
        name = singleMod ? sanitize(payload.lastPathComponent, fallback: id) : sanitize(meta.title, fallback: id)

        // An update replaces the installation in the folder it already lives in; a new download, or one
        // whose files were moved into a game, goes into the game's folder inside ModShelf.
        let destination: URL
        if let existing, fm.fileExists(atPath: existing.folder),
           Self.isInsideAppStorage(URL(fileURLWithPath: existing.folder, isDirectory: true)) {
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
        // The hidden manifest is written either way: it is how the folder is recognised later.
        Self.writeManifest(InstalledModManifest(workshopID: id,
                                                title: meta.title,
                                                appID: meta.appID ?? existing?.appID,
                                                gameName: meta.gameName ?? existing?.gameName,
                                                publishedUpdatedAt: meta.updatedAt > 0 ? meta.updatedAt : existing?.publishedUpdatedAt,
                                                installedAt: existing?.addedAt ?? Date(),
                                                fileCount: counts.count,
                                                byteCount: counts.bytes,
                                                modShelfVersion: modShelfVersion),
                           in: destination)
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
        if meta.updatedAt > 0 {
            lines.append("Last updated on Workshop: \(stamp.string(from: Date(timeIntervalSince1970: TimeInterval(meta.updatedAt))))")
        }
        lines.append("")
        lines.append("Installed on: \(stamp.string(from: Date()))")
        lines.append("Installed with: ModShelf \(modShelfVersion) (build \(modShelfBuild))")
        lines.append("Size: \(Fmt.bytes(bytes)) - Files: \(files)")
        lines.append("")
        lines.append("This file is written by ModShelf and is safe to delete or leave as is, turn future info files off in ModShelf's options.")
        return lines.joined(separator: "\n")
    }

    /// Rewrites the info file inside a mod's folder with the freshest Workshop numbers, so an update
    /// never leaves the previous version's dates in it. The hidden manifest is always refreshed; the
    /// visible file only when the option asks for it.
    private func rewriteInfoFile(_ item: WorkshopItem, meta: WorkshopMetadata) {
        let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        Self.writeManifest(InstalledModManifest(workshopID: item.id,
                                                title: meta.title,
                                                appID: meta.appID ?? item.appID,
                                                gameName: meta.gameName ?? item.gameName,
                                                publishedUpdatedAt: meta.updatedAt > 0 ? meta.updatedAt : item.publishedUpdatedAt,
                                                installedAt: item.addedAt,
                                                fileCount: item.fileCount,
                                                byteCount: item.lastVerifiedBytes ?? item.byteCount,
                                                modShelfVersion: modShelfVersion),
                           in: folder)
        guard UserDefaults.standard.object(forKey: "options.infoFile") as? Bool ?? true else { return }
        let text = infoText(meta: meta, id: item.id, files: item.fileCount ?? 0, bytes: item.lastVerifiedBytes ?? item.byteCount ?? 0,
                            existing: item, singleMod: false)
        try? text.write(to: folder.appendingPathComponent(modShelfInfoFileName), atomically: true, encoding: .utf8)
    }

    /// An update starts from the metadata already stored for the mod, so the new version's date is
    /// only known once Workshop is asked. This fills it in and refreshes the info file.
    private func refreshInstalledMetadata(id: String) {
        Task { @MainActor in
            guard let fresh = await SteamMeta.fetch(id: id, includePage: false) else { return }
            guard let index = library.firstIndex(where: { $0.id == id }) else { return }
            if fresh.updatedAt > 0 { library[index].publishedUpdatedAt = fresh.updatedAt }
            if !fresh.title.isEmpty { library[index].title = fresh.title }
            if !fresh.tags.isEmpty { library[index].tags = fresh.tags }
            if fresh.rating != nil { library[index].rating = fresh.rating; library[index].ratingCount = fresh.ratingCount }
            if let game = fresh.gameName { library[index].gameName = game }
            library[index].updateAvailable = false
            saveLibrary()
            rewriteInfoFile(library[index], meta: fresh)
        }
    }

    /// Bytes allocated under a folder, used to follow a download Steam is not reporting on. This is
    /// the allocated size rather than the logical size: files are pre-allocated to their full length
    /// before any data arrives, so only the allocated size grows as chunks are written.
    nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in en {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            if values?.isRegularFile == true {
                bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        return bytes
    }

    nonisolated static func scan(folder: String) -> (exists: Bool, count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return (false, 0, 0) }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return (true, 0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let file as URL in en {
            if file.lastPathComponent == modShelfInfoFileName || file.lastPathComponent == modShelfManifestName { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { count += 1; bytes += Int64(values?.fileSize ?? 0) }
        }
        return (true, count, bytes)
    }

    // MARK: library actions

    /// Partial downloads and replaced copies left behind inside any game folder by a session that
    /// was interrupted, found however deep they sit.
    nonisolated static func partialLeftovers(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [URL] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix(".partial-") || name.hasPrefix(".modshelf-replacing-") else { continue }
            found.append(url)
            en.skipDescendants()
        }
        return found
    }

    func remove(_ item: WorkshopItem) {
        // A mod moved out of ModShelf belongs to wherever the user put it: only forget the entry.
        if !item.isInsideModShelf {
            library.removeAll { $0.id == item.id }; saveLibrary(); refreshLibraryBytes()
            operationMessage = "Removed \(item.displayTitle) from your library. Its files are still in the folder you moved it to."
            log("forgot \(item.id) (files outside ModShelf)")
            return
        }
        do { if FileManager.default.fileExists(atPath: item.folder) { try FileManager.default.removeItem(atPath: item.folder) } }
        catch { errorMessage = "Those files wouldn't delete."; log("delete failed \(item.id): \(error)"); return }
        library.removeAll { $0.id == item.id }; saveLibrary(); refreshLibraryBytes()
        log("deleted \(item.id) \"\(item.displayTitle)\"")
    }
    func requestDelete(_ item: WorkshopItem) {
        if UserDefaults.standard.object(forKey: "options.confirmDelete") as? Bool ?? true {
            pendingDelete = item; showDeleteConfirmation = true
        } else { remove(item) }
    }

    /// Deletes several installations. An entry stays in the library when its files can't be removed.
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let entries = library.filter { wanted.contains($0.id) }
        var removed: [String] = []
        var failed: [String] = []
        for item in entries {
            guard item.isInsideModShelf else { removed.append(item.id); continue }
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
            log("deleted \(removed.count) mods; \(failed.count) failed")
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
        log("favourite \(item.id): \(library[i].isFavourite)")
        Haptics.tap()
    }
    func export(_ item: WorkshopItem) { export([item.id]) }

    /// Zips the chosen mods into one archive, written straight out of the folders the mods already
    /// live in. Copying them somewhere first doubled the space needed, which is what made a ZIP of
    /// the big mods fail on a device with little room left.
    func export(_ ids: [String]) {
        guard !isExporting else { operationMessage = "A ZIP is already being built."; return }
        let wanted = Set(ids)
        let chosen = library.filter { wanted.contains($0.id) }
        guard !chosen.isEmpty else { return }
        var folders: [(url: URL, name: String)] = []
        var used = Set<String>()
        var missing = 0
        for item in chosen {
            let url = URL(fileURLWithPath: item.folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            var name = Self.sanitizedName(item.displayTitle, fallback: item.id)
            var copy = 2
            // Two mods can share a name; keep them apart rather than overwriting one in the archive.
            while used.contains(name.lowercased()) { name = "\(Self.sanitizedName(item.displayTitle, fallback: item.id)) \(copy)"; copy += 1 }
            used.insert(name.lowercased())
            folders.append((url, name))
        }
        guard !folders.isEmpty else {
            errorMessage = chosen.count == 1
                ? "That mod's files aren't in ModShelf any more, so there's nothing to export."
                : "Those mods' files aren't in ModShelf any more, so there's nothing to export."
            return
        }
        let archiveName = folders.count == 1 ? folders[0].name : "ModShelf-Export"
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("\(archiveName).zip")
        isExporting = true
        operationMessage = folders.count == 1
            ? "Preparing the ZIP…"
            : "Preparing \(folders.count) mods as one ZIP…"
        log("zip start: \(folders.count) mods, \(missing) missing")
        Task { @MainActor in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                try? FileManager.default.removeItem(at: zip)
                do {
                    let archive = try Archive(url: zip, accessMode: .create)
                    for folder in folders { try Self.add(folder: folder.url, as: folder.name, to: archive) }
                    return nil
                } catch {
                    try? FileManager.default.removeItem(at: zip)
                    let reason = error as NSError
                    return "\(reason.domain) \(reason.code): \(reason.localizedDescription)"
                }
            }.value
            isExporting = false
            guard let failure else {
                shareURL = zip
                operationMessage = missing == 0
                    ? (folders.count == 1 ? "" : "Zipped \(folders.count) mods.")
                    : "Zipped \(folders.count) mod\(folders.count == 1 ? "" : "s") and left out \(missing) whose files are not in ModShelf."
                log("zip done: \(folders.count) mods, \(Fmt.bytes(Int64((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))")
                Haptics.success()
                return
            }
            log("zip failed: \(failure)")
            errorMessage = Self.exportMessage(failure)
            Haptics.error()
        }
    }

    /// Adds one mod's folder under its own name, a file at a time, so a big mod is read where it
    /// already is instead of being copied somewhere first.
    nonisolated private static func add(folder: URL, as name: String, to archive: Archive) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            // ModShelf's own hidden record of the install has no place in a shared archive.
            guard !file.lastPathComponent.hasPrefix(".modshelf") else { continue }
            let prefix = folder.path + "/"
            let relative = file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.lastPathComponent
            try archive.addEntry(with: "\(name)/\(relative)", fileURL: file, compressionMethod: .deflate)
        }
    }

    /// The reason a ZIP failed, put in terms that can be acted on.
    nonisolated static func exportMessage(_ failure: String) -> String {
        let text = failure.lowercased()
        if text.contains("nsposixerrordomain 28") || text.contains("nscocoaerrordomain 640") || text.contains("space") {
            return "There wasn't enough free space to build the ZIP."
        }
        if text.contains("nsposixerrordomain 2") || text.contains("nscocoaerrordomain 4") || text.contains("no such file") {
            return "Some of those mods' files have moved, so the ZIP didn't build."
        }
        return "The ZIP didn't build."
    }

    /// Steam's size and the files on disk are close, not always identical, so allow a small margin.
    nonisolated static func sizeMatches(disk: Int64, steam: Int64) -> Bool {
        let tolerance = max(256 * 1024, steam / 10)
        return abs(disk - steam) <= tolerance
    }

    /// Puts the Download tab back to its default view, with no mod on display.
    func clearDisplayedMod() {
        guard !isBusy else { return }
        preview = nil
        input = ""
        errorMessage = ""
    }

    private func applyCheck(_ id: String, broken: Bool) {
        if let i = library.firstIndex(where: { $0.id == id }) { library[i].filesBroken = broken; saveLibrary() }
    }

    /// Remembers that a mod's files were readable and complete, so a mod the user later moves out
    /// of ModShelf can still say when it was last known to be fine.
    private func recordVerified(_ id: String, files: Int, bytes: Int64) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        library[i].lastVerifiedAt = Date()
        library[i].lastVerifiedFiles = files
        library[i].lastVerifiedBytes = bytes
        library[i].filesBroken = false
        library[i].filesMoved = false
        saveLibrary()
    }

    /// Files aren't where they were installed any more. That is what happens when a mod is moved
    /// into a game, so the mod counts as moved out rather than as damaged.
    private func markMoved(_ id: String) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        guard library[i].filesMoved != true || library[i].filesBroken else { return }
        library[i].filesMoved = true
        library[i].filesBroken = false
        saveLibrary()
    }

    /// What to say about a mod whose files are no longer inside ModShelf.
    private func movedMessage(_ item: WorkshopItem) -> String {
        guard let when = item.lastVerifiedAt else {
            return "\(item.displayTitle) is outside ModShelf now, so its files can't be checked here."
        }
        let size = (item.lastVerifiedBytes ?? item.byteCount).map { " at \(Fmt.bytes($0))" } ?? ""
        return "\(item.displayTitle) is outside ModShelf now. It was last checked \(Fmt.date(when))\(size), so it should still be fine."
    }

    /// Libraries saved before install records existed get one, taken from the download itself.
    func migrateRecords() {
        var changed = false
        for i in library.indices where library[i].lastVerifiedAt == nil {
            library[i].lastVerifiedAt = library[i].updatedAt
            library[i].lastVerifiedBytes = library[i].lastVerifiedBytes ?? library[i].byteCount
            library[i].lastVerifiedFiles = library[i].lastVerifiedFiles ?? library[i].fileCount
            changed = true
        }
        if changed { saveLibrary() }
    }

    private enum FileCheck { case ok, mismatch, moved, unknown }

    /// Reads a mod's files and compares them with the size Steam has. `.unknown` means Steam no
    /// longer reports a size, so the files were readable but nothing could be compared.
    private func checkFiles(id: String, folder: String) async -> FileCheck {
        let scan = await Task.detached(priority: .utility) { Self.scan(folder: folder) }.value
        guard scan.exists, scan.count > 0 else {
            markMoved(id)
            return .moved
        }
        guard let meta = await SteamMeta.fetch(id: id, includePage: false), meta.fileSize > 0 else {
            recordVerified(id, files: scan.count, bytes: scan.bytes)
            return .unknown
        }
        let ok = Self.sizeMatches(disk: scan.bytes, steam: meta.fileSize)
        guard ok else {
            applyCheck(id, broken: true)
            return .mismatch
        }
        recordVerified(id, files: scan.count, bytes: scan.bytes)
        return .ok
    }

    func verify(_ item: WorkshopItem) {
        guard !isVerifyingAll else { return }
        repairFolders()
        let latest = library.first(where: { $0.id == item.id }) ?? item
        guard latest.isInsideModShelf else {
            operationMessage = movedMessage(latest)
            return
        }
        operationMessage = "Validating \(latest.displayTitle)…"
        Task { @MainActor in
            switch await checkFiles(id: latest.id, folder: latest.folder) {
            case .ok:
                operationMessage = "\(latest.displayTitle) matches Steam."
                log("verify \(latest.id): matches Steam")
            case .mismatch:
                operationMessage = "\(latest.displayTitle) differs from Steam's copy. Downloading it again puts that right."
                log("verify \(latest.id): differs from Steam")
            case .moved:
                operationMessage = "\(latest.displayTitle) isn't in ModShelf any more, so its files were probably moved into the game."
            case .unknown:
                operationMessage = "\(latest.displayTitle) is still there, but Steam has no size to compare."
            }
        }
    }

    func verifyAllFiles() {
        guard !isVerifyingAll else { return }
        guard !library.isEmpty else { return }
        repairFolders()
        isVerifyingAll = true
        let entries = library.map { (id: $0.id, title: $0.displayTitle, folder: $0.folder, inside: $0.isInsideModShelf) }
        Task { @MainActor in
            var ok = 0
            var unknown = 0
            var moved = 0
            var changed: [String] = []
            for (index, entry) in entries.enumerated() {
                guard entry.inside else { moved += 1; continue }
                operationMessage = "Validating \(index + 1) of \(entries.count)…"
                switch await checkFiles(id: entry.id, folder: entry.folder) {
                case .ok: ok += 1
                case .moved: moved += 1
                case .unknown: unknown += 1
                case .mismatch: changed.append(entry.title)
                }
                if index + 1 < entries.count { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            isVerifyingAll = false
            var parts: [String] = []
            if ok > 0 { parts.append(ok == 1 ? "1 mod matches Steam" : "\(ok) mods match Steam") }
            if !changed.isEmpty {
                parts.append(changed.count == 1 ? "1 doesn't match" : "\(changed.count) don't match")
            }
            if unknown > 0 { parts.append(unknown == 1 ? "1 couldn't be compared" : "\(unknown) couldn't be compared") }
            if moved > 0 { parts.append(moved == 1 ? "1 moved out of ModShelf" : "\(moved) moved out of ModShelf") }
            operationMessage = parts.isEmpty ? "Nothing to validate." : parts.joined(separator: ", ") + "."
            log("verify all: \(operationMessage.replacingOccurrences(of: "\n", with: " "))")
        }
    }

    // MARK: update checks

    func checkUpdates(_ item: WorkshopItem) {
        guard !isCheckingUpdates else { operationMessage = "An update check is already running."; return }
        isCheckingUpdates = true
        operationMessage = "Checking \(item.displayTitle)…"
        Task { @MainActor in
            let success = await refreshMetadata(for: item, full: true)
            isCheckingUpdates = false
            guard success, let latest = library.first(where: { $0.id == item.id }) else {
                operationMessage = "Steam didn't answer for that one."
                return
            }
            operationMessage = latest.updateAvailable
                ? "An update is available for \(latest.displayTitle)."
                : "\(latest.displayTitle) is up to date."
            log("check \(latest.id): \(latest.updateAvailable ? "update available" : "up to date")")
            if !latest.isInsideModShelf || latest.filesMoved {
                operationMessage += "\nIts files are outside ModShelf, so only the Workshop version was checked."
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
        var installedStamp = library[index].publishedUpdatedAt ?? 0
        if installedStamp == 0 {
            // The hidden manifest knows which version was installed, so a real update is not mistaken
            // for the current one when the library entry lost its stamp.
            let folder = URL(fileURLWithPath: library[index].folder, isDirectory: true)
            if let stamp = Self.readManifest(in: folder)?.publishedUpdatedAt, stamp > 0 {
                installedStamp = stamp
                library[index].publishedUpdatedAt = stamp
            }
        }
        if installedStamp == 0 {
            library[index].publishedUpdatedAt = meta.updatedAt   // legacy entry: treat the current version as installed
            library[index].updateAvailable = false
        } else if installedStamp > meta.updatedAt, meta.updatedAt > 0 {
            // A stored version newer than Steam's own can't be real (an old simulated run, or a clock
            // change), so Steam's date is taken as the installed one and future updates show again.
            installedStamp = meta.updatedAt
            library[index].publishedUpdatedAt = installedStamp
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
        if let app = library[index].appID, let game = library[index].gameName, !game.isEmpty {
            renameGameFolder(appID: app, to: game)
        }
        return true
    }

    func checkAllUpdates(silent: Bool = false) {
        guard !isCheckingUpdates else { if !silent { operationMessage = "An update check is already running." }; return }
        guard !library.isEmpty else { if !silent { operationMessage = "Your library is empty." }; return }
        isCheckingUpdates = true
        let entries = library
        Task { @MainActor in
            var checked = 0, updated = 0, failed = 0, unverified = 0
            for item in entries {
                if !silent { operationMessage = "Checking \(checked + failed + 1) of \(entries.count)…" }
                if await refreshMetadata(for: item, full: false) {
                    checked += 1
                    if let current = library.first(where: { $0.id == item.id }) {
                        if current.updateAvailable { updated += 1 }
                        if !current.isInsideModShelf || current.filesBroken || current.filesMoved { unverified += 1 }
                    }
                } else { failed += 1 }
                if checked + failed < entries.count { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            isCheckingUpdates = false
            if silent {
                operationMessage = updated > 0 ? "\(updated) mod update\(updated == 1 ? "" : "s") available." : ""
            } else if checked == 0 {
                operationMessage = "Steam didn't answer just now."
            } else {
                var parts: [String] = [updated > 0 ? "\(updated) update\(updated == 1 ? "" : "s") available" : "Everything is up to date"]
                if failed > 0 { parts.append("\(failed) couldn't be checked") }
                operationMessage = parts.joined(separator: ", ") + "."
                if unverified > 0 { operationMessage += "\nUnverified mods checked: \(unverified)" }
                log("update check: \(operationMessage.replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }

    /// Runs once per launch: quick folder check, then an update check for every mod.
    func runLaunchChecks() {
        guard !didLaunchChecks else { return }
        didLaunchChecks = true
        repairFolders()
        // ZIPs and abandoned partial downloads count against the app's storage, so every launch
        // starts from the library and nothing else.
        let freed = purgeTemporaryFiles()
        if freed > 0 { log("launch cleanup freed \(Fmt.bytes(freed))") }
        var changed = false
        let fm = FileManager.default
        for i in library.indices {
            // Files that were moved into a game are simply not here any more, which is normal use:
            // that counts as moved out, never as a problem.
            let movedAway = !library[i].isInsideModShelf || !fm.fileExists(atPath: library[i].folder)
            if library[i].filesMoved != movedAway { library[i].filesMoved = movedAway; changed = true }
            if movedAway, library[i].filesBroken { library[i].filesBroken = false; changed = true }
        }
        if changed { saveLibrary() }
        if UserDefaults.standard.object(forKey: "options.autoCheck") as? Bool ?? true { checkAllUpdates(silent: true) }
    }

    func retry(_ record: DownloadRecord) {
        input = record.workshopID
        if let item = library.first(where: { $0.id == record.workshopID }) { update(item) }
        else { download(record.workshopID) }
    }
    func clearHistory() {
        log("history cleared (\(history.count) entries)")
        history.removeAll(); saveHistory(); UserDefaults.standard.removeObject(forKey: "history")
    }
    func clearTemporaryFiles() {
        let freed = purgeTemporaryFiles()
        status = "Temporary files cleared"
        operationMessage = freed > 0
            ? "Cleared \(Fmt.bytes(freed)) of temporary files."
            : "Temporary files cleared."
        log("temporary files cleared: \(Fmt.bytes(freed))")
    }

    /// Removes what the library does not need: shared ZIPs, stale partial downloads and replaced
    /// copies. Run at launch as well as from Options, so nothing quietly piles up in storage.
    @discardableResult
    private func purgeTemporaryFiles() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        // An older build kept a visible "ModShelfTemporary" folder in Documents; nothing needs it now.
        let legacy = documents.appendingPathComponent("ModShelfTemporary", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            freed += sizeOnDisk(legacy)
            try? fm.removeItem(at: legacy)
        }
        // The app's own temporary folder is where ZIP builds work, and iOS may clear it anyway.
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            freed += sizeOnDisk(url)
            try? fm.removeItem(at: url)
        }
        // Leftover partial downloads and replaced copies from interrupted sessions, in any game
        // folder they were left in.
        for url in Self.partialLeftovers(in: downloadsRoot) {
            freed += sizeOnDisk(url)
            try? fm.removeItem(at: url)
        }
        return freed
    }

    /// What a file or folder takes up on disk, for saying how much a cleanup recovered.
    private func sizeOnDisk(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory == true { return Self.directoryBytes(url) }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }
    // MARK: app updates

    /// The release the app checks against: the build publishes a tiny version file next to the IPA.
    nonisolated static let appRepo = "shplash/ModShelf"

    func checkForAppUpdate() {
        guard !isCheckingAppUpdate else { return }
        isCheckingAppUpdate = true
        appUpdateMessage = "Checking for updates…"
        Task { @MainActor in
            isCheckingAppUpdate = false
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.appRepo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                appUpdateMessage = "Couldn't check for updates."
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            appUpdateMessage = Self.version(latest, isNewerThan: modShelfVersion)
                ? "v\(latest) is available."
                : "You're on the latest version."
            log("app update check: latest \(latest), current \(modShelfVersion)")
        }
    }

    /// Compares dotted version numbers, ignoring a trailing letter such as 1.0b.
    nonisolated static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: .letters)
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let new = parts(candidate), old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// A line for the runtime log: time, then what happened. Kept short so a long session stays useful.
    /// Nothing is recorded until the developer menu has been unlocked, so a normal user never pays for it.
    func log(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "dev.unlocked") else { return }
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let line = "\(stamp)  \(message)"
        runtimeLog.append(line)
        if runtimeLog.count > 400 { runtimeLog.removeFirst(runtimeLog.count - 400) }
        Self.appendRuntimeLog(line)
        // Keep the file from growing without bound, and rewrite it with what is still in memory.
        if runtimeLog.count % 200 == 0, let data = runtimeLog.joined(separator: "\n").data(using: .utf8) {
            try? data.write(to: Self.runtimeLogFile, options: .atomic)
        }
    }

    nonisolated private static var runtimeLogFile: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModShelf", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("runtime.log")
    }

    /// The log is kept on disk too, so it survives a crash or a relaunch and can still be copied.
    nonisolated private static func appendRuntimeLog(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = runtimeLogFile
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated private static func loadRuntimeLog() -> [String] {
        guard let text = try? String(contentsOf: runtimeLogFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(200).map(String.init)
    }

    func clearRuntimeLog() {
        runtimeLog.removeAll()
        try? FileManager.default.removeItem(at: Self.runtimeLogFile)
        log("log cleared")
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
    /// The first tab says "Queue" while a batch is running.
    var firstTitle: String = "Download"
    var onTap: (Int) -> Void = { _ in }
    private let items: [(String, String)] = [("Download", "arrow.down.circle.fill"), ("Workshop", "safari.fill"),
                                             ("Library", "square.grid.2x2.fill"), ("Options", "gearshape.fill")]

    private func title(_ i: Int) -> String { i == 0 ? firstTitle : items[i].0 }

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
                if !compact { Text(title(i)).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: compact ? 54 : 78, height: compact ? 40 : 54)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(i))
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
                        Text(title(i)).font(.system(size: 12, weight: .semibold))
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
    var body: some View { glyph.accessibilityLabel(label) }

    @ViewBuilder private var glyph: some View {
        switch status {
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(Color.green)
        // Fine, but the files live in a game folder now: a green folder with an arrow in it, so it
        // reads at a glance without a warning colour or another line of text. The ready-made symbol
        // only exists on newer iOS, so older versions get the same shape drawn from two symbols.
        case .moved:
            if UIImage(systemName: "arrow.forward.folder") != nil {
                Image(systemName: "arrow.forward.folder")
                    .font(.system(size: size, weight: .medium)).foregroundStyle(Color.green)
            } else {
                ZStack {
                    Image(systemName: "folder")
                        .font(.system(size: size, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .offset(x: size * 0.08, y: size * 0.14)
                }
                .foregroundStyle(Color.green)
            }
        case .needsUpdate:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size)).foregroundStyle(Color.accentColor)
        case .notChecked:
            Image(systemName: "questionmark.circle.fill").font(.system(size: size)).foregroundStyle(Color.secondary)
        case .broken:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size)).foregroundStyle(Color.yellow)
        }
    }

    private var label: String {
        switch status {
        case .upToDate: return "Up to date"
        case .moved: return "Up to date, files outside ModShelf"
        case .needsUpdate: return "Update available"
        case .notChecked: return "Not checked yet"
        case .broken: return "Files don't match Steam"
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

/// One line of text that scrolls sideways when it doesn't fit, so a long mod name never makes a
/// grid cell taller than its neighbours. The timing lives in UIKit, so leaving a tab puts the name
/// back on its first letter immediately and coming back always waits a second before it moves.
struct MarqueeText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14
    var weight: UIFont.Weight = .semibold
    var height: CGFloat = 17
    var speed: CGFloat = 26
    var active = true
    var restartToken = 0
    var color: UIColor = .label

    func makeUIView(context: Context) -> MarqueeUIView {
        let view = MarqueeUIView()
        view.update(text: text, font: .systemFont(ofSize: fontSize, weight: weight),
                    active: active, token: restartToken, speed: speed, color: color)
        return view
    }

    func updateUIView(_ view: MarqueeUIView, context: Context) {
        view.update(text: text, font: .systemFont(ofSize: fontSize, weight: weight),
                    active: active, token: restartToken, speed: speed, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarqueeUIView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// The label that does the scrolling. All of the state is here, so a tab switch can never leave a
/// half-finished scroll behind.
final class MarqueeUIView: UIView {
    private let label = UILabel()
    private var speed: CGFloat = 26
    private var active = false
    private var generation = 0
    private var lastWidth: CGFloat = 0
    private var lastToken = -1
    private var lastText = ""
    private var lastSpeed: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String, font: UIFont, active: Bool, token: Int, speed: CGFloat, color: UIColor = .label) {
        self.speed = speed
        if label.font != font { label.font = font }
        if label.textColor != color { label.textColor = color }
        if label.text != text { label.text = text }
        let changed = text != lastText || token != lastToken || active != self.active
            || abs(speed - lastSpeed) > 0.01
        lastText = text
        lastToken = token
        lastSpeed = speed
        self.active = active
        if changed { restart() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            restart()
        }
    }

    /// Coming back to the library (from history, say) starts the name over with its pause.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restart() }
    }

    /// Puts the first letter at the left edge and, when there is something to scroll, starts the
    /// one-second pause that begins every pass. With scrolling off the name stays one line and is
    /// cut with an ellipsis where it no longer fits.
    private func restart() {
        generation += 1
        let generation = self.generation
        label.layer.removeAllAnimations()
        label.transform = .identity
        label.sizeToFit()

        if active {
            label.lineBreakMode = .byClipping
            label.frame = CGRect(x: 0, y: (bounds.height - label.frame.height) / 2,
                                 width: label.frame.width, height: label.frame.height)
        } else {
            label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 0, y: (bounds.height - label.frame.height) / 2,
                                 width: max(bounds.width, 0), height: label.frame.height)
        }
        guard active, bounds.width > 0 else { return }
        schedulePass(generation: generation)
    }

    private func schedulePass(generation: Int, delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation, self.active else { return }
            let overflow = max(0, self.label.bounds.width - self.bounds.width)
            guard overflow > 0.5 else { return }
            let travel = max(1.2, Double(overflow / self.speed))
            UIView.animate(withDuration: travel, delay: 1.0,
                           options: [.curveLinear, .beginFromCurrentState]) {
                self.label.transform = CGAffineTransform(translationX: -overflow, y: 0)
            } completion: { _ in
                guard self.generation == generation, self.active else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard self.generation == generation, self.active else { return }
                    self.label.transform = .identity
                    self.schedulePass(generation: generation)
                }
            }
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
                .lineLimit(1)
        }
    }
}

// MARK: - Main view

/// Which mods a ZIP export would really contain, and how many have to be left out.
struct ExportPrompt: Identifiable {
    let id = UUID()
    let ids: [String]
    let missing: Int
    let total: Int
}

/// A mod that was dropped on the running one, waiting for a yes before the engine is stopped.
struct ReorderRequest: Identifiable {
    let id: String
    let title: String
}

/// One place to work out how fast a marquee should run, from the scrolling text options. Anything
/// outside this screen reads the same stored values, so every scrolling name obeys them.
enum MarqueeSpeed {
    private static func stored(_ key: String, fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
    private static var oneSpeedForAll: Bool {
        UserDefaults.standard.object(forKey: "options.marqueeGlobal") as? Bool ?? true
    }
    private static var one: Double { stored("options.marqueeSpeed", fallback: 1) }
    /// The speed used inside the library, in either layout.
    static var library: Double { oneSpeedForAll ? one : stored("options.marqueeSpeedLibrary", fallback: 1) }
    /// The speed used everywhere else: the download queue, history and the browser's start page.
    static var other: Double { oneSpeedForAll ? one : stored("options.marqueeSpeedOther", fallback: 1) }
    static var librarySpeed: CGFloat { CGFloat(26 * library) }
    static var otherSpeed: CGFloat { CGFloat(26 * other) }
    /// Below this, scrolling text is switched off and the name is cut with an ellipsis instead.
    static var libraryRunning: Bool { library >= 0.25 }
    static var otherRunning: Bool { other >= 0.25 }
}

/// How far the page has moved and how far it has run upwards, held off the view's state on purpose.
final class ScrollTracker {
    var lastY: CGFloat = 0
    var upRun: CGFloat = 0
}

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = true
    @AppStorage("options.haptics") private var haptics = true
    @AppStorage("options.marqueeSpeed") private var marqueeSpeed = 1.0
    /// One speed everywhere, or a separate speed for the library and for everything else.
    @AppStorage("options.marqueeGlobal") private var marqueeGlobal = true
    @AppStorage("options.marqueeSpeedLibrary") private var marqueeSpeedLibrary = 1.0
    @AppStorage("options.marqueeSpeedOther") private var marqueeSpeedOther = 1.0
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
    /// The filtered and sorted library, rebuilt only when its inputs change. Computing it inside
    /// the view body meant re-sorting everything on every scroll tick.
    @State private var visibleItems: [WorkshopItem] = []
    /// The game and tag options for the filter pills, cached for the same reason.
    @State private var installedGameOptions: [(id: String, name: String)] = []
    @State private var installedTagOptions: [String] = []
    @State private var historySearch = ""
    @State private var showingHistory = false
    @State private var inputWasSubmitted = false
    @State private var pendingDeleteItem: WorkshopItem?
    @State private var tabCollapsed = false
    @State private var scrollAnchor: CGFloat = 0
    @State private var selecting = false
    /// The tabs that have been opened at least once; only those are built.
    @State private var openedTabs: Set<Int> = [0]
    @State private var selection: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var exportPrompt: ExportPrompt?
    @State private var mediaViewer: MediaViewer?
    @State private var mediaIndex = 0
    @State private var marqueeToken = 0
    @State private var freeSpaceCache: Int64 = 0
    @State private var pendingAutoDownload: String?
    @State private var confirmClearViewed = false
    @State private var selectedGame: String? = nil
    @State private var selectedTag: String? = nil
    @State private var favouritesOnly = false
    @State private var themeOpen = false
    @State private var tabStyleOpen = false
    @State private var sortOpen = false
    @State private var confirmClearHistory = false
    /// Scroll bookkeeping kept in a reference type, so a scroll frame never re-renders the whole app.
    @State private var scrollTracker = ScrollTracker()
    @AppStorage("options.libraryFilter") private var libraryFilter = "All"
    /// Figures the download screen shows on every render, worked out when the library changes instead.
    @State private var gameCount = 0
    @State private var updateCount = 0
    @State private var browserHomeToken = 0
    @State private var lastWorkshopTap = Date.distantPast
    @State private var lastDownloadTap = Date.distantPast
    @State private var showDeveloperMenu = false
    @AppStorage("dev.unlocked") private var devUnlocked = false
    @State private var logoTapCount = 0
    @State private var lastLogoTap = Date.distantPast
    @State private var dragRowID: String?
    @State private var dragOffsetY: CGFloat = 0
    @State private var dragTarget: Int?
    @State private var confirmReorder: ReorderRequest?

    /// Space reserved under every tab for the tab bar, so content can always scroll clear of it.
    private var tabBarReserve: CGFloat { tabStyle == "bar" ? 84 : 100 }

    private let sortGroups: [[String]] = [
        ["Recently added", "Recently updated", "Oldest added"],
        ["Name", "Game"],
        ["Largest first", "Smallest first"],
        ["Updates first", "Highest rated", "Favourites first"]
    ]
    private var sortOrders: [String] { sortGroups.flatMap { $0 } }

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
        return installedGameOptions.first(where: { $0.id == g })?.name
    }
    private var filteredLibrary: [WorkshopItem] {
        let filtered = store.library.filter { item in
            if libraryFilter == "Favourites" && !item.isFavourite { return false }
            if libraryFilter == "Updates" && !item.updateAvailable { return false }
            if libraryFilter == "Problems" && !item.status.needsAttention { return false }
            if let g = selectedGame, item.appID != g { return false }
            if let t = selectedTag, !item.tags.contains(t) { return false }
            if searchText.isEmpty { return true }
            if item.displayTitle.localizedCaseInsensitiveContains(searchText) { return true }
            if item.id.contains(searchText) { return true }
            if item.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) { return true }
            return (item.gameName ?? "").localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case "Name": return filtered.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case "Game": return filtered.sorted { a, b in
            let ga = a.gameName ?? "", gb = b.gameName ?? ""
            if ga.localizedCaseInsensitiveCompare(gb) == .orderedSame {
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            }
            return ga.localizedCaseInsensitiveCompare(gb) == .orderedAscending
        }
        case "Updates first": return filtered.sorted { $0.updateAvailable && !$1.updateAvailable }
        case "Recently updated": return filtered.sorted { ($0.publishedUpdatedAt ?? 0) > ($1.publishedUpdatedAt ?? 0) }
        case "Oldest added": return filtered.sorted { $0.addedAt < $1.addedAt }
        case "Largest first": return filtered.sorted { ($0.byteCount ?? 0) > ($1.byteCount ?? 0) }
        case "Smallest first": return filtered.sorted { ($0.byteCount ?? Int64.max) < ($1.byteCount ?? Int64.max) }
        case "Highest rated": return filtered.sorted { a, b in
            let ra = a.rating ?? -1, rb = b.rating ?? -1
            if ra != rb { return ra > rb }
            let ca = a.ratingCount ?? 0, cb = b.ratingCount ?? 0
            if ca != cb { return ca > cb }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
        case "Favourites first": return filtered.sorted { $0.isFavourite && !$1.isFavourite }
        default: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    /// "Select and export as ZIP" turns on selection so a subset can be picked, then exported.
    private func startExportSelection() {
        Haptics.tap()
        selection.removeAll()
        selecting = true
        store.operationMessage = "Pick the mods to export, then choose Export selected from the three dot menu."
    }

    private func exportSelection() {
        guard !selection.isEmpty else { return }
        Haptics.tap()
        beginExport(all: false)
    }

    /// Only mods whose files are still in ModShelf can go into a ZIP, so say so before starting.
    private func beginExport(all: Bool) {
        guard !store.isExporting else { store.operationMessage = "A ZIP is already being built."; return }
        let pool = all ? store.library : store.library.filter { selection.contains($0.id) }
        guard !pool.isEmpty else { return }
        let present = pool.filter { FileManager.default.fileExists(atPath: $0.folder) }
        guard !present.isEmpty else {
            store.errorMessage = all
                ? "None of your mods' files are in ModShelf any more, so there's nothing to export."
                : "Those mods' files aren't in ModShelf any more, so there's nothing to export."
            return
        }
        let missing = pool.count - present.count
        guard missing > 0 else {
            store.export(present.map(\.id))
            return
        }
        exportPrompt = ExportPrompt(ids: present.map(\.id), missing: missing, total: pool.count)
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
    private func requestDeleteSelected() {        guard !selection.isEmpty else { return }
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

    // MARK: body

    var body: some View {
        rootWithObservers
            .onChange(of: store.library) { _ in rebuildLibraryOptions() }
            .onChange(of: searchText) { _ in visibleItems = filteredLibrary }
            .onChange(of: libraryFilter) { _ in visibleItems = filteredLibrary }
            .onChange(of: selectedGame) { _ in
                visibleItems = filteredLibrary
                installedTagOptions = installedTags
            }
            .onChange(of: selectedTag) { _ in visibleItems = filteredLibrary }
            .onChange(of: sortOrder) { _ in visibleItems = filteredLibrary }
    }

    /// The screens and the sheets they present. Kept apart from the observers below so that no one
    /// expression has to carry every modifier the app owns: a long chain is itself a deep type.
    private var rootScene: some View {
        ZStack {
            mainStack
            overlayDetails
            overlayDialogs
            overlayMedia
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showDeveloperMenu) { DeveloperMenuView(store: store) }
        .sheet(isPresented: $showShare, onDismiss: {
            // A ZIP exists only to be handed over: once the sheet is gone it is deleted, so nothing
            // large is left behind in the app's storage.
            if let url = store.shareURL,
               url.isFileURL,
               url.path.hasPrefix(FileManager.default.temporaryDirectory.path + "/") {
                try? FileManager.default.removeItem(at: url)
            }
            store.shareURL = nil
        }) { if let url = store.shareURL { ShareSheet(activityItems: [url]) } }
        .sheet(isPresented: Binding(get: { store.revealFolderURL != nil },
                                    set: { if !$0 { store.revealFolderURL = nil } })) {
            if let folder = store.revealFolderURL {
                FolderContentsSheet(url: folder) { store.revealFolderURL = nil }
            }
        }
    }

    private var rootWithObservers: some View {
        rootScene
            .onChange(of: store.shareURL) { showShare = $0 != nil }
            .onChange(of: confirmDelete) { UserDefaults.standard.set($0, forKey: "options.confirmDelete") }
            .onChange(of: scenePhase) { phase in
                // Coming back from another app restarts the scrolling names, like arriving on the tab does.
                if phase == .active, selectedTab == 2 { marqueeToken += 1 }
                if phase == .active { refreshFreeSpace() }
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
                    // A ZIP of a big library takes a while; its message stays until it is done.
                    if store.operationMessage == message, !store.isExporting { withAnimation { store.operationMessage = "" } }
                }
            }
            .onChange(of: store.library.count) { count in
                if let g = selectedGame, !installedGameOptions.contains(where: { $0.id == g }) { selectedGame = nil }
                if let t = selectedTag, !installedTagOptions.contains(t) { selectedTag = nil }
                // A selection can never keep mods that are no longer in the library.
                let liveIDs = Set(store.library.map(\.id))
                selection = selection.intersection(liveIDs)
                if selection.isEmpty { selecting = false }
            }
            .onChange(of: autoDownload) { on in
                // Auto download starts with its confirmation armed, and off with it off.
                confirmAutoDownload = on
            }
            .alert("Clear recently viewed mods?", isPresented: $confirmClearViewed) {
                Button("Clear", role: .destructive) {
                    UserDefaults.standard.set("[]", forKey: "browser.recentMods")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("They will appear again as you browse the Workshop.")
            }
            .onChange(of: store.preview) { _ in
                mediaIndex = 0
                mediaViewer = nil
            }
            .task {
                store.runLaunchChecks()
                rebuildLibraryOptions()
            }
    }

    /// Rebuilds everything the library screen derives from the collection, in one pass.
    private func rebuildLibraryOptions() {
        visibleItems = filteredLibrary
        installedGameOptions = installedGames
        installedTagOptions = installedTags
        gameCount = Set(store.library.compactMap { $0.appID }).count
        updateCount = store.library.filter { $0.updateAvailable }.count
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            accountHeader
            if !store.showLogin { errorBanner }
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab, style: tabStyle, collapsed: tabCollapsed,
                      libraryBadge: updateCount > 0,
                      firstTitle: store.queueRows.count > 1 ? "Queue" : "Download",
                      onTap: { tabTapped($0) })
                .frame(height: tabBarReserve, alignment: .bottom)
        }
        .tint(Color.accentColor)
        .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))
        .onChange(of: selectedTab) { tab in
            tabCollapsed = false
            store.log("tab: \(["Download", "Workshop", "Library", "Options"][min(max(tab, 0), 3)])")
            // Every arrival on the library restarts the scrolling names from their resting place.
            if tab == 2 { marqueeToken += 1 }
        }
        .onAppear {
            // A sort saved by an older build may name an option that is no longer offered.
            if !sortOrders.contains(sortOrder) { sortOrder = "Recently added" }
            refreshFreeSpace()
        }
    }

    private var tabContent: some View {
        // A tab is built the first time it is opened and kept afterwards, so launch builds one screen
        // instead of four. Four full screen hierarchies at once is what ran the main thread out of
        // stack while SwiftUI was working out their types.
        ZStack(alignment: .top) {
            if openedTabs.contains(0) { AnyView(downloadView.tabLayer(0, selected: selectedTab)) }
            if openedTabs.contains(1) { AnyView(browserTab.tabLayer(1, selected: selectedTab)) }
            if openedTabs.contains(2) { AnyView(libraryView.tabLayer(2, selected: selectedTab)) }
            if openedTabs.contains(3) { AnyView(optionsView.tabLayer(3, selected: selectedTab)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: selectedTab) { tab in openedTabs.insert(tab) }
    }

    private var browserTab: some View {
        WorkshopBrowserView(onOpenInApp: { id in
                                inputWasSubmitted = false
                                selectedTab = 0
                                store.log("open in app: \(id)")
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

    /// Detail popups and menus. Each group is its own ZStack, so no single expression has to carry
    /// every overlay the app can show at once.
    @ViewBuilder private var overlayDetails: some View {
        ZStack {
            if let item = popupItem {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.45))
                    .ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } }
                ItemDetailPopup(item: currentItem(item), store: store, showIDs: showIDs,
                                onClose: { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } },
                                onOpenWorkshop: { openWorkshop(item.id); popupItem = nil },
                                onUpdate: {
                                    store.update(item)
                                    selectedTab = 0
                                    withAnimation(.easeOut(duration: 0.16)) { popupItem = nil }
                                },
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
        }
    }

    @ViewBuilder private var overlayDialogs: some View {
        ZStack {
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
                             message: "Their downloaded files will be removed from this device. You can download them again later.",
                             actionTitle: "Delete",
                             confirm: {
                                 deleteSelected()
                             },
                             cancel: { confirmBulkDelete = false })
                    .padding(30).zIndex(15)
            }
            if let request = confirmReorder {
                Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { confirmReorder = nil }.zIndex(30)
                ConfirmPopup(heading: "Start this mod now?",
                             message: "\(request.title) will jump the queue and the download running now will stop. It stays in the queue for later.",
                             actionTitle: "Download now",
                             tint: .accentColor,
                             confirm: {
                                 confirmReorder = nil
                                 store.startMovedMod(request.id)
                             },
                             cancel: { confirmReorder = nil })
                    .padding(30).zIndex(31)
            }
            if let prompt = exportPrompt {
                Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { exportPrompt = nil }.zIndex(14)
                ConfirmPopup(heading: "Some mods can't be exported",
                             message: "\(prompt.missing) of \(prompt.total) mod\(prompt.total == 1 ? "" : "s") have files outside ModShelf, so they'd be left out. Export the \(prompt.ids.count) still here?",
                             actionTitle: prompt.ids.count == 1 ? "Export 1 mod" : "Export \(prompt.ids.count) mods",
                             tint: .accentColor,
                             confirm: {
                                 store.export(prompt.ids)
                                 exportPrompt = nil
                             },
                             cancel: { exportPrompt = nil })
                    .padding(30).zIndex(15)
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
    }

    @ViewBuilder private var overlayMedia: some View {
        ZStack {
            if let viewer = mediaViewer {
                ExpandedMediaView(media: viewer.media, startIndex: viewer.index,
                                  onIndexChange: { mediaIndex = $0 }) {
                    withAnimation(.easeOut(duration: 0.18)) { mediaViewer = nil }
                }
                .transition(.opacity)
                .zIndex(20)
            }
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

    // MARK: header

    private var accountHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                brandLogo
                    .contentShape(Rectangle())
                    .onTapGesture { logoTapped() }
                if devUnlocked {
                    Button { showDeveloperMenu = true } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Developer")
                }
                Spacer()
                if store.ringVisible || store.isDownloading || store.isPaused {
                    Button { Haptics.tap(); selectedTab = 0 } label: { downloadRing }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open downloads")
                }
                signInPill
            }
            .padding(.horizontal, 16).padding(.top, 0).padding(.bottom, 14)
            fadingLine
        }
    }

    /// A quiet ring beside the sign-in pill while a download runs: grey, filling blue, with an arrow.
    private var downloadRing: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, min(1, store.ringProgress)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: store.isPaused ? "pause.fill" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(store.ringDone ? Color.accentColor : Color.secondary)
        }
        .frame(width: 26, height: 26)
        .animation(.easeOut(duration: 0.3), value: store.ringProgress)
        .accessibilityLabel(store.ringDone ? "Download finished" : "Downloading \(percentText(store.ringProgress))")
    }

    /// The artwork lives in the asset catalogue: a white one for the dark appearance, a black one
    /// for the light one. Until those images are added, the old mark stands in.
    @ViewBuilder private var brandLogo: some View {
        let name = colorScheme == .dark ? "LogoOnDark" : "LogoOnLight"
        if UIImage(named: name) != nil {
            Image(name)
                .resizable().scaledToFit()
                .frame(height: logoHeight)
                // The version sits under the wordmark: clear of the mark on the left, on the same
                // baseline as the bottom of that mark, starting at the "M" of ModShelf.
                .overlay(alignment: .bottomLeading) {
                    versionBadge.padding(.leading, logoWidth * 0.29)
                }
                .accessibilityLabel("ModShelf")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text("ModShelf").font(.system(size: 20, weight: .bold, design: .rounded))
            }
        }
    }

    /// "v1.0" sits under the wordmark, aligned with the bottom of the mark beside it.
    private var versionBadge: some View {
        Text("v\(modShelfVersion)")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Version \(modShelfVersion)")
    }

    /// The logo's size, so the version can be placed relative to the artwork inside it.
    private let logoHeight: CGFloat = 34
    private let logoAspect: CGFloat = 1121.0 / 317.0
    private var logoWidth: CGFloat { logoHeight * logoAspect }

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
            let tint: Color = isError ? .orange : Color.accentColor
            HStack(alignment: .center, spacing: 10) {
                if store.isExporting || store.isCheckingUpdates || store.isVerifyingAll {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 18)
                } else {
                    Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isError ? "That didn't finish" : bannerTitle)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    if isError { store.errorMessage = "" } else { store.operationMessage = "" }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            .padding(.horizontal, 14).padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            fadingLine
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
    }

    /// Turns raw engine text into one short line a person can act on.
    private func friendlyError(_ raw: String) -> String {
        ErrorText.friendly(raw)
    }

    /// The heading of the info banner, so it names what is actually running.
    private var bannerTitle: String {
        if store.isExporting { return "Building a ZIP" }
        if store.isVerifyingAll { return "Validating files" }
        if store.isCheckingUpdates { return "Checking for updates" }
        if store.isDownloading { return "Downloading" }
        if store.isBusy { return "Please wait" }
        return "Status"
    }

    /// A percent that can never trap: a missing or infinite figure reads as 0%.
    private func percentText(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return "\(Int(max(0, min(1, fraction)) * 100))%"
    }

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
                    Text(store.isPreparingDownload
                         ? "Initialising…"
                         : (store.isInstalling ? "Installing…" : percentText(store.progress)))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Button { store.cancel() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel download")
                }
                progressBar(store.progress)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.top, 8)
        }
    }

    // MARK: scrolling → tab bar shrink

    private func handleScroll(_ y: CGFloat) {
        guard tabStyle == "pill" else { return }
        let delta = y - scrollTracker.lastY
        scrollTracker.lastY = y
        if y > -8 {
            // At the top the bar always opens.
            if tabCollapsed { tabCollapsed = false }
            scrollTracker.upRun = 0
            return
        }
        if delta < 0 {
            // Scrolling down: fold once past the first part of the page, and stay folded.
            scrollTracker.upRun = 0
            if y < -40 && !tabCollapsed { tabCollapsed = true }
        } else if delta > 0 {
            // Scrolling up: only open after a real upward run, so small bounces don't reopen it.
            scrollTracker.upRun += delta
            if scrollTracker.upRun > 40 && tabCollapsed { tabCollapsed = false; scrollTracker.upRun = 0 }
        }
    }

    private func tabTapped(_ index: Int) {
        if index == 0 {
            // Two taps on the Download tab take the mod on display away and return to the default view.
            let now = Date()
            let gap = now.timeIntervalSince(lastDownloadTap)
            if selectedTab == 0, gap > 0.08, gap < 0.45, !store.isBusy, store.preview != nil {
                store.clearDisplayedMod()
                inputWasSubmitted = false
                Haptics.tap()
                lastDownloadTap = .distantPast
                return
            }
            lastDownloadTap = now
            lastWorkshopTap = .distantPast
            return
        }
        guard index == 1 else {
            lastWorkshopTap = .distantPast
            lastDownloadTap = .distantPast
            return
        }
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
            downloadScroll
        }
    }

    /// The ScrollView is kept apart from its modifiers, so no single expression has to carry the
    /// whole tab: a type that big overflows the main thread's stack while it is being built.
    private var downloadScroll: some View {
        downloadColumn
            .coordinateSpace(name: "scroll")
            .scrollDisabled(dragRowID != nil)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
    }

    private var downloadColumn: some View {
        ScrollView {
            VStack(spacing: 0) {
                ScrollSpy(onChange: handleScroll)
                downloadCards
            }
            .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, tabBarReserve)
        }
    }

    /// One group of cards per property, so the tab is built from a handful of small view types.
    private var downloadCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            downloadLookupCards
            downloadPreviewCards
            downloadControlCards
            downloadQueueCards
        }
    }

    @ViewBuilder private var downloadLookupCards: some View {
        if downloadIntro { downloadHeader }
        lookupCard
    }

    @ViewBuilder private var downloadPreviewCards: some View {
        if store.isFetching { downloadLoadingRow }
        if let item = store.preview,
           !store.queueRows.contains(where: { $0.id == item.id }) {
            if store.isBusy || store.isPaused { queuedDownloadCard(item) }
            downloadButton(item)
        }
    }

    private var downloadLoadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading Workshop details…").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var downloadControlCards: some View {
        if store.isDownloading || store.isPaused { downloadControlTiles }
        if downloadIntro { glanceCard }
    }

    private var downloadControlTiles: some View {
        HStack(spacing: 10) {
            downloadControlTile(symbol: store.isPaused ? "play.fill" : "pause.fill",
                                title: store.isPaused ? "Resume" : "Pause",
                                action: { store.togglePause() })
            downloadControlTile(symbol: "xmark", title: "Cancel",
                                action: { store.cancel() })
        }
    }

    private func downloadControlTile(symbol: String, title: String,
                                     action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var downloadQueueCards: some View {
        if !store.isDownloading, store.queueRows.isEmpty, let item = store.preview {
            metadataCard(item)
        }
        if !store.queueRows.isEmpty { queueCard }
    }

    /// Taps on the logo are counted silently; nothing in the app suggests they lead anywhere.
    private func logoTapped() {
        let now = Date()
        if now.timeIntervalSince(lastLogoTap) > 1.5 { logoTapCount = 0 }
        lastLogoTap = now
        logoTapCount += 1
        if logoTapCount >= 20 {
            logoTapCount = 0
            devUnlocked = true
            showDeveloperMenu = true
            store.log("developer menu unlocked")
        }
    }

    /// The running batch: what it is on, a line of progress for the whole set, then a row per mod.
    private var queueCard: some View {
        queueCardBody
            .padding(.bottom, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            // A drag must never outlive the rows it was moving, or scrolling would stay switched off.
            .onDisappear { endReorder() }
            .onChange(of: store.queueRows.count) { _ in
                if dragRowID != nil, !store.queueRows.contains(where: { $0.id == dragRowID }) { endReorder() }
            }
    }

    private var queueCardBody: some View {
        let active = store.queueRows.filter { $0.state != .failed }
        return VStack(alignment: .leading, spacing: 0) {
            if store.queueTotal > 1 { queueCardHeader }
            queueRowsList(active: active)
                .padding(.top, store.queueTotal > 1 ? 6 : 2)
        }
    }

    private var queueCardHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08))
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)
            Text(queueHeadline)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(percentText(queueOverallProgress))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 46)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Button { Haptics.tap(); store.cancel() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel downloads")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private func queueRowsList(active: [DownloadQueueRow]) -> some View {
        let failed = store.queueRows.filter { $0.state == .failed }
        return VStack(spacing: 0) {
            ForEach(Array(active.enumerated()), id: \.element.id) { index, row in
                if index > 0, !(dragRowID != nil && dragTarget == index) {
                    Divider().padding(.horizontal, 14)
                }
                if dragRowID != nil, dragTarget == index { dropLine }
                queueRow(row, index: index, count: active.count)
            }
            if !failed.isEmpty {
                if !active.isEmpty { Divider().padding(.horizontal, 14) }
                queueFailedHeader
                ForEach(Array(failed.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    queueRow(row)
                }
            }
        }
    }

    private var queueFailedHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
            Text("Didn't finish")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }

    private func endReorder() {
        dragRowID = nil
        dragOffsetY = 0
        dragTarget = nil
    }

    private var queueHeadline: String {
        if store.queueTotal == 0 { return "Finished" }
        if store.queueTotal > 1 {
            return "Downloading \(min(store.queueStep, store.queueTotal)) of \(store.queueTotal)"
        }
        return "Downloading"
    }

    private var queueSubline: String {
        let done = store.queueRows.filter { $0.state == .done }.count
        let failed = store.queueRows.filter { $0.state == .failed }.count
        let waiting = store.queueRows.filter { $0.state == .waiting }.count
        if failed > 0 { return "\(done) done · \(failed) didn't finish" }
        if waiting > 0 { return "\(done) done · \(waiting) waiting" }
        if done == store.queueRows.count, !store.queueRows.isEmpty { return "All done" }
        return "\(done) of \(store.queueRows.count) done"
    }

    /// How far the whole batch has come, weighted by each mod's size.
    private var queueOverallProgress: Double {
        guard !store.queueRows.isEmpty else { return 0 }
        let weights = store.queueRows.map { max(1, Double($0.fileSize)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var done = 0.0
        for (index, row) in store.queueRows.enumerated() {
            let fraction = row.state == .done ? 1 : min(1, max(0, row.progress))
            done += weights[index] * fraction
        }
        return min(1, done / total)
    }

    private func queueTint(_ row: DownloadQueueRow) -> Color {
        switch row.state {
        case .done: return .green
        case .failed: return .red
        case .waiting: return .secondary
        case .downloading:
            if store.isPreparingDownload || store.isInstalling || store.isDownloadStalled { return .secondary }
            return .accentColor
        }
    }

    /// How much room one row takes, so a drag can tell which slot the finger is over.
    private let queueRowSpan: CGFloat = 104

    private func queueRow(_ row: DownloadQueueRow, index: Int? = nil, count: Int = 0) -> some View {
        queueRowBody(row, index: index, count: count)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dragRowID == row.id ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear)
            )
            .offset(y: dragRowID == row.id ? dragOffsetY : 0)
            .zIndex(dragRowID == row.id ? 1 : 0)
            .shadow(color: dragRowID == row.id ? .black.opacity(0.16) : .clear,
                    radius: dragRowID == row.id ? 9 : 0, y: dragRowID == row.id ? 4 : 0)
            .animation(.easeOut(duration: 0.18), value: dragTarget)
    }

    private func queueRowBody(_ row: DownloadQueueRow, index: Int?, count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let index, row.state != .failed, count > 1 {
                dragHandle(row, index: index, count: count)
                    .frame(height: 84)
            }
            Color.clear
                .frame(width: 84, height: 84)
                .overlay(CachedImage(urlString: row.imageURL, fill: false, maxPixel: 320).allowsHitTesting(false))
            queueRowText(row)
            queueRowActions(row)
        }
    }

    private func queueRowText(_ row: DownloadQueueRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                MarqueeText(text: row.title, fontSize: 14, weight: .semibold, height: 18,
                            speed: MarqueeSpeed.otherSpeed,
                            active: row.state == .downloading && MarqueeSpeed.otherRunning)
                if let game = row.gameName, !game.isEmpty {
                    Text(game).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                queueStatusText(row)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(queueTint(row))
                    .lineLimit(1)
            }
            // The percent sits on the line under the state, where it has room to be read.
            queuePercent(row)
                .padding(.top, 2)
                .frame(height: 14, alignment: .leading)
            Spacer(minLength: 0)
            queueBar(row)
        }
        .frame(height: 84)
    }

    private func queueRowActions(_ row: DownloadQueueRow) -> some View {
        HStack(spacing: 8) {
            if row.state == .failed {
                Button { Haptics.tap(); store.download(row.id) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 22)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry download")
            }
            Button { Haptics.tap(); store.cancelItem(row.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel this download")
        }
        .frame(height: 84, alignment: .center)
    }

    /// Two grey lines on a grey pill: enough of a grip to be found, quiet enough to stay out of the way.
    private func dragHandle(_ row: DownloadQueueRow, index: Int, count: Int) -> some View {
        VStack(spacing: 3) {
            Capsule().fill(Color.primary.opacity(0.24)).frame(width: 11, height: 2)
            Capsule().fill(Color.primary.opacity(0.24)).frame(width: 11, height: 2)
        }
        .frame(width: 20, height: 30)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
        .contentShape(Capsule(style: .continuous))
        .highPriorityGesture(reorderGesture(row, index: index, count: count))
        .accessibilityLabel("Move \(row.title) in the queue")
    }

    /// A hold on the grip picks the row up, and the drag that follows slides it within the card.
    private func reorderGesture(_ row: DownloadQueueRow, index: Int, count: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if dragRowID != row.id {
                    dragRowID = row.id
                    dragOffsetY = 0
                    dragTarget = index
                    Haptics.medium()
                }
                let low: CGFloat = -CGFloat(index) * queueRowSpan
                let high = max(low, CGFloat(count - 1 - index) * queueRowSpan)
                dragOffsetY = min(max(drag.translation.height, low), high)
                let steps = Int((dragOffsetY / queueRowSpan).rounded())
                let target = max(0, min(count - 1, index + steps))
                if target != dragTarget {
                    dragTarget = target
                    Haptics.select()
                }
            }
            .onEnded { _ in
                guard dragRowID == row.id else { return }
                finishReorder(row, to: dragTarget ?? index)
            }
    }

    /// Puts the row where the blue line was, and asks first when that means stopping a running one.
    private func finishReorder(_ row: DownloadQueueRow, to target: Int) {
        dragRowID = nil
        dragOffsetY = 0
        dragTarget = nil
        let order = store.queueRows.filter { $0.state != .failed }
        guard target >= 0, target < order.count,
              let from = store.queueRows.firstIndex(where: { $0.id == row.id }) else { return }
        let to = store.queueRows.firstIndex(where: { $0.id == order[target].id }) ?? from
        guard to != from else { return }
        Haptics.tap()
        if row.state == .waiting, order[target].id == store.activeID,
           store.isDownloading || store.isPaused {
            confirmReorder = ReorderRequest(id: row.id, title: row.title)
            return
        }
        store.moveRow(row.id, to: to)
    }

    /// The line that shows where a row picked up by its grip will land.
    private var dropLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .transition(.opacity)
    }

    /// The percent for one row, on the line under its state.
    @ViewBuilder private func queuePercent(_ row: DownloadQueueRow) -> some View {
        if row.state == .done
            || (row.state == .downloading && !store.isPreparingDownload) {
            Text(percentText(row.progress))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(queueTint(row))
        } else {
            Color.clear.frame(height: 14)
        }
    }

    private func queueBar(_ row: DownloadQueueRow) -> some View {
        let fraction = row.state == .done ? 1 : min(1, max(0, row.progress))
        let tint = queueTint(row)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.opacity(row.state == .waiting ? 0.4 : 1))
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder private func queueStatusText(_ row: DownloadQueueRow) -> some View {
        if row.state == .failed { Text("Failed") }
        else if row.state == .done { Text("Done") }
        else if row.state == .waiting { Text("Waiting") }
        else if store.isPreparingDownload { Text("Initialising…") }
        else if store.isInstalling { Text("Installing…") }
        else if store.isDownloadStalled { Text("Waiting") }
        else { Text("Downloading") }
    }

    private var inputIsInvalid: Bool { inputWasSubmitted && WorkshopStore.workshopID(from: store.input) == nil }

    private var lookupCard: some View {
        VStack(spacing: 8) {
            Button { selectedTab = 1 } label: {
                HStack(spacing: 10) {
                    Image(systemName: "safari.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Browse the Workshop").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("URL or ID…", text: $store.input)
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
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// True while the Download tab has nothing on it, so the intro shows only then.
    private var downloadIntro: Bool {
        store.preview == nil && !store.isDownloading && store.queueRows.isEmpty
    }

    /// The heading of the empty tab. Its icon stays neutral so the accent colour is kept for actions.
    private var downloadHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Download a Workshop mod").font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Paste a link into the box below, or browse the Workshop to find one.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Three numbers at a glance: what is installed, how many games it covers and how many have an
    /// update, plus the storage the library takes and what is left on the device.
    private var glanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AT A GLANCE")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .kerning(0.4)
            HStack(spacing: 10) {
                glanceStat("\(store.library.count)", "mods")
                glanceStat("\(gameCount)", gameCount == 1 ? "game" : "games")
                glanceStat("\(updateCount)", "updates")
            }
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.85))
                            .frame(width: max(2, geo.size.width * storageFraction))
                    }
                }
                .frame(height: 6)
                Text("\(Fmt.bytes(store.libraryStorageBytes)) on this device · \(Fmt.bytes(freeSpaceBytes)) free")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func glanceStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var freeSpaceBytes: Int64 {
        freeSpaceCache
    }

    /// Reading free space touches the file system, so it is done when the app opens or returns rather
    /// than on every redraw of the card that shows it.
    private func refreshFreeSpace() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeSpaceCache = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private var storageFraction: Double {
        let used = Double(store.libraryStorageBytes)
        let total = used + Double(freeSpaceBytes)
        guard total > 0 else { return 0 }
        return min(1, used / total)
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

    /// The mod that a button is about to add to the queue, with its name visible while another
    /// download runs. Without it the Download tab only showed the lookup field.
    private func queuedDownloadCard(_ item: WorkshopMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Color.clear
                    .frame(width: 84, height: 84)
                    .overlay(CachedImage(urlString: item.imageURL, fill: false, maxPixel: 320).allowsHitTesting(false))
                VStack(alignment: .leading, spacing: 5) {
                    MarqueeText(text: item.title, fontSize: 15, weight: .semibold, height: 19,
                                speed: MarqueeSpeed.otherSpeed, active: MarqueeSpeed.otherRunning)
                    RatingLine(rating: item.rating, count: item.ratingCount, size: 13)
                    if let game = item.gameName, !game.isEmpty {
                        Text(game).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 84)
            }
            HStack(spacing: 6) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 11, weight: .semibold))
                Text("Queued behind the download that is running")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private func downloadButton(_ item: WorkshopMetadata) -> some View {
        let existing = store.library.first(where: { $0.id == item.id })
        var label = "Download mod"
        if store.isBusy || store.isPaused { label = "Add to queue" }
        else if let existing { label = existing.updateAvailable ? "Update mod" : "Download again" }
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
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
            .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)
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
            if !item.description.isEmpty { ExpandableDescription(text: item.description, lineLimit: 8) }
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
                libraryBar
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

    /// The library's top area: search and the select toggle, then sort, filter and the counts, with
    /// the actions as a row of labelled tiles below.
    private var libraryBar: some View {
        VStack(spacing: 8) {
            if showingHistory {
                HStack(spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search history", text: $historySearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !historySearch.isEmpty {
                            Button { historySearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    libraryIconTile("trash") { if confirmDelete { confirmClearHistory = true } else { store.clearHistory() } }
                        .disabled(store.history.isEmpty)
                        .opacity(store.history.isEmpty ? 0.5 : 1)
                    libraryIconTile("xmark") { showingHistory = false }
                }
            } else {
                HStack(spacing: 8) {
                    sortMenu
                    filterMenu
                    Spacer(minLength: 0)
                    Text(librarySubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 8) {
                    libraryAction("arrow.clockwise", "Updates", spinning: store.isCheckingUpdates) { store.checkAllUpdates() }
                        .disabled(store.isCheckingUpdates)
                    libraryAction("checkmark.shield", "Verify", spinning: store.isVerifyingAll) { store.verifyAllFiles() }
                        .disabled(store.isVerifyingAll)
                    libraryAction("clock.arrow.circlepath", "History") { showingHistory = true }
                    moreMenu
                }
                HStack(spacing: 8) {
                    librarySearchField
                    selectPill
                    if !installedGameOptions.isEmpty { gameFilterMenu }
                    if !installedTagOptions.isEmpty { tagFilterMenu }
                }
            }
        }
        .padding(.horizontal, 15).padding(.top, 6).padding(.bottom, 8)
    }

    /// A single icon in the same grey tile as the other library controls.
    private func libraryIconTile(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 34)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func libraryAction(_ symbol: String, _ label: String, spinning: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            libraryActionLabel(symbol, label, spinning: spinning)
        }
        .buttonStyle(.plain)
    }

    private func libraryActionLabel(_ symbol: String, _ label: String, spinning: Bool = false) -> some View {
        VStack(spacing: 3) {
            Group {
                if spinning {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 17)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func filterSymbol(_ filter: String) -> String {
        switch filter {
        case "Updates": return "arrow.down.circle"
        case "Favourites": return "star.fill"
        case "Problems": return "exclamationmark.triangle"
        default: return "line.3.horizontal.decrease.circle"
        }
    }

    private func filterTint(_ filter: String) -> Color {
        .secondary
    }

    /// The library filter as a chip whose icon has no backing of its own, with the chosen filter named.
    private var filterMenu: some View {
        Menu {
            ForEach(["All", "Updates", "Favourites", "Problems"], id: \.self) { name in
                Button {
                    Haptics.select(); libraryFilter = name
                } label: {
                    if libraryFilter == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                if libraryFilter != "All" {
                    Text("•").font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                    Image(systemName: filterSymbol(libraryFilter))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(filterTint(libraryFilter))
                }
                // The chosen filter is always named in full: the chip grows, it never clips.
                Text(libraryFilter)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Array(sortGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { order in
                    Button {
                        Haptics.select(); sortOrder = order
                    } label: {
                        if order == sortOrder { Label(order, systemImage: "checkmark") } else { Text(order) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(sortOrder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var moreMenu: some View {
        Menu {
            if selecting {
                Button { selectAllVisible() } label: { Label("Select all", systemImage: "checkmark.circle") }
                Button { selection.removeAll() } label: { Label("Deselect all", systemImage: "circle.dashed") }
                Divider()
                Button { exportSelection() } label: {
                    Label(selection.isEmpty ? "Export as ZIP" : "Export selected (\(selection.count)) as ZIP", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty || store.isExporting)
                Button(role: .destructive) { requestDeleteSelected() } label: {
                    Label("Delete selected (\(selection.count))", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            } else {
                let pending = store.library.filter { $0.updateAvailable }.count
                Button { store.updateAll(); selectedTab = 0 } label: { Label("Update all (\(pending))", systemImage: "arrow.down.circle") }
                    .disabled(pending == 0 || store.isBusy)
                Button { startExportSelection() } label: { Label("Select and export as ZIP", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(store.library.isEmpty || store.isExporting)
                Button { beginExport(all: true) } label: { Label(store.isExporting ? "Exporting…" : "Export all as ZIP", systemImage: "square.and.arrow.up") }
                    .disabled(store.library.isEmpty || store.isExporting)
                Button {
                    UIPasteboard.general.string = store.library.map(\.id).joined(separator: "\n")
                    Haptics.success()
                    store.operationMessage = "Copied \(store.library.count) Workshop ID\(store.library.count == 1 ? "" : "s")."
                } label: {
                    Label("Copy all Workshop IDs", systemImage: "doc.on.doc")
                }
                .disabled(store.library.isEmpty)
            }
        } label: {
            VStack(spacing: 3) {
                Group {
                    if selecting { SelectionWaveDots() } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 17)
                Text(selecting ? "Done" : "More")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var librarySearchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search library", text: $searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var libraryBody: some View {
        VStack(spacing: 0) {
            if !store.library.isEmpty { }
            let items = visibleItems
            if store.library.isEmpty {
                emptyState("Your library is empty", detail: "Downloaded mods will appear here, go to the workshop to pick some up.", symbol: "square.grid.2x2")
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
        case "Problems": return store.library.filter { $0.status.needsAttention }.count
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
        EmptyView()
    }

    /// The game and tag filters, icon-only beside the search box like the select toggle.
    private var gameFilterMenu: some View {
        Menu {
            Button { Haptics.select(); selectedGame = nil; selectedTag = nil } label: {
                if selectedGame == nil { Label("All games", systemImage: "checkmark") } else { Text("All games") }
            }
            Divider()
            ForEach(installedGameOptions, id: \.id) { game in
                Button { Haptics.select(); selectedGame = game.id; selectedTag = nil } label: {
                    if selectedGame == game.id { Label(game.name, systemImage: "checkmark") } else { Text(game.name) }
                }
            }
        } label: { filterIconLabel("gamecontroller.fill") }
    }

    private var tagFilterMenu: some View {
        Menu {
            Button { Haptics.select(); selectedTag = nil } label: {
                if selectedTag == nil { Label("All tags", systemImage: "checkmark") } else { Text("All tags") }
            }
            Divider()
            ForEach(installedTagOptions, id: \.self) { tag in
                Button { Haptics.select(); selectedTag = tag } label: {
                    if selectedTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                }
            }
        } label: { filterIconLabel("tag.fill") }
    }

    private func filterIconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 20, height: 18)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        // Pull the grid down to check every mod's Workshop state.
        .refreshable { store.checkAllUpdates() }
    }

    private func listContent(_ items: [WorkshopItem]) -> some View {
        List {
            ScrollSpy(onChange: handleScroll)
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(items) { item in
                listRow(item)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color(uiColor: .systemGroupedBackground))
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
        // Pull the list down to check every mod's Workshop state.
        .refreshable { store.checkAllUpdates() }
    }

    private func dateLine(_ item: WorkshopItem) -> (String, Color) {
        switch item.status {
        case .broken: return ("Files don't match Steam", Color.yellow)
        case .needsUpdate: return ("New update available", Color.accentColor)
        case .notChecked: return (item.checkFailed ? "Couldn't reach Steam" : "Not checked yet", Color.secondary)
        case .upToDate, .moved: break
        }
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
                .contentShape(Rectangle())
                    .overlay(Rectangle()
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
                    MarqueeText(text: item.displayTitle, fontSize: 14, weight: .semibold,
                                height: 17, speed: MarqueeSpeed.librarySpeed,
                                active: selectedTab == 2 && MarqueeSpeed.libraryRunning,
                                restartToken: marqueeToken)
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
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.06)))
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
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: picked ? 3 : 0))
                    VStack(alignment: .leading, spacing: 4) {
                        MarqueeText(text: item.displayTitle, fontSize: 15, weight: .semibold, height: 19,
                                    speed: MarqueeSpeed.librarySpeed, active: MarqueeSpeed.libraryRunning)
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
                    .frame(height: 84)
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
                VStack(spacing: 0) {
                    if filteredHistory.isEmpty {
                        emptyState("Nothing matches", detail: "No attempt matches “\(historySearch)”.", symbol: "magnifyingglass")
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ScrollSpy(onChange: handleScroll)
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredHistory) { record in
                                        historyRow(record)
                                        Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 0.5).padding(.leading, 83)
                                    }
                                }
                                .padding(.bottom, tabBarReserve)
                            }
                        }
                        .coordinateSpace(name: "scroll")
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
        }
    }

    /// History rows that match the search box: title, Workshop ID or game.
    private var filteredHistory: [DownloadRecord] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.history }
        return store.history.filter { record in
            record.title.localizedCaseInsensitiveContains(query)
                || record.workshopID.contains(query)
                || (record.gameName ?? "").localizedCaseInsensitiveContains(query)
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
        return HStack(alignment: .center, spacing: 12) {
            Color.clear.frame(width: 84, height: 84)
                .overlay(CachedImage(urlString: record.imageURL, fill: true, maxPixel: 300))
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(text: record.title, fontSize: 15, weight: .semibold, height: 19,
                            speed: MarqueeSpeed.otherSpeed, active: MarqueeSpeed.otherRunning)
                HStack(spacing: 5) {
                    if let game = record.gameName, !game.isEmpty {
                        Text(game).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Text("•").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    TimelineView(.everyMinute) { _ in
                        Text(Fmt.historyTime(record.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    StatusGlyph(status: historyStatus(record), size: 12)
                    Text(record.result).font(.system(size: 12, weight: .medium)).foregroundStyle(historyColor(record.result))
                }
                if failed, let error = record.error, !error.isEmpty {
                    MarqueeText(text: error, fontSize: 12, weight: .regular, height: 16,
                                speed: MarqueeSpeed.otherSpeed, active: MarqueeSpeed.otherRunning,
                                color: .systemRed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 84)
            VStack(spacing: 8) {
                navCircle("arrow.clockwise") { store.retry(record); selectedTab = 0 }
                navCircle("ellipsis") { contextHistory = record }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    private func historyStatus(_ record: DownloadRecord) -> ModStatus {
        switch record.result {
        case "Downloaded": return .upToDate
        case "Failed": return .broken
        case "Cancelled": return .moved
        default: return .notChecked
        }
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
                    appearanceSettings
                    downloadsSettings
                    browserSettings
                    steamAccountSettings
                    aboutSettings
                    creditsSettings
                }
                .padding(.horizontal, 15)
                .padding(.bottom, tabBarReserve)
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
                toggleRow("Haptic feedback", symbol: "hand.tap", isOn: $haptics)
                divider
                toggleRow("One speed for all scrolling text", symbol: "textformat", isOn: $marqueeGlobal)
                divider
                marqueeSpeedRow("Scrolling text speed", value: $marqueeSpeed)
                if !marqueeGlobal {
                    divider
                    marqueeSpeedRow("Library scrolling speed", value: $marqueeSpeedLibrary)
                    divider
                    marqueeSpeedRow("Everything else", value: $marqueeSpeedOther)
                }
            }
        )
    }

    private var browserSettings: AnyView {
        AnyView(
            settingsGroup("Browser") {
                toggleRow("Auto download from browser", symbol: "arrow.down.circle", isOn: $autoDownload)
                divider
                toggleRow("Confirm auto download", symbol: "checkmark.circle", isOn: $confirmAutoDownload)
                divider
                Button { Haptics.tap(); confirmClearViewed = true } label: {
                    rowContent("Clear recently viewed mods in the browser", symbol: "trash", detail: nil)
                }
                .buttonStyle(.plain)
            }
        )
    }

    private var downloadsSettings: AnyView {
        AnyView(
            settingsGroup("Downloads") {
                toggleRow("Confirm before deleting", symbol: "trash", isOn: $confirmDelete)
                divider
                toggleRow("Check mod updates on launch", symbol: "arrow.clockwise", isOn: $autoCheck)
                divider
                toggleRow("Wi-Fi only downloads", symbol: "wifi", isOn: $wifiOnly)
                divider
                toggleRow("Write info file into each mod", symbol: "doc.text", isOn: $infoFile)
                divider
                HStack(spacing: 10) {
                    rowContent("Mod folder", symbol: "folder", detail: store.downloadsFolderLabel, chevron: false)
                    Button { Haptics.tap(); store.revealFolder(store.downloadsFolderURL) } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the mod folder")
                }
                .padding(.trailing, 12)
                divider
                Button { Haptics.tap(); store.clearTemporaryFiles() } label: {
                    rowContent("Clear temporary files", symbol: "trash.slash", detail: nil)
                }.buttonStyle(.plain)
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

    private var aboutSettings: AnyView {
        AnyView(
            settingsGroup("About") {
                Button { Haptics.tap(); store.checkForAppUpdate() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for app updates").font(.system(size: 16))
                            if !store.appUpdateMessage.isEmpty {
                                Text(store.appUpdateMessage).font(.system(size: 12))
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("v\(modShelfVersion)").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("build \(modShelfBuild)").font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 15).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isCheckingAppUpdate)

                divider
                linkRow("GitHub", symbol: "chevron.left.forwardslash.chevron.right", detail: WorkshopStore.appRepo,
                        url: "https://github.com/\(WorkshopStore.appRepo)")
                divider
                linkRow("Report a bug", symbol: "ladybug", detail: nil,
                        url: "https://github.com/\(WorkshopStore.appRepo)/issues/new?template=bug_report.yml")
                divider
                linkRow("Request a feature", symbol: "lightbulb", detail: nil,
                        url: "https://github.com/\(WorkshopStore.appRepo)/issues/new?template=feature_request.yml")
                divider
                linkRow("Support ModShelf", symbol: "heart", detail: "ko-fi.com/shplash", url: "https://ko-fi.com/shplash")
            }
        )
    }

    private func linkRow(_ title: String, symbol: String, detail: String?, url: String) -> some View {
        Button {
            Haptics.tap()
            if let link = URL(string: url) { UIApplication.shared.open(link) }
        } label: {
            rowContent(title, symbol: symbol, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private var creditsSettings: AnyView {
        AnyView(
            settingsGroup("Credits") {
                creditLicenseRow("ModShelf", "Created by Splash (@shplash)", license: "MPL-2.0 License")
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

    /// A speed's value on the right, with its slider underneath. The bottom step is Off.
    private func marqueeSpeedRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 0) {
            row(title, symbol: "speedometer") {
                Text(value.wrappedValue < 0.25 ? "Off" : String(format: "%.2f×", value.wrappedValue))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: { new in
                // Off is one step below the slowest speed, not a stretch of dead slider.
                value.wrappedValue = new < 0.25 ? 0 : max(0.25, new)
            }), in: 0...2, step: 0.05)
                .tint(.accentColor)
                .padding(.leading, 51).padding(.trailing, 15).padding(.bottom, 12)
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

    private func rowContent(_ title: String, symbol: String, detail: String?, tint: Color = .primary, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint == .primary ? Color.secondary : tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if tint == .primary && chevron { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
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
    let onUpdate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                // Bigger artwork, with the text block matching its height: the name sits on the top
                // edge and the state on the bottom edge.
                CachedImage(urlString: item.imageURL, fill: true, maxPixel: 400)
                    .frame(width: 108, height: 108).clipShape(Rectangle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    RatingLine(rating: item.rating, count: item.ratingCount, size: 13)
                    if let game = item.gameName { Text(game).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) {
                        StatusGlyph(status: item.status, size: 15)
                        Text(statusText).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.status.textColor)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.top, 1)
                }
                .frame(height: 108, alignment: .top)
                .padding(.trailing, 28)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .accessibilityLabel("Close")
            }
            if let d = item.description, !d.isEmpty {
                ScrollView { ExpandableDescription(text: d, lineLimit: 18) }.frame(maxHeight: 360)
            }
            if !item.tags.isEmpty {
                Text("Tags: " + item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(installedLine)
                if let verified = item.lastVerifiedAt {
                    Text((item.isInsideModShelf ? "Files last checked " : "Last known good ") + Fmt.date(verified))
                }
                if showIDs {
                    Text("Workshop ID \(item.id)").font(.system(size: 12, design: .monospaced))
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Haptics.tap(); onOpenWorkshop() } label: {
                    Label("Workshop", systemImage: "safari").font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.14)))
                }.buttonStyle(.plain)
                if item.updateAvailable {
                    Button { Haptics.medium(); onUpdate() } label: {
                        Label("Update", systemImage: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.orange))
                    }.buttonStyle(.plain)
                } else if item.filesBroken {
                    // A mod whose files no longer match Steam can only be put right by fetching it again.
                    Button { Haptics.medium(); onUpdate() } label: {
                        Label("Reinstall", systemImage: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.orange))
                    }.buttonStyle(.plain)
                }
                Button { Haptics.tap(); store.revealInFiles(item) } label: {
                    Image(systemName: "folder").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42).background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.12)))
                }.buttonStyle(.plain).accessibilityLabel("Reveal in Files")
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

    private var installedLine: String {
        var text = "Installed \(Fmt.date(item.addedAt))"
        if let files = item.fileCount { text += " · \(files) files" }
        if let bytes = item.byteCount { text += " · \(Fmt.bytes(bytes))" }
        return text
    }

    private var statusText: String {
        switch item.status {
        case .upToDate: return "Up to date"
        case .needsUpdate: return "Update available"
        case .moved: return "Files elsewhere"
        case .notChecked: return item.checkFailed ? "Couldn't reach Steam" : "Not checked yet"
        case .broken: return "Files don't match Steam"
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
            if item.updateAvailable {
                action("Update now", "arrow.down.circle", favourite: false, action: updateNow)
            } else {
                action("Check for updates", "arrow.clockwise", favourite: false, action: checkUpdates)
                // A mod whose files were damaged can only be put right by fetching it again.
                if item.filesBroken { action("Download again", "arrow.down.circle", favourite: false, action: updateNow) }
            }
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
            Text("The downloaded files will be removed from this device. You can download the mod again later.")
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
                            // Images and GIFs zoom in place; videos never do.
                            ZoomableCarouselImage(urlString: url, onTap: {
                                Haptics.tap()
                                onExpand(item, i)
                            })
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
/// pan gesture is off, so a sideways swipe still moves the pager to the next page. Only images and
/// GIFs use this; videos are always plain players.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var animate = false
    /// Called for a single tap while the image is not zoomed in.
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> ZoomImageView {
        let view = ZoomImageView()
        view.set(image: image, animated: animate)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ZoomImageView, context: Context) {
        context.coordinator.onTap = onTap
        if view.shownImage !== image { view.set(image: image, animated: animate) }
    }

    final class Coordinator {
        var onTap: (() -> Void)?
        weak var view: ZoomImageView?

        init(onTap: (() -> Void)?) { self.onTap = onTap }

        func attach(to view: ZoomImageView) {
            self.view = view
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
            singleTap.require(toFail: doubleTap)
            view.addGestureRecognizer(singleTap)
        }

        @objc private func singleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view, view.zoomScale <= 1.01 else { return }
            onTap?()
        }

        @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            view.toggleZoom(at: gesture.location(in: view.imageView))
        }
    }
}

/// An image or GIF in the downloads carousel, with the same pinch-to-zoom as the full-screen
/// viewer. A tap while it is not zoomed opens the full-screen viewer.
struct ZoomableCarouselImage: View {
    let urlString: String?
    var onTap: () -> Void
    @AppStorage("options.gifDownloads") private var gifDownloads = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, animate: image.images != nil && gifDownloads, onTap: onTap)
            } else {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .task(id: (urlString ?? "") + (gifDownloads ? "|1" : "|0")) {
            guard let s = urlString, !s.isEmpty, let url = URL(string: s) else { image = nil; return }
            if let hit = ImageStore.shared.cached(url, animate: gifDownloads) { image = hit; return }
            image = await ImageStore.shared.load(url, maxPixel: 1000, animate: gifDownloads)
        }
    }
}

final class ZoomImageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
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

    func toggleZoom(at point: CGPoint) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
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
        // A video is never zoomable: no pinch, no rubber-banding, no page scale.
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 1
        view.scrollView.bouncesZoom = false
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.scrollView.isMultipleTouchEnabled = false
        view.navigationDelegate = links
        view.uiDelegate = links
        view.loadHTMLString(Self.page(id), baseURL: URL(string: Self.origin))
        webView = view
        loadedID = id
        return view
    }

    private static func page(_ videoID: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
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

/// Opens "Watch on YouTube", the video's logo and similar links in the YouTube app instead of
/// inside the player. The logo opens a new window, so the UI delegate answers that too.
final class YouTubeLinkHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, Self.shouldLeavePlayer(url) {
            Self.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isYouTube(url) { Self.open(url) }
        return nil
    }

    static func isYouTube(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// A YouTube page that is not the player itself: the video page, a channel, the logo's link.
    static func shouldLeavePlayer(_ url: URL) -> Bool {
        guard isYouTube(url) else { return false }
        let host = url.host?.lowercased() ?? ""
        if host.contains("consent") || host.contains("nocookie") { return false }
        if url.path.contains("/embed") { return false }
        return true
    }

    static func open(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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

/// Lists a folder's contents. This is how a folder inside another app's container is shown, since
/// iOS cannot hand the Files app someone else's folder.
struct FolderContentsSheet: View {
    let url: URL
    let onClose: () -> Void
    @State private var entries: [URL] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if entries.isEmpty {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(entries, id: \.self) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: isDirectory(entry) ? "folder" : "doc")
                                    .foregroundStyle(isDirectory(entry) ? Color.accentColor : Color.secondary)
                                Text(entry.lastPathComponent).lineLimit(1)
                            }
                        }
                    } header: {
                        Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onClose() } }
            }
            .task { load() }
        }
    }

    private func isDirectory(_ item: URL) -> Bool {
        (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func load() {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            error = "Couldn't read this folder."
            return
        }
        entries = contents.sorted { a, b in
            let aDir = isDirectory(a), bDir = isDirectory(b)
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
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

    /// Forgets the downloaded game list and its cache file, so it is fetched again next time.
    func clearCache() {
        entries = nil
        if let url = Self.cacheURL { try? FileManager.default.removeItem(at: url) }
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
    /// Steam's store search finds the name (aliases included), then each game that is not already
    /// in the cached Workshop list is checked once for a real Workshop, so a title missing from the
    /// cached list still appears and a game without a Workshop still does not.
    static func search(_ term: String) async -> [GameHit] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let lowered = query.lowercased()

        let catalogue = await WorkshopCatalogue.shared.games()
        let known = Set(catalogue.map { $0.id })

        // Candidates: the store's name matches, then any Workshop-list matches it missed.
        let store = await storeSearch(query)
        var candidates: [GameHit] = []
        var seen = Set<Int>()
        for hit in store where seen.insert(hit.id).inserted { candidates.append(hit) }
        for hit in catalogue
        where hit.name.lowercased().contains(lowered) && seen.insert(hit.id).inserted {
            candidates.append(hit)
        }
        candidates = candidates.filter { $0.name.lowercased().contains(lowered) }
        guard !candidates.isEmpty else { return [] }

        var keep = [Bool](repeating: false, count: candidates.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, hit) in candidates.enumerated() {
                group.addTask {
                    if known.contains(hit.id) { return (index, true) }
                    return (index, await WorkshopAvailability.shared.hasWorkshop(id: hit.id))
                }
            }
            for await (index, ok) in group { keep[index] = ok }
        }

        let matches = zip(candidates, keep).filter { $0.1 }.map { $0.0 }
        let ranked = matches.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(lowered)
            let bPrefix = b.name.lowercased().hasPrefix(lowered)
            if aPrefix != bPrefix { return aPrefix }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(30))
    }

    private static func storeSearch(_ term: String) async -> [GameHit] {
        guard let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(q)&l=english&cc=US"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONDecoder().decode(GameSearchResponse.self, from: data) else { return [] }
        return root.items
    }
}

/// Remembers whether an app has a Workshop, for the games the cached list does not cover.
final class WorkshopAvailability {
    static let shared = WorkshopAvailability()
    private let key = "modshelf.workshopAvailability"
    private var cache: [Int: Bool] = [:]

    private init() {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] else { return }
        for (raw, value) in stored { if let id = Int(raw) { cache[id] = value } }
    }

    func hasWorkshop(id: Int) async -> Bool {
        if let hit = cache[id] { return hit }
        guard let url = URL(string: "https://steamcommunity.com/app/\(id)/workshop/") else { return true }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            // Unknown: keep the game rather than hide a real Workshop.
            return true
        }
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        let value: Bool
        if html.localizedCaseInsensitiveContains("does not have a workshop") {
            value = false
        } else if finalURL.path.contains("/app/\(id)/workshop") || html.contains("/app/\(id)/workshop") {
            value = true
        } else if finalURL.host?.contains("store.steampowered.com") == true
                    || finalURL.path == "/app/\(id)/" || finalURL.path == "/app/\(id)" {
            // Steam sent us to the store or the plain hub: there is no Workshop tab.
            value = false
        } else {
            // Unknown page: keep it rather than hide a real Workshop.
            return true
        }
        remember(id, value)
        return value
    }

    private func remember(_ id: Int, _ value: Bool) {
        cache[id] = value
        var stored: [String: Bool] = [:]
        for (key, flag) in cache { stored[String(key)] = flag }
        UserDefaults.standard.set(stored, forKey: key)
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
    @AppStorage("browser.recentMods") private var viewedJSON = "[]"

    private var recent: [GameHit] { GameListStore.decode(recentJSON) }
    private var favourites: [GameHit] { GameListStore.decode(favJSON) }
    private var viewedMods: [GameHit] { GameListStore.decode(viewedJSON) }
    /// True until the first game is opened or favourited; the search box is then ready to type in.
    private var isFirstRun: Bool { recent.isEmpty && favourites.isEmpty && lastPage == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollSpy(onChange: onScroll)
                if let lastPage { continueCard(lastPage) }
                searchField
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    resultsSection
                } else {
                    if !favourites.isEmpty { favouritesSection }
                    if !viewedMods.isEmpty { viewedModsSection }
                    if !recentlyOpened.isEmpty { recentsSection }
                    if isFirstRun { firstRunCard }
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)
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
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            TextField("Search for a game", text: $query)
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
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if searching {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Searching…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if results.isEmpty {
                Text("No games found for \"\(query)\".")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                gameList(results)
            }
        }
    }

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Favourites", count: favourites.count)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(favourites.prefix(4))) { hit in favouriteTile(hit) }
            }
        }
    }

    private var viewedModsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recently viewed mods", count: viewedMods.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewedMods) { hit in viewedTile(hit) }
                }
                .padding(.horizontal, 1).padding(.vertical, 2)
            }
        }
    }

    private func viewedTile(_ hit: GameHit) -> some View {
        Button {
            Haptics.tap()
            if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(hit.id)") {
                onOpenURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .frame(width: 78, height: 78)
                    .overlay(CachedImage(urlString: hit.tiny_image, fill: false, maxPixel: 220).allowsHitTesting(false))
                MarqueeText(text: hit.name, fontSize: 11, weight: .medium, height: 15,
                            speed: MarqueeSpeed.otherSpeed, active: MarqueeSpeed.otherRunning)
                    .frame(width: 78, alignment: .leading)
            }
            .padding(6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0))
        }
        .buttonStyle(.plain)
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recently opened games", count: recentlyOpened.count)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Array(recentlyOpened.prefix(4))) { hit in favouriteTile(hit) }
            }
        }
    }

    /// A whole card of the game's own landscape capsule, with its name centred over it.
    private func landscapeGameCard(_ hit: GameHit) -> some View {
        Button { openGame(hit) } label: {
            ZStack {
                Color.clear
                    .frame(height: 88)
                    .overlay(CachedImage(urlString: capsuleURL(hit.id), fill: true, maxPixel: 600).allowsHitTesting(false))
                Text(hit.name)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) { starButton(hit).padding(1) }
        }
        .buttonStyle(.plain)
    }

    private func capsuleURL(_ id: Int) -> String {
        "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(id)/capsule_231x87.jpg"
    }

    /// A game that is already in the favourites above does not need listing twice.
    private var recentlyOpened: [GameHit] {
        let favs = Set(favourites.map(\.id))
        return recent.filter { !favs.contains($0.id) }
    }

    /// Rows share one rounded card with hairlines between them, so the page reads as a list rather
    /// than a stack of loose boxes.
    private func gameList(_ hits: [GameHit]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                if index > 0 { Divider().padding(.leading, 68) }
                gameRow(hit)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func favouriteTile(_ hit: GameHit) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { openGame(hit) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                        .overlay(CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 300))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    MarqueeText(text: hit.name, fontSize: 12, weight: .semibold, height: 15,
                                speed: MarqueeSpeed.otherSpeed, active: MarqueeSpeed.otherRunning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)
            starButton(hit).padding(2)
        }
    }

    private func gameRow(_ hit: GameHit) -> some View {
        HStack(spacing: 0) {
            Button { openGame(hit) } label: {
                HStack(spacing: 12) {
                    CachedImage(urlString: hit.tiny_image, fill: true, maxPixel: 160)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(hit.name)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            starButton(hit)
        }
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

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            if let count {
                Text("\(count)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// What the page is for on a fresh install, in place of one lonely line of grey text.
    private var firstRunCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Start with a game").font(.system(size: 15, weight: .semibold))
                Text("Type the name of a game in your Steam library — Project Zomboid, for example — then tap it to open its Workshop.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func continueCard(_ url: URL) -> some View {
        Button { Haptics.tap(); onOpenURL(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue where you left off").font(.system(size: 15, weight: .semibold))
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(18)
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
            if !showHome { topBar }
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
        .onChange(of: currentURL) { url in
            // Whatever mod page is actually browsed gets remembered, not only the ones looked up here.
            guard let url, let id = WorkshopStore.workshopID(from: url.absoluteString) else { return }
            Task {
                if let meta = await SteamMeta.fetch(id: id, includePage: false) {
                    WorkshopStore.rememberViewedMod(meta)
                }
            }
        }
        .onChange(of: homeToken) { _ in showHome = true }
        .onAppear { if requestedURL != nil { showHome = false } }
    }

    private func open(_ url: URL) {
        showHome = false
        requestedURL = url
    }

    /// Back, Forward, the address (tap to copy) and Home, all across the top. On the launcher only
    /// Home is shown, since there is no page to go back to or copy.
    private var topBar: some View {
        HStack(spacing: 8) {
            navButton("chevron.left", "Back", enabled: canGoBack) { handle.webView?.goBack() }
            navButton("chevron.right", "Forward", enabled: canGoForward) { handle.webView?.goForward() }
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


// MARK: - Developer menu
//
// Nothing in the app points here: it opens after twenty quick taps on the logo in the header.

struct DeveloperMenuView: View {
    @ObservedObject var store: WorkshopStore
    @Environment(\.dismiss) private var dismiss

    @State private var fakeCount = 3
    @State private var fakeEvery = 0
    @State private var fakeSpeed = 2.0
    @State private var report: String?
    @State private var showingManifests = false

    var body: some View {
        NavigationStack {
            List {
                Section("Simulation") {
                    Stepper("Mods in the fake update: \(fakeCount)", value: $fakeCount, in: 1...10)
                    Stepper("Fail every: \(fakeEvery == 0 ? "off" : "\(fakeEvery)")", value: $fakeEvery, in: 0...5)
                    HStack {
                        Text("Seconds per mod")
                        Spacer()
                        Text(String(format: "%.1f", fakeSpeed)).foregroundStyle(.secondary)
                    }
                    Slider(value: $fakeSpeed, in: 0.5...8, step: 0.5)
                    Button("Fake update all") {
                        report = nil
                        store.devFakeUpdateAll(count: fakeCount, failEvery: fakeEvery, seconds: fakeSpeed)
                    }
                    Button("Fake download success") {
                        report = nil
                        store.devFakeDownload(fail: false, seconds: fakeSpeed)
                    }
                    Button("Fake download failure") {
                        report = nil
                        store.devFakeDownload(fail: true, seconds: fakeSpeed)
                    }
                    Button("Simulate an available update") {
                        report = store.devMarkUpdates(count: fakeCount)
                    }
                }

                Section("Storage") {
                    Button("Run folder repair") { report = store.devRepairReport() }
                    Button("Rewrite manifests and info files") { report = store.devRewriteManifests() }
                    NavigationLink("Hidden manifests") { DevManifestList(store: store) }
                    NavigationLink("Runtime log") { DevLogView(store: store) }
                    Button("Storage report") { report = store.devStorageReport() }
                }

                Section("Maintenance") {
                    Button("Clear image cache") {
                        ImageStore.shared.clear()
                        report = "Image cache cleared."
                    }
                    Button("Clear Steam session cache") { report = store.devClearSteamCache() }
                    Button("Clear Workshop catalogue") {
                        WorkshopCatalogue.shared.clearCache()
                        report = "Workshop catalogue cleared."
                    }
                    Button("Clear download history") {
                        store.clearHistory()
                        report = "Download history cleared."
                    }
                    Button("Reset moved and broken flags") { report = store.devResetFlags() }
                    Button("Clear update badges") { report = store.devClearUpdateFlags() }
                    Button("Reset all settings", role: .destructive) { report = store.devResetSettings() }
                }

                Section("Engine") {
                    LabeledContent("Status", value: store.devEngineStatus)
                    LabeledContent("Progress", value: String(format: "%.2f", store.devEngineProgress))
                    LabeledContent("File", value: store.devEngineFile.isEmpty ? "—" : store.devEngineFile)
                    LabeledContent("Last error", value: store.devEngineError.isEmpty ? "—" : store.devEngineError)
                    Button("Copy debug snapshot") {
                        UIPasteboard.general.string = store.devSnapshot
                        report = "Snapshot copied."
                    }
                }

                if let report {
                    Section("Last result") {
                        Text(report)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct DevManifestList: View {
    @ObservedObject var store: WorkshopStore

    var body: some View {
        List(store.library) { item in
            NavigationLink(item.displayTitle) {
                ScrollView {
                    Text(store.devManifestJSON(for: item))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(item.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Hidden manifests")
    }
}


struct DevLogView: View {
    @ObservedObject var store: WorkshopStore

    var body: some View {
        List {
            if store.runtimeLog.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            } else {
                ForEach(store.runtimeLog.indices, id: \.self) { index in
                    Text(store.runtimeLog[index])
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Runtime log")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Clear") { store.clearRuntimeLog() }
                    .disabled(store.runtimeLog.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Copy") {
                    UIPasteboard.general.string = store.runtimeLog.joined(separator: "\n")
                }
                .disabled(store.runtimeLog.isEmpty)
            }
        }
    }
}
