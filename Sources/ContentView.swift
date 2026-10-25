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
