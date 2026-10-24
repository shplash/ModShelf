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

    private let engine = SteamengineNewEngine()!
    private var poller: Timer?
    private var activeID = ""

    var isAuthenticated: Bool { engine.isAuthenticated() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var downloadsRoot: URL {
        let url = documents.appendingPathComponent("WorkshopDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var cachePath: String {
        let url = documents.appendingPathComponent("ModShelfCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    init() {
        library = Self.load([WorkshopItem].self, key: "library") ?? []
        let oldHistory = Self.load([String].self, key: "history") ?? []
        history = Self.load([DownloadRecord].self, key: "modshelf.history") ?? oldHistory.map {
            DownloadRecord(workshopID: $0, title: "Workshop item \($0)", date: Date(), result: "Attempted")
        }
        status = engine.status()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
        if !username.isEmpty && !password.isEmpty {
            Task { await signIn(automatic: true) }
        }
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

    static func workshopID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value.allSatisfy({ $0.isNumber }) { return value }
        guard let c = URLComponents(string: value),
              let host = c.host?.lowercased(),
              ["steamcommunity.com", "www.steamcommunity.com"].contains(host),
              c.path.contains("/sharedfiles/filedetails"),
              let id = c.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.allSatisfy({ $0.isNumber }) else { return nil }
        return id
    }

    func fetchPreview() {
        guard let id = Self.workshopID(from: input) else {
            errorMessage = "Paste a valid Steam Workshop URL or numeric item ID."; return
        }
        input = id
        isFetching = true
        errorMessage = ""
        Task {
            let result = await Self.metadata(id: id)
            await MainActor.run {
                self.preview = result ?? WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "Unknown author", description: "Details could not be loaded. You can still try downloading this item.", imageURL: "", updatedAt: 0)
                self.isFetching = false
            }
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
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any],
                  let details = response["publishedfiledetails"] as? [[String: Any]],
                  let item = details.first, (item["result"] as? Int) == 1 else { return nil }
            return WorkshopMetadata(id: id,
                                    title: item["title"] as? String ?? "Workshop item \(id)",
                                    author: item["creator"] as? String ?? "Unknown author",
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
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            if !automatic { showLogin = true }
            errorMessage = automatic ? "" : "Enter your Steam username and password."
            return
        }
        isBusy = true; status = "Signing in to Steam…"; errorMessage = ""
        let user = username
        let pass = password
        let code = guardCode
        let path = cachePath
        let activeEngine = engine
        let result = await Task.detached(priority: .userInitiated) {
            activeEngine.login(user, password: pass, guardCode: code, cachePath: path)
        }.value
        isBusy = false
        status = engine.status()
        if engine.isAuthenticated() || result.isEmpty {
            Keychain.write(username, key: "steam.username")
            Keychain.write(password, key: "steam.password")
            guardCode = ""
            showLogin = false
            status = "Signed in to Steam"
        } else {
            errorMessage = result.isEmpty ? engine.lastError() : result
            if !automatic { showLogin = true }
        }
    }
    func signOut() {
        engine.logout(); Keychain.delete("steam.password"); password = ""; guardCode = ""
        status = "Signed out"
    }

    func download(_ raw: String? = nil) {
        errorMessage = ""
        guard isAuthenticated else { errorMessage = "Sign in to Steam first."; showLogin = true; return }
        guard let id = Self.workshopID(from: raw ?? input) else { errorMessage = "Enter a valid Workshop URL or ID."; return }
        activeID = id
        let meta = preview?.id == id ? preview! : WorkshopMetadata(id: id, title: "Workshop item \(id)", author: "Unknown author", description: "", imageURL: "", updatedAt: 0)
        let folder = downloadsRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = engine.downloadWorkshopItem(id, targetDir: folder.path)
        if !result.isEmpty { errorMessage = result; status = result; return }
        isBusy = true; progress = 0; currentFile = ""; status = "Starting download…"
        if !history.contains(where: { $0.workshopID == id && $0.result == "Downloaded" }) {
            history.insert(DownloadRecord(workshopID: id, title: meta.title, date: Date(), result: "Downloading"), at: 0)
            saveHistory()
        }
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }
    func refreshState() {
        status = engine.status(); progress = min(1, max(0, engine.progress())); currentFile = engine.currentFile()
        guard isBusy else { return }
        let s = status.lowercased()
        if s.contains("download complete") || s == "complete" || s.contains("download finished") || s.contains("download failed") || s.contains("download cancelled") {
            isBusy = false; poller?.invalidate(); poller = nil
            let success = s.contains("complete") || s.contains("finished")
            let meta = preview?.id == activeID ? preview : nil
            if success {
                let existing = library.firstIndex(where: { $0.id == activeID })
                let item = WorkshopItem(id: activeID, folder: downloadsRoot.appendingPathComponent(activeID).path,
                                        addedAt: existing.map { library[$0].addedAt } ?? Date(), updatedAt: Date(),
                                        title: meta?.title, author: meta?.author, description: meta?.description,
                                        imageURL: meta?.imageURL, publishedUpdatedAt: meta?.updatedAt)
                if let index = existing { library[index] = item } else { library.insert(item, at: 0) }
            }
            if let index = history.firstIndex(where: { $0.workshopID == activeID && $0.result == "Downloading" }) {
                history[index].result = success ? "Downloaded" : (s.contains("cancel") ? "Cancelled" : "Failed")
                history[index].date = Date()
            }
            saveLibrary(); saveHistory()
        }
        if !engine.lastError().isEmpty && s.contains("error") { errorMessage = engine.lastError() }
    }
    func cancel() { engine.cancelDownload(); status = "Download cancelled"; isBusy = false; poller?.invalidate(); poller = nil }
    func remove(_ item: WorkshopItem) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.folder))
        library.removeAll { $0.id == item.id }; saveLibrary()
    }
    func requestDelete(_ item: WorkshopItem) {
        if UserDefaults.standard.object(forKey: "options.confirmDelete") as? Bool ?? true {
            pendingDelete = item; showDeleteConfirmation = true
        } else { remove(item) }
    }
    func export(_ item: WorkshopItem) {
        let source = URL(fileURLWithPath: item.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { errorMessage = "Downloaded files could not be found."; return }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Workshop-\(item.id).zip")
        try? FileManager.default.removeItem(at: zip)
        do { try FileManager.default.zipItem(at: source, to: zip, shouldKeepParent: true); shareURL = zip }
        catch { errorMessage = "ZIP export failed: \(error.localizedDescription)" }
    }
    func refreshMetadata(_ item: WorkshopItem) {
        Task {
            guard let m = await Self.metadata(id: item.id), let i = library.firstIndex(where: { $0.id == item.id }) else { return }
            library[i].title = m.title; library[i].author = m.author; library[i].description = m.description
            library[i].imageURL = m.imageURL; library[i].publishedUpdatedAt = m.updatedAt; saveLibrary()
        }
    }
    func clearHistory() { history.removeAll(); saveHistory(); UserDefaults.standard.removeObject(forKey: "history") }
    func clearCache() {
        let url = documents.appendingPathComponent("ModShelfCache", isDirectory: true)
        try? FileManager.default.removeItem(at: url); status = "Temporary cache cleared"
    }
}

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @AppStorage("options.appearance") private var appearance = "System"
    @AppStorage("options.confirmDelete") private var confirmDelete = true
    @AppStorage("options.showIDs") private var showIDs = false
    @AppStorage("options.compactLibrary") private var compactLibrary = false
    @AppStorage("options.externalLinks") private var externalLinks = false
    @State private var selectedTab = 0
    @State private var showShare = false

    var body: some View {
        TabView(selection: $selectedTab) {
            downloadView.tabItem { Label("Download", systemImage: "arrow.down.circle") }.tag(0)
            NavigationStack { WorkshopBrowserView().navigationTitle("Workshop").navigationBarTitleDisplayMode(.inline) }
                .tabItem { Label("Workshop", systemImage: "safari") }.tag(1)
            libraryView.tabItem { Label("Library", systemImage: "square.grid.2x2") }.tag(2)
            historyView.tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(3)
            optionsView.tabItem { Label("Options", systemImage: "gearshape") }.tag(4)
        }
        .tint(.primary)
        .preferredColorScheme(appearance == "System" ? nil : (appearance == "Dark" ? .dark : .light))
        .alert("ModShelf", isPresented: Binding(get: { !store.errorMessage.isEmpty }, set: { if !$0 { store.errorMessage = "" } })) {
            Button("OK", role: .cancel) { store.errorMessage = "" }
        } message: { Text(store.errorMessage) }
        .confirmationDialog("Delete this downloaded item?", isPresented: $store.showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = store.pendingDelete { store.remove(item) }; store.pendingDelete = nil }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        }
        .sheet(isPresented: $store.showLogin) { loginSheet.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showShare, onDismiss: { store.shareURL = nil }) {
            if let url = store.shareURL { ShareSheet(activityItems: [url]) }
        }
        .onChange(of: store.shareURL) { value in showShare = value != nil }
    }

    private var downloadView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ModShelf").font(.largeTitle.bold())
                        Text("Steam Workshop downloader").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Workshop URL or item ID", text: $store.input)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .submitLabel(.go).onSubmit { dismissKeyboard(); store.fetchPreview() }
                        Button("Go") { dismissKeyboard(); store.fetchPreview() }.buttonStyle(.borderedProminent)
                    }
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() } } }
                    if store.isFetching { ProgressView("Fetching Workshop details…") }
                    if let item = store.preview {
                        metadataCard(item)
                        if store.isBusy {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(store.status); Spacer(); Text("\(Int(store.progress * 100))%") }
                                ProgressView(value: store.progress)
                                if !store.currentFile.isEmpty { Text(store.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Button("Cancel download", role: .destructive) { store.cancel() }
                            }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            Button { store.download(item.id) } label: {
                                Label("Download item", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                    HStack {
                        Image(systemName: store.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                            .foregroundStyle(store.isAuthenticated ? .green : .secondary)
                        Text(store.isAuthenticated ? "Steam connected" : "Steam not connected")
                        Spacer()
                        Button(store.isAuthenticated ? "Account" : "Sign in") { store.showLogin = true }.buttonStyle(.bordered)
                    }
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("Download").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func metadataCard(_ item: WorkshopMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary).overlay(ProgressView()) }
                    .frame(height: 180).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(item.title).font(.title3.bold())
            Text("By \(item.author)").font(.subheadline).foregroundStyle(.secondary)
            Text(item.description.isEmpty ? "No description provided." : item.description).textSelection(.enabled)
            if showIDs { Text("Workshop ID: \(item.id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            HStack {
                Link("Open Workshop page", destination: item.pageURL)
                Spacer()
                if item.updatedAt > 0 { Text(Date(timeIntervalSince1970: TimeInterval(item.updatedAt)), style: .date).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private var libraryView: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty { emptyState("Your library is empty", detail: "Downloaded items will appear here.", symbol: "square.grid.2x2") }
                else {
                    List {
                        ForEach(store.library) { item in
                            HStack(alignment: .top, spacing: 12) {
                                if !compactLibrary { thumbnail(item.imageURL ?? "") }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title ?? "Workshop item \(item.id)").font(.headline).lineLimit(2)
                                    Text("By \(item.author ?? "Unknown author")").font(.subheadline).foregroundStyle(.secondary)
                                    if showIDs { Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                    Text("Added \(item.addedAt, style: .date)").font(.caption).foregroundStyle(.secondary)
                                    HStack(spacing: 12) {
                                        Link("Workshop page", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!)
                                        Button("Refresh") { store.refreshMetadata(item) }
                                        Button("Export ZIP") { store.export(item) }
                                    }.font(.caption)
                                }
                                Spacer(minLength: 0)
                                Menu {
                                    Button("Refresh details") { store.refreshMetadata(item) }
                                    Button("Export ZIP") { store.export(item) }
                                    Button("Delete download", role: .destructive) { store.requestDelete(item) }
                                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                            }.padding(.vertical, compactLibrary ? 1 : 5)
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("Library").toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button { selectedTab = 0 } label: { Image(systemName: "plus") } }
            }
        }
    }

    private var historyView: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty { emptyState("No download history", detail: "Download attempts will appear here.", symbol: "clock.arrow.circlepath") }
                else {
                    List {
                        ForEach(store.history) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.result == "Downloaded" ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(item.result == "Downloaded" ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text("ID \(item.workshopID) · \(item.result)").font(.caption).foregroundStyle(.secondary)
                                    Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("History")
        }
    }

    private var optionsView: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
                    }
                }
                Section("Library") {
                    Toggle("Confirm before deleting", isOn: $confirmDelete)
                    Toggle("Show Workshop IDs", isOn: $showIDs)
                    Toggle("Compact library rows", isOn: $compactLibrary)
                }
                Section("Workshop") {
                    Toggle("Open Workshop links externally", isOn: $externalLinks)
                    Text("Workshop website sign-in and downloader sign-in are separate sessions.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Steam account") {
                    LabeledContent("Status", value: store.isAuthenticated ? "Connected" : "Not connected")
                    Button(store.isAuthenticated ? "Manage account" : "Sign in") { store.showLogin = true }
                    if store.isAuthenticated { Button("Sign out", role: .destructive) { store.signOut() } }
                }
                Section("Storage") {
                    Button("Clear download history", role: .destructive) { store.clearHistory() }
                    Button("Clear temporary cache") { store.clearCache() }
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
                    Text("Credentials are saved in the iOS Keychain after successful sign-in. Steam may ask for a Guard code again.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign in") { Task { await store.signIn() } }.frame(maxWidth: .infinity).buttonStyle(.borderedProminent)
                if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
                if store.isAuthenticated { Button("Sign out", role: .destructive) { store.signOut() } }
            }.navigationTitle("Steam account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { store.showLogin = false } } }
        }
    }

    private func thumbnail(_ source: String) -> some View {
        Group {
            if let url = URL(string: source), !source.isEmpty {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { RoundedRectangle(cornerRadius: 8).fill(.quaternary) }
            } else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).overlay(Image(systemName: "shippingbox").foregroundStyle(.secondary)) }
        }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct WorkshopBrowserView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://steamcommunity.com/workshop/")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
