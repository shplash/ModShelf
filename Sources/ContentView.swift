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
    var imageURL: String? = nil
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
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var isBusy = false
    @Published var isFetching = false
    @Published var preview: WorkshopMetadata?
    @Published var library: [WorkshopItem] = []
    @Published var history: [DownloadRecord] = []
    @Published var showLogin = false
    @Published var pendingDelete: WorkshopItem?
    @Published var showDeleteConfirmation = false
    @Published var shareURL: URL?
    @Published var lastOutcome = ""
    @Published var browserURL: URL?
    @Published var operationMessage = ""
    @Published var isCheckingUpdates = false
    @Published var isVerifyingAll = false
    @Published var libraryStorageBytes: Int64 = 0

    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""
    private var activeTitle = ""
    private var lastObservedTerminalStatus = ""

    var isAuthenticated: Bool { engine.isAuthenticated() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var downloadsRoot: URL {
        let url = documents.appendingPathComponent("Downloaded Mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    // Keep Steam's token/session cache outside Documents so it is not exposed in the Files app.
    // This remains sandboxed app data; Keychain is still used for the saved login credentials.
    private var sessionPath: String {
        let fm = FileManager.default
        let library = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = library.appendingPathComponent("ModShelf/SteamSession", isDirectory: true)
        let legacyURL = documents.appendingPathComponent("SteamSession", isDirectory: true)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Migrate any existing token cache out of Documents so it no longer appears in Files.
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
        // Also migrate cache files left directly in Documents by older builds.
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
        status = engine.status()
        _ = sessionPath // Migrate any legacy token cache out of Documents on launch.
        refreshLibraryBytes()
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
    private func saveLibrary() { save(library, key: "library") }
    private func saveHistory() { save(history, key: "modshelf.history") }
    private func record(_ id: String, title: String, result: String, error: String? = nil, imageURL: String? = nil) {
        history.insert(DownloadRecord(workshopID: id, title: title, date: Date(), result: result, error: error, imageURL: imageURL), at: 0)
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
        guard let id = Self.workshopID(from: input) else {
            preview = nil
            errorMessage = "Paste a valid Steam Workshop URL or numeric item ID."
            return
        }
        isFetching = true
        preview = nil
        errorMessage = ""
        Task {
            let result = await Self.metadata(id: id)
            if let result {
                preview = result
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
                                    author: "Creator ID: \(item["creator"] as? String ?? "Unknown")",
                                    description: cleanHTML(item["description"] as? String ?? "No description provided."),
                                    imageURL: item["preview_url"] as? String ?? "",
                                    updatedAt: item["time_updated"] as? Int ?? 0)
        } catch { return nil }
    }
    private static func cleanHTML(_ html: String) -> String {
        var value = html
        // Remove embedded image blocks; plain text descriptions should not show raw image tags or URLs.
        value = value.replacingOccurrences(of: "\\[img\\][\\s\\S]*?\\[/img\\]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "<img\\b[^>]*>", with: "", options: .regularExpression)
        // Convert common HTML formatting into Markdown so the description retains its hierarchy.
        value = value.replacingOccurrences(of: "(?is)<h[1-6]\\b[^>]*>(.*?)</h[1-6]>", with: "\n\n**$1**\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<(?:b|strong)\\b[^>]*>(.*?)</(?:b|strong)>", with: "**$1**", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<(?:i|em)\\b[^>]*>(.*?)</(?:i|em)>", with: "*$1*", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)<li\\b[^>]*>(.*?)</li>", with: "\n• $1", options: .regularExpression)
        value = value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "</p\\s*>", with: "\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Steam Workshop descriptions frequently use BBCode instead of HTML.
        value = value.replacingOccurrences(of: "(?is)\\[h[1-6]\\](.*?)\\[/h[1-6]\\]", with: "\n\n**$1**\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)\\[(?:b|strong)\\](.*?)\\[/(?:b|strong)\\]", with: "**$1**", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?is)\\[(?:i|em)\\](.*?)\\[/(?:i|em)\\]", with: "*$1*", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[\\*\\]", with: "\n• ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[/?(?:u|strike|list|olist|hr)\\]", with: "\n", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[url(?:=[^\\]]*)?\\]", with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[/url\\]", with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "\\[[a-zA-Z][a-zA-Z0-9_]*(?:=[^\\]]*)?\\]", with: "", options: .regularExpression)
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&#10;", "\n")] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        value = value.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard isAuthenticated else { operationMessage = "Sign in to Steam to download this item."; showLogin = true; return }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a valid Workshop URL or ID."; return }
        activeID = id
        let meta = preview?.id == id ? preview! : WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "Unknown creator", description: "", imageURL: "", updatedAt: 0)
        activeTitle = meta.title
        let finalFolder = downloadsRoot.appendingPathComponent(id, isDirectory: true)
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
        status = "Starting download…"
        lastOutcome = ""
        lastObservedTerminalStatus = ""
        record(id, title: meta.title, result: "Downloading", imageURL: meta.imageURL.isEmpty ? nil : meta.imageURL)
        startPolling()
        // Store staging path in memory so only a verified completed download is promoted.
        UserDefaults.standard.set(staging.path, forKey: "modshelf.activeStaging")
        UserDefaults.standard.set(finalFolder.path, forKey: "modshelf.activeFinal")
    }

    func refreshState() {
        let nextStatus = engine.status()
        let nextProgress = min(1, max(0, engine.progress()))
        let nextFile = engine.currentFile()

        // Avoid triggering SwiftUI updates when the engine state has not changed.
        if status != nextStatus { status = nextStatus }
        if abs(progress - nextProgress) > 0.001 { progress = nextProgress }
        if currentFile != nextFile { currentFile = nextFile }

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
                if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                try FileManager.default.moveItem(at: staging, to: final)
                success = true
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
            saveLibrary(); updateHistory(id: activeID, result: "Downloaded", error: nil)
            refreshLibraryBytes()
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
            if let meta = preview, meta.id == id, !meta.imageURL.isEmpty { history[index].imageURL = meta.imageURL }
        } else { record(id, title: activeTitle, result: result, error: error) }
    }
    func cancel() { engine.cancelDownload(); status = "Cancelling download…" }

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
    func export(_ item: WorkshopItem) {
        let source = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { errorMessage = "Downloaded files could not be found. Use Verify files to check the library entry."; return }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Workshop-\(item.id).zip")
        do { try? FileManager.default.removeItem(at: zip); try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: true); shareURL = zip }
        catch { errorMessage = "ZIP export failed: \(error.localizedDescription)" }
    }
    func verify(_ item: WorkshopItem) {
        operationMessage = "Verifying files for \(item.title ?? item.id)…"
        let folder = item.folder
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { () -> (Bool, Int, String?) in
                guard FileManager.default.fileExists(atPath: folder) else { return (false, 0, "Folder is missing") }
                do {
                    let files = try FileManager.default.subpathsOfDirectory(atPath: folder)
                    return (!files.isEmpty, files.count, files.isEmpty ? "Folder contains no files" : nil)
                } catch { return (false, 0, error.localizedDescription) }
            }.value
            if result.0 { self.operationMessage = "Verified \(result.1) files for item \(item.id)." }
            else { self.operationMessage = "Verification failed for \(item.id): \(result.2 ?? "No files found")." }
        }
    }

    func verifyAllFiles() {
        guard !isVerifyingAll else { return }
        guard !library.isEmpty else { operationMessage = "Your library is empty."; return }
        isVerifyingAll = true
        let entries = library.map { ($0.id, $0.folder) }
        operationMessage = "Verifying 0 of \(entries.count) items…"
        Task { @MainActor in
            var valid = 0
            var missing: [String] = []
            for (index, entry) in entries.enumerated() {
                operationMessage = "Verifying \(index + 1) of \(entries.count)…"
                let result = await Task.detached(priority: .utility) { () -> Bool in
                    guard FileManager.default.fileExists(atPath: entry.1),
                          let files = try? FileManager.default.subpathsOfDirectory(atPath: entry.1) else { return false }
                    return !files.isEmpty
                }.value
                if result { valid += 1 } else { missing.append(entry.0) }
            }
            isVerifyingAll = false
            if missing.isEmpty {
                operationMessage = "Verified all \(valid) library items."
            } else {
                operationMessage = "Verified \(valid) of \(entries.count) items. Missing or empty: \(missing.joined(separator: ", "))."
            }
        }
    }

    func checkUpdates(_ item: WorkshopItem) {
        guard !isCheckingUpdates else { operationMessage = "An update check is already running."; return }
        isCheckingUpdates = true
        operationMessage = "Checking for updates…"
        Task { @MainActor in
            let success = await refreshMetadata(for: item)
            isCheckingUpdates = false
            if success, let latest = library.first(where: { $0.id == item.id }) {
                operationMessage = latest.updateAvailable ? "Update available: \(latest.title ?? latest.id)" : "No update detected for \(latest.title ?? latest.id)."
            } else {
                operationMessage = "Could not check item \(item.id). It may be private, deleted, or Steam may be rate-limiting requests."
            }
        }
    }

    private func refreshMetadata(for item: WorkshopItem) async -> Bool {
        guard let metadata = await Self.metadata(id: item.id), let index = library.firstIndex(where: { $0.id == item.id }) else { return false }
        let oldStamp = library[index].publishedUpdatedAt ?? 0
        library[index].updateAvailable = oldStamp > 0 && metadata.updatedAt > oldStamp
        library[index].publishedUpdatedAt = metadata.updatedAt
        library[index].lastCheckedAt = Date()
        library[index].title = metadata.title
        library[index].author = metadata.author
        library[index].description = metadata.description
        library[index].imageURL = metadata.imageURL
        saveLibrary()
        return true
    }

    func checkAllUpdates() {
        guard !isCheckingUpdates else { operationMessage = "An update check is already running."; return }
        guard !library.isEmpty else { operationMessage = "Your library is empty."; return }
        isCheckingUpdates = true
        let entries = library
        Task { @MainActor in
            var checked = 0
            var updated = 0
            var failed = 0
            for item in entries {
                operationMessage = "Checking updates: \(checked + 1) of \(entries.count)…"
                if await refreshMetadata(for: item) {
                    checked += 1
                    if library.first(where: { $0.id == item.id })?.updateAvailable == true { updated += 1 }
                } else { failed += 1 }
                if checked + failed < entries.count { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            isCheckingUpdates = false
            operationMessage = "Update check complete: \(checked) checked, \(updated) update(s) available, \(failed) failed."
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
    func libraryBytes() -> Int64 { libraryStorageBytes }

    func refreshLibraryBytes() {
        let folders = library.map(\.folder)
        Task { @MainActor in
            let total = await Task.detached(priority: .utility) { () -> Int64 in
                let fm = FileManager.default
                var total: Int64 = 0
                for folder in folders {
                    guard let enumerator = fm.enumerator(atPath: folder) else { continue }
                    for case let path as String in enumerator {
                        let fullPath = URL(fileURLWithPath: folder).appendingPathComponent(path).path
                        if let attrs = try? fm.attributesOfItem(atPath: fullPath), let size = attrs[.size] as? NSNumber {
                            total += size.int64Value
                        }
                    }
                }
                return total
            }.value
            libraryStorageBytes = total
        }
    }

}

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = true
    @State private var selectedTab = 0
    @State private var showShare = false
    @State private var popupItem: WorkshopItem?
    @State private var contextItem: WorkshopItem?
    @State private var contextHistory: DownloadRecord?
    @State private var searchText = ""
    @State private var sortOrder = "Recently added"
    @State private var showingHistory = false
    @State private var inputWasSubmitted = false
    @State private var expandedDownloadDescription = false
    @State private var pendingDeleteItem: WorkshopItem?

    private let sortOrders = ["Recently added", "Oldest added", "Name", "Updates first"]

    private var filteredLibrary: [WorkshopItem] {
        let filtered = store.library.filter {
            searchText.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(searchText) || $0.id.contains(searchText) || ($0.author ?? "").localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case "Name": return filtered.sorted { ($0.title ?? $0.id).localizedCaseInsensitiveCompare($1.title ?? $1.id) == .orderedAscending }
        case "Updates first": return filtered.sorted { $0.updateAvailable && !$1.updateAvailable }
        case "Oldest added": return filtered.sorted { $0.addedAt < $1.addedAt }
        default: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                accountHeader
                if !store.errorMessage.isEmpty {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(store.errorMessage).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { store.errorMessage = "" } label: { Image(systemName: "xmark").font(.caption.bold()) }.accessibilityLabel("Dismiss error")
                    }.padding(11).background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14).padding(.bottom, 8)
                }
                TabView(selection: $selectedTab) {
                    downloadView.tabItem { Label("Download", systemImage: "arrow.down.circle") }.tag(0)
                    WorkshopBrowserView(onValidItem: { url in
                        store.browserURL = url
                        store.input = url.absoluteString
                        inputWasSubmitted = false
                        selectedTab = 0
                        store.fetchPreview()
                    }, requestedURL: $store.browserURL)
                    .tabItem { Label("Workshop", systemImage: "safari") }.tag(1)
                    libraryView.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(2)
                    optionsView.tabItem { Label("Options", systemImage: "gearshape") }.tag(3)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(Color.accentColor)
            .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))

            if let item = popupItem {
                Color.black.opacity(0.34).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } }
                ItemDetailPopup(item: item, store: store, showIDs: showIDs,
                                onClose: { withAnimation(.easeOut(duration: 0.16)) { popupItem = nil } },
                                onOpenWorkshop: { openWorkshop(item.id); popupItem = nil },
                                onDelete: { requestDelete(item); popupItem = nil })
                    .padding(20).transition(.scale(scale: 0.97).combined(with: .opacity)).zIndex(5)
            }
            if let item = contextItem {
                Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.14)) { contextItem = nil } }.zIndex(6)
                ItemActionPopup(item: item,
                                openWorkshop: { openWorkshop(item.id); contextItem = nil },
                                copyID: { UIPasteboard.general.string = item.id; store.operationMessage = "Workshop ID copied."; contextItem = nil },
                                checkUpdates: { store.checkUpdates(item); contextItem = nil },
                                verify: { store.verify(item); contextItem = nil },
                                export: { store.export(item); contextItem = nil },
                                delete: { requestDelete(item); contextItem = nil },
                                close: { contextItem = nil })
                    .padding(28).transition(.scale(scale: 0.96).combined(with: .opacity)).zIndex(7)
            }
            if let record = contextHistory {
                Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.14)) { contextHistory = nil } }.zIndex(8)
                HistoryActionPopup(record: record,
                                   openWorkshop: { openWorkshop(record.workshopID); contextHistory = nil },
                                   copyID: { UIPasteboard.general.string = record.workshopID; store.operationMessage = "Workshop ID copied."; contextHistory = nil },
                                   retry: { store.retry(record); selectedTab = 0; contextHistory = nil },
                                   close: { contextHistory = nil })
                    .padding(28).transition(.scale(scale: 0.96).combined(with: .opacity)).zIndex(9)
            }
            if let item = pendingDeleteItem {
                Color.black.opacity(0.38).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { pendingDeleteItem = nil }.zIndex(10)
                DeleteConfirmationPopup(title: item.title ?? "Workshop item \(item.id)",
                                        confirm: { store.remove(item); pendingDeleteItem = nil },
                                        cancel: { pendingDeleteItem = nil })
                    .padding(30).zIndex(11)
            }
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showShare, onDismiss: { store.shareURL = nil }) { if let url = store.shareURL { ShareSheet(activityItems: [url]) } }
        .onChange(of: store.shareURL) { showShare = $0 != nil }
        .onChange(of: confirmDelete) { UserDefaults.standard.set($0, forKey: "options.confirmDelete") }
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text("ModShelf").font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button {
                if !store.isAuthenticated { store.showLogin = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                    Text(store.isAuthenticated ? "Signed in" : "Sign in")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(store.isAuthenticated ? Color.green : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(store.isAuthenticated ? Color.green.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isAuthenticated ? "Signed in to Steam" : "Sign in to Steam")
        }
        .padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private var downloadView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find a Workshop mod").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Paste a Steam Workshop link or item ID to get started.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Required · Workshop URL or ID", text: $store.input)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                                .onSubmit { submitLookup() }
                                .onChange(of: store.input) { _ in if inputWasSubmitted { inputWasSubmitted = false } }
                            if !store.input.isEmpty {
                                Button { store.input = ""; store.preview = nil; inputWasSubmitted = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear Workshop URL or ID")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(inputWasSubmitted && WorkshopStore.workshopID(from: store.input) == nil ? Color.red.opacity(0.75) : Color.primary.opacity(0.06), lineWidth: 1))
                        if inputWasSubmitted && WorkshopStore.workshopID(from: store.input) == nil {
                            Text("Enter a Workshop URL or numeric item ID to continue.").font(.caption).foregroundStyle(.red).padding(.leading, 4)
                        }
                        Button(action: submitLookup) {
                            HStack(spacing: 8) {
                                if store.isFetching { ProgressView().tint(.white) }
                                Text(store.isFetching ? "Looking up…" : "Look up item")
                                Spacer()
                                Image(systemName: "magnifyingglass")
                            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 13).padding(.vertical, 10).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).disabled(store.isFetching || store.isBusy)
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    if store.isFetching { HStack(spacing: 10) { ProgressView(); Text("Loading Workshop details…").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 4) }

                    if let item = store.preview {
                        metadataCard(item)
                        if store.isBusy {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(store.status).font(.headline); Spacer(); Text("\(Int(store.progress * 100))%").font(.subheadline.monospacedDigit().weight(.semibold)) }
                                ProgressView(value: store.progress).tint(.accentColor)
                                if !store.currentFile.isEmpty { Text(store.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Button("Cancel download", role: .destructive) { store.cancel() }.buttonStyle(.bordered)
                            }.padding(15).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            Button { dismissKeyboard(); store.download(item.id) } label: {
                                Label("Download mod", systemImage: "arrow.down.to.line.compact").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    } else {
                        Button { selectedTab = 1 } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "safari.fill").font(.title2).foregroundStyle(Color.accentColor).frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Start browsing").font(.headline)
                                    Text("Open the Steam Workshop and choose a mod.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }

                    if !store.operationMessage.isEmpty { operationBanner }
                }.padding(.horizontal, 15).padding(.bottom, 22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() }.padding(.horizontal, 9).padding(.vertical, 5).background(Color.gray.opacity(0.22), in: Capsule()) } }
        }
    }

    private func submitLookup() {
        dismissKeyboard()
        guard WorkshopStore.workshopID(from: store.input) != nil else { inputWasSubmitted = true; return }
        inputWasSubmitted = false
        store.fetchPreview()
    }

    private var operationBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            if store.isCheckingUpdates || store.isVerifyingAll { ProgressView().scaleEffect(0.8) }
            else { Image(systemName: "info.circle.fill").foregroundStyle(.secondary) }
            Text(store.operationMessage).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.operationMessage = "" } label: { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary) }.accessibilityLabel("Dismiss status")
        }.padding(11).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metadataCard(_ item: WorkshopMetadata) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill)).overlay(ProgressView().scaleEffect(0.8)) }
                    .frame(height: 170).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(item.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            Text(item.author).font(.subheadline).foregroundStyle(.secondary)
            if !item.description.isEmpty { ExpandableDescription(text: item.description, lineLimit: 7) }
            if showIDs { Text("Workshop ID: \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            if item.updatedAt > 0 { Label("Updated \(Date(timeIntervalSince1970: TimeInterval(item.updatedAt)), style: .date)", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 9) {
                Button { openWorkshop(item.id) } label: { Label("Workshop page", systemImage: "safari").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { UIPasteboard.general.string = item.id; store.operationMessage = "Workshop ID copied." } label: { Image(systemName: "doc.on.doc").frame(width: 38, height: 34) }.buttonStyle(.bordered).accessibilityLabel("Copy Workshop ID")
            }
        }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var libraryView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(showingHistory ? "Download history" : "Library").font(.system(size: 27, weight: .bold, design: .rounded))
                        Text(showingHistory ? "Recent downloads and attempts" : "\(store.library.count) mods · \(ByteCountFormatter.string(fromByteCount: store.libraryBytes(), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary).contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    if !showingHistory {
                        Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 38, height: 38) }.buttonStyle(.bordered).accessibilityLabel("Show download history")
                        Button { cycleSort() } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 38, height: 38) }.buttonStyle(.bordered).accessibilityLabel("Sort: \(sortOrder)")
                        Button { store.checkAllUpdates() } label: { if store.isCheckingUpdates { ProgressView().frame(width: 38, height: 38) } else { Image(systemName: "arrow.clockwise").frame(width: 38, height: 38) } }.buttonStyle(.bordered).disabled(store.isCheckingUpdates).accessibilityLabel("Check all for updates")
                        Button { store.verifyAllFiles() } label: { if store.isVerifyingAll { ProgressView().frame(width: 38, height: 38) } else { Image(systemName: "checkmark.shield").frame(width: 38, height: 38) } }.buttonStyle(.bordered).disabled(store.isVerifyingAll).accessibilityLabel("Verify all files")
                    } else {
                        Button { store.clearHistory() } label: { Image(systemName: "trash").frame(width: 38, height: 38) }.buttonStyle(.bordered).disabled(store.history.isEmpty).accessibilityLabel("Clear history")
                        Button { showingHistory = false } label: { Image(systemName: "xmark").frame(width: 38, height: 38) }.buttonStyle(.bordered).accessibilityLabel("Return to library")
                    }
                }.padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 12)

                if !store.operationMessage.isEmpty { operationBanner.padding(.horizontal, 12).padding(.bottom, 9) }

                if showingHistory {
                    historyContent
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search library", text: $searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                    }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14).padding(.bottom, 7)

                    if store.library.isEmpty {
                        emptyState("Your library is empty", detail: "Downloaded mods will appear here. Browse the Workshop to find one.", symbol: "square.grid.2x2")
                        Button { selectedTab = 1 } label: { Label("Browse Workshop", systemImage: "safari").frame(maxWidth: .infinity).padding(.vertical, 5) }.buttonStyle(.borderedProminent).padding(.horizontal, 24)
                    } else if filteredLibrary.isEmpty {
                        emptyState("No matches", detail: "Try a different search term.", symbol: "magnifyingglass")
                    } else if compactLibrary {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)], spacing: 0) {
                                ForEach(Array(filteredLibrary.enumerated()), id: \.element.id) { index, item in
                                    VStack(spacing: 0) {
                                        HStack(alignment: .top, spacing: 3) {
                                            Spacer(minLength: 0)
                                            Button { popupItem = item } label: {
                                                VStack(spacing: 7) {
                                                    modIcon(item.imageURL ?? "", size: 96)
                                                        .overlay(alignment: .topTrailing) { if item.updateAvailable { Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.orange).background(Circle().fill(Color(uiColor: .systemGroupedBackground))).offset(x: 3, y: -3) } }
                                                    Text(item.title ?? "Workshop item \(item.id)").font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                                                    if showIDs { Text(item.id).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                                                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                            }.buttonStyle(.plain)
                                            Button { contextItem = item } label: { Image(systemName: "ellipsis").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 28, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Actions for \(item.title ?? item.id)")
                                            Spacer(minLength: 0)
                                        }.padding(.horizontal, 5)
                                        Rectangle().fill(Color.gray.opacity(0.20)).frame(height: 0.6).padding(.horizontal, 6)
                                    }
                                }
                            }.padding(.horizontal, 8)
                        }.scrollDismissesKeyboard(.interactively)
                    } else {
                        List {
                            ForEach(filteredLibrary) { item in
                                HStack(spacing: 11) {
                                    Button { popupItem = item } label: {
                                        HStack(spacing: 11) {
                                            modIcon(item.imageURL ?? "", size: 62)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.title ?? "Workshop item \(item.id)").font(.subheadline.weight(.semibold)).lineLimit(2)
                                                Text(item.author ?? "Unknown creator").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                Text(item.updateAvailable ? "Update available" : "Added \(item.addedAt, style: .date)").font(.caption2).foregroundStyle(item.updateAvailable ? .orange : .secondary)
                                            }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Spacer(minLength: 0)
                                    Button { contextItem = item } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 30, height: 42) }.buttonStyle(.plain).accessibilityLabel("Actions for \(item.title ?? item.id)")
                                }.listRowBackground(Color(uiColor: .systemGroupedBackground)).listRowSeparatorTint(Color.gray.opacity(0.2))
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var historyContent: some View {
        Group {
            if store.history.isEmpty {
                emptyState("No download history", detail: "Download attempts and results will appear here.", symbol: "clock.arrow.circlepath")
            } else {
                List {
                    ForEach(store.history) { record in
                        HStack(spacing: 11) {
                            modIcon(record.imageURL ?? store.library.first(where: { $0.id == record.workshopID })?.imageURL ?? "", size: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                HStack(spacing: 5) {
                                    Circle().fill(historyColor(record.result)).frame(width: 6, height: 6)
                                    Text(record.result).font(.caption.weight(.medium))
                                    Text("· \(record.date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                                }.foregroundStyle(historyColor(record.result))
                                if let reason = record.error, !reason.isEmpty { Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                                Text("ID \(record.workshopID)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button { contextHistory = record } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 32, height: 42) }.buttonStyle(.plain).accessibilityLabel("Actions for \(record.title)")
                        }.listRowBackground(Color(uiColor: .systemGroupedBackground)).listRowSeparatorTint(Color.gray.opacity(0.2))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }

    private var optionsView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Preferences").font(.system(size: 28, weight: .bold, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("APPEARANCE")
                        HStack { Label("Theme", systemImage: "circle.lefthalf.filled"); Spacer(); Button { cycleAppearance() } label: { HStack(spacing: 6) { Text(appearance); Image(systemName: "arrow.left.arrow.right").font(.caption) }.font(.subheadline.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.gray.opacity(0.14), in: Capsule()) } }.padding(14)
                        Divider().padding(.leading, 14)
                        Toggle(isOn: $compactLibrary) { Label("Compact library", systemImage: "square.grid.2x2") }.padding(14)
                        Divider().padding(.leading, 14)
                        Toggle(isOn: $showIDs) { Label("Show Workshop IDs", systemImage: "number") }.padding(14)
                    }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("DOWNLOADS")
                        Toggle(isOn: $confirmDelete) { Label("Confirm before deleting", systemImage: "trash") }.padding(14)
                        Divider().padding(.leading, 14)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) { Text("Download folder").font(.subheadline.weight(.medium)); Text("On My iPhone / ModShelf / Downloaded Mods").font(.caption).foregroundStyle(.secondary) }
                        }.padding(14)
                        Divider().padding(.leading, 14)
                        Button { store.clearTemporaryFiles() } label: { Label("Clear temporary files", systemImage: "trash.slash").frame(maxWidth: .infinity, alignment: .leading).padding(14) }.buttonStyle(.plain)
                    }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("STEAM ACCOUNT")
                        HStack(spacing: 10) {
                            Image(systemName: store.isAuthenticated ? "checkmark.shield.fill" : "person.crop.circle").font(.title2).foregroundStyle(store.isAuthenticated ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) { Text(store.isAuthenticated ? "Connected to Steam" : "Not signed in").font(.subheadline.weight(.semibold)); Text(store.isAuthenticated ? "Your Steam session is active." : "Sign in to download Workshop files.").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }.padding(14)
                        if store.isAuthenticated {
                            Divider().padding(.leading, 14)
                            Button(role: .destructive) { store.signOut(); store.operationMessage = "Signed out of Steam." } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity, alignment: .leading).padding(14) }.buttonStyle(.plain)
                        } else {
                            Divider().padding(.leading, 14)
                            Button { store.showLogin = true } label: { Label("Sign in to Steam", systemImage: "person.crop.circle.badge.checkmark").frame(maxWidth: .infinity, alignment: .leading).padding(14) }.buttonStyle(.plain)
                        }
                    }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    Text("Steam sign-in is used to authenticate Workshop downloads. Your saved credentials are kept in the iOS Keychain; the session cache is stored in the app's private support directory.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
                    if !store.operationMessage.isEmpty { operationBanner }
                }.padding(.horizontal, 15).padding(.bottom, 28)
            }.background(Color(uiColor: .systemGroupedBackground)).toolbar(.hidden, for: .navigationBar)
        }
    }

    private var loginSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to Steam").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Steam sign-in is needed to authenticate your account before ModShelf can download Workshop files. ModShelf does not need your Steam Guard code unless Steam asks for it.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    TextField("Steam username", text: $store.username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(13)
                    Divider().padding(.leading, 13)
                    SecureField("Password", text: $store.password).textInputAutocapitalization(.never).autocorrectionDisabled().padding(13)
                    Divider().padding(.leading, 13)
                    TextField("Steam Guard code (if requested)", text: $store.guardCode).textInputAutocapitalization(.characters).autocorrectionDisabled().padding(13)
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
                Button { Task { await store.signIn() } } label: {
                    HStack { if store.isBusy { ProgressView().tint(.white) }; Text(store.isBusy ? "Signing in…" : "Sign in") }.frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isBusy)
                if !store.errorMessage.isEmpty {
                    Text(store.errorMessage).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(20).background(Color(uiColor: .systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { store.showLogin = false } } }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func cycleSort() {
        let index = sortOrders.firstIndex(of: sortOrder) ?? 0
        sortOrder = sortOrders[(index + 1) % sortOrders.count]
    }

    private func cycleAppearance() {
        let values = ["System", "Light", "Dark"]
        let index = values.firstIndex(of: appearance) ?? 0
        appearance = values[(index + 1) % values.count]
    }

    private func openWorkshop(_ id: String) {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else { return }
        store.browserURL = url
        selectedTab = 1
    }

    private func requestDelete(_ item: WorkshopItem) {
        if confirmDelete { pendingDeleteItem = item } else { store.remove(item) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary).tracking(0.8).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 5)
    }

    private func modIcon(_ source: String, size: CGFloat) -> some View {
        Group {
            if let url = URL(string: source), !source.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "shippingbox").font(.system(size: size * 0.36)).foregroundStyle(.tertiary) }
            } else { Image(systemName: "shippingbox").font(.system(size: size * 0.36)).foregroundStyle(.tertiary) }
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }

    private func historyColor(_ result: String) -> Color {
        switch result { case "Downloaded": return .green; case "Failed": return .red; case "Cancelled": return .secondary; default: return .accentColor }
    }

    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

struct ExpandableDescription: View {
    let text: String
    var lineLimit: Int = 7
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.subheadline).lineLimit(expanded ? nil : lineLimit).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if text.count > 260 {
                Button(expanded ? "Read less" : "Read more…") { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct ItemDetailPopup: View {
    let item: WorkshopItem
    @ObservedObject var store: WorkshopStore
    let showIDs: Bool
    let onClose: () -> Void
    let onOpenWorkshop: () -> Void
    let onDelete: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if let urlString = item.imageURL, let url = URL(string: urlString), !urlString.isEmpty {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary) }
                        .frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
                } else { Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary).frame(width: 76, height: 76) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title ?? "Workshop item \(item.id)").font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(item.author ?? "Unknown creator").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if showIDs { Text("ID \(item.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                    if item.updateAvailable { Label("Update available", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Close mod details")
            }.padding(16)
            if let description = item.description, !description.isEmpty {
                ScrollView { ExpandableDescription(text: description, lineLimit: 7).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8) }
                    .frame(maxHeight: 150)
            }
            Divider().padding(.horizontal, 14)
            VStack(spacing: 3) {
                popupAction("Open Workshop page", symbol: "safari", action: onOpenWorkshop)
                popupAction("Check for updates", symbol: "arrow.clockwise") { store.checkUpdates(item); onClose() }
                popupAction("Verify downloaded files", symbol: "checkmark.shield") { store.verify(item); onClose() }
                popupAction("Export as ZIP", symbol: "square.and.arrow.up") { store.export(item); onClose() }
                popupAction("Copy Workshop ID", symbol: "doc.on.doc") { UIPasteboard.general.string = item.id; store.operationMessage = "Workshop ID copied."; onClose() }
                popupAction("Delete download", symbol: "trash", destructive: true, action: onDelete)
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: 410).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.20), radius: 24, y: 10)
    }
    private func popupAction(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: symbol).frame(width: 22); Text(title); Spacer() }
                .font(.subheadline.weight(.medium)).foregroundStyle(destructive ? Color.red : Color.primary).padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ItemActionPopup: View {
    let item: WorkshopItem
    let openWorkshop: () -> Void
    let copyID: () -> Void
    let checkUpdates: () -> Void
    let verify: () -> Void
    let export: () -> Void
    let delete: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title ?? "Workshop item \(item.id)").font(.headline).lineLimit(2).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 7)
            action("Open Workshop link", "safari", openWorkshop)
            action("Copy Workshop ID", "doc.on.doc", copyID)
            action("Check for updates", "arrow.clockwise", checkUpdates)
            action("Verify files", "checkmark.shield", verify)
            action("Export ZIP", "square.and.arrow.up", export)
            action("Delete download", "trash", delete, destructive: true)
        }.padding(.bottom, 7).frame(maxWidth: 310).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.06), lineWidth: 1)).shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }
    private func action(_ title: String, _ symbol: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) { HStack(spacing: 11) { Image(systemName: symbol).frame(width: 20); Text(title); Spacer() }.font(.subheadline).foregroundStyle(destructive ? Color.red : Color.primary).padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

struct HistoryActionPopup: View {
    let record: DownloadRecord
    let openWorkshop: () -> Void
    let copyID: () -> Void
    let retry: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title).font(.headline).lineLimit(2).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 7)
            action("Open Workshop link", "safari", openWorkshop)
            action("Copy Workshop ID", "doc.on.doc", copyID)
            if record.result == "Failed" || record.result == "Cancelled" { action("Retry download", "arrow.clockwise", retry) }
            action("Close", "xmark", close)
        }.padding(.bottom, 7).frame(maxWidth: 310).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.06), lineWidth: 1)).shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }
    private func action(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 11) { Image(systemName: symbol).frame(width: 20); Text(title); Spacer() }.font(.subheadline).foregroundStyle(.primary).padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

struct DeleteConfirmationPopup: View {
    let title: String
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete download?").font(.title3.bold())
            Text("\(title) and its downloaded files will be removed from ModShelf.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered)
                Spacer()
                Button("Delete", role: .destructive, action: confirm).buttonStyle(.borderedProminent)
            }.padding(.top, 4)
        }.padding(18).frame(maxWidth: 350).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)).shadow(color: .black.opacity(0.22), radius: 22, y: 9)
    }
}

struct WorkshopBrowserView: View {
    let onValidItem: (URL) -> Void
    @Binding var requestedURL: URL?
    @State private var webView: WKWebView?
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showCopy = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 17) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack).accessibilityLabel("Back")
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!canGoForward).accessibilityLabel("Forward")
                Button { if let url = currentURL { webView?.load(URLRequest(url: url)) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.8) }
                if showCopy { Button("Use link") { if let url = currentURL { onValidItem(url) } }.font(.subheadline.weight(.semibold)) }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(Color(uiColor: .systemGroupedBackground))
            WorkshopWebContainer(webView: $webView, currentURL: $currentURL, canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, showCopy: $showCopy, requestedURL: $requestedURL)
        }.background(Color(uiColor: .systemBackground))
            .onAppear {
                if let url = requestedURL, let webView {
                    webView.load(URLRequest(url: url))
                    requestedURL = nil
                }
            }
            .onChange(of: requestedURL) { url in
                guard let url, let webView else { return }
                webView.load(URLRequest(url: url))
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
    @Binding var requestedURL: URL?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let css = "#global_header,#footer,.global_header,.store_header,.supernav_container,#store_nav_area,.store_nav,.responsive_page_template_content>.breadcrumbs{display:none!important} body{padding-top:0!important;margin-top:0!important} .responsive_page_content{padding-top:0!important}"
        let script = WKUserScript(source: "(function(){var s=document.createElement('style');s.innerHTML='\(css)';document.head.appendChild(s);})();", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor.systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        webView = view
        let startURL = requestedURL ?? URL(string: "https://steamcommunity.com/workshop/")!
        view.load(URLRequest(url: startURL))
        if requestedURL != nil { DispatchQueue.main.async { self.requestedURL = nil } }
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WorkshopWebContainer
        var observations: [NSKeyValueObservation] = []
        init(_ parent: WorkshopWebContainer) { self.parent = parent }
        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoBack = v.canGoBack } },
                view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.canGoForward = v.canGoForward } },
                view.observe(\.isLoading, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.parent.isLoading = v.isLoading } },
                view.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in DispatchQueue.main.async { self?.updateURL(v.url) } }
            ]
        }
        func updateURL(_ url: URL?) {
            parent.currentURL = url
            guard let url, WorkshopStore.workshopID(from: url.absoluteString) != nil, url.path.contains("/sharedfiles/filedetails") else { parent.showCopy = false; return }
            parent.showCopy = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateURL(webView.url)
            let css = "#global_header,#footer,.global_header,.store_header,.supernav_container,#store_nav_area,.store_nav,.responsive_page_template_content>.breadcrumbs{display:none!important} body{padding-top:0!important;margin-top:0!important} .responsive_page_content{padding-top:0!important}"
            let escaped = css.replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("(function(){var s=document.getElementById('modshelf-clean-workshop');if(!s){s=document.createElement('style');s.id='modshelf-clean-workshop';document.head.appendChild(s)}s.innerHTML='\(escaped)';})();")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Steam frequently uses target="_blank". Load those links in this same WKWebView.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
