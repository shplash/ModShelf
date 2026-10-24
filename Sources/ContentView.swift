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

    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""
    private var activeTitle = ""
    private var lastObservedTerminalStatus = ""

    var isAuthenticated: Bool { engine.isAuthenticated() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var downloadsRoot: URL {
        let url = documents.appendingPathComponent("WorkshopDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    // Never clear this directory as part of temporary-cache cleanup: it contains Steam's session.
    private var sessionPath: String {
        let url = documents.appendingPathComponent("SteamSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
                status = "Workshop details loaded"
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
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p\\s*>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
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
        record(id, title: meta.title, result: "Downloading")
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
        Task {
            for item in library { checkUpdates(item); try? await Task.sleep(nanoseconds: 500_000_000) }
            status = "Update checks started for \(library.count) items"
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
    func libraryBytes() -> Int64 {
        let fm = FileManager.default
        return library.reduce(Int64(0)) { total, item in
            guard let enumerator = fm.enumerator(atPath: item.folder) else { return total }
            var sum = total
            for case let path as String in enumerator {
                let full = URL(fileURLWithPath: item.folder).appendingPathComponent(path)
                if let attrs = try? fm.attributesOfItem(atPath: full.path), let size = attrs[.size] as? NSNumber { sum += size.int64Value }
            }
            return sum
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
    @State private var selectedItem: WorkshopItem?
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
            NavigationStack { WorkshopBrowserView(onValidItem: { url in store.browserURL = url; store.input = url.absoluteString; selectedTab = 0; store.fetchPreview() }) }
                .tabItem { Label("Workshop", systemImage: "safari") }.tag(1)
            libraryView.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(2)
            historyView.tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(3)
            optionsView.tabItem { Label("Options", systemImage: "gearshape") }.tag(4)
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
        .sheet(item: $selectedItem) { item in ItemDetailSheet(item: item, store: store, showIDs: showIDs) }
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
                            TextField("Workshop URL or item ID", text: $store.input)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                                .onSubmit { dismissKeyboard(); store.fetchPreview() }
                            if !store.input.isEmpty { Button { store.input = ""; store.preview = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear item ID") }
                        }
                        Button { dismissKeyboard(); store.fetchPreview() } label: {
                            HStack { if store.isFetching { ProgressView().tint(.white) }; Text(store.isFetching ? "Looking up item…" : "Look up Workshop item"); Spacer(); Image(systemName: "magnifyingglass") }
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).disabled(store.isFetching || store.isBusy)
                    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    if store.isFetching { ProgressView("Fetching item details…").frame(maxWidth: .infinity, alignment: .leading) }
                    if let item = store.preview {
                        metadataCard(item)
                        if store.isBusy {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(store.status).font(.headline); Spacer(); Text("\(Int(store.progress * 100))%").monospacedDigit() }
                                ProgressView(value: store.progress)
                                if !store.currentFile.isEmpty { Text(store.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                Button("Cancel download", role: .destructive) { store.cancel() }.buttonStyle(.bordered)
                            }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            Button { store.download(item.id) } label: { Label("Download item", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity).padding(.vertical, 4) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                    accountCard
                    if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
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
            if !item.description.isEmpty { Text(item.description).font(.subheadline).lineLimit(7).textSelection(.enabled) }
            if showIDs { Text("Workshop ID: \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            if item.updatedAt > 0 { Label("Last updated \(Date(timeIntervalSince1970: TimeInterval(item.updatedAt)), style: .date)", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                Link(destination: item.pageURL) { Label("Workshop page", systemImage: "safari").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
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
                ToolbarItem(placement: .topBarLeading) { Menu {
                    Button("Check all for updates", systemImage: "arrow.clockwise") { store.checkAllUpdates() }
                    Button("Verify all files", systemImage: "checkmark.shield") { for item in store.library { store.verify(item) } }
                    Button("Clear download history", role: .destructive) { store.clearHistory() }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Library actions") }
                ToolbarItem(placement: .topBarTrailing) { Button { selectedTab = 0 } label: { Image(systemName: "plus") }.accessibilityLabel("Add Workshop item") }
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
                                HStack { Link("Workshop", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.workshopID)")!); Spacer(); Button("Copy ID") { UIPasteboard.general.string = item.workshopID; store.status = "Workshop ID copied" } }
                                    .font(.caption)
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
                    Button("Verify all downloaded files") { for item in store.library { store.verify(item) } }
                }
                Section("Workshop browser") { Text("The in-app browser keeps its own website session. It does not share login cookies with the Steam app or Safari.").font(.caption).foregroundStyle(.secondary) }
                Section("Steam account") {
                    LabeledContent("Status", value: store.isAuthenticated ? "Connected" : "Not connected")
                    Button(store.isAuthenticated ? "Account details" : "Sign in") { store.showLogin = true }
                    if store.isAuthenticated { Button("Sign out", role: .destructive) { store.signOut() } }
                }
                Section("Storage") {
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
                if store.isAuthenticated { Button("Sign out", role: .destructive) { store.signOut() } }
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
    let onValidItem: (URL) -> Void
    @State private var webView: WKWebView?
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showCopy = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack).accessibilityLabel("Back")
                Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!canGoForward).accessibilityLabel("Forward")
                Button { if let url = currentURL { webView?.load(URLRequest(url: url)) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.8) }
                if showCopy { Button("Use link") { if let url = currentURL { onValidItem(url) } } }
            }.padding(.horizontal).padding(.vertical, 10)
            WorkshopWebContainer(webView: $webView, currentURL: $currentURL, canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, showCopy: $showCopy)
        }.navigationTitle("Workshop").navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkshopWebContainer: UIViewRepresentable {
    @Binding var webView: WKWebView?
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var showCopy: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        webView = view
        view.load(URLRequest(url: URL(string: "https://steamcommunity.com/workshop/")!))
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
            guard let url, let id = WorkshopStore.workshopID(from: url.absoluteString), url.path.contains("/sharedfiles/filedetails") else { parent.showCopy = false; return }
            parent.showCopy = true
            _ = id
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateURL(webView.url) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
