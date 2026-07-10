import SwiftUI

@main
struct DingbatApp: App {
    @StateObject private var library = RomLibrary()
    @State private var current: RomEntry?

    /// Dev hook: `simctl launch booted com.mattrb.dingbat -autoplay [name]`
    /// jumps straight into the named (or first) library ROM, so headless
    /// tooling can exercise the play screen without synthesizing taps.
    private static func autoplayEntry(in library: RomLibrary) -> RomEntry? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-autoplay") else { return nil }
        let name = idx + 1 < args.count ? args[idx + 1] : nil
        if let name, let match = library.entries.first(where: { $0.name == name }) {
            return match
        }
        return library.entries.first
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let rom = current {
                    PlayView(rom: rom) {
                        current = nil
                        library.refresh()
                    }
                } else {
                    HomeView(library: library) { entry in
                        current = entry
                    }
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                if current == nil, let entry = Self.autoplayEntry(in: library) {
                    current = entry
                }
            }
        }
    }
}
