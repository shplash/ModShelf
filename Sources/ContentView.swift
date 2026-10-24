
import SwiftUI
import UIKit
import Security
import ZIPFoundation
import SteamEngine

@main
struct WorkshopDownloaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct WorkshopItem: Identifiable, Codable {
    var id: String
    var folder: String
    var addedAt: Date
    var updatedAt: Date
}

@MainActor
final class WorkshopStore: ObservableObject {
    @Published var workshopURL = ""
    @Published var username = ""
    @Published var password = ""
    @Published var guardCode = ""
    @Published var status = "Not connected"
    @Published var errorMessage = ""
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var isBusy = false
    @Published var library: [WorkshopItem] = []
    @Published var history: [String] = []
    @Published var exportURL: URL?

    private let engine = SteamengineNewEngine()!

    init() {
        library = Self.load([WorkshopItem].self, key: "library") ?? []
        history = Self.load([String].self, key: "history") ?? []
        username = Keychain.read("steam.username") ?? ""
        password = Keychain.read("steam.password") ?? ""
        status = engine.status()

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        key: String
    ) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var isAuthenticated: Bool {
        engine.isAuthenticated()
    }

    func signIn() {
        errorMessage = ""

        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            errorMessage = "Enter your Steam username and password."
            return
        }

        isBusy = true

        let user = username
        let pass = password
        let code = guardCode
        let engine = self.engine

        let cache = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        DispatchQueue.global(qos: .userInitiated).async {
            let result = engine.login(
                user,
                password: pass,
                guardCode: code,
                cachePath: cache.path
            )

            DispatchQueue.main.async {
                self.isBusy = false
                self.status = self.engine.status()

                if result.isEmpty {
                    Keychain.write(user, key: "steam.username")
                    Keychain.write(pass, key: "steam.password")
                    self.guardCode = ""
                } else {
                    self.errorMessage = result
                }
            }
        }
    }

    func signOut() {
        engine.logout()
        Keychain.delete("steam.password")
        password = ""
        status = "Not connected"
    }

    func download(_ input: String? = nil, existing: WorkshopItem? = nil) {
        errorMessage = ""

        guard isAuthenticated else {
            errorMessage = "Sign in to Steam first."
            return
        }

        let raw = input ?? workshopURL

        guard let id = Self.workshopID(from: raw) else {
            errorMessage = "Paste a valid Steam Workshop item URL or numeric item ID."
            return
        }

        let root = downloadsRoot()

        let folder = existing.map {
            URL(fileURLWithPath: $0.folder)
        } ?? root.appendingPathComponent(id, isDirectory: true)

        let result = engine.downloadWorkshopItem(id, targetDir: folder.path)

        if !result.isEmpty {
            errorMessage = result
            return
        }

        isBusy = true

        if !history.contains(id) {
            history.insert(id, at: 0)
        }
        save(history, key: "history")

        if !library.contains(where: { $0.id == id }) {
            library.insert(
                WorkshopItem(
                    id: id,
                    folder: folder.path,
                    addedAt: Date(),
                    updatedAt: Date()
                ),
                at: 0
            )
            save(library, key: "library")
        }

        workshopURL = ""
    }

    func remove(_ item: WorkshopItem) {
        library.removeAll { $0.id == item.id }
        save(library, key: "library")
    }

    func clearHistory() {
        history.removeAll()
        save(history, key: "history")
    }

    func clearTemporaryExports() {
        let temp = FileManager.default.temporaryDirectory

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files where
            file.lastPathComponent.hasPrefix("Workshop-")
            && file.pathExtension == "zip" {
            try? FileManager.default.removeItem(at: file)
        }

        exportURL = nil
    }

    func export(_ item: WorkshopItem) {
        let source = URL(
            fileURLWithPath: item.folder,
            isDirectory: true
        )

        guard FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "That item has not been downloaded to this device yet."
            return
        }

        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workshop-\(item.id).zip")

        try? FileManager.default.removeItem(at: zip)

        do {
            try FileManager.default.zipItem(
                at: source,
                to: zip,
                shouldKeepParent: true
            )
            exportURL = zip
        } catch {
            errorMessage = "Could not create ZIP: \(error.localizedDescription)"
        }
    }

    func refreshState() {
        status = engine.status()
        progress = engine.progress()
        currentFile = engine.currentFile()

        let engineError = engine.lastError()
        if !engineError.isEmpty {
            errorMessage = engineError
        }

        if status == "Download complete"
            || status == "Download failed"
            || status == "Download cancelled" {

            isBusy = false

            if status == "Download complete",
               let id = history.first,
               let index = library.firstIndex(where: { $0.id == id }) {
                library[index].updatedAt = Date()
                save(library, key: "library")
            }
        }
    }

    func cancel() {
        engine.cancelDownload()
    }

    private func downloadsRoot() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let root = docs.appendingPathComponent(
            "WorkshopDownloads",
            isDirectory: true
        )

        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        return root
    }

    static func workshopID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if !value.isEmpty && value.allSatisfy(\.isNumber) {
            return value
        }

        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              host == "steamcommunity.com"
                || host == "www.steamcommunity.com",
              components.path.contains("/sharedfiles/filedetails"),
              let id = components.queryItems?.first(where: {
                  $0.name == "id"
              })?.value,
              !id.isEmpty,
              id.allSatisfy(\.isNumber) else {
            return nil
        }

        return id
    }
}

struct ContentView: View {
    @StateObject private var store = WorkshopStore()
    @State private var selectedTab = 0

    @AppStorage("options.appearance")
    private var appearance = "system"

    @AppStorage("options.confirmDelete")
    private var confirmDelete = true

    @AppStorage("options.showIDs")
    private var showIDs = false

    @AppStorage("options.compactLibrary")
    private var compactLibrary = false

    @State private var pendingDelete: WorkshopItem?
    @State private var showDeleteConfirmation = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                Form {
                    Section("Workshop item") {
                        TextField(
                            "Workshop URL or item ID",
                            text: $store.workshopURL,
                            axis: .vertical
                        )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            store.download()
                        } label: {
                            Label(
                                "Download item",
                                systemImage: "arrow.down.circle.fill"
                            )
                        }
                        .disabled(store.isBusy || !store.isAuthenticated)

                        Text(
                            "Use an individual Workshop item URL. Collection links are not supported yet."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Section("Status") {
                        HStack {
                            Circle()
                                .fill(store.isAuthenticated ? .green : .gray)
                                .frame(width: 8, height: 8)

                            Text(store.status)

                            Spacer()

                            if store.isBusy {
                                Button("Cancel") {
                                    store.cancel()
                                }
                            }
                        }

                        if store.isBusy {
                            ProgressView(value: store.progress)

                            Text("\(Int(store.progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !store.currentFile.isEmpty {
                                Text(store.currentFile)
                                    .font(.caption2)
                                    .lineLimit(2)
                            }
                        }

                        if !store.errorMessage.isEmpty {
                            Text(store.errorMessage)
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }

                    Section("Steam account") {
                        if store.isAuthenticated {
                            Label(
                                "Signed in as \(store.username)",
                                systemImage: "checkmark.shield.fill"
                            )

                            Button("Sign out", role: .destructive) {
                                store.signOut()
                            }
                        } else {
                            TextField(
                                "Steam username",
                                text: $store.username
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            SecureField(
                                "Steam password",
                                text: $store.password
                            )

                            TextField(
                                "Steam Guard code, if requested",
                                text: $store.guardCode
                            )
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                            Button("Sign in to Steam") {
                                store.signIn()
                            }
                            .disabled(store.isBusy)

                            Text(
                                "Credentials are stored in iOS Keychain after successful sign-in. Guard codes are not saved."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Label(
                            "Downloads stay in this app's private storage.",
                            systemImage: "lock.fill"
                        )

                        Text(
                            "Steam may require ownership of the parent game. This unofficial app is not affiliated with Valve."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Download")
            }
            .tabItem {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tag(0)

            NavigationStack {
                List {
                    if store.library.isEmpty {
                        Text("No downloads yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.library) { item in
                        VStack(
                            alignment: .leading,
                            spacing: compactLibrary ? 4 : 8
                        ) {
                            Text(
                                showIDs
                                    ? "Workshop item \(item.id)"
                                    : "Downloaded mod"
                            )
                            .font(.headline)

                            Text(
                                "Last updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack {
                                Button("Update") {
                                    store.download(item.id, existing: item)
                                }
                                .disabled(
                                    store.isBusy || !store.isAuthenticated
                                )

                                Button("Export ZIP") {
                                    store.export(item)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    if confirmDelete {
                                        pendingDelete = item
                                        showDeleteConfirmation = true
                                    } else {
                                        store.remove(item)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, compactLibrary ? 0 : 4)
                    }
                }
                .navigationTitle("Library")
                .confirmationDialog(
                    "Remove this mod?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove from Library", role: .destructive) {
                        if let item = pendingDelete {
                            store.remove(item)
                        }
                        pendingDelete = nil
                    }

                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: {
                    Text(
                        "This removes the entry from your library, not the downloaded files."
                    )
                }
                .sheet(
                    item: Binding(
                        get: {
                            store.exportURL.map {
                                ExportFile(url: $0)
                            }
                        },
                        set: {
                            store.exportURL = $0?.url
                        }
                    )
                ) { file in
                    ShareSheet(url: file.url)
                }
            }
            .tabItem {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .tag(1)

            NavigationStack {
                List {
                    if store.history.isEmpty {
                        Text("No download history yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.history, id: \.self) { id in
                        HStack {
                            Text("Workshop item \(id)")

                            Spacer()

                            Button("Download again") {
                                store.workshopURL = id
                                selectedTab = 0
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }
                .navigationTitle("History")
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }
            .tag(2)

            NavigationStack {
                Form {
                    Section("Appearance") {
                        Picker("Theme", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }
                    }

                    Section("Library") {
                        Toggle(
                            "Confirm before deleting",
                            isOn: $confirmDelete
                        )

                        Toggle(
                            "Show Workshop IDs",
                            isOn: $showIDs
                        )

                        Toggle(
                            "Compact library",
                            isOn: $compactLibrary
                        )
                    }

                    Section("Storage & History") {
                        Button("Clear Download History", role: .destructive) {
                            store.clearHistory()
                        }

                        Button(
                            "Clear Temporary ZIP Exports",
                            role: .destructive
                        ) {
                            store.clearTemporaryExports()
                        }

                        Text(
                            "Clearing history does not delete downloaded mods. Clearing temporary exports may remove ZIP files created for sharing."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Section("About ModShelf") {
                        Label(
                            "Your Steam Workshop library, on iPhone.",
                            systemImage: "square.grid.2x2.fill"
                        )

                        Text("Unofficial app. Not affiliated with Valve.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Options")
            }
            .tabItem {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .tag(3)
        }
        .preferredColorScheme(
            appearance == "dark" ? .dark :
                appearance == "light" ? .light : nil
        )
    }
}

private struct ExportFile: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

private enum Keychain {
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shplash.workshopdownloader",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
        let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, key: String) {
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shplash.workshopdownloader",
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shplash.workshopdownloader",
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
