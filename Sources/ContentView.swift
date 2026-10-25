import SwiftUI
import UIKit
import WebKit
import Security
import ZIPFoundation
import SteamEngine

@main
struct ModShelfApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
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
}

struct WorkshopMetadata: Codable, Equatable {
    var id: String
    var title: String
    var author: String
    var description: String
    var imageURL: String
    var updatedAt: Int
    var pageURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }
}

struct DownloadRecord: Identifiable, Codable {
    var id = UUID()
    var workshopID: String
    var title: String
    var date: Date
    var result: String
    var error: String? = nil
}

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

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var input = ""
    @Published var username = Keychain.read("steam.username") ?? ""
    @Published var password = Keychain.read("steam.password") ?? ""
    @Published var guardCode = ""
    @Published var status = "Ready"
    @Published var errorMessage = ""
    @Published var inputValidationMessage = ""
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var downloadedBytes: Int64 = 0
    @Published var downloadStage = "Preparing download"
    @Published var isBusy = false
    @Published var isVerifyingAll = false
    @Published var isFetching = false
    @Published var preview: WorkshopMetadata?
    @Published var library: [WorkshopItem] = []
    @Published private(set) var cachedLibraryBytes: Int64 = 0
    @Published var history: [DownloadRecord] = []
    @Published var showLogin = false
    @Published var pendingDelete: WorkshopItem?
    @Published var showDeleteConfirmation = false
    @Published var shareURL: URL?
    @Published var lastOutcome = ""
    @Published var browserURL: URL?

    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""
    private var activeTitle = ""
    private var lastObservedTerminalStatus = ""
    private var lastBytesSampleAt = Date.distantPast

    var isAuthenticated: Bool { engine.isAuthenticated() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var downloadsRoot: URL {
        let url = documents.appendingPathComponent("Downloaded Mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    // Keep Steam's token/session cache outside Documents so it is not exposed in Files or backups.
    private var sessionPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("SteamSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let legacy = documents.appendingPathComponent("SteamSession", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            do {
                for child in try FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                    let destination = url.appendingPathComponent(child.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.moveItem(at: child, to: destination) }
                }
                try? FileManager.default.removeItem(at: legacy)
            } catch { /* keep the legacy cache if migration cannot complete */ }
        }
        return url.path
    }
    private var temporaryPath: URL { documents.appendingPathComponent("ModShelfTemporary", isDirectory: true) }

    init() {
        library = Self.load([WorkshopItem].self, key: "library") ?? []
        refreshLibrarySize()
        let oldHistory = Self.load([String].self, key: "history") ?? []
        history = Self.load([DownloadRecord].self, key: "modshelf.history") ?? oldHistory.map {
            DownloadRecord(workshopID: $0, title: "Workshop item \($0)", date: Date(), result: "Attempted")
        }
        status = engine.status()
        // Poll only while a login or download is active, not while the app is idle.
        if !username.isEmpty && !password.isEmpty { Task { await signIn(automatic: true) } }
    }

    deinit { poller?.invalidate() }

    private func startPolling() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }
    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func saveLibrary() { save(library, key: "library"); refreshLibrarySize() }
    private func refreshLibrarySize() {
        let paths = library.map(\.folder)
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var total: Int64 = 0
            for path in paths {
                guard let enumerator = fm.enumerator(atPath: path) else { continue }
                for case let relative as String in enumerator {
                    let full = URL(fileURLWithPath: path).appendingPathComponent(relative)
                    if let attrs = try? fm.attributesOfItem(atPath: full.path), let size = attrs[.size] as? NSNumber { total += size.int64Value }
                }
            }
            await MainActor.run { self.cachedLibraryBytes = total }
        }
    }
    private func saveHistory() { save(history, key: "modshelf.history") }
    private func record(_ id: String, title: String, result: String, error: String? = nil) {
        history.insert(DownloadRecord(workshopID: id, title: title, date: Date(), result: result, error: error), at: 0)
        if history.count > 500 { history = Array(history.prefix(500)) }
        saveHistory()
    }

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
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = nil
            inputValidationMessage = "Required — enter a Workshop URL or item ID."
            return
        }
        guard let id = Self.workshopID(from: input) else {
            preview = nil
            inputValidationMessage = "Enter a valid Steam Workshop URL or numeric item ID."
            return
        }
        inputValidationMessage = ""
        isFetching = true
        preview = nil
        errorMessage = ""
        Task {
            let result = await Self.metadata(id: id)
            if let result {
                preview = result
                status = ""
            } else {
                preview = nil
                errorMessage = "Workshop item \(id) could not be found or its details could not be loaded. It may be private, deleted, unavailable, or Steam may be rate-limiting requests. You can still try downloading it by ID."
                // Keep a valid fallback preview so a user can still attempt a direct download.
                preview = WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "Creator ID unavailable", description: "Metadata was unavailable. Downloading may still work if this item is accessible to your Steam account.", imageURL: "", updatedAt: 0)
            }
            isFetching = false
        }
    }

    private static func metadata(id: String) async -> WorkshopMetadata? {
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
                  let response = root["response"] as? [String: Any],
                  let details = response["publishedfiledetails"] as? [[String: Any]],
                  let item = details.first, (item["result"] as? Int) == 1 else { return nil }
            return WorkshopMetadata(id: id,
                                    title: item["title"] as? String ?? "Workshop item \(id)",
                                    author: (item["creator"] as? String).map { _ in "Steam Workshop creator" } ?? "Unknown creator",
                                    description: cleanHTML(item["description"] as? String ?? "No description provided."),
                                    imageURL: item["preview_url"] as? String ?? "",
                                    updatedAt: item["time_updated"] as? Int ?? 0)
        } catch { return nil }
    }
    private static func cleanHTML(_ html: String) -> String {
        var s = html
        // Convert common Steam Workshop BBCode into readable text instead of exposing raw tags.
        s = s.replacingOccurrences(of: "(?i)\\[/?h[1-6]\\]", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\[/?(?:b|i|u|strike|spoiler|quote|code|list|hr)\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\[\\*\\]", with: "\n• ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\[url(?:=[^\\]]+)?\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\[/url\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\[img\\].*?\\[/img\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p\\s*>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signIn(automatic: Bool = false) async {
        guard !isBusy else { errorMessage = "Cancel the current download before signing in or out."; return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            if !automatic { showLogin = true }
            errorMessage = automatic ? "" : "Enter your Steam username and password."
            return
        }
        isBusy = true; status = "Signing in to Steam…"; errorMessage = ""
        startPolling()
        let user = username, pass = password, code = guardCode, path = sessionPath
        let activeEngine = engine
        let result = await Task.detached(priority: .userInitiated) {
            activeEngine.login(user, password: pass, guardCode: code, cachePath: path)
        }.value
        isBusy = false
        stopPolling()
        status = engine.status()
        if engine.isAuthenticated() {
            Keychain.write(username, key: "steam.username")
            Keychain.write(password, key: "steam.password")
            guardCode = ""; showLogin = false; status = "Signed in to Steam"
        } else {
            errorMessage = result.isEmpty ? (engine.lastError().isEmpty ? "Steam sign-in did not complete." : engine.lastError()) : result
            if errorMessage.localizedCaseInsensitiveContains("guard") { status = "Steam Guard code required" }
            if !automatic { showLogin = true }
        }
    }
    func signOut() {
        guard !isBusy else { errorMessage = "Cancel the current download before signing out."; return }
        engine.logout(); Keychain.delete("steam.password"); password = ""; guardCode = ""
        status = "Signed out"
    }

    func download(_ raw: String? = nil) {
        errorMessage = ""
        guard !isBusy else { errorMessage = "A download or sign-in is already running."; return }
        guard isAuthenticated else { errorMessage = "Sign in to Steam first."; showLogin = true; return }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a valid Workshop URL or ID."; return }
        activeID = id
        let meta = preview?.id == id ? preview! : WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "Unknown creator", description: "", imageURL: "", updatedAt: 0)
        activeTitle = meta.title
        let existingEntry = library.first(where: { $0.id == id })
        let baseFolderName = Self.safeFolderName(meta.title)
        let nameCollision = library.contains { $0.id != id && URL(fileURLWithPath: $0.folder).lastPathComponent == baseFolderName }
        let folderName = nameCollision ? "\(baseFolderName) - \(id.suffix(6))" : baseFolderName
        let finalFolder = downloadsRoot.appendingPathComponent(folderName, isDirectory: true)
        let staging = downloadsRoot.appendingPathComponent(".partial-\(id)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch { errorMessage = "Could not create a download folder: \(error.localizedDescription)"; record(id, title: meta.title, result: "Failed", error: errorMessage); return }
        let result = engine.downloadWorkshopItem(id, targetDir: staging.path)
        if !result.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            errorMessage = result; status = result; record(id, title: meta.title, result: "Failed", error: result); return
        }
        isBusy = true
        progress = 0
        currentFile = ""
        downloadedBytes = 0
        downloadStage = "Starting download"
        status = "Starting download…"
        lastOutcome = ""
        lastObservedTerminalStatus = ""
        record(id, title: meta.title, result: "Downloading")
        startPolling()
        // Store staging path in memory so only a verified completed download is promoted.
        UserDefaults.standard.set(staging.path, forKey: "modshelf.activeStaging")
        UserDefaults.standard.set(finalFolder.path, forKey: "modshelf.activeFinal")
        UserDefaults.standard.set(existingEntry?.folder ?? "", forKey: "modshelf.previousFolder")
    }

    func refreshState() {
        let nextStatus = engine.status()
        let nextProgress = min(1, max(0, engine.progress()))
        let nextFile = engine.currentFile()

        // Avoid triggering SwiftUI updates when the engine state has not changed.
        if status != nextStatus { status = nextStatus }
        if abs(progress - nextProgress) > 0.001 { progress = nextProgress }
        if currentFile != nextFile { currentFile = nextFile }
        if isBusy {
            downloadStage = Self.friendlyStage(nextStatus, progress: nextProgress)
            // Sample disk usage sparingly: recursive scans on every polling tick cause UI stalls.
            if Date().timeIntervalSince(lastBytesSampleAt) >= 3 {
                lastBytesSampleAt = Date()
                let stagingPath = UserDefaults.standard.string(forKey: "modshelf.activeStaging") ?? ""
                if !stagingPath.isEmpty { downloadedBytes = Self.directorySize(at: URL(fileURLWithPath: stagingPath)) }
            }
        }

        guard isBusy else {
            stopPolling()
            return
        }

        let s = nextStatus.lowercased()
        guard ["download complete", "download failed", "download cancelled"].contains(where: { s.contains($0) }) else { return }
        lastObservedTerminalStatus = nextStatus
        isBusy = false
        stopPolling()
        let stagingPath = UserDefaults.standard.string(forKey: "modshelf.activeStaging") ?? ""
        let finalPath = UserDefaults.standard.string(forKey: "modshelf.activeFinal") ?? ""
        UserDefaults.standard.removeObject(forKey: "modshelf.activeStaging")
        UserDefaults.standard.removeObject(forKey: "modshelf.activeFinal")
        let previousFolderPath = UserDefaults.standard.string(forKey: "modshelf.previousFolder") ?? ""
        UserDefaults.standard.removeObject(forKey: "modshelf.previousFolder")
        let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let final = URL(fileURLWithPath: finalPath, isDirectory: true)
        let error = engine.lastError()
        let successStatus = s.contains("download complete")
        let cancelled = s.contains("download cancelled")
        var success = false
        if successStatus, !stagingPath.isEmpty, !finalPath.isEmpty {
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: staging.path)
                guard !files.isEmpty else { throw NSError(domain: "ModShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Steam reported completion but the download folder is empty."]) }
                // Steam sometimes nests the payload in a redundant `mods` directory. Move
                // its contents up one level while leaving all internal mod folders untouched.
                let nestedMods = staging.appendingPathComponent("mods", isDirectory: true)
                if FileManager.default.fileExists(atPath: nestedMods.path) {
                    for child in try FileManager.default.contentsOfDirectory(at: nestedMods, includingPropertiesForKeys: nil) {
                        let destination = staging.appendingPathComponent(child.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: child, to: destination) }
                    }
                    if (try? FileManager.default.contentsOfDirectory(at: nestedMods, includingPropertiesForKeys: nil).isEmpty) == true {
                        try FileManager.default.removeItem(at: nestedMods)
                    }
                }
                // Write provenance alongside the downloaded files, not in another wrapper folder.
                let info = staging.appendingPathComponent("ModShelf-Info.txt")
                let details = ["ModShelf download information", "", "Title: \(activeTitle)", "Workshop ID: \(activeID)", "Workshop URL: https://steamcommunity.com/sharedfiles/filedetails/?id=\(activeID)", "Installed with: ModShelf for iOS", "Downloaded: \(ISO8601DateFormatter().string(from: Date()))", "", "This folder contains the downloaded Workshop files. ModShelf does not install them into a game automatically.", "Update this file only if you intentionally edit these details."].joined(separator: "\n")
                try details.write(to: info, atomically: true, encoding: .utf8)
                // Promote atomically as far as the filesystem allows. Keep the previous
                // download until the new staging folder is ready to take its place.
                let backup = downloadsRoot.appendingPathComponent(".backup-\(activeID)-\(UUID().uuidString)", isDirectory: true)
                let hadPrevious = FileManager.default.fileExists(atPath: final.path)
                if hadPrevious { try FileManager.default.moveItem(at: final, to: backup) }
                do {
                    try FileManager.default.moveItem(at: staging, to: final)
                    success = true
                    if hadPrevious { try? FileManager.default.removeItem(at: backup) }
                } catch {
                    if hadPrevious && !FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.moveItem(at: backup, to: final) }
                    throw error
                }
            } catch {
                errorMessage = "Download could not be finalised: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: staging)
            }
        } else if !stagingPath.isEmpty {
            try? FileManager.default.removeItem(at: staging)
        }
        if success {
            let old = library.firstIndex(where: { $0.id == activeID })
            let meta = preview?.id == activeID ? preview : nil
            let item = WorkshopItem(id: activeID, folder: final.path,
                                    addedAt: old.map { library[$0].addedAt } ?? Date(), updatedAt: Date(),
                                    title: meta?.title ?? activeTitle, author: meta?.author,
                                    description: meta?.description, imageURL: meta?.imageURL,
                                    publishedUpdatedAt: meta?.updatedAt, lastCheckedAt: Date(), updateAvailable: false)
            if let old { library[old] = item } else { library.insert(item, at: 0) }
            saveLibrary()
            if !previousFolderPath.isEmpty && previousFolderPath != final.path && FileManager.default.fileExists(atPath: previousFolderPath) {
                try? FileManager.default.removeItem(atPath: previousFolderPath)
            }
            updateHistory(id: activeID, result: "Downloaded", error: nil)
            lastOutcome = "Download completed"
        } else {
            let reason = cancelled ? "Download cancelled." : (!error.isEmpty ? error : (!errorMessage.isEmpty ? errorMessage : "The download failed before it could be finalised."))
            updateHistory(id: activeID, result: cancelled ? "Cancelled" : "Failed", error: reason)
            if !cancelled { errorMessage = reason }
            lastOutcome = cancelled ? "Download cancelled" : "Download failed"
        }
        saveHistory()
    }
    private func updateHistory(id: String, result: String, error: String?) {
        if let index = history.firstIndex(where: { $0.workshopID == id && $0.result == "Downloading" }) {
            history[index].result = result; history[index].date = Date(); history[index].error = error
        } else { record(id, title: activeTitle, result: result, error: error) }
    }
    func cancel() { engine.cancelDownload(); status = "Cancelling download…" }

    private static func safeFolderName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let compact = String((cleaned.isEmpty ? "Workshop Mod" : cleaned).prefix(70))
        return compact == "." || compact == ".." ? "Workshop Mod" : compact
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
    private static func friendlyStage(_ raw: String, progress: Double) -> String {
        let s = raw.lowercased()
        if s.contains("diff") { return "Comparing existing files" }
        if s.contains("manifest") { return "Reading Workshop manifest" }
        if s.contains("start") || s.contains("prepar") || s.contains("connect") { return "Preparing download" }
        if s.contains("complete") { return "Finalising files" }
        if s.contains("download") || progress > 0 { return "Downloading files" }
        return raw.isEmpty ? "Preparing download" : raw
    }

    func remove(_ item: WorkshopItem) {
        do { if FileManager.default.fileExists(atPath: item.folder) { try FileManager.default.removeItem(atPath: item.folder) } }
        catch { errorMessage = "Could not delete downloaded files: \(error.localizedDescription)"; return }
        library.removeAll { $0.id == item.id }; saveLibrary()
    }
    func requestDelete(_ item: WorkshopItem) {
        if UserDefaults.standard.object(forKey: "options.confirmDelete") as? Bool ?? true {
            pendingDelete = item; showDeleteConfirmation = true
        } else { remove(item) }
    }
    func export(_ item: WorkshopItem) {
        let source = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { errorMessage = "Downloaded files could not be found. Use Verify files to check the library entry."; return }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Workshop-\(item.id).zip")
        do { try? FileManager.default.removeItem(at: zip); try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: true); shareURL = zip }
        catch { errorMessage = "ZIP export failed: \(error.localizedDescription)" }
    }
    func verify(_ item: WorkshopItem) {
        let path = item.folder
        guard FileManager.default.fileExists(atPath: path) else { errorMessage = "Files are missing for \(item.title ?? item.id). Delete this library entry and download it again."; return }
        do {
            let files = try FileManager.default.subpathsOfDirectory(atPath: path)
            guard !files.isEmpty else { errorMessage = "The download folder exists but contains no files."; return }
            status = "Verified \(files.count) files for item \(item.id)"
        } catch { errorMessage = "Could not verify files: \(error.localizedDescription)" }
    }
    func checkUpdates(_ item: WorkshopItem) {
        Task {
            guard let m = await Self.metadata(id: item.id), let i = library.firstIndex(where: { $0.id == item.id }) else {
                errorMessage = "Could not check item \(item.id). Steam may be rate-limiting requests or the item may be private/deleted."; return
            }
            let oldStamp = library[i].publishedUpdatedAt ?? 0
            library[i].updateAvailable = oldStamp > 0 && m.updatedAt > oldStamp
            library[i].publishedUpdatedAt = m.updatedAt
            library[i].lastCheckedAt = Date()
            library[i].title = m.title; library[i].author = m.author; library[i].description = m.description; library[i].imageURL = m.imageURL
            saveLibrary()
            status = library[i].updateAvailable ? "Update available: \(m.title)" : "No update detected: \(m.title)"
        }
    }
    func checkAllUpdates() {
        guard !library.isEmpty else { status = "Your library is empty"; return }
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        Task {
            var checked = 0
            var failed = 0
            let ids = library.map(\.id)
            for id in ids {
                if let meta = await Self.metadata(id: id), let index = library.firstIndex(where: { $0.id == id }) {
                    let oldStamp = library[index].publishedUpdatedAt ?? 0
                    library[index].updateAvailable = oldStamp > 0 && meta.updatedAt > oldStamp
                    library[index].publishedUpdatedAt = meta.updatedAt
                    library[index].lastCheckedAt = Date()
                    library[index].title = meta.title; library[index].author = meta.author
                    library[index].description = meta.description; library[index].imageURL = meta.imageURL
                    checked += 1
                } else { failed += 1 }
                status = "Checking updates… \(checked + failed) of \(ids.count)"
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            saveLibrary()
            let available = library.filter(\.updateAvailable).count
            status = "Checked \(checked) items · \(available) updates available · \(failed) failed"
            if failed > 0 { errorMessage = "Update check finished, but \(failed) item(s) could not be checked. Check your connection or try again later." }
            isCheckingUpdates = false
        }
    }
    @Published var isCheckingUpdates = false

    func verifyAllFiles() {
        guard !isVerifyingAll else { return }
        isVerifyingAll = true
        let snapshot = library.map { ($0.id, $0.title ?? $0.id, $0.folder) }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var good = 0
            var missing = 0
            for (_, _, path) in snapshot {
                guard fm.fileExists(atPath: path), let files = try? fm.subpathsOfDirectory(atPath: path), !files.isEmpty else { missing += 1; continue }
                good += 1
            }
            await MainActor.run {
                self.status = "Verified \(good) items · \(missing) missing or empty"
                if missing > 0 { self.errorMessage = "\(missing) library item(s) are missing files or have empty folders. Open each item to inspect it." }
                self.isVerifyingAll = false
            }
        }
    }
    func retry(_ record: DownloadRecord) {
        input = record.workshopID
        download(record.workshopID)
    }
    func clearHistory() { history.removeAll(); saveHistory(); UserDefaults.standard.removeObject(forKey: "history") }
    func clearTemporaryFiles() {
        do {
            try FileManager.default.createDirectory(at: temporaryPath, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: temporaryPath, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
            status = "Temporary files cleared"
        } catch { errorMessage = "Could not clear temporary files: \(error.localizedDescription)" }
    }
    func libraryBytes() -> Int64 { cachedLibraryBytes }
}

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = true
    @State private var selectedTab = 0
    @State private var showShare = false
    @State private var selectedItem: WorkshopItem?
    @State private var showHistory = false
    @State private var searchText = ""
    @State private var sortOrder = "Recently added"

    private var filteredLibrary: [WorkshopItem] {
        let filtered = store.library.filter { searchText.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(searchText) || $0.id.contains(searchText) || ($0.author ?? "").localizedCaseInsensitiveContains(searchText) }
        switch sortOrder {
        case "Name": return filtered.sorted { ($0.title ?? $0.id).localizedCaseInsensitiveCompare($1.title ?? $1.id) == .orderedAscending }
        case "Updates first": return filtered.sorted { $0.updateAvailable && !$1.updateAvailable }
        case "Oldest added": return filtered.sorted { $0.addedAt < $1.addedAt }
        default: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            downloadView.tabItem { Label("Download", systemImage: "arrow.down.circle") }.tag(0)
            NavigationStack { WorkshopBrowserView(requestedURL: $store.browserURL, onValidItem: { url in store.browserURL = url; store.input = url.absoluteString; selectedTab = 0; store.fetchPreview() }) }
                .tabItem { Label("Workshop", systemImage: "safari") }.tag(1)
            libraryView.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(2)
            optionsView.tabItem { Label("Options", systemImage: "gearshape") }.tag(3)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.title2.weight(.bold)).foregroundStyle(.blue)
                Text("ModShelf").font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer()
                Button { store.showLogin = true } label: {
                    Label(store.isAuthenticated ? "Signed in" : "Sign in", systemImage: store.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(store.isAuthenticated ? Color.green : Color.blue)
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background((store.isAuthenticated ? Color.green : Color.blue).opacity(0.14), in: Capsule())
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
             .background(.ultraThinMaterial)
        }
        .overlay {
            if let item = selectedItem {
                ItemDetailPopup(item: item, store: store, showIDs: showIDs, openWorkshop: { url in store.browserURL = url; selectedTab = 1 }) { selectedItem = nil }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(20)
            }
        }
        .tint(Color.accentColor)
        .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))
        .alert("ModShelf", isPresented: Binding(get: { !store.errorMessage.isEmpty }, set: { if !$0 { store.errorMessage = "" } })) {
            Button("OK", role: .cancel) { store.errorMessage = "" }
        } message: { Text(store.errorMessage) }
        .confirmationDialog("Delete this downloaded item and its files?", isPresented: $store.showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete download", role: .destructive) { if let item = store.pendingDelete { store.remove(item) }; store.pendingDelete = nil }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showShare, onDismiss: { store.shareURL = nil }) { if let url = store.shareURL { ShareSheet(activityItems: [url]) } }
        .sheet(isPresented: $showHistory) { historyView }
        .onChange(of: store.shareURL) { value in showShare = value != nil }
    }

    private var downloadView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ModShelf").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Steam Workshop downloads, organised.").foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Required · Workshop URL or ID", text: $store.input)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                                .onSubmit { dismissKeyboard(); store.fetchPreview() }
                                .onChange(of: store.input) { _ in store.inputValidationMessage = "" }
                            if !store.input.isEmpty { Button { store.input = ""; store.preview = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear item ID") }
                        }
                        Button { dismissKeyboard(); store.fetchPreview() } label: {
                            HStack { if store.isFetching { ProgressView().tint(.white) }; Text(store.isFetching ? "Looking up item…" : "Look up Workshop item"); Spacer(); Image(systemName: "magnifyingglass") }
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).disabled(store.isFetching || store.isBusy)
                    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    if !store.inputValidationMessage.isEmpty {
                        Text(store.inputValidationMessage).font(.caption).foregroundStyle(.orange).padding(.horizontal, 4)
                    }
                    if store.preview == nil && !store.isFetching {
                        Button { selectedTab = 1 } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "safari.fill").font(.title2).foregroundStyle(.blue).frame(width: 54, height: 54).background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Start browsing").font(.headline).foregroundStyle(.primary)
                                    Text("Open the Steam Workshop and choose a mod.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                    if store.isFetching { ProgressView("Fetching item details…").frame(maxWidth: .infinity, alignment: .leading) }
                    if let item = store.preview {
                        metadataCard(item)
                        if store.isBusy {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(store.downloadStage).font(.headline); Spacer(); Text("\(Int(store.progress * 100))%").monospacedDigit() }
                                ProgressView(value: store.progress)
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                                    Text("\(ByteCountFormatter.string(fromByteCount: store.downloadedBytes, countStyle: .file)) downloaded")
                                        .font(.caption.weight(.medium)).monospacedDigit()
                                    Spacer()
                                    Text("file progress").font(.caption2).foregroundStyle(.secondary)
                                }
                                if !store.currentFile.isEmpty { Text(store.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Button("Cancel download", role: .destructive) { store.cancel() }.buttonStyle(.bordered)
                            }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            Button { store.download(item.id) } label: { Label("Download item", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity).padding(.vertical, 4) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                    if !store.status.isEmpty && store.status != "Signed in to Steam" && store.status != "Connected to Steam" && store.status != "Ready" { Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding()
            }.background(Color(uiColor: .systemGroupedBackground)).toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() } } }
        }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: store.isAuthenticated ? "checkmark.shield.fill" : "person.crop.circle")
                .font(.title2).foregroundStyle(store.isAuthenticated ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.isAuthenticated ? "Steam connected" : "Steam not connected").font(.headline)
                Text(store.isAuthenticated ? "Ready to download Workshop files" : "Sign in to download items").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.isAuthenticated ? "Account" : "Sign in") { store.showLogin = true }.buttonStyle(.bordered)
        }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metadataCard(_ item: WorkshopMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary).overlay(ProgressView()) }
                    .frame(height: 180).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(item.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            Text(item.author).font(.subheadline).foregroundStyle(.secondary)
            if !item.description.isEmpty { ExpandableDescription(text: item.description, lineLimit: 7) }
            if showIDs { Text("Workshop ID: \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            if item.updatedAt > 0 { Label("Last updated \(Date(timeIntervalSince1970: TimeInterval(item.updatedAt)), style: .date)", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                Button { store.browserURL = item.pageURL; selectedTab = 1 } label: { Label("Workshop page", systemImage: "safari").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { store.input = item.id; UIPasteboard.general.string = item.id; store.status = "Workshop ID copied" } label: { Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 36) }.buttonStyle(.bordered).accessibilityLabel("Copy Workshop ID")
            }
        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var libraryView: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty { emptyState("Your library is empty", detail: "Downloaded items will appear here.", symbol: "square.grid.2x2") }
                else {
                    VStack(spacing: 0) {
                        HStack { Image(systemName: "externaldrive"); Text("\(store.library.count) items · \(ByteCountFormatter.string(fromByteCount: store.libraryBytes(), countStyle: .file))").font(.subheadline); Spacer() }
                            .padding(.horizontal).padding(.vertical, 10)
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search library", text: $searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Menu { ForEach(["Recently added", "Oldest added", "Name", "Updates first"], id: \.self) { value in Button(value) { sortOrder = value } } } label: { Label(sortOrder, systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly) }.accessibilityLabel("Sort library")
                        }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                        if !store.status.isEmpty && store.status != "Ready" && store.status != "Signed in to Steam" {
                            Text(store.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 6)
                        }
                        if compactLibrary {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                    ForEach(filteredLibrary) { item in
                                        Button { selectedItem = item } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ZStack(alignment: .topTrailing) {
                                                    thumbnail(item.imageURL ?? "").frame(maxWidth: .infinity).frame(height: 104)
                                                    if item.updateAvailable { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange).padding(6).background(.regularMaterial, in: Circle()).padding(5) }
                                                }
                                                Text(item.title ?? "Workshop item \(item.id)").font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                                                if showIDs { Text(item.id).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                        }.buttonStyle(.plain).accessibilityLabel("Details for \(item.title ?? item.id)")
                                    }
                                }.padding()
                            }
                        } else {
                            List(filteredLibrary) { item in
                                Button { selectedItem = item } label: {
                                    HStack(spacing: 12) { thumbnail(item.imageURL ?? ""); VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title ?? "Workshop item \(item.id)").font(.headline).lineLimit(2)
                                        Text(item.author ?? "Unknown creator").font(.caption).foregroundStyle(.secondary)
                                        Text(item.updateAvailable ? "Update available" : "Added \(item.addedAt, style: .date)").font(.caption).foregroundStyle(item.updateAvailable ? .orange : .secondary)
                                    }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                }.buttonStyle(.plain)
                            }.listStyle(.plain)
                        }
                    }
                }
            }.navigationTitle("Library").toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Download history")
                    Button { store.checkAllUpdates() } label: { if store.isCheckingUpdates { ProgressView() } else { Image(systemName: "arrow.clockwise") } }.disabled(store.isCheckingUpdates).accessibilityLabel("Check all for updates")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.verifyAllFiles() } label: { if store.isVerifyingAll { ProgressView() } else { Image(systemName: "checkmark.shield") } }.disabled(store.isVerifyingAll).accessibilityLabel("Verify all files")
                }
            }
        }
    }

    private var historyView: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty { emptyState("No download history", detail: "Every download attempt will appear here.", symbol: "clock.arrow.circlepath") }
                else {
                    List {
                        ForEach(store.history) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Image(systemName: item.result == "Downloaded" ? "checkmark.circle.fill" : (item.result == "Failed" ? "xmark.octagon.fill" : (item.result == "Cancelled" ? "minus.circle.fill" : "arrow.down.circle.fill")))
                                        .font(.title3).foregroundStyle(item.result == "Downloaded" ? .green : (item.result == "Failed" ? .red : (item.result == "Cancelled" ? .secondary : .blue)))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.headline).lineLimit(2)
                                        Text("ID \(item.workshopID) · \(item.result)").font(.caption).foregroundStyle(.secondary)
                                        Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if item.result == "Failed" || item.result == "Cancelled" { Button { store.retry(item) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Retry \(item.title)") }
                                }
                                if let reason = item.error, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(item.result == "Failed" ? .red : .secondary).textSelection(.enabled) }
                                HStack {
                                    Button("Workshop") { store.browserURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.workshopID)"); selectedTab = 1; showHistory = false }
                                    Spacer()
                                    Button("Copy ID") { UIPasteboard.general.string = item.workshopID; store.status = "Workshop ID copied" }
                                }.font(.caption)
                            }.padding(.vertical, 5)
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("History").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear") { store.clearHistory() }.disabled(store.history.isEmpty) } }
        }
    }

    private var optionsView: some View {
        NavigationStack {
            Form {
                Section("Appearance") { Picker("Theme", selection: $appearance) { Text("System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark") } }
                Section("Library") {
                    Toggle("Confirm before deleting", isOn: $confirmDelete)
                    Toggle("Show Workshop IDs", isOn: $showIDs)
                    Toggle("Compact two-column library", isOn: $compactLibrary)
                    Button("Check all items for updates") { store.checkAllUpdates() }
                    Button("Verify all downloaded files") { store.verifyAllFiles() }
                }
                Section("Workshop browser") { Text("The in-app browser keeps its own website session. It does not share login cookies with the Steam app or Safari.").font(.caption).foregroundStyle(.secondary) }
                Section("Steam account") {
                    LabeledContent("Status", value: store.isAuthenticated ? "Connected" : "Not connected")
                    Button(store.isAuthenticated ? "Account details" : "Sign in") { store.showLogin = true }
                    }
                Section("Storage") {
                    LabeledContent("Download folder", value: "On My iPhone / ModShelf / Downloaded Mods")
                    LabeledContent("Library size", value: ByteCountFormatter.string(fromByteCount: store.libraryBytes(), countStyle: .file))
                    Button("Clear download history", role: .destructive) { store.clearHistory() }
                    Button("Clear temporary files") { store.clearTemporaryFiles() }
                    Text("This does not delete your library or Steam session. Delete items from the Library tab to remove their downloaded files.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("App", value: "ModShelf")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                    Text("Unofficial utility. Not affiliated with Valve or Steam.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Options")
        }
    }

    private var loginSheet: some View {
        NavigationStack {
            Form {
                Section("Steam sign-in") {
                    TextField("Steam username", text: $store.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $store.password)
                    TextField("Steam Guard code (if requested)", text: $store.guardCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Text("Credentials are stored in the iOS Keychain after successful sign-in. If Steam Guard is requested, enter the code and retry.").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await store.signIn() } } label: { HStack { if store.isBusy { ProgressView() }; Text("Sign in") }.frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.navigationTitle("Steam account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { store.showLogin = false } } }
        }
    }

    private func thumbnail(_ source: String) -> some View {
        Group {
            if let url = URL(string: source), !source.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill)).overlay(ProgressView().scaleEffect(0.7)) }
            } else { RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill)).overlay(Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary)) }
        }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}


struct ExpandableDescription: View {
    let text: String
    var lineLimit: Int = 7
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.subheadline).lineLimit(expanded ? nil : lineLimit).textSelection(.enabled)
            if text.count > 360 {
                Button(expanded ? "Read less" : "Read more…") { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.plain)
            }
        }
    }
}

struct ItemDetailPopup: View {
    let item: WorkshopItem
    @ObservedObject var store: WorkshopStore
    let showIDs: Bool
    let openWorkshop: (URL) -> Void
    let onClose: () -> Void
    @State private var expanded = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            if let url = URL(string: item.imageURL ?? ""), !(item.imageURL ?? "").isEmpty {
                                AsyncImage(url: url) { $0.resizable().scaledToFill() }
                                    placeholder: { RoundedRectangle(cornerRadius: 12).fill(.quaternary) }
                                    .frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                Image(systemName: "shippingbox.fill").font(.largeTitle).frame(width: 88, height: 88)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title ?? "Workshop item \(item.id)").font(.title3.bold()).lineLimit(3)
                                if showIDs { Text("Workshop ID: \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                                Text(item.updateAvailable ? "Update available" : "Added \(item.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(item.updateAvailable ? .orange : .secondary)
                            }
                            Spacer(minLength: 0)
                            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                                .accessibilityLabel("Close item actions")
                        }
                        if let description = item.description, !description.isEmpty {
                            Text(description).font(.subheadline).lineLimit(expanded ? nil : 6).textSelection(.enabled)
                            if description.count > 300 {
                                Button(expanded ? "Read less" : "Read more…") { expanded.toggle() }.font(.subheadline.weight(.semibold))
                            }
                        }
                    }.padding(16)
                }.frame(maxHeight: 250)
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 0) {
                    popupAction("Open Workshop page", symbol: "safari") {
                        if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") { openWorkshop(url) }
                        onClose()
                    }
                    popupAction("Check for updates", symbol: "arrow.clockwise") { store.checkUpdates(item); onClose() }
                    popupAction("Verify downloaded files", symbol: "checkmark.shield") { store.verify(item); onClose() }
                    popupAction("Export as ZIP", symbol: "square.and.arrow.up") { store.export(item); onClose() }
                    popupAction("Copy Workshop ID", symbol: "doc.on.doc") { UIPasteboard.general.string = item.id; store.status = "Workshop ID copied"; onClose() }
                    popupAction("Delete download", symbol: "trash", destructive: true) { store.requestDelete(item); onClose() }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(maxWidth: 520).frame(maxHeight: 610)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 28, y: 12)
            .padding(.horizontal, 22)
        }
    }
    private func popupAction(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: 26)
                Text(title).font(.body.weight(.semibold))
                Spacer()
            }.foregroundStyle(destructive ? Color.red : Color.primary).padding(.horizontal, 12).padding(.vertical, 13)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ItemDetailSheet: View {
    let item: WorkshopItem
    @ObservedObject var store: WorkshopStore
    let showIDs: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showDescription = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        if let url = URL(string: item.imageURL ?? ""), !(item.imageURL ?? "").isEmpty {
                            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius: 12).fill(.quaternary) }.frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 12))
                        } else { Image(systemName: "shippingbox").font(.largeTitle).frame(width: 112, height: 112).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.title ?? "Workshop item \(item.id)").font(.title3.bold())
                            Text(item.author ?? "Unknown creator").font(.subheadline).foregroundStyle(.secondary)
                            if showIDs { Text("ID \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            if item.updateAvailable { Label("Update available", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                        }
                    }
                    if let description = item.description, !description.isEmpty {
                        DisclosureGroup("Description", isExpanded: $showDescription) { Text(description).font(.subheadline).textSelection(.enabled).padding(.top, 8) }
                    }
                    VStack(spacing: 10) {
                        Link(destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!) { Label("Open Workshop page", systemImage: "safari").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                        Button { store.checkUpdates(item) } label: { Label("Check for updates", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        Button { store.verify(item) } label: { Label("Verify downloaded files", systemImage: "checkmark.shield").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        Button { store.export(item) } label: { Label("Export as ZIP", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        Button { UIPasteboard.general.string = item.id; store.status = "Workshop ID copied" } label: { Label("Copy Workshop ID", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                        Button(role: .destructive) { store.requestDelete(item); dismiss() } label: { Label("Delete download", systemImage: "trash").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }
                    Text("Downloaded in ModShelf. This does not mean the files have been installed into a game.").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("Item details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct WorkshopBrowserView: View {
    @Binding var requestedURL: URL?
    let onValidItem: (URL) -> Void
    @State private var webView: WKWebView?
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showCopy = false
    private let homeURL = URL(string: "https://steamcommunity.com/workshop/")!
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack).accessibilityLabel("Back")
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!canGoForward).accessibilityLabel("Forward")
                Button { webView?.load(URLRequest(url: homeURL)) } label: { Image(systemName: "house") }.accessibilityLabel("Workshop home")
                Button { if let url = currentURL { webView?.load(URLRequest(url: url)) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.8) }
                if showCopy { Button("Use link") { if let url = currentURL { onValidItem(url) } } }
            }.font(.system(size: 17, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 12)
            WorkshopWebContainer(webView: $webView, currentURL: $currentURL, canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, showCopy: $showCopy, homeURL: homeURL)
        }.navigationTitle("Workshop").navigationBarTitleDisplayMode(.inline)
            .onChange(of: requestedURL) { url in
                guard let url else { return }
                webView?.load(URLRequest(url: url))
                requestedURL = nil
            }
    }
}

struct WorkshopWebContainer: UIViewRepresentable {
    @Binding var webView: WKWebView?
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var showCopy: Bool
    let homeURL: URL
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent cookies/login between launches
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        webView = view
        let saved = UserDefaults.standard.string(forKey: "modshelf.browser.lastURL").flatMap(URL.init(string:))
        let startURL = saved.flatMap { ["steamcommunity.com", "www.steamcommunity.com"].contains($0.host?.lowercased() ?? "") ? $0 : nil } ?? homeURL
        view.load(URLRequest(url: startURL))
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WorkshopWebContainer
        var observations: [NSKeyValueObservation] = []
        init(_ parent: WorkshopWebContainer) { self.parent = parent }
        func observe(_ view: WKWebView) {
            observations = [view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoBack = v.canGoBack } },
                            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoForward = v.canGoForward } },
                            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.isLoading = v.isLoading } },
                            view.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.updateURL(v.url) } }]
        }
        func updateURL(_ url: URL?) {
            parent.currentURL = url
            if let url, ["steamcommunity.com", "www.steamcommunity.com"].contains(url.host?.lowercased() ?? "") {
                UserDefaults.standard.set(url.absoluteString, forKey: "modshelf.browser.lastURL")
            }
            guard let url, WorkshopStore.workshopID(from: url.absoluteString) != nil, url.path.contains("/sharedfiles/filedetails") else { parent.showCopy = false; return }
            parent.showCopy = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateURL(webView.url)
            let css = "#global_header,#global_header_shadow,#footer,#workshop_header,#workshop_browse_header {display:none!important;} body {padding-top:0!important;}"
            let escaped = css.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("(function(){var s=document.getElementById('modshelf-clean-workshop');if(!s){s=document.createElement('style');s.id='modshelf-clean-workshop';document.head.appendChild(s)}s.textContent='\(escaped)';})();")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)); decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
