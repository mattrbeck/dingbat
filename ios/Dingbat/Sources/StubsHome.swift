// PLACEHOLDER — replaced by the home-screen work (HomeView.swift etc.).
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: RomLibrary
    var body: some View {
        List(library.entries) { e in
            Button(e.name) { model.openLibraryGame(e) }
        }
    }
}

struct TileMenuView: View {
    let entry: RomEntry
    var body: some View { Text(entry.name) }
}

struct RenameView: View {
    let entry: RomEntry
    var body: some View { Text(entry.name) }
}
