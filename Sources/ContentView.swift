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

struct WorkshopMetadata {
    var title: String?
    var id: String?
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

    var identifier: String { id }
}

struct ContentView: View {
    @State private var input: String = ""
    @State private var queue: [String] = []
    @State private var operationMessage: String = ""
    @State private var errorMessage: String = ""
    @State private var isBusy: Bool = false
    @State private var isAuthenticated: Bool = true
    @State private var showLogin: Bool = false
    @State private var browserURL: URL? = nil
    @State private var selectedTab: Int = 0

    static let openButtonScript = """
    (function(){
      function pageIDs(){
        var ids = [];
        function add(id){ if(id && /^\\d+$/.test(id) && ids.indexOf(id) === -1) ids.push(id); }

        var pageID = new URLSearchParams(location.search).get('id');
        if(pageID) add(pageID);

        var candidates = document.querySelectorAll('a[href*="/sharedfiles/filedetails/"], a[href*="/workshop/filedetails/"], a[href*="/sharedfiles/collection/"], a[href*="/workshop/collection/"]');
        for (var i=0;i<candidates.length;i++){
          var href = candidates[i].getAttribute('href') || '';
          var m = href.match(/[?&]id=(\\d+)/);
          if(m) add(m[1]);
        }

        var all = document.querySelectorAll('a,button');
        for (var i=0;i<all.length;i++){
          var text = (all[i].textContent || '').trim().toLowerCase();
          if (text === 'subscribe' || text === 'follow' || text === 'add to collection') {
            var href = all[i].getAttribute('href') || '';
            var m = href.match(/[?&]id=(\\d+)/);
            if(m) add(m[1]);
          }
        }

        return ids;
      }

      function addOpenButton(){
        if (document.getElementById('ms-open')) return;
        var ids = pageIDs();
        if (!ids.length) return;

        var target = null;
        var direct = document.getElementById('SubscribeItemBtn');
        if (direct) target = direct.closest('a,button') || direct;

        if (!target) {
          var els = Array.prototype.slice.call(document.querySelectorAll('a,button,span,div'));
          target = els.find(function(e){
            if (!e) return false;
            var t = (e.textContent || '').trim();
            return /^\\s*subscribe\\s*$/i.test(t) || /^\\s*follow\\s*$/i.test(t);
          });
        }

        if (!target) return;

        var holder = target.closest('a,button') || target;
        holder.style.setProperty('display','none','important');

        var b = document.createElement('a');
        b.id = 'ms-open';
        b.href = '#';
        b.innerHTML = '<span style="font-size:22px;font-weight:300;line-height:1;margin-right:12px">+</span><span style="line-height:1.2;white-space:nowrap">Download in<br>ModShelf</span>';
        b.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;box-sizing:border-box;width:100%;padding:10px 16px;margin-top:6px;background:#0A84FF;color:#fff;border:2px solid #000;border-radius:4px;font:600 14px -apple-system,sans-serif;white-space:nowrap;text-decoration:none;cursor:pointer';
        b.addEventListener('click', function(e){
          e.preventDefault();
          var ids = pageIDs();
          var payload = ids.length > 1 ? ids.join(',') : ids[0];
          if (payload) window.webkit.messageHandlers.modshelf.postMessage(payload);
        });
        holder.insertAdjacentElement('afterend', b);
      }

      addOpenButton();
      setTimeout(addOpenButton, 800);
      setTimeout(addOpenButton, 2000);
      new MutationObserver(addOpenButton).observe(document.body, { childList: true, subtree: true });
    })();
    """

    static func workshopID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "0" { return nil }
        if value.allSatisfy({ $0.isNumber }) { return value }

        let candidates = Self.workshopIDs(from: value)
        return candidates.first
    }

    static func workshopIDs(from input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rawItems = trimmed
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var ids: [String] = []
        var seen: Set<String> = []

        for raw in rawItems {
            if raw.allSatisfy({ $0.isNumber }) && raw != "0" {
                if !seen.contains(raw) {
                    seen.insert(raw)
                    ids.append(raw)
                }
                continue
            }

            guard let url = URLComponents(string: raw),
                  let host = url.host?.lowercased(),
                  host.contains("steamcommunity.com") || host.contains("steampowered.com")
            else {
                guard let parsed = URL(string: raw),
                      let comps = URLComponents(url: parsed, resolvingAgainstBase: false),
                      let host2 = comps.host?.lowercased(),
                      host2.contains("steamcommunity.com") || host2.contains("steampowered.com")
                else {
                    continue
                }

                guard let id = comps.queryItems?.first(where: { $0.name == "id" })?.value,
                      !id.isEmpty,
                      id.allSatisfy({ $0.isNumber }),
                      id != "0"
                else {
                    continue
                }

                if !seen.contains(id) {
                    seen.insert(id)
                    ids.append(id)
                }
                continue
            }

            guard let id = url.queryItems?.first(where: { $0.name == "id" })?.value,
                  !id.isEmpty,
                  id.allSatisfy({ $0.isNumber }),
                  id != "0"
            else {
                continue
            }

            if !seen.contains(id) {
                seen.insert(id)
                ids.append(id)
            }
        }

        return ids
    }

    func download(_ raw: String? = nil, meta override: WorkshopMetadata? = nil) {
        errorMessage = ""
        guard !isBusy else {
            errorMessage = "A download or sign-in is already running."
            return
        }
        guard isAuthenticated else {
            operationMessage = "Sign in to Steam to download this item."
            showLogin = true
            return
        }

        let ids = Self.workshopIDs(from: raw ?? input)
        if ids.count > 1 {
            queue.append(contentsOf: ids)
            operationMessage = "Queued \(ids.count) Workshop items."
            Haptics.tap()
            if !isBusy { startNextInQueue() }
            return
        }

        guard let id = Self.workshopID(from: raw ?? input) else {
            errorMessage = "Enter a valid Workshop URL or ID."
            return
        }

        // Existing download logic continues here in the real project.
        // This stub keeps the feature set usable without clobbering unrelated code.
        operationMessage = "Downloading Workshop item \(id)."
        Haptics.tap()
    }

    func startNextInQueue() {
        guard !queue.isEmpty, !isBusy else { return }
        isBusy = true
        let next = queue.removeFirst()
        operationMessage = "Downloading Workshop item \(next)."
        _ = Self.workshopID(from: next)
    }

    func onOpenInApp(_ raw: String) {
        let ids = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard !ids.isEmpty else { return }

        if ids.count > 1 {
            queue.append(contentsOf: ids)
            operationMessage = "Queued \(ids.count) Workshop items."
            Haptics.tap()
            if !isBusy { startNextInQueue() }
            return
        }

        openWorkshop(ids[0])
    }

    private func openWorkshop(_ id: String) {
        let ids = id
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard !ids.isEmpty else { return }

        if ids.count > 1 {
            queue.append(contentsOf: ids)
            operationMessage = "Queued \(ids.count) Workshop items."
            Haptics.tap()
            return
        }

        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(ids[0])") else { return }
        browserURL = url
        selectedTab = 1
    }

    var body: some View {
        VStack(spacing: 16) {
            TextField("Steam Workshop URL or ID", text: $input)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

            if !operationMessage.isEmpty {
                Text(operationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Download") {
                    download()
                }
                .buttonStyle(.borderedProminent)

                Button("Queue from input") {
                    let ids = Self.workshopIDs(from: input)
                    if ids.count > 1 {
                        queue.append(contentsOf: ids)
                        operationMessage = "Queued \(ids.count) Workshop items."
                    } else if let id = Self.workshopID(from: input) {
                        openWorkshop(id)
                    }
                }
                .buttonStyle(.bordered)
            }

            if !queue.isEmpty {
                Text("Queued: \(queue.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            BrowserView(url: $browserURL) { value in
                onOpenInApp(value)
            }
            .frame(minHeight: 420)
        }
        .padding()
    }
}

private struct BrowserView: UIViewRepresentable {
    @Binding var url: URL?
    let onOpenInApp: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = configuration.userContentController
        contentController.add(context.coordinator, name: "modshelf")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url else { return }
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenInApp: onOpenInApp)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onOpenInApp: (String) -> Void

        init(onOpenInApp: @escaping (String) -> Void) {
            self.onOpenInApp = onOpenInApp
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "modshelf" else { return }
            let raw = String(describing: message.body)
            let ids = raw
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)

            guard !ids.isEmpty else { return }

            if ids.count == 1 {
                onOpenInApp(ids[0])
                return
            }

            onOpenInApp(ids.joined(separator: ","))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = ContentView.openButtonScript
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

private enum Haptics {
    static func tap() {
        // No-op fallback for the lightweight project scaffold.
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
