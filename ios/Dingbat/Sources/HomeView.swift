import SwiftUI
import UniformTypeIdentifiers

/// Home screen mimicking the web UI: brand header, ROM library with
/// thumbnails, and a Files-app import button.
struct HomeView: View {
    @ObservedObject var library: RomLibrary
    let onPlay: (RomEntry) -> Void

    @State private var showImporter = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if library.entries.isEmpty {
                    emptyState
                } else {
                    romList
                }
                footer
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.gbaRom, .gbRom, .gbcRom, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.importRom(from: url)
            }
        }
        .alert("Import", isPresented: .init(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
                .shadow(color: Theme.accentGlow, radius: 6)
            Text("dingbat")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.text)
            Spacer()
            Text("GBA · GB · GBC")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textFaint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var romList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(library.entries) { entry in
                    romCard(entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func romCard(_ entry: RomEntry) -> some View {
        Button {
            onPlay(entry)
        } label: {
            HStack(spacing: 12) {
                thumbnail(entry)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(entry.system)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accentGlow.opacity(0.4))
                            .cornerRadius(4)
                        Text(entry.sizeText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textFaint)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textDim)
            }
            .padding(12)
            .background(Theme.surface1)
            .cornerRadius(11)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border, lineWidth: 1))
        }
        .contextMenu {
            Button(role: .destructive) {
                library.delete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func thumbnail(_ entry: RomEntry) -> some View {
        Group {
            if let ui = UIImage(contentsOfFile: entry.shotURL.path) {
                Image(uiImage: ui)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.stage
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textFaint)
                }
            }
        }
        .frame(width: 66, height: 44)
        .cornerRadius(6)
        .clipped()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "gamecontroller")
                .font(.system(size: 34))
                .foregroundColor(Theme.textFaint)
            Text("No ROMs yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textDim)
            Text("Import a .gba, .gb, or .gbc file")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textFaint)
            Spacer()
        }
    }

    private var footer: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add ROM")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(Theme.accentInk)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Theme.accent)
            .cornerRadius(11)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 8)
    }
}
